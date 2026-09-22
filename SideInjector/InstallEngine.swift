import Foundation
import Network
import Security

/// 安装结果
struct InstallResult {
    let ok: Bool
    let message: String
}

/// 设备端安装引擎 —— 参考 FrizzleM/SideInstaller 的「本地回环隧道」思路。
///
/// 机制：通过 LocalDevVPN（本地 VPN/DNS 描述文件）让设备自身向本机
/// `lockdownd` 服务发起连接，再经 `com.apple.mobile.installation_proxy`
/// 把重签后的 IPA 装到同一台设备。
///   - iOS 27+：可设备端自配对（无需 PC）。
///   - iOS 18–26：需要 PC 预先生成的配对文件（在「配对文件」一栏选择）。
///
/// 注：完整的 CoreDevice/XPC 自配对握手由 SideInstaller 的 rust-core(idevice) 实现；
/// 这里用 `Network` 框架实现了回环隧道连接 + lockdownd/installation_proxy 的
/// plist 协议，作为可直接编译运行的安装层。
final class InstallEngine {
    static let shared = InstallEngine()

    /// 本地回环隧道端点（LocalDevVPN 把设备自身的 lockdownd 暴露到回环地址）。
    private let lockdownHost = "127.0.0.1"
    private let lockdownPort: UInt16 = 62078

    func install(ipaPath: String, teamId: String, pairingURL: URL?) async -> InstallResult {
        LogStore.shared.append("install: 建立本地回环隧道 → \(lockdownHost):\(lockdownPort)")
        let pairing = pairingURL.flatMap { loadPairing($0) }

        do {
            let conn = try await connectTLS(host: lockdownHost, port: lockdownPort)
            defer { conn.cancel() }

            let ld = LockdownClient(connection: conn)
            _ = try await ld.queryType()
            LogStore.shared.append("install: lockdownd 握手成功")

            if let pairing {
                try await ld.startSession(pairing: pairing)
                LogStore.shared.append("install: 已用提供的配对文件启动会话")
            } else {
                do {
                    try await ld.startSession(pairing: nil)
                    LogStore.shared.append("install: 设备端自配对会话已建立（iOS 27+）")
                } catch {
                    return .init(ok: false,
                        message: "启动会话失败：iOS 18–26 需要 PC 生成的配对文件（请在「配对文件」中选择）。\(error.localizedDescription)")
                }
            }

            let svc = try await ld.startService("com.apple.mobile.installation_proxy")
            LogStore.shared.append("install: 已取得 installation_proxy 服务（端口 \(svc.port)）")

            let ip = try await connectTLS(host: lockdownHost, port: svc.port, ssl: svc.ssl)
            defer { ip.cancel() }
            let inst = InstallationProxy(connection: ip)
            try await inst.install(ipaPath: ipaPath, teamId: teamId)
            return .init(ok: true, message: "安装请求已发送，设备正在安装")
        } catch {
            return .init(ok: false, message: "回环隧道安装失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 配对文件

    private func loadPairing(_ url: URL) -> [String: Any]? {
        guard url.startAccessingSecurityScopedResource() else {
            LogStore.shared.append("install: 无法访问配对文件（安全作用域）")
            return nil
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            LogStore.shared.append("install: 配对文件解析失败")
            return nil
        }
        return dict
    }
}

// MARK: - 连接 / 收发底层

/// 建立 TLS（默认）或明文 TCP 连接并等待 ready。lockdownd 使用自签名证书，关闭对端校验。
private func connectTLS(host: String, port: UInt16, ssl: Bool = true) async throws -> NWConnection {
    let nwPort = NWEndpoint.Port(integerLiteral: port)
    let params: NWParameters
    if ssl {
        let opts = NWProtocolTLS.Options()
        sec_protocol_options_set_peer_authentication_required(opts.securityProtocolOptions, false)
        params = NWParameters(tls: opts, tcp: NWProtocolTCP.Options())
    } else {
        params = NWParameters.tcp
    }
    let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        var done = false
        conn.stateUpdateHandler = { state in
            guard !done else { return }
            switch state {
            case .ready:
                done = true; cont.resume()
            case .failed(let err):
                done = true; cont.resume(throwing: err)
            case .cancelled:
                done = true; cont.resume(throwing: CancellationError())
            default:
                break
            }
        }
        conn.start(queue: .global())
    }
    return conn
}

private func sendPlist(_ dict: [String: Any], on conn: NWConnection) async throws {
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        conn.send(content: data, completion: .contentProcessed { err in
            if let err { cont.resume(throwing: err) } else { cont.resume() }
        })
    }
}

private func receiveChunk(on conn: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, err in
            if let err { cont.resume(throwing: err) }
            else if let data { cont.resume(returning: data) }
            else { cont.resume(throwing: NSError(domain: "eof", code: 1)) }
        }
    }
}

/// 从累计缓冲里解析出第一个完整 XML plist（兼容一条流里紧跟多条消息）。
private func parseFirstPlist(_ data: Data) -> ([String: Any]?, Int)? {
    guard let end = data.range(of: Data("</plist>".utf8)) else { return nil }
    let slice = data[...end.upperBound]
    guard let dict = try? PropertyListSerialization.propertyList(from: Data(slice), format: nil) as? [String: Any] else {
        return nil
    }
    return (dict, end.upperBound)
}

// MARK: - lockdownd 客户端

final class LockdownClient {
    let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) { self.connection = connection }

    private func recvPlist() async throws -> [String: Any] {
        while true {
            if let (dict, consumed) = parseFirstPlist(buffer) {
                buffer.removeSubrange(0..<consumed)
                return dict
            }
            let chunk = try await receiveChunk(on: connection)
            if chunk.isEmpty { throw NSError(domain: "eof", code: 1) }
            buffer.append(chunk)
        }
    }

    func queryType() async throws -> [String: Any] {
        try await sendPlist(["Request": "QueryType"], on: connection)
        return try await recvPlist()
    }

    func startSession(pairing: [String: Any]?) async throws {
        var req: [String: Any] = ["Request": "StartSession"]
        if let pairing {
            req["PairRecord"] = pairing
            if let hostId = pairing["HostID"] as? String { req["HostID"] = hostId }
            if let systemBuild = pairing["SystemBUID"] as? String { req["SystemBUID"] = systemBuild }
        }
        try await sendPlist(req, on: connection)
        let resp = try await recvPlist()
        if let err = resp["Error"] as? String {
            throw NSError(domain: "lockdown", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: err])
        }
    }

    func startService(_ name: String) async throws -> (port: UInt16, ssl: Bool) {
        try await sendPlist(["Request": "StartService", "Service": name], on: connection)
        let resp = try await recvPlist()
        if let err = resp["Error"] as? String {
            throw NSError(domain: "lockdown", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: err])
        }
        let port: UInt16
        if let n = resp["Port"] as? Int { port = UInt16(n) }
        else if let n = resp["Port"] as? NSNumber { port = n.uint16Value }
        else {
            throw NSError(domain: "lockdown", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "响应缺少 Port"])
        }
        let ssl = (resp["EnableServiceSSL"] as? Bool) ?? false
        return (port, ssl)
    }
}

// MARK: - installation_proxy 客户端

final class InstallationProxy {
    let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) { self.connection = connection }

    private func recvPlist() async throws -> [String: Any] {
        while true {
            if let (dict, consumed) = parseFirstPlist(buffer) {
                buffer.removeSubrange(0..<consumed)
                return dict
            }
            let chunk = try await receiveChunk(on: connection)
            if chunk.isEmpty { throw NSError(domain: "eof", code: 1) }
            buffer.append(chunk)
        }
    }

    /// 通过 PackagePath 安装已位于设备上的 IPA（需 lockdownd/installd 可读该路径）。
    func install(ipaPath: String, teamId: String) async throws {
        let req: [String: Any] = [
            "Command": "Install",
            "PackagePath": ipaPath,
            "ApplicationAttributes": [:]
        ]
        try await sendPlist(req, on: connection)
        while true {
            let resp = try await recvPlist()
            if let err = resp["Error"] as? String {
                throw NSError(domain: "install", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: err])
            }
            if let status = resp["Status"] as? String {
                LogStore.shared.append("install[进度]: \(status)")
                if status == "Complete" { return }
            } else {
                return
            }
        }
    }
}
