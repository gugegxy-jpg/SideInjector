import SwiftUI

/// 统一的「玻璃」外观：iOS 26+ 使用 Liquid Glass，以下版本回退到毛玻璃材质。
enum UILook {
    /// 当前系统是否支持 Liquid Glass（iOS 26 起）
    static var isLiquidGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

extension View {
    /// 给任意内容套一层玻璃卡片背景。
    /// - iOS 26+：系统 Liquid Glass（`.glassEffect`）
    /// - 旧系统：`.ultraThinMaterial` 毛玻璃 + 细描边
    @ViewBuilder
    func siGlass(cornerRadius: CGFloat = 22) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        }
    }

    /// 玻璃质感的主操作按钮背景；用环境 tint 让 iOS 26 的 Liquid Glass 着色。
    @ViewBuilder
    func siGlassButton(cornerRadius: CGFloat = 16, tint: Color = .accentColor) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .tint(tint)
        } else {
            self
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(tint.opacity(0.5), lineWidth: 1)
                )
        }
    }

    /// 底部页签的「悬浮玻璃胶囊」：iOS 26+ 用系统 Liquid Glass，旧系统退回毛玻璃 + 描边。
    @ViewBuilder
    func siGlassBar() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: Capsule())
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        }
    }
}

/// 全屏渐变背景，衬托玻璃层级。
extension View {
    func siBackdrop() -> some View {
        self.background(AppBackground())
    }
}

// MARK: - 底部页签栏

extension View {
    /// 系统页签栏的「浮动玻璃」行为。
    ///
    /// - iOS 26+：让页签栏在**向下滚动时收起**（配合系统的 Liquid Glass 就是那种悬浮效果）；
    /// - 旧系统：保持系统默认（无需额外处理）。
    ///
    /// 注：不再自绘 dock —— 自绘时它得放在内容区的 VStack 里，下方会露出 OLED 黑底，
    /// 看起来像「矩形深色底板 + 胶囊玻璃」，而且拿不到系统的浮动/收起行为。
    @ViewBuilder
    func siFloatingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
