// [INPUT]: 依赖 AppKit 的矢量绘制能力。 [OUTPUT]: 生成 Resources/AppIcon.iconset 各尺寸 PNG。 [POS]: 历史麦克风图标的备用生成器；当前 P 品牌使用 import-icon.swift。 [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
import AppKit
import CoreGraphics

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// 背景：深蓝纵向渐变 + 右上环境光，与手机页主题一致。
let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerWidth: 224, cornerHeight: 224, transform: nil)
context.addPath(bg); context.clip()
let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(srgbRed: 0.10, green: 0.14, blue: 0.27, alpha: 1),
    CGColor(srgbRed: 0.045, green: 0.065, blue: 0.125, alpha: 1)
] as CFArray, locations: [0, 1])!
context.drawLinearGradient(base, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(srgbRed: 0.32, green: 0.45, blue: 0.72, alpha: 0.40),
    CGColor(srgbRed: 0.32, green: 0.45, blue: 0.72, alpha: 0)
] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 820, y: 940), startRadius: 0, endCenter: CGPoint(x: 820, y: 940), endRadius: 640, options: [])

// 前景：薄荷绿麦克风 + 声波弧，渐变统一从上到下。
let ink = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(srgbRed: 0.68, green: 0.97, blue: 0.84, alpha: 1),
    CGColor(srgbRed: 0.24, green: 0.80, blue: 0.53, alpha: 1)
] as CFArray, locations: [0, 1])!

// save/restore 隔离 clip，避免图形间互相污染。
func strokeInk(_ path: CGPath, width: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.setLineWidth(width); context.setLineCap(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(ink, start: CGPoint(x: 512, y: 760), end: CGPoint(x: 512, y: 160), options: [])
    context.restoreGState()
}

// 麦克风拾音头（胶囊，填充）
context.saveGState()
context.addPath(CGPath(roundedRect: CGRect(x: 437, y: 330, width: 150, height: 210), cornerWidth: 75, cornerHeight: 75, transform: nil))
context.clip()
context.drawLinearGradient(ink, start: CGPoint(x: 512, y: 760), end: CGPoint(x: 512, y: 160), options: [])
context.restoreGState()

// 支架 U 型弧（下半圆）+ 引线 + 底座
let bracket = CGMutablePath()
bracket.addArc(center: CGPoint(x: 512, y: 430), radius: 170, startAngle: CGFloat.pi, endAngle: 0, clockwise: false)
strokeInk(bracket, width: 42)
let stem = CGMutablePath()
stem.move(to: CGPoint(x: 512, y: 260)); stem.addLine(to: CGPoint(x: 512, y: 208))
strokeInk(stem, width: 42)
strokeInk(CGPath(roundedRect: CGRect(x: 424, y: 176, width: 176, height: 36), cornerWidth: 18, cornerHeight: 18, transform: nil), width: 26)

// 两侧声波弧（白色，近实远虚，以麦克风为圆心左右张开）
let spread = CGFloat(0.5)
for (radius, width, alpha) in [(CGFloat(250), CGFloat(40), CGFloat(0.9)), (CGFloat(322), CGFloat(34), CGFloat(0.5))] {
    for side in [CGFloat(0), CGFloat.pi] {
        context.saveGState()
        let wave = CGMutablePath()
        wave.addArc(center: CGPoint(x: 512, y: 430), radius: radius,
                    startAngle: side - spread, endAngle: side + spread, clockwise: false)
        context.addPath(wave)
        context.setLineWidth(width); context.setLineCap(.round)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        context.strokePath()
        context.restoreGState()
    }
}

// 顶部内高光
context.addPath(CGPath(roundedRect: CGRect(x: 6, y: 6, width: size - 12, height: size - 12), cornerWidth: 218, cornerHeight: 218, transform: nil))
context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)); context.setLineWidth(3); context.strokePath()

image.unlockFocus()

// 导出 iconset 全部尺寸
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for side in [16.0, 32.0, 128.0, 256.0, 512.0] {
    for scale in [1.0, 2.0] {
        let pixel = Int(side * scale)
        let scaled = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard let tiff = scaled.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
              let png = out.representation(using: .png, properties: [:]) else { fatalError("render \(pixel)") }
        let name = scale == 1 ? "icon_\(Int(side))x\(Int(side)).png" : "icon_\(Int(side))x\(Int(side))@2x.png"
        try! png.write(to: outDir.appendingPathComponent(name))
        print("wrote", name)
    }
}
