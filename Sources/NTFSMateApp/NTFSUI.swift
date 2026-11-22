import SwiftUI

/// 兼容层: macOS 26+ 默认启用 Liquid Glass UI, 低版本回退到等效的常规样式。
/// 所有 26+ 专属 API 都必须经由这里的封装调用, 不得在视图代码里直接使用。

extension View {
    /// 玻璃按钮: 26+ 用 .glass, 低版本回退 .bordered
    @ViewBuilder
    func ntfsGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// 主操作玻璃按钮: 26+ 用 .glassProminent, 低版本回退 .borderedProminent
    @ViewBuilder
    func ntfsGlassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// 玻璃背景: 26+ 用 .glassEffect(in:), 低版本回退材质底
    @ViewBuilder
    func ntfsGlassEffect<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: shape)
        } else {
            self.background(shape.fill(.regularMaterial))
        }
    }

    /// 描边: 13 安全实现 (Shape.strokeBorder 的 ShapeStyle 泛型重载是 macOS 14+)
    func ntfsStrokeBorder<S: Shape>(_ shape: S, _ color: Color, lineWidth: CGFloat = 0.5) -> some View {
        overlay(
            GeometryReader { geo in
                Path { $0.addPath(shape.path(in: CGRect(origin: .zero, size: geo.size))) }
                    .stroke(color, lineWidth: lineWidth)
            }
        )
    }

    /// 玻璃容器: 26+ 用 GlassEffectContainer 分组联动, 低版本原样呈现
    @ViewBuilder
    func ntfsGlassContainer(spacing: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
