import SwiftUI
import Network
import UIKit

/// 网络与隧道状态的**实时**监听。
///
/// 用途：首页标题栏显示「iOS 版本 · LocalDevVPN · WiFi」。
///
/// 为什么必须是实时的：WiFi 开关、LocalDevVPN 连接/断开都会改变系统路径 —— 只在启动时检测一次的话，
/// 关掉 WiFi 后标题栏还写着「WiFi 已连接」，比不显示更误导。
///
/// 检测方式与取舍：
///   - **WiFi / 蜂窝**：`NWPathMonitor` 的变化通知 + `usesInterfaceType`（即「当前出口走哪个接口」）；
///   - **LocalDevVPN**：loopback VPN 必然带来一个 utun/ipsec/ppp 隧道接口（判据与「环境自检」卡片一致，
///     同一份 `TunnelNet` 逻辑）；
///   - **不读 SSID**：那需要额外 entitlement（`com.apple.developer.networking.wifi-info`），
///     侧载环境拿不到，而且也没必要 —— 判断「WiFi 在不在工作」看接口类型就够了。
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// 当前 iOS 版本（标题栏显示用）。
    let osVersion = UIDevice.current.systemVersion
    /// LocalDevVPN（loopback VPN）是否已连接。
    @Published private(set) var vpnUp = false
    /// 当前出口是否走 WiFi。
    @Published private(set) var wifiUp = false
    /// 蜂窝是否可用（WiFi 关掉时 iOS 会走它）。
    @Published private(set) var cellularUp = false
    /// 当前出口的一句话描述：WiFi 已连接 / 蜂窝网络 / 其他网络 / 无网络。
    @Published private(set) var networkText = "检测中…"

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            let cell = path.usesInterfaceType(.cellular)
            let text: String
            if path.status != .satisfied {
                text = "无网络"
            } else if wifi {
                text = "WiFi 已连接"
            } else if cell {
                text = "蜂窝网络"
            } else {
                text = "其他网络"
            }
            // 每次路径变化都重算一次：只有**带 10.7.x.x 地址**的隧道才算 LocalDevVPN 连上了
            // （别的 VPN 也会建 utun，不能只看"有没有隧道接口"）。
            let vpn = TunnelNet.isLocalDevVPNUp()
            DispatchQueue.main.async {
                guard let self else { return }
                self.wifiUp = wifi
                self.cellularUp = cell
                self.vpnUp = vpn
                self.networkText = text
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.sideinjector.network-monitor"))
    }

    /// 当前 iOS **主版本号**（标题栏据此着色：27 及以上算「够用」）。
    ///
    /// 标题行本身由 View 侧拼装（`ContentView.statusLine`）—— 因为要按项着色，
    /// 一个纯 String 表达不了，所以这里只提供判断所需的原始值。
    var osMajorVersion: Int {
        Int(osVersion.split(separator: ".").first ?? "") ?? 0
    }
}
