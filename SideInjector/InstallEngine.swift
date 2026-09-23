import Foundation
import Network
import Security
import Darwin
import UIKit

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
/// 代码出处（开源署名）：候选地址的枚举策略参考 FrizzleM/SideInstaller
///   —— https://github.com/FrizzleM/SideInstaller
///   许可：SideInstaller License（Copyright © 2026 FrizzleM，须署名，禁止商业使用）。
///   本文件改动：实际连接与安装走本项目 Rust core 的 `idevice`（MIT）实现，
///   本文件只负责候选枚举、超时控制与错误提示。
enum TunnelNet {
    /// 本机所有 IPv4 地址（含接口名）。
    static func allIPv4() -> [(name: String, ip: String)] {
        var out: [(name: String, ip: String)] = []
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
                        out.append((name, String(cString: buf)))
                    }
                }
                ptr = entry.ifa_next
            }
        }
        return out
    }

    /// VPN / 隧道类接口（loopback VPN 就是靠 utun 提供映射的）。
    static func isTunnelInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec")
            || name.hasPrefix("ppp") || name.hasPrefix("tap")
    }

    /// loopback VPN 的隧道接口及其地址；为空即表示 VPN 未连接。
    static func vpnInterfaces() -> [(name: String, ip: String)] {
        allIPv4().filter { isTunnelInterface($0.name) }
    }

    static func candidateHosts() -> [String] {
        let all = allIPv4()
        let tunnels = all.filter { isTunnelInterface($0.name) }.map(\.ip)
        let others = all.filter { !isTunnelInterface($0.name) }.map(\.ip)
        var seen = Set<String>()
        // VPN 隧道地址优先；再补几个常见映射地址与回环兜底。
        return (tunnels + others + ["10.7.0.1", "10.7.0.2", "127.0.0.1"])
            .filter { !$0.hasPrefix("169.254.") && seen.insert($0).inserted }
    }
}

/// 环境自检结果：安装排障最需要的几项。
struct EnvSnapshot {
    var osVersion = "?"
    var osBuild = "-"
    var selfPairCapable = false
    var vpnUp = false
    var vpnDetail = "未检测"
    var portLines: [String] = []
}

enum EnvProbe {
    /// iOS 版本 + build（如 18.5 / 22F76）。
    static func osInfo() -> (version: String, build: String) {
        let version = UIDevice.current.systemVersion
        var build = "-"
        var size = 0
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osversion", &buf, &size, nil, 0) == 0 {
                build = String(cString: buf)
            }
        }
        return (version, build)
    }

    /// iOS 27+ 支持设备端自配对，不需要 PC 生成的配对文件。
    static func isSelfPairCapable(_ version: String) -> Bool {
        (Int(version.split(separator: ".").first ?? "") ?? 0) >= 27
    }

    static func snapshot() -> EnvSnapshot {
        var s = EnvSnapshot()
        let os = osInfo()
        s.osVersion = os.version
        s.osBuild = os.build
        s.selfPairCapable = isSelfPairCapable(os.version)
        let vpn = TunnelNet.vpnInterfaces()
        s.vpnUp = !vpn.isEmpty
        s.vpnDetail = vpn.isEmpty
            ? "未发现 utun/ipsec/ppp/tap 隧道接口（请先打开 LocalDevVPN）"
            : vpn.map { "\($0.name) · \($0.ip)" }.joined(separator: "、")
        return s
    }
}

/// 设备端安装引擎 —— 走 **CoreDevice / RSD** 链路（iOS 17+ 的设备端安装通道）。
///
/// 实测结论（App 内端口探测）：设备自身只有 **RSD 49152** 可连；
/// lockdownd 62078 / usbmuxd 27015 在回环、VPN 地址、WiFi 地址上全部超时，
/// 因此经典 lockdownd 方案已废弃。
///
/// 真正的安装由 Rust core（`idevice` crate，MIT 许可）完成：
///   TcpStream(127.0.0.1:49152) → RsdHandshake → AFC 上传 /PublicStaging
///     → installation_proxy 安装（PackageType=Developer，带真实进度）。
/// 本类只负责启动它并按轮询上报进度。
final class InstallEngine {
    static let shared = InstallEngine()

    /// lockdownd 固定端口。
    private let lockdownPort: UInt16 = 62078

    /// 实际跑通的隧道端点（多候选探测成功后记录，后续服务连接沿用）。
    private var tunnelHost = "127.0.0.1"

    /// 安装并**逐步上报真实进度**（0…1）。
    ///
    /// 设备端安装由 Rust core 走 **CoreDevice / RSD 链路**（AFC 上传到 `/PublicStaging`
    /// + installation_proxy 安装，PackageType=Developer），这里只负责：
    ///   1. 在后台线程调用阻塞的 `si_install_ipa`；
    ///   2. 轮询 `si_install_progress` 把真实进度喂给 UI。
    /// 只有 installd 真正返回成功（FFI 返回 0）才算完成——绝不以进度值判定成功。
    func install(ipaPath: String,
                 pairingURL: URL?,
                 onProgress: @escaping (Double, String) -> Void) async -> InstallResult {
        LogStore.shared.append("install: 走 CoreDevice/RSD 链路（127.0.0.1:49152）")

        final class InstallState { var done = false; var rc: Int32 = -1 }
        let state = InstallState()
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = RustBridge.shared.install(ipa: ipaPath)
            DispatchQueue.main.async {
                state.rc = rc
                state.done = true
            }
        }

        // 必须显式写成 Int32：si_install_progress() 返回 Int32，
        // 用 `-2` 字面量会让编译器推断成 Int，后面 `lastPercent = p` 就编译不过。
        var lastPercent: Int32 = -2
        while !state.done {
            if Task.isCancelled { break }
            let p = RustBridge.shared.installProgress()
            if p != lastPercent {
                lastPercent = p
                if p >= 0 {
                    let frac = min(max(Double(p) / 100.0, 0), 1)
                    let text = p >= 100 ? "安装完成" : "安装中：\(p)%"
                    DispatchQueue.main.async { onProgress(frac, text) }
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        if state.rc == 0 {
            return .init(ok: true, message: "安装成功")
        }
        return .init(ok: false,
                     message: "设备端安装失败：详见日志里的 `install error: …`（下一步据此定位）")
    }

    // MARK: - 环境检测

    /// 检测本地回环隧道是否可用（绿/红）。
    /// 探测：连接 lockdownd → QueryType 握手 → 试探 StartSession(nil) 判断是否支持设备端自配对。
    ///
    /// 注意：这条隧道依赖 **loopback VPN**（StosVPN / SideStore 的 VPN 描述文件）——
    /// 它把本设备自身的 lockdownd/CoreDevice 暴露到某个本地地址上；没有它任何地址都连不通。
    func diagnose() async -> TunnelStatus {
        for line in await probePorts() {
            LogStore.shared.append("tunnel-probe: \(line)")
        }
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

    /// 探测各候选地址上「回环隧道」实际开放的端口 —— 用来判断 VPN 路由是否生效、
    /// 以及该走哪条协议路径。三个端口对应三种机制：
    ///   62078  经典 lockdownd（直接连通常不通：经典路径要先经 usbmuxd 转发）
    ///   27015  usbmuxd（libimobiledevice / idevice 的入口，经它转发到 62078）
    ///   49152  CoreDevice / RSD（iOS 17+ 现代路径，需远程配对或配对记录）
    /// 全部并发探测，每个 2 秒超时，总耗时约 2 秒。
    func probePorts() async -> [String] {
        let hosts = Array(TunnelNet.candidateHosts().prefix(4))
        var targets: [(name: String, host: String, port: UInt16)] = []
        for h in hosts {
            targets.append(("lockdownd", h, 62078))
            targets.append(("usbmuxd", h, 27015))
            targets.append(("RSD", h, 49152))
        }
        return await withTaskGroup(of: (Int, String).self) { group in
            for (idx, t) in targets.enumerated() {
                group.addTask {
                    do {
                        let c = try await withTimeout(seconds: 2) {
                            try await connectTLS(host: t.host, port: t.port, ssl: false)
                        }
                        c.cancel()
                        return (idx, "✅ \(t.host):\(t.port)（\(t.name)）可连接")
                    } catch {
                        return (idx, "❌ \(t.host):\(t.port)（\(t.name)）：\(error.localizedDescription)")
                    }
                }
            }
            var out: [(Int, String)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
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
