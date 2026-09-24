import SwiftUI
import UIKit

/// 顶部状态栏蒙版：**常驻铺一条，但平时看不出来**。
///
/// 想要的观感（与 SideInstaller 一致）：
///   - 没内容滑上来时，它**看不出存在**（不能像贴了一条带子）；
///   - 内容滚到状态栏下面时立刻呈现毛玻璃感，系统的时钟 / 电量不再与 App 文字压字。
///
/// 关键一：**只模糊、不叠色**。
///   - SwiftUI 的 `.ultraThinMaterial` / `.glassEffect` 除模糊外还会**叠一层填充色**（玻璃还带高光），
///     在 App 这种深色渐变背景上会浮出一条能看出来的"带子" —— 所以不用它们；
///   - `UIBlurEffect(style: .regular)` 是纯模糊（跟随深浅色自适应）：把一层平滑渐变模糊之后 ≈ 原来的
///     渐变，所以空着时看不见；而内容滑到它下面就会明显变糊。
///
/// 关键二：**强度必须做成渐变**。模糊并非"完全无痕" —— 它同时会轻微**去色**（降饱和）。整条等强时，
/// 那条带的上下边界/色彩差仍能看出来（实测反馈："还是能看出来"）。所以这里把强度做成自上而下的渐变：
/// 顶端约 `0.70`（这里是系统状态栏文字所在处，必须压住），往下递减到 0 —— 越往下越淡，直到与背景
/// 无差别，整体就"融为一体"了。**想更淡/更明显，只调下面 mask 里那几个 opacity 即可。**
///
/// 高度取窗口 `safeAreaInsets.top`（状态栏 / 灵动岛那一条的真实高度）+ 一小段收尾，保证状态栏文字
/// 整条都在"最强"区间内；整层 `allowsHitTesting(false)`，不吃点击。
///
/// 为什么不随滚动显隐（曾经的实现）：既然平时看不出来，就没有必要做「滚动检测 → 淡入淡出」那套状态，
/// 常驻反而更稳（不会因为滚动状态判断出偏差而闪一下）。系统那层 scroll edge effect 指望不上 ——
/// 本 App 无导航栏 / `safeAreaBar`，实测（iOS 27）系统那层根本不渲染。
struct StatusBarMask: View {
    /// 顶端最强区间之外多铺的高度：强度在这 14pt 内渐变到 0。
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
        //   0.70 → 0.35 → 0.15 → 0，越往下越淡，下边界与背景无差。
        // 若还想更淡，把这三个数整体再乘一个系数即可（例如 0.5 / 0.25 / 0.1）。
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.70), location: 0),
                    .init(color: .black.opacity(0.35), location: 0.62),
                    .init(color: .black.opacity(0.15), location: 0.86),
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
/// 只有 `UIBlurEffect` 能拿到"纯模糊"。强度由外层 mask 的 alpha 调节。
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
