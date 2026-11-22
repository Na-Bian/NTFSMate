// make-dmg-background.swift — NTFSMate 品牌化 DMG 背景图绘制 (640×400 @2x)
// 产物: script/release/dmg-assets/NTFSMate-dmg-background.png (1280×800)
// 设计: 深蓝渐变底 + 品牌标题栏 + 应用图标 + "drag to" 箭头引导
// 运行: swift script/make-dmg-background.swift   (项目根目录)
import AppKit

let W: CGFloat = 1280, H: CGFloat = 800   // @2x 像素; 逻辑 640×400

let outputDir = URL(fileURLWithPath: "script/release/dmg-assets")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let outFile = outputDir.appendingPathComponent("NTFSMate-dmg-background.png")

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
defer { NSGraphicsContext.restoreGraphicsState() }

let ctx = NSGraphicsContext.current!.cgContext

// 1) 深蓝渐变底 (与应用图标同族色)
let bg = CGRect(x: 0, y: 0, width: W, height: H)
ctx.setFillColor(NSColor(srgbRed: 0.075, green: 0.118, blue: 0.212, alpha: 1).cgColor)
ctx.fill(bg)
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.10, green: 0.16, blue: 0.30, alpha: 1).cgColor,
    NSColor(srgbRed: 0.055, green: 0.09, blue: 0.18, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

// 2) 顶部品牌条 (半透明白 + 细分隔线)
let headerH: CGFloat = 150
ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
ctx.fill(CGRect(x: 0, y: H - headerH, width: W, height: headerH))
ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
ctx.fill(CGRect(x: 0, y: H - headerH - 2, width: W, height: 2))

// 3) 应用图标 + 标题 (顶部条内)
let iconSide: CGFloat = 104
let iconRect = CGRect(x: 56, y: H - headerH + 23, width: iconSide, height: iconSide)
if let icon = NSImage(contentsOfFile: "Resources/AppIcon.iconset/icon_512x512.png") {
    // 圆角裁切绘制
    ctx.saveGState()
    let radius: CGFloat = 22
    let path = CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    icon.draw(in: iconRect)
    ctx.restoreGState()
}
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 46, weight: .bold),
    .foregroundColor: NSColor.white,
]
NSAttributedString(string: "NTFSMate", attributes: attrs)
    .draw(at: NSPoint(x: iconRect.maxX + 30, y: H - headerH + 52))
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold),
    .foregroundColor: NSColor(srgbRed: 0.55, green: 0.65, blue: 0.82, alpha: 1),
]
let sub = NSAttributedString(string: "READ · WRITE · AUTO-MOUNT NTFS", attributes: subAttrs)
sub.draw(at: NSPoint(x: iconRect.maxX + 30, y: H - headerH + 20))

// 4) 中部 "drag to →" 引导 (箭头线由 Finder 图标位置关系表达, 这里画文字+箭头)
let midY: CGFloat = H * 0.42
let dragAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 34, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.72, green: 0.78, blue: 0.88, alpha: 1),
]
let dragText = NSAttributedString(string: "drag to", attributes: dragAttrs)
let dragSize = dragText.size()
dragText.draw(at: NSPoint(x: W / 2 - dragSize.width / 2, y: midY))

// 箭头线
ctx.setStrokeColor(NSColor(srgbRed: 0.55, green: 0.62, blue: 0.75, alpha: 1).cgColor)
ctx.setLineWidth(4)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: W / 2 - 70, y: midY - 46))
ctx.addLine(to: CGPoint(x: W / 2 + 70, y: midY - 46))
ctx.strokePath()
// 箭头头
ctx.move(to: CGPoint(x: W / 2 + 56, y: midY - 58))
ctx.addLine(to: CGPoint(x: W / 2 + 70, y: midY - 46))
ctx.addLine(to: CGPoint(x: W / 2 + 56, y: midY - 34))
ctx.strokePath()

// 5) 底部说明
let footAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22),
    .foregroundColor: NSColor(srgbRed: 0.52, green: 0.60, blue: 0.74, alpha: 1),
]
let foot = NSAttributedString(string: "Drag NTFSMate into Applications to install", attributes: footAttrs)
let footSize = foot.size()
foot.draw(at: NSPoint(x: W / 2 - footSize.width / 2, y: 60))

// 输出
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: outFile)
print("生成: \(outFile.path)")
