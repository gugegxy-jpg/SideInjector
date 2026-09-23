import SwiftUI

/// 共享视觉语言：品牌色、渐变，以及每个页面由之拼装出的卡片、按钮与头部。
/// 风格参照 FrizzleM/SideInstaller 的 Theme.swift。
enum Theme {
    /// 主品牌色，深蓝。
    static let accent = Color(red: 0.13, green: 0.44, blue: 0.96)
    /// 次品牌色，渐变远端。
    static let accent2 = Color(red: 0.30, green: 0.68, blue: 1.0)
    /// 头部图标后的深蓝晕（对应图标美术 #011A5C）。
    static let glow = Color(red: 1 / 255, green: 26 / 255, blue: 92 / 255)

    /// 标志性的斜向渐变，用于 logo、主操作按钮与强调。
    static var brand: LinearGradient {
        LinearGradient(colors: [accent, accent2],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 由任意色调出的斜向渐变，用于着色字形。
    static func gradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.72)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - 背景

/// 应用背景：OLED 黑底之上两团缓慢游走的蓝色光晕。
struct AppBackground: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Color.black
                RadialGradient(colors: [Theme.accent.opacity(0.55), .clear],
                               center: UnitPoint(x: CGFloat(0.3 + 0.15 * sin(t * 0.3)),
                                                 y: CGFloat(0.25 + 0.12 * cos(t * 0.25))),
                               startRadius: 0, endRadius: 460)
                    .blur(radius: 36)
                    .opacity(0.5)
                RadialGradient(colors: [Theme.accent2.opacity(0.5), .clear],
                               center: UnitPoint(x: CGFloat(0.75 + 0.12 * cos(t * 0.22)),
                                                 y: CGFloat(0.72 + 0.1 * sin(t * 0.27))),
                               startRadius: 0, endRadius: 500)
                    .blur(radius: 36)
                    .opacity(0.45)
                LinearGradient(colors: [Theme.glow.opacity(0.35), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(0.5)
            }
        }
        // 关键：ignoresSafeArea 必须作用在最外层（TimelineView 之上），
        // 否则 TimelineView 不会把「延伸出安全区」的请求向上传递，
        // 灵动岛/Home 指示条区域会露出系统黑底。
        .ignoresSafeArea()
    }
}

// MARK: - 卡片

/// 每个区块所在的通用中性容器。
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.07), radius: 14, x: 0, y: 7)
    }
}

/// 着色的 PanelCard，用于提示、错误与成功。
struct CalloutCard<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
    }
}

// MARK: - 按钮

/// 全宽渐变主操作按钮；传入 gradient 可重新着色。
struct PrimaryButtonStyle: ButtonStyle {
    var gradient: LinearGradient = Theme.brand
    var glow: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(gradient)
            )
            .shadow(color: glow.opacity(0.4), radius: 16, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.22), value: configuration.isPressed)
    }
}

// MARK: - 字段样式

private struct FieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
    }
}

extension View {
    /// 给 .plain 文本/密码框套上应用的凹陷字段背景。
    func fieldBackground() -> some View { modifier(FieldBackground()) }

    /// 在键盘上方挂一个「完成」按钮，用于收起键盘（否则密码框输入后无处收起）。
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

// MARK: - 过渡

extension AnyTransition {
    /// 每个状态卡使用的进出动画：淡入缩放。
    static var cardAppear: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.96, anchor: .top))
                .combined(with: .offset(y: -10)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }
}

// MARK: - 入场级联

private struct CascadeItem: ViewModifier {
    let index: Int
    @State private var shown = false
    private var delay: Double { Double(index) * 0.055 }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.98, anchor: .top)
            .offset(y: shown ? 0 : 16)
            .onAppear {
                withAnimation(.smooth(duration: 0.4, extraBounce: 0.1).delay(delay)) {
                    shown = true
                }
            }
            .onDisappear { shown = false }
    }
}

extension View {
    /// 让元素在页面入场时按 index 错峰出现（0 最先）。
    func cascadeItem(_ index: Int) -> some View { modifier(CascadeItem(index: index)) }
}

// MARK: - 小组件

/// 头部下方紧凑的彩色状态胶囊。
struct StatusPill: View {
    var text: String
    var systemImage: String
    var color: Color
    /// 在 iOS 26+ 使用玻璃胶囊而非着色填充（空闲态不读作状态芯片）。
    var glass: Bool = false

    var body: some View {
        let label = Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        if glass, #available(iOS 26.0, *) {
            label.glassEffect(.regular, in: Capsule())
        } else {
            label.background(Capsule().fill(color.opacity(0.16)))
        }
    }
}

/// 每屏顶部的英雄区：字形、标题与配件。
struct BrandHeader<Accessory: View>: View {
    var icon: String
    var title: String
    var subtitle: String? = nil
    var animateIcon: Bool = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(Theme.brand)
                    .frame(width: 86, height: 86)
                    .shadow(color: Theme.glow, radius: 20, x: 0, y: 12)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: animateIcon)
            }
            .scaleEffect(animateIcon ? 1.04 : 1)
            .animation(animateIcon ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: animateIcon)
            VStack(spacing: 4) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            accessory()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}
