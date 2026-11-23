// make-dmg-background.swift — NTFSMate 品牌化 DMG 背景 (1280×800 px @144dpi = 640×400 pt)
// Finder 按原始尺寸 1:1 绘制背景图, 因此图的 pt 尺寸必须【恰好等于】窗口 bounds (640×400),
// 内容坐标与 Finder 图标位置 (NTFSMate {165,220} / Applications {475,220}) 对位。
// 运行: swift scripts/make-dmg-background.swift   (项目根目录)
// 输出 72dpi PNG, 144dpi 由 ntfsmate-dmg-layout.sh prepare 步骤用 sips 写入。
import AppKit

let W: CGFloat = 1280, H: CGFloat = 800   // px;  pt = px / 2

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
// 统一 pt 坐标系绘制 (pt = 逻辑窗口坐标; 1pt = 2px)
let S: CGFloat = 2
ctx.scaleBy(x: S, y: S)
let w = W / S, h = H / S   // 640 × 400 pt

// 1) 浅色渐变底 (Finder 图标标签为黑字, 底色必须亮)
let bg = CGRect(x: 0, y: 0, width: w, height: h)
ctx.setFillColor(NSColor(srgbRed: 0.965, green: 0.973, blue: 0.985, alpha: 1).cgColor)
ctx.fill(bg)
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.93, green: 0.945, blue: 0.97, alpha: 1).cgColor,
    NSColor(srgbRed: 0.88, green: 0.90, blue: 0.945, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])

// 2) 品牌行 (左上): 图标 52pt + 标题 + 副标
let iconSide: CGFloat = 52
let iconPt = CGRect(x: 75, y: h - 82, width: iconSide, height: iconSide)   // 顶边距 30pt
if let icon = NSImage(contentsOfFile: "Resources/AppIcon.iconset/icon_512x512.png") {
    ctx.saveGState()
    let path = CGPath(roundedRect: iconPt, cornerWidth: 11, cornerHeight: 11, transform: nil)
    ctx.addPath(path); ctx.clip()
    icon.draw(in: iconPt)
    ctx.restoreGState()
}
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 23, weight: .bold),
    .foregroundColor: NSColor(srgbRed: 0.09, green: 0.12, blue: 0.18, alpha: 1),
]
NSAttributedString(string: "NTFSMate", attributes: titleAttrs)
    .draw(at: NSPoint(x: iconPt.maxX + 13, y: h - 62))
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold),
    .foregroundColor: NSColor(srgbRed: 0.42, green: 0.50, blue: 0.62, alpha: 1),
]
NSAttributedString(string: "READ · WRITE · AUTO-MOUNT NTFS", attributes: subAttrs)
    .draw(at: NSPoint(x: iconPt.maxX + 13, y: h - 78))

// 3) 分隔细线
ctx.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
ctx.fill(CGRect(x: 70, y: h - 100, width: 500, height: 1))

// 4) "drag to →": 两图标 (x=165 与 x=475) 中点 x=320, 文字在上、箭头在下指右
let midX: CGFloat = 320
let dragAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.42, green: 0.48, blue: 0.58, alpha: 1),
]
let dragText = NSAttributedString(string: "drag to", attributes: dragAttrs)
let dragSize = dragText.size()
dragText.draw(at: NSPoint(x: midX - dragSize.width / 2, y: h - 195))
ctx.setStrokeColor(NSColor(srgbRed: 0.45, green: 0.52, blue: 0.62, alpha: 1).cgColor)
ctx.setLineWidth(2)
ctx.setLineCap(.round)
let arrowY: CGFloat = h - 220
ctx.move(to: CGPoint(x: midX - 33, y: arrowY))
ctx.addLine(to: CGPoint(x: midX + 33, y: arrowY))
ctx.strokePath()
ctx.move(to: CGPoint(x: midX + 26, y: arrowY + 6))
ctx.addLine(to: CGPoint(x: midX + 33, y: arrowY))
ctx.addLine(to: CGPoint(x: midX + 26, y: arrowY - 6))
ctx.strokePath()

// 5) 底部说明 (居中)
let footAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 10),
    .foregroundColor: NSColor(srgbRed: 0.48, green: 0.54, blue: 0.64, alpha: 1),
]
let foot = NSAttributedString(string: "Drag NTFSMate into Applications to install", attributes: footAttrs)
let footSize = foot.size()
foot.draw(at: NSPoint(x: w / 2 - footSize.width / 2, y: 20))

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: outFile)
print("生成: \(outFile.path) (72dpi; 144dpi 由 dmg-layout prepare 写入)")
