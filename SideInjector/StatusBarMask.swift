import SwiftUI
import UIKit

/// 顶部状态栏蒙版。
///
/// 作用：内容滚到系统状态栏下面时，盖住状态栏那一条，避免系统的时钟/电量与 App 文字互相压字。
///
/// ## 为什么是自绘（**不要**改成"交给系统"）
///
/// iOS 26 起 Apple 给滚动视图加了「滚动边缘效果」（scroll edge effect），文档原话：*By default,
/// a scroll view renders an automatic edge effect.*（`scrollEdgeEffectStyle(_:for:)` 的 Discussion）。
/// 曾经据此把 iOS 26+ 改成"什么都不画、交给系统"，**结果在本 App 的布局里系统那层不出现** ——
/// 实测 iOS 27 上状态栏区域完全透明，文字与时钟直接压在一起。原因应是系统效果只在它与
/// 导航栏 / `safeAreaBar` / 系统栏交叠时才渲染，而这里是「自定义 TabView + 纯 ScrollView、无栏」。
///
/// 所以：**所有系统版本都自绘这条蒙版**（系统效果若在某个版本/场景下出现了，就当作额外一层）。
/// 另外**不要**去显式设 `.scrollEdgeEffectStyle(.soft, for: .top)`：已有反馈称 iOS 27 beta 1 上
/// `.soft` 会渲染成全透明，默认的 `.automatic` 更稳。
///
/// 显示时机：内容真的滚到状态栏下面之后才出现，并且渐显（见 `siTrackScrollEdge()`）。
/// 材质：与 App 其它玻璃元素一致（见 `Glass.swift`）—— iOS 26+ Liquid Glass，旧系统系统毛玻璃。
/// 高度：窗口 `safeAreaInsets.top`（状态栏 / 灵动岛那一条的真实高度，比 Scene 场景下已不推荐的
/// `UIWindowScene.statusBarManager` 可靠）+ 一段渐隐余量，保证状态栏文字整条被完全盖住。
struct StatusBarMask: View {
    @ObservedObject private var edge = ScrollEdgeState.shared

    /// 底边渐隐的高度：让蒙版像系统的 `.soft` 一样弥散收尾，而不是硬切一条边。
    private static let fadeHeight: CGFloat = 14

    var body: some View {
        let height = Self.topInset + Self.fadeHeight
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
        // 底边渐隐：状态栏那一条保持满强度，最后一小段淡出（模拟系统 `.soft` 边缘效果）。
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: max(0, 1 - Self.fadeHeight / max(height, 1))),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .opacity(visible ? 1 : 0)
        // 渐显 / 渐隐：滚动位置变化时淡入淡出，而不是硬切。
        .animation(.easeOut(duration: 0.2), value: visible)
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
    /// 在最上层铺一条状态栏蒙版（挂在根视图上；**所有系统版本都铺**，理由见 `StatusBarMask`）。
    /// 显示与否由 `siTrackScrollEdge()` 汇报的滚动状态决定，出现时渐显。
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

    /// 挂在**滚动视图**上：把「内容是否已滚到状态栏下面」汇报给 `ScrollEdgeState`。
    /// iOS 17 没有对应 API，蒙版退回常显（见 `StatusBarMask`）。
    func siTrackScrollEdge() -> some View { modifier(ScrollEdgeTracker()) }
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
