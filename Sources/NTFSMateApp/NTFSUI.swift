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

    /// 描边: 13 安全实现 (Shape.strokeBorder 的 ShapeStyle 泛型重载是 macOS 14+)
    func ntfsStrokeBorder<S: Shape>(_ shape: S, _ color: Color, lineWidth: CGFloat = 0.5) -> some View {
        overlay(
            GeometryReader { geo in
                Path { $0.addPath(shape.path(in: CGRect(origin: .zero, size: geo.size))) }
                    .stroke(color, lineWidth: lineWidth)
            }
        )
    }

    /// 玻璃衬底: 26+ 托管原生 NSGlassEffectView (GlassSurfaceView),
    /// 低版本回退 NSVisualEffectView 材质 —— 由 GlassSurfaceView 内部处理
    func glassSurfaceBackground(cornerRadius: CGFloat,
                                style: GlassSurfaceView.Style = .interactive) -> some View {
        background(GlassSurfaceBackground(cornerRadius: cornerRadius, style: style))
    }
}

/// SwiftUI 桥接: 把 AppKit 玻璃表面作为衬底视图
struct GlassSurfaceBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var style: GlassSurfaceView.Style = .interactive

    func makeNSView(context: Context) -> GlassSurfaceView {
        let view = GlassSurfaceView(style: style, backingOnly: true)
        view.cornerRadiusOverride = cornerRadius
        return view
    }

    func updateNSView(_ view: GlassSurfaceView, context: Context) {
        view.cornerRadiusOverride = cornerRadius
    }
}
