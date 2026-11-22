// make-icon.swift — NTFSMate 应用图标生成 (AppKit, 无第三方依赖)
// 产物: Resources/AppIcon.iconset/ (16~1024 全尺寸 + @2x) → iconutil 打包 .icns
//
// 设计: macOS 26 图标形状 (824/1024 圆角矩形), 蓝色渐变底,
//       白色外置盘符号 (SF Symbol externaldrive), 右下角绿色读写角标。
// 运行: swift scripts/make-icon.swift   (在项目根目录执行)
import AppKit

let canvas: CGFloat = 1024
let shapeSize: CGFloat = 824
let shapeInset = (canvas - shapeSize) / 2
let cornerRadius: CGFloat = 184
let outputDir = URL(fileURLWithPath: "Resources/AppIcon.iconset")

/// 把任意图像统一染成纯白
func whiteVersion(of image: NSImage) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        NSColor.white.setFill()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func drawIcon(size: CGFloat) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // 统一在 1024 画布坐标系绘制, 输出时按比例缩放
    let scale = size / canvas
    if let cg = NSGraphicsContext.current?.cgContext {
        cg.scaleBy(x: scale, y: scale)
    }

    // 等比适配绘制
    func drawAspectFit(_ image: NSImage, in rect: CGRect) {
        let s = min(rect.width / image.size.width, rect.height / image.size.height)
        let w = image.size.width * s, h = image.size.height * s
        image.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    // 1) 底板: 圆角矩形 + 垂直渐变 (亮蓝 → 深蓝)
    let shapeRect = CGRect(x: shapeInset, y: shapeInset, width: shapeSize, height: shapeSize)
    let shapePath = NSBezierPath(roundedRect: shapeRect, xRadius: cornerRadius, yRadius: cornerRadius)
    shapePath.addClip()
    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.48, blue: 1.00, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.20, blue: 0.62, alpha: 1))!
        .draw(in: shapeRect, angle: -90)

    // 2) 顶部柔光 (层次感)
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: CGRect(x: shapeInset, y: shapeInset + shapeSize * 0.55,
                                     width: shapeSize, height: shapeSize * 0.45),
                 xRadius: cornerRadius, yRadius: cornerRadius).fill()

    // 3) 主符号: 外置盘 (白色)
    if let base = NSImage(systemSymbolName: "externaldrive.connected.to.line.below",
                          accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 480, weight: .medium)) {
        drawAspectFit(whiteVersion(of: base),
                      in: CGRect(x: 150, y: 240, width: 724, height: 520))
    }

    // 4) 读写角标: 右下角绿色圆 + 白色双向箭头
    let badgeD: CGFloat = 235
    let badgeRect = CGRect(x: canvas - shapeInset - badgeD + 26,
                           y: shapeInset - 26,
                           width: badgeD, height: badgeD)
    NSColor(srgbRed: 0.10, green: 0.78, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(ovalIn: badgeRect).fill()
    if let arrows = NSImage(systemSymbolName: "arrow.left.arrow.right",
                            accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 105, weight: .bold)) {
        drawAspectFit(whiteVersion(of: arrows),
                      in: badgeRect.insetBy(dx: badgeD * 0.2, dy: badgeD * 0.2))
    }

    // 输出 PNG
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outputDir.appendingPathComponent("icon_\(Int(size))x\(Int(size)).png"))
    print("生成 icon_\(Int(size))x\(Int(size)).png")
}

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for s in [CGFloat(16), 32, 64, 128, 256, 512, 1024] {
    drawIcon(size: s)
}
// @2x 命名对 (iconutil 要求)
for (base, two) in [(16.0, 32.0), (32.0, 64.0), (128.0, 256.0), (256.0, 512.0), (512.0, 1024.0)] {
    let src = outputDir.appendingPathComponent("icon_\(Int(two))x\(Int(two)).png")
    let dst = outputDir.appendingPathComponent("icon_\(Int(base))x\(Int(base))@2x.png")
    try? FileManager.default.removeItem(at: dst)
    try? FileManager.default.copyItem(at: src, to: dst)
}
print("完成: \(outputDir.path)")
