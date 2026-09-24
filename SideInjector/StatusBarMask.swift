import SwiftUI
import UIKit

/// 顶部状态栏蒙版。
///
/// 作用：内容滚到系统状态栏下面时，盖住状态栏那一条，避免系统的时钟/电量与 App 文字互相压字。
///
/// ## 为什么分层实现（参考系统与主流 App 的做法）
///
/// iOS 26 起，**系统给滚动视图自带了一层「滚动边缘效果」（scroll edge effect）**。
/// Apple 文档原话：*By default, a scroll view renders an automatic edge effect.*
/// （`scrollEdgeEffectStyle(_:for:)` 的 Discussion）；默认样式是 `ScrollEdgeEffectStyle.automatic`
/// （另有 `.hard` 明确边界带分隔线、`.soft` 圆润弥散），作用区域是**滚动视图与安全区交叠的地方**，
/// 也就是状态栏那一条 —— 而且它**只在内容真的滚过去时**才出现、自带系统渐变。
///
/// 所以：
///   - **iOS 26+：什么都不画**（见 `siStatusBarMask()`）—— 自己再叠一层只会更糊更重（双重蒙版），
///     而且系统那层在动效、与 Tab Bar/工具栏的联动上都比自绘更地道。这也是 SideStore / AltStore /
///     Feather 这类 App 的共同做法：顶部那条交给系统，不手搓。
///     注意：**不要**去显式设 `.scrollEdgeEffectStyle(.soft, for: .top)` —— 已有反馈称 iOS 27 beta 1 上
///     `.soft` 在 `safeAreaBar` 之上会渲染成全透明；默认的 `.automatic` 是安全选择。
///   - **iOS 18–25：自绘**（系统没有这层效果）。做成**模仿系统 `.soft`** 的样子：系统材质 +
///     **底边渐隐**（而不是一刀切的硬边），并且只在内容滚上去之后才出现、出现时渐显。
///   - **iOS 17：自绘但常显** —— 这一档没有 `onScrollGeometryChange`，读不到滚动位置，
///     常显总好过永远不出现。
///
/// 材质：与 App 其它玻璃元素一致（见 `Glass.swift`），旧系统用系统毛玻璃 `.ultraThinMaterial`。
/// 高度取窗口的 `safeAreaInsets.top`（状态栏 / 灵动岛那一条的真实高度，比 Scene 场景下已不推荐的
/// `UIWindowScene.statusBarManager` 可靠），再**向下多留一段做渐隐**，保证状态栏文字整条被完全盖住。
struct StatusBarMask: View {
    @ObservedObject private var edge = ScrollEdgeState.shared

    /// 底边渐隐的高度：让蒙版像系统的 `.soft` 一样弥散收尾，而不是硬切一条边。
    private static let fadeHeight: CGFloat = 14

    var body: some View {
        let height = Self.topInset + Self.fadeHeight
        Group {
            if height <= 0 {
                Color.clear
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
    /// 在最上层铺一条状态栏蒙版（挂在根视图上）。
    ///
    /// - iOS 26+：**不铺** —— 系统的滚动边缘效果已经在做同一件事（见类型文档）。
    /// - 更低系统：铺，显示与否由 `siTrackScrollEdge()` 汇报的滚动状态决定。
    @ViewBuilder
    func siStatusBarMask() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
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

    /// 挂在**滚动视图**上：把「内容是否已滚到状态栏下面」汇报给 `ScrollEdgeState`。
    /// iOS 26+ 由系统效果负责，这里连状态都不再更新；iOS 17 没有对应 API，蒙版退回常显。
    @ViewBuilder
    func siTrackScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            modifier(ScrollEdgeTracker())
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
