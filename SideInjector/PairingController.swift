import Foundation
import Combine

/// 设备端自配对控制器：启动 Rust 配对主机 + Bonjour 广播 + PIN 展示 + 完成检测。
/// 参考 SideInstaller 的 PairingController / PairingManager。
final class PairingController: ObservableObject {
    static let shared = PairingController()

    @Published var status: String = "未配对"
    @Published var pin: String?
    @Published var pairedDeviceName: String?
    @Published var pairingFilePath: String?
    @Published var isPairing = false

    private var netService: NetService?
    private var pollTask: Task<Void, Never>?
    private let pairingPath: String

    private init() {
        let dir = FileManager.default.temporaryDirectory
        pairingPath = dir.appendingPathComponent("rp_pairing.plist").path
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
        setStatus("请求本地网络权限…")

        let rc = RustBridge.shared.pairingStart(outPath: pairingPath)
        if rc != 0 {
            setStatus("启动配对失败")
            isPairing = false
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
        isPairing = false
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
        service.publish()
        netService = service
        setStatus("正在广播，请到 设置 → 隐私与安全性 → 开发者模式 完成配对")
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    private func finishSuccess(deviceName: String?) {
        DispatchQueue.main.async {
            self.stopAdvertising()
            self.pairedDeviceName = deviceName
            self.pairingFilePath = self.pairingPath
            self.pin = nil
            self.status = "已配对：\(deviceName ?? "设备")"
            self.isPairing = false
        }
    }

    private func finishError(_ msg: String?) {
        DispatchQueue.main.async {
            self.stopAdvertising()
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
