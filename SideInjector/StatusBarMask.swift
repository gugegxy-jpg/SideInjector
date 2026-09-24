import SwiftUI
import UIKit

/// 顶部状态栏蒙版。
///
/// 为什么需要：首页内容是一个 `ScrollView`，向上滚动时标题 / 卡片会滑到**系统状态栏下面**，
/// 于是系统的时钟、电量与 App 文字互相压字。这里在状态栏那一条上盖一层系统材质，
/// 位置固定在屏幕顶部、**不随内容滚动**，并且**不吃点击**。
///
/// 材质跟系统版本走（与 App 其它玻璃元素一致，见 `Glass.swift`）：
///   - iOS 26+：Liquid Glass（`.glassEffect`）
///   - 旧系统：系统毛玻璃（`.ultraThinMaterial`）
///
/// 高度取窗口的 `safeAreaInsets.top` —— 这是状态栏（含灵动岛）那一条的真实高度，
/// 比 `UIWindowScene.statusBarManager`（Scene 场景下已不推荐）可靠，也不需要任何
/// GeometryReader 嵌套（那种写法在忽略安全区的层级里经常读出 0）。
struct StatusBarMask: View {
    var body: some View {
        let height = Self.topInset
        Group {
            if height <= 0 {
                Color.clear
            } else if #available(iOS 26.0, *) {
                Rectangle().glassEffect(.regular, in: Rectangle())
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(height, 0))
        .allowsHitTesting(false)
    }

    /// 顶部安全区高度（状态栏 / 灵动岛那一条）。
    static var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }
}

extension View {
    /// 在最上层铺一条固定的状态栏蒙版（不影响布局：走 `overlay`，且整层不吃点击）。
    ///
    /// 用法：挂在根视图（`ContentView` 的最外层 ZStack）上，这样两个页签都受保护，
    /// 弹窗 / 分享面板等系统层仍然显示在它之上。
    func siStatusBarMask() -> some View {
        overlay {
            VStack(spacing: 0) {
                StatusBarMask()
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}
