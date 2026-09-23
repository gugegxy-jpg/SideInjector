import Foundation
import Network
import Security
import Darwin

/// 安装结果
struct InstallResult {
    let ok: Bool
    let message: String
}

/// 本地回环隧道健康状态（绿/红）
struct TunnelStatus {
    let ok: Bool              // true = 绿（隧道可达且 lockdownd 握手成功）
    let message: String
    let deviceClass: String?  // lockdownd 返回的 Type，如 com.apple.mobile.lockdown
    let selfPair: Bool?       // 是否支持设备端自配对（nil = 未探测）
}

/// 给异步操作加超时，避免探测时卡死在连接等待上。
func withTimeout<T>(seconds: Double, _ body: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NSError(domain: "timeout", code: 1, userInfo: [NSLocalizedDescriptionKey: "连接超时"])
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw NSError(domain: "timeout", code: 2) }
        return result
    }
}

/// 枚举本机 IPv4 候选地址，用来定位「loopback VPN」把设备自身暴露出来的那个端点。
///
/// 为什么不能写死 127.0.0.1：不同 loopback VPN 映射到的地址并不固定
/// （StosVPN 常见 10.7.0.1，也有 10.7.0.2 等），写死回环地址会直接连接超时。
/// 参考 SideInstaller 的做法：把 RSD 地址、回环、以及各本地接口地址一起作为候选，
/// 在一个统一超时内逐个尝试。
enum TunnelNet {
    static func candidateHosts() -> [String] {
        var tunnels: [String] = []   // utun/ipsec/ppp/tap 等 VPN 隧道接口
        var others: [String] = []    // en0/lo0 等普通接口
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = ptr {
                let entry = cur.pointee
                if let sa = entry.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: entry.ifa_name)
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                   &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: buf)
                        if name.hasPrefix("utun") || name.hasPrefix("ipsec")
                            || name.hasPrefix("ppp") || name.hasPrefix("tap") {
                            tunnels.append(ip)
                        } else {
                            others.append(ip)
                        }
                    }
                }
                ptr = entry.ifa_next
            }
        }
        var seen = Set<String>()
        // VPN 隧道地址优先；再补几个常见映射地址与回环兜底。
        return (tunnels + others + ["10.7.0.1", "10.7.0.2", "127.0.0.1"])
            .filter { !$0.hasPrefix("169.254.") && seen.insert($0).inserted }
    }
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

    /// lockdownd 固定端口。
    private let lockdownPort: UInt16 = 62078

    /// 实际跑通的隧道端点（多候选探测成功后记录，后续服务连接沿用）。
    private var tunnelHost = "127.0.0.1"

    /// 安装并**逐步上报真实进度**（0…1）。
    /// 只有 installd 真正返回 Complete 才算成功——绝不以进度值判定成功。
    func install(ipaPath: String,
                 pairingURL: URL?,
                 onProgress: @escaping (Double, String) -> Void) async -> InstallResult {
        let candidates = TunnelNet.candidateHosts()
        LogStore.shared.append("install: 探测本地回环隧道端点（候选：\(candidates.joined(separator: "、"))）")
        let pairing = pairingURL.flatMap { loadPairing($0) }

        do {
            // 逐个候选尝试：loopback VPN 把设备自身的 lockdownd 暴露在某个本地地址上，
            // 具体是哪个地址随 VPN 实现而变 —— 写死 127.0.0.1 就会直接连接超时。
            var locked: NWConnection?
            var lastErr: Error?
            for host in candidates {
                do {
                    let c = try await withTimeout(seconds: 3) {
                        try await connectTLS(host: host, port: self.lockdownPort)
                    }
                    locked = c
                    self.tunnelHost = host
                    LogStore.shared.append("install: 隧道端点 \(host):\(self.lockdownPort) 已连通")
                    break
                } catch {
                    lastErr = error
                    LogStore.shared.append("install: 端点 \(host) 无响应（\(error.localizedDescription)）")
                }
            }
            guard let conn = locked else {
                return .init(ok: false, message: """
                回环隧道安装失败：候选端点都连不上（\(candidates.joined(separator: "、"))）。
                请先安装并开启 loopback VPN（StosVPN / SideStore 的 VPN 描述文件）—— 它的作用就是把本设备自身的 lockdownd/CoreDevice 暴露到本地地址，没有它任何地址都连不通。
                也可改用「分享已签名 IPA」，交给 AltStore / SideStore 安装。
                最后错误：\(lastErr?.localizedDescription ?? "未知")
                """)
            }
            defer { conn.cancel() }

            let ld = LockdownClient(connection: conn)
            _ = try await withTimeout(seconds: 6) { try await ld.queryType() }
            LogStore.shared.append("install: lockdownd 握手成功")

            if let pairing {
                try await withTimeout(seconds: 10) { try await ld.startSession(pairing: pairing) }
                LogStore.shared.append("install: 已用提供的配对文件启动会话")
            } else {
                do {
                    try await withTimeout(seconds: 10) { try await ld.startSession(pairing: nil) }
                    LogStore.shared.append("install: 设备端自配对会话已建立（iOS 27+）")
                } catch {
                    return .init(ok: false,
                        message: "启动会话失败：iOS 18–26 需要 PC 生成的配对文件（请在「配对文件」中选择）。\(error.localizedDescription)")
                }
            }

            let svc = try await withTimeout(seconds: 10) {
                try await ld.startService("com.apple.mobile.installation_proxy")
            }
            LogStore.shared.append("install: 已取得 installation_proxy 服务（端口 \(svc.port)）")

            let ip = try await withTimeout(seconds: 10) {
                try await connectTLS(host: self.tunnelHost, port: svc.port, ssl: svc.ssl)
            }
            defer { ip.cancel() }
            let inst = InstallationProxy(connection: ip)
            // 安装本身可能较慢，给足超时；一旦卡住即抛错 → 主流程暂停并允许「继续」。
            try await withTimeout(seconds: 300) {
                try await inst.install(ipaPath: ipaPath) { frac, status in
                    DispatchQueue.main.async { onProgress(frac, "安装中：\(status)") }
                }
            }
            return .init(ok: true, message: "安装成功")
        } catch {
            return .init(ok: false, message: "回环隧道安装失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 环境检测

    /// 检测本地回环隧道是否可用（绿/红）。
    /// 探测：连接 lockdownd → QueryType 握手 → 试探 StartSession(nil) 判断是否支持设备端自配对。
    ///
    /// 注意：这条隧道依赖 **loopback VPN**（StosVPN / SideStore 的 VPN 描述文件）——
    /// 它把本设备自身的 lockdownd/CoreDevice 暴露到某个本地地址上；没有它任何地址都连不通。
    func diagnose() async -> TunnelStatus {
        let candidates = TunnelNet.candidateHosts()
        var found: NWConnection?
        var lastErr: Error?
        for host in candidates {
            do {
                let c = try await withTimeout(seconds: 3) {
                    try await connectTLS(host: host, port: self.lockdownPort)
                }
                found = c
                self.tunnelHost = host
                break
            } catch {
                lastErr = error
            }
        }
        guard let conn = found else {
            return TunnelStatus(ok: false,
                                message: "候选端点都连不上（\(candidates.joined(separator: "、"))）：请先安装并开启 loopback VPN（StosVPN / SideStore 的 VPN 描述文件），它负责把本设备自身的 lockdownd/CoreDevice 暴露到本地地址。最后错误：\(lastErr?.localizedDescription ?? "未知")",
                                deviceClass: nil, selfPair: nil)
        }
        defer { conn.cancel() }
        let ld = LockdownClient(connection: conn)
        let resp: [String: Any]
        do {
            resp = try await withTimeout(seconds: 3) { try await ld.queryType() }
        } catch {
            return TunnelStatus(ok: false,
                                message: "端点可连通，但 lockdownd 无响应（端口 \(lockdownPort)）：请确认 loopback VPN 仍在运行；也可点「分享已签名 IPA」用 AltStore/SideStore 手动安装。",
                                deviceClass: nil, selfPair: nil)
        }
        let deviceClass = resp["Type"] as? String
        var selfPair: Bool? = nil
        do {
            try await withTimeout(seconds: 3) { try await ld.startSession(pairing: nil) }
            selfPair = true
        } catch {
            selfPair = false
        }
        let extra = selfPair == true ? "（支持设备端自配对，iOS 27+）"
                    : (selfPair == false ? "（需 PC 配对文件，iOS 18–26）" : "")
        return TunnelStatus(ok: true, message: "本地回环隧道已连通\(extra)",
                            deviceClass: deviceClass, selfPair: selfPair)
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
    try await withTaskCancellationHandler {
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
    } onCancel: {
        conn.cancel()
    }
    return conn
}

private func sendPlist(_ dict: [String: Any], on conn: NWConnection) async throws {
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    } onCancel: {
        conn.cancel()
    }
}

private func receiveChunk(on conn: NWConnection) async throws -> Data {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, err in
                if let err { cont.resume(throwing: err) }
                else if let data { cont.resume(returning: data) }
                else { cont.resume(throwing: NSError(domain: "eof", code: 1)) }
            }
        }
    } onCancel: {
        conn.cancel()
    }
}

/// 从累计缓冲里解析出第一个完整 XML plist（兼容一条流里紧跟多条消息）。
private func parseFirstPlist(_ data: Data) -> ([String: Any], Int)? {
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

    /// 通过 PackagePath 安装（需 lockdownd/installd 可读该路径）。
    /// 成功判据是**看到 Status == "Complete"**；任何 Error 或流中断都视为失败。
    func install(ipaPath: String, onProgress: @escaping (Double, String) -> Void) async throws {
        let req: [String: Any] = [
            "Command": "Install",
            "PackagePath": ipaPath,
            // 必须带 PackageType=Developer，否则 installd 不读内嵌描述文件，
            // 会在 VerifyingApplication 阶段以 0xe8008015 拒绝。
            "ClientOptions": ["PackageType": "Developer"]
        ]
        try await sendPlist(req, on: connection)
        while true {
            let resp = try await recvPlist()
            if let err = resp["Error"] as? String {
                let desc = (resp["ErrorDescription"] as? String)
                    ?? (resp["ErrorDetail"] as? String) ?? ""
                throw NSError(domain: "install", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: desc.isEmpty ? err : "\(err)：\(desc)"])
            }
            guard let status = resp["Status"] as? String else {
                throw NSError(domain: "install", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "安装流意外结束（未收到 Complete）"])
            }
            let pct = (resp["PercentComplete"] as? NSNumber)?.doubleValue
            onProgress(Self.fraction(status: status, percent: pct), status)
            LogStore.shared.append("install[进度]: \(status)\(pct.map { " \(Int($0))%" } ?? "")")
            if status == "Complete" { return }
        }
    }

    /// installd 各阶段 → 进度分数（0…1）。
    private static func fraction(status: String, percent: Double?) -> Double {
        func p() -> Double { percent.map { min(max($0, 0), 100) / 100 } ?? 0 }
        switch status {
        case "CreatingStagingDirectory": return 0.05
        case "ExtractingPackage":        return 0.15
        case "InspectingPackage":        return 0.30
        case "TakingInstallLock":        return 0.35
        case "PreflightingApplication":  return 0.40
        case "VerifyingApplication":     return 0.55
        case "InstallingApplication":    return percent.map { 0.55 + 0.35 * min(max($0, 0), 100) / 100 } ?? 0.70
        case "PostInstallation":         return 0.92
        case "InstallationComplete", "Complete": return 1.0
        default:                         return percent != nil ? p() : 0.10
        }
    }
}
