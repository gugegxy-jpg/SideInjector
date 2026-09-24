import Foundation
import Combine
import Network

/// 设备端自配对控制器：启动 Rust 配对主机 + Bonjour 广播 + PIN 展示 + 完成检测。
///
/// 代码出处（开源署名）：参考 FrizzleM/SideInstaller 的 `PairingController` / `PairingManager`
///   —— https://github.com/FrizzleM/SideInstaller
///   许可：SideInstaller License（Copyright © 2026 FrizzleM）：允许使用 / 修改 / 以源码形式
///   再分发（须署名 "SideInstaller by FrizzleM"、附许可并标明修改）；禁止商业使用；
///   禁止再分发其官方构建 / IPA。
///   本文件改动：状态一律取自 Rust 侧（si_pairing_* 轮询），并增加了 Network 权限探测与
///   配对文件持久化路径。
final class PairingController: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = PairingController()

    @Published var status: String = "未配对"
    @Published var pin: String?
    @Published var pairedDeviceName: String?
    @Published var pairingFilePath: String?
    @Published var isPairing = false

    private var netService: NetService?
    private var permissionProbe: NWBrowser?
    private var pollTask: Task<Void, Never>?
    private let pairingPath: String

    private override init() {
        // 放在 Application Support（持久）而非 tmp：这样才能做到
        // 「下次使用若检测到已配对，就不再重新配对」。
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        pairingPath = base.appendingPathComponent("rp_pairing.plist").path
        // 若上次已配对过，恢复状态
        if FileManager.default.fileExists(atPath: pairingPath),
           let size = try? FileManager.default.attributesOfItem(atPath: pairingPath)[.size] as? Int,
           size > 0 {
            pairingFilePath = pairingPath
            status = "已有配对文件"
        }
    }

    func startPairing() {
        guard !isPairing else { return }
        isPairing = true
        pin = nil
        pairedDeviceName = nil
        // 配对期间必须保持进程存活：用户要切到「设置 → 开发者 → 配对」，
        // 若 App 被系统挂起，Bonjour 注册会随之失效，设备就搜不到本 App。
        KeepAlive.shared.start()
        setStatus("正在请求「本地网络」权限，请点「允许」弹窗…")
        // 主动触发本地网络授权弹窗（NetService.publish 在部分 iOS 版本上不一定弹窗）
        requestLocalNetworkPermission()

        let rc = RustBridge.shared.pairingStart(outPath: pairingPath)
        if rc != 0 {
            setStatus("启动配对失败")
            stopPairing()
            return
        }

        pollTask = Task.detached { [weak self] in
            guard let self else { return }
            var advertisedPort: Int32 = 0
            var lastPin: String?
            while !Task.isCancelled {
                let st = RustBridge.shared.pairingStatus()
                if st == 1 {
                    self.finishSuccess(deviceName: RustBridge.shared.pairingDeviceName())
                    return
                } else if st == -1 {
                    self.finishError(RustBridge.shared.pairingError())
                    return
                }
                if advertisedPort == 0 {
                    let port = RustBridge.shared.pairingServicePort()
                    if port > 0 {
                        advertisedPort = port
                        DispatchQueue.main.async { self.advertise(port: port) }
                    }
                }
                if let p = RustBridge.shared.pairingPIN(), p != lastPin {
                    lastPin = p
                    self.setPin(p)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stopPairing() {
        pollTask?.cancel()
        pollTask = nil
        stopAdvertising()
        permissionProbe?.cancel()
        permissionProbe = nil
        KeepAlive.shared.stop()
        isPairing = false
    }

    /// 主动触发 iOS 的「本地网络」授权弹窗。
    /// 系统只在 App 首次进行本地网络 I/O（Bonjour 浏览/广播）时弹窗；
    /// NetService.publish() 在某些 iOS 版本上不一定可靠，这里用 NWBrowser 显式浏览本机
    /// Bonjour 服务来确保弹窗出现。浏览本身不影响配对，仅用于触发授权。
    /// 注意：NWBrowser 的 type 必须是「不带末尾点」的形式（与 NSBonjourServices 一致），
    /// NetService 才需要带末尾点的完整类型。
    func requestLocalNetworkPermission() {
        permissionProbe?.cancel()
        // includePeerToPeer 允许经 AWDL 等点对点发现，提升触发/发现的成功率（与参考实现一致）。
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_remotepairing-pairable-host._tcp", domain: "local."),
            using: params
        )
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                // 失败即收工（下面的分支会给出原因）。
                self?.cancelPermissionProbe()
            }
            if case let .failed(error) = state {
                // -65555（kDNSServiceErr_NoAuth）表示本地网络权限未授予：
                // iOS 在缺少 NSLocalNetworkUsageDescription / NSBonjourServices 时
                // 会直接拒绝且「不弹窗」，因此务必确认打包用的 Info.plist 含这两个键。
                Task { @MainActor in
                    let ns = error as NSError
                    if ns.code == -65555 {
                        self?.status = "本地网络未授权（NoAuth）：请到 设置 → 隐私与安全性 → 本地网络 打开 SideInjector；若列表里没有本 App，说明当前 IPA 的 Info.plist 缺少 NSLocalNetworkUsageDescription / NSBonjourServices，请删除后重装最新构建"
                    } else if ns.domain == "NWErrorDomain" && ns.code == 1 {
                        self?.status = "本地网络权限被拒绝：请到 设置 → SideInjector → 本地网络 打开，再重试配对"
                    } else {
                        // 其它错误（如 -65569 DefunctConnection）多为 mDNS 探测的瞬时错误，
                        // 探测本身只为触发授权，不影响真实配对流程：只记日志，不覆盖配对状态。
                        LogStore.shared.append("本地网络探测失败（仅用于触发授权，已忽略）：\(error.localizedDescription)")
                    }
                }
            }
        }
        browser.start(queue: .main)
        permissionProbe = browser
    }

    /// 收工：取消「本地网络授权探测」的那次 Bonjour 浏览。
    ///
    /// 那个浏览只有一个目的 —— 触发系统的「本地网络」授权弹窗；触发完没必要常驻，
    /// 否则它会一直做 mDNS 浏览，空闲时持续唤醒网卡（费电）。
    /// 调用点：离开配对卡片时、探测失败时、配对流程结束 / 取消时。
    func cancelPermissionProbe() {
        permissionProbe?.cancel()
        permissionProbe = nil
    }

    private func advertise(port: Int32) {
        stopAdvertising()
        let serviceID = RustBridge.shared.pairingServiceIdentifier() ?? "SideInjector"
        var txt: [String: Data] = [:]
        if let json = RustBridge.shared.pairingTxtJSON(),
           let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String]] {
            for pair in arr where pair.count == 2 {
                txt[pair[0]] = Data(pair[1].utf8)
            }
        }
        let service = NetService(domain: "", type: "_remotepairing-pairable-host._tcp.",
                                 name: serviceID, port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.delegate = self
        service.publish()
        netService = service
        LogStore.shared.append("开始广播 Bonjour：name=\(serviceID) port=\(port) TXT=\(txt.count) 项")
        setStatus("正在广播，请在本机打开 设置 → 开发者 → 配对，选择「SideInjector」并输入上方配对码（若没有「开发者」菜单，请先到 设置 → 隐私与安全性 → 开发者模式 开启；并允许本 App 的「本地网络」权限）")
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        LogStore.shared.append("Bonjour 广播成功：\(sender.name) @\(sender.port) 域 \(sender.domain)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        LogStore.shared.append("Bonjour 广播失败：code=\(code) \(errorDict)")
        setStatus("Bonjour 广播失败（code=\(code)）：请确认已连接 Wi‑Fi 且本地网络权限已开启")
    }

    func netServiceDidStop(_ sender: NetService) {
        LogStore.shared.append("Bonjour 广播已停止")
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    private func finishSuccess(deviceName: String?) {
        DispatchQueue.main.async {
            self.stopAdvertising()
            self.permissionProbe?.cancel()
            self.permissionProbe = nil
            KeepAlive.shared.stop()
            self.pairedDeviceName = deviceName
            self.pairingFilePath = self.pairingPath
            self.pin = nil
            self.status = "已配对：\(deviceName ?? "设备")"
            self.isPairing = false
            // 若主流程正卡在「设备配对」阶段，配对完成后自动续跑。
            Model.shared.resume()
        }
    }

    private func finishError(_ msg: String?) {
        DispatchQueue.main.async {
            self.stopAdvertising()
            self.permissionProbe?.cancel()
            self.permissionProbe = nil
            KeepAlive.shared.stop()
            self.pin = nil
            self.status = "配对失败：\(msg ?? "未知错误")"
            self.isPairing = false
        }
    }

    private func setPin(_ p: String) {
        DispatchQueue.main.async {
            self.pin = p
            self.status = "请输入配对码"
        }
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }
}
