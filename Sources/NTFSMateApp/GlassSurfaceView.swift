import AppKit

/// 应用内玻璃表面的统一接缝 (移植自 MarkLeaf GlassSurfaceView, MIT License,
/// Copyright (c) 2026 MarkLeaf — 依 MIT 许可并入本 GPLv2 项目)。
///
/// macOS 26+ 使用系统 Liquid Glass (NSGlassEffectView); 更早版本与
/// "减弱透明度"辅助设置自动回退 NSVisualEffectView, 调用方无需按系统版本分支。
/// 支持 macOS 27 新增的 effectIsInteractive 属性 (经运行时 selector, 见文末)。
final class GlassSurfaceView: NSView {
    enum Style {
        case regular
        case interactive

        /// 对应 NSGlassEffectView.Style: regular = 0, clear = 1
        var glassStyleRawValue: Int { 0 }

        var legacyMaterial: NSVisualEffectView.Material {
            switch self {
            case .interactive: return .windowBackground
            case .regular: return .windowBackground
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .interactive: return 12
            case .regular: return 0
            }
        }
    }

    static let systemSupportsGlass: Bool = {
        if #available(macOS 26, *) { return true }
        return false
    }()

    let style: Style
    var cornerRadiusOverride: CGFloat? = nil {
        didSet {
            guard cornerRadiusOverride != oldValue else { return }
            if #available(macOS 26, *), shouldUseGlass,
               let effect = glassEffectView as? NSGlassEffectView {
                effect.cornerRadius = cornerRadiusOverride ?? style.cornerRadius
            }
            layer?.cornerRadius = cornerRadiusOverride ?? 0
        }
    }

    private var glassEffectView: AnyObject?
    private var legacyEffectView: NSVisualEffectView?
    private var preferredDark: Bool?
    private var fallbackBackgroundColor: NSColor?

    /// 背景专用模式: 无内容子视图, 玻璃表面仅作为 SwiftUI 内容的衬底
    private let backingOnly: Bool

    init(style: Style, preferredDark: Bool? = nil,
         fallbackBackgroundColor: NSColor? = nil, backingOnly: Bool = false) {
        self.style = style
        self.preferredDark = preferredDark
        self.fallbackBackgroundColor = fallbackBackgroundColor
        self.backingOnly = backingOnly
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fallbackBackgroundColor?.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        GlassSurfaceRegistry.shared.register(self)
        rebuildSurface()
    }

    required init?(coder: NSCoder) {
        style = .regular
        backingOnly = false
        super.init(coder: coder)
        GlassSurfaceRegistry.shared.register(self)
        rebuildSurface()
    }

    func refresh(forceDark: Bool? = nil) {
        if shouldUseGlass != (glassEffectView != nil) {
            rebuildSurface()
            return
        }
        let seededDark = window == nil ? preferredDark : nil
        let dark = forceDark ?? seededDark
            ?? (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let active = window?.isKeyWindow == true
        applyAppearance(dark: dark, active: active, reducedTransparency: reduceTransparency)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 一旦上窗, NSGlassEffectView 接管视觉; 保留回退底色会把玻璃压平成灰色
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.fallbackBackgroundColor = nil
                self.layer?.backgroundColor = nil
            }
        }
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var shouldUseGlass: Bool {
        Self.systemSupportsGlass && !reduceTransparency
    }

    private func rebuildSurface() {
        glassEffectView?.removeFromSuperview()
        legacyEffectView?.removeFromSuperview()
        glassEffectView = nil
        legacyEffectView = nil

        if shouldUseGlass, #available(macOS 26, *) {
            let effect = NSGlassEffectView()
            effect.style = .regular
            Self.setEffectInteractive(effect, interactive: style == .interactive)
            effect.cornerRadius = cornerRadiusOverride ?? style.cornerRadius
            effect.translatesAutoresizingMaskIntoConstraints = false
            addSubview(effect)
            glassEffectView = effect
            constrain(effect)
        } else {
            let effect = NSVisualEffectView()
            effect.material = reduceTransparency ? .windowBackground : style.legacyMaterial
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            effect.wantsLayer = true
            effect.translatesAutoresizingMaskIntoConstraints = false
            addSubview(effect)
            constrain(effect)
            legacyEffectView = effect
        }
        refresh()
    }

    private func applyAppearance(dark: Bool, active: Bool, reducedTransparency: Bool) {
        let themedAppearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        appearance = themedAppearance
        layer?.backgroundColor = fallbackBackgroundColor?.cgColor
        legacyEffectView?.state = active ? .active : .inactive
        legacyEffectView?.material = reducedTransparency ? .windowBackground : style.legacyMaterial
        guard #available(macOS 26, *) else { return }
        let glassEffectView = self.glassEffectView as? NSGlassEffectView
        glassEffectView?.appearance = themedAppearance
        glassEffectView?.style = reducedTransparency ? .clear : .regular
        Self.setEffectInteractive(glassEffectView ?? NSView(), interactive: style == .interactive)
        glassEffectView?.cornerRadius = cornerRadiusOverride ?? style.cornerRadius
    }

    /// effectIsInteractive 为 macOS 27 新增属性, 26 SDK 中无声明, 无法直接
    /// 引用编译; 经 selector 在运行时设置, 旧系统上自动退化为常规玻璃。
    private static func setEffectInteractive(_ effect: NSView, interactive: Bool) {
        let selector = NSSelectorFromString("setEffectIsInteractive:")
        guard effect.responds(to: selector) else { return }
        effect.perform(selector, with: NSNumber(value: interactive))
    }

    private func constrain(_ backing: NSView) {
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// 让长驻窗口表面跟随辅助功能设置与窗口激活状态变化。
/// 表面自行注册; 注册表只持弱引用, 窗口销毁不会滞留 UI。
final class GlassSurfaceRegistry {
    static let shared = GlassSurfaceRegistry()

    private var surfaces = NSHashTable<AnyObject>.weakObjects()
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAll()
        })

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                self?.refreshSurfaces(in: window)
            })
        }
    }

    func register(_ surface: GlassSurfaceView) {
        surfaces.add(surface)
    }

    func unregister(_ surface: GlassSurfaceView) {
        surfaces.remove(surface)
    }

    func refreshAll(forceDark: Bool? = nil) {
        for case let surface as GlassSurfaceView in Array(surfaces.allObjects) {
            surface.refresh(forceDark: forceDark)
        }
    }

    func refreshSurfaces(in window: NSWindow) {
        for case let surface as GlassSurfaceView in Array(surfaces.allObjects)
        where surface.window === window {
            surface.refresh()
        }
    }
}
