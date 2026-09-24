import SwiftUI
import UIKit

/// 顶部状态栏蒙版。
///
/// 作用：内容滚到系统状态栏下面时，在状态栏那一条上盖一层系统材质，避免系统的时钟/电量与
/// App 文字互相压字。
///
/// **只在真的滚上去之后才出现**（并且渐显）：显示与否由各个滚动视图汇报
/// （见 `siTrackScrollEdge()`），汇总在 `ScrollEdgeState` 里 —— 因为没有内容滚上去时，
/// 状态栏那条本来就没有东西可压，常显只会白白糊掉渐变背景。
///
/// 材质跟系统版本走（与 App 其它玻璃元素一致，见 `Glass.swift`）：
///   - iOS 26+：Liquid Glass（`.glassEffect`）
///   - 旧系统：系统毛玻璃（`.ultraThinMaterial`）
///
/// 高度取窗口的 `safeAreaInsets.top` —— 状态栏（含灵动岛）那一条的真实高度，
/// 比 `UIWindowScene.statusBarManager`（Scene 场景下已不推荐）可靠，也不需要任何
/// GeometryReader 嵌套（那种写法在忽略安全区的层级里经常读出 0）。
struct StatusBarMask: View {
    @ObservedObject private var edge = ScrollEdgeState.shared

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
        .opacity(visible ? 1 : 0)
        // 渐显 / 渐隐：滚动位置变化时淡入淡出，而不是硬切。
        .animation(.easeOut(duration: 0.18), value: visible)
        .allowsHitTesting(false)
    }

    /// 现在要不要显示。
    ///
    /// iOS 18+ 有 `onScrollGeometryChange`，能精确知道内容有没有滚到状态栏下面；
    /// iOS 17 没有这个 API，拿不到滚动信息 → 退回**常显**（否则蒙版永远不会出现）。
    private var visible: Bool {
        if #available(iOS 18.0, *) {
            return edge.scrolledUnder
        }
        return true
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

/// 「顶部蒙版要不要显示」的共享状态：由**当前可见页签的滚动视图**汇报（见 `siTrackScrollEdge()`）。
///
/// 为什么要一个跨层级的对象：蒙版画在最外层（只有那里能固定盖住状态栏），而"有没有内容滚上去"
/// 只有滚动视图自己知道 —— 用一个轻量对象搭桥最直接。
final class ScrollEdgeState: ObservableObject {
    static let shared = ScrollEdgeState()

    /// 内容是否已经滚到顶部安全区（状态栏）下面。
    @Published var scrolledUnder = false

    private init() {}
}

extension View {
    /// 挂在**滚动视图**上：把「内容是否已滚到状态栏下面」汇报给 `ScrollEdgeState`，
    /// 于是顶部蒙版只在需要时出现、且渐显。iOS 17 没有对应 API，蒙版退回常显（见 `StatusBarMask`）。
    func siTrackScrollEdge() -> some View { modifier(ScrollEdgeTracker()) }

    /// 在最上层铺一条状态栏蒙版（走 `overlay`，不影响布局，整层不吃点击）。
    /// 挂在根视图上；显示与否由 `siTrackScrollEdge()` 汇报的滚动状态决定。
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

/// 见 `siTrackScrollEdge()`。
private struct ScrollEdgeTracker: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                // 停在顶部时 `contentOffset.y == -contentInsets.top`，所以"加回 insets 之后 > 1"
                // 就等于"内容已经钻到顶部安全区下面了"；留 1pt 容差，避免停在边界时来回抖。
                geo.contentOffset.y + geo.contentInsets.top > 1
            } action: { _, scrolled in
                ScrollEdgeState.shared.scrolledUnder = scrolled
            }
        } else {
            content
        }
    }
}
