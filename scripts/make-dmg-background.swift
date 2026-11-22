// make-dmg-background.swift — NTFSMate 品牌化 DMG 背景图绘制 (1280×800 @2x, 逻辑 640×400)
// 产物: scripts/dmg-assets/NTFSMate-dmg-background.png
// 设计: MarkLeaf 式构图 — 内容集中于中央安全区 (窗口即使轻微裁切也不损失内容)
// 运行: swift scripts/make-dmg-background.swift   (项目根目录)
import AppKit

let W: CGFloat = 1280, H: CGFloat = 800

let outputDir = URL(fileURLWithPath: "scripts/dmg-assets")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let outFile = outputDir.appendingPathComponent("NTFSMate-dmg-background.png")

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
defer { NSGraphicsContext.restoreGraphicsState() }

let ctx = NSGraphicsContext.current!.cgContext

// 1) 全幅深蓝渐变底 (窗口放大裁切时只是底色延伸, 内容无损失)
let bg = CGRect(x: 0, y: 0, width: W, height: H)
ctx.setFillColor(NSColor(srgbRed: 0.075, green: 0.118, blue: 0.212, alpha: 1).cgColor)
ctx.fill(bg)
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.10, green: 0.16, blue: 0.30, alpha: 1).cgColor,
    NSColor(srgbRed: 0.055, green: 0.09, blue: 0.18, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

// 2) 品牌行 (图标 + 名称 + 副标)
let iconSide: CGFloat = 104
let iconX: CGFloat = 150
let iconYTop: CGFloat = 62
let iconRect = CGRect(x: iconX, y: H - iconYTop - iconSide, width: iconSide, height: iconSide)
if let icon = NSImage(contentsOfFile: "Resources/AppIcon.iconset/icon_512x512.png") {
    ctx.saveGState()
    let path = CGPath(roundedRect: iconRect, cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.addPath(path); ctx.clip()
    icon.draw(in: iconRect)
    ctx.restoreGState()
}
// AppKit y 轴向上: 标题在副标上方 → 标题 y 更大
let titleY = H - iconYTop - 48      // 标题基线 (上)
let subY = titleY - 44              // 副标基线 (下)
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 44, weight: .bold),
    .foregroundColor: NSColor.white,
]
NSAttributedString(string: "NTFSMate", attributes: titleAttrs)
    .draw(at: NSPoint(x: iconRect.maxX + 26, y: titleY))
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
    .foregroundColor: NSColor(srgbRed: 0.58, green: 0.68, blue: 0.85, alpha: 1),
]
NSAttributedString(string: "READ · WRITE · AUTO-MOUNT NTFS", attributes: subAttrs)
    .draw(at: NSPoint(x: iconRect.maxX + 26, y: subY))

// 3) 分隔细线 (安全区内, 不通栏)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
ctx.fill(CGRect(x: 140, y: H - 200, width: 1000, height: 2))

// 4) "drag to →" 引导 (逻辑居中)
let midY: CGFloat = H * 0.47
let dragAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 32, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.70, green: 0.76, blue: 0.87, alpha: 1),
]
let dragText = NSAttributedString(string: "drag to", attributes: dragAttrs)
let dragSize = dragText.size()
dragText.draw(at: NSPoint(x: W / 2 - dragSize.width / 2, y: midY))
ctx.setStrokeColor(NSColor(srgbRed: 0.52, green: 0.60, blue: 0.74, alpha: 1).cgColor)
ctx.setLineWidth(4)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: W / 2 - 66, y: midY - 44))
ctx.addLine(to: CGPoint(x: W / 2 + 66, y: midY - 44))
ctx.strokePath()
ctx.move(to: CGPoint(x: W / 2 + 52, y: midY - 56))
ctx.addLine(to: CGPoint(x: W / 2 + 66, y: midY - 44))
ctx.addLine(to: CGPoint(x: W / 2 + 52, y: midY - 32))
ctx.strokePath()

// 5) 底部说明
let footAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 20),
    .foregroundColor: NSColor(srgbRed: 0.50, green: 0.58, blue: 0.72, alpha: 1),
]
let foot = NSAttributedString(string: "Drag NTFSMate into Applications to install", attributes: footAttrs)
let footSize = foot.size()
foot.draw(at: NSPoint(x: W / 2 - footSize.width / 2, y: 46))

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: outFile)
print("生成: \(outFile.path)")
