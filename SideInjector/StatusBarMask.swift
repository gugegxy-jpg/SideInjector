import SwiftUI
import UIKit

/// 顶部状态栏蒙版：**常驻铺一条，平时尽量看不出来**。
///
/// 想要的观感（与 SideInstaller 一致）：
///   - 没内容滑上来时，它尽量**看不出存在**；
///   - 内容滚到状态栏下面时要**真的糊得住**，系统的时钟 / 电量不与 App 文字压字。
///
/// 关键一：**只模糊、不叠色**。
///   - SwiftUI 的 `.ultraThinMaterial` / `.glassEffect` 除模糊外还会**叠一层填充色**（玻璃还带高光），
///     在 App 这种深色渐变背景上会浮出一条能看出来的"带子" —— 所以不用它们；
///   - `UIBlurEffect(style: .regular)` 是纯模糊（跟随深浅色自适应）：模糊一层平滑渐变 ≈ 原来的渐变。
///
/// 关键二：**强度做成渐变，而不是整条等强**。模糊会轻微**去色**（降饱和），等强时那条带的边界与
/// 色彩差看得出来。现在前端（系统状态栏文字所在区间）保持**全强度**，后端快速淡出到 0 ——
/// 该压住的地方糊得实，下边界又与背景无差。
///
/// 这两个诉求本质上是相互牵制的：**越强越"糊得住"内容，也越容易被看出蒙版本身**。当前取值是
/// 偏"糊得住"的一档（实测反馈：调弱之后模糊感不足）。要再调只改 `body` 里 mask 的四个 opacity。
///
/// 高度取窗口 `safeAreaInsets.top`（状态栏 / 灵动岛那一条的真实高度）+ 一小段收尾，保证状态栏文字
/// 整条都落在全强度区间内；整层 `allowsHitTesting(false)`，不吃点击。
///
/// 为什么不随滚动显隐（曾经的实现）：既然平时不明显，就没有必要做「滚动检测 → 淡入淡出」那套状态，
/// 常驻反而更稳（不会因为滚动状态判断出偏差而闪一下）。系统那层 scroll edge effect 指望不上 ——
/// 本 App 无导航栏 / `safeAreaBar`，实测（iOS 27）系统那层根本不渲染。
struct StatusBarMask: View {
    /// 全强度区间之外多铺的高度：强度在这 14pt 内淡出到 0。
    private static let fadeHeight: CGFloat = 14

    var body: some View {
        let height = Self.topInset + Self.fadeHeight
        Group {
            if height <= 0 {
                Color.clear
            } else {
                BlurOnly()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(height, 0))
        // 强度渐变（mask 的 alpha 直接乘在模糊层上）：
        //   0 ~ 0.55   全强度 1.00 —— 状态栏文字所在区间，要真的糊得住；
        //   0.55 ~ 0.82  1.00 → 0.45 —— 过渡；
        //   0.82 ~ 1.00  0.45 → 0    —— 与背景融为一体，下边界看不出来。
        // 这是唯一的强度旋钮：想更淡/更糊就调这四个 opacity（或给它们乘同一个系数）。
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(1.00), location: 0),
                    .init(color: .black.opacity(1.00), location: 0.55),
                    .init(color: .black.opacity(0.45), location: 0.82),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
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

/// 只模糊、不叠色的背景层（见 `StatusBarMask`）。
///
/// 用 UIKit 而不是 SwiftUI 材质的原因：SwiftUI 的 Material / Liquid Glass 都自带填充色，
/// 只有 `UIBlurEffect` 能拿到"纯模糊"。强度由外层 mask 的 alpha 调节；
/// 若哪天连全强度都嫌不够糊，下一档是把 `style` 换成 `.prominent`（半径更大，但底色也更容易被看出来）。
private struct BlurOnly: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: .regular)
    }
}

extension View {
    /// 在最上层铺一条状态栏蒙版（挂在根视图上）。常驻，不依赖任何滚动状态。
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
