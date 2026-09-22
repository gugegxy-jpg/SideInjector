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
}

/// 全屏渐变背景，衬托玻璃层级。
extension View {
    func siBackdrop() -> some View {
        self.background(AppBackground())
    }
}
