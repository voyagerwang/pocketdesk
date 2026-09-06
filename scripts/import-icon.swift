// [INPUT]: 依赖 AppKit 与白底蓝色 PocketDesk 图标原稿。
// [OUTPUT]: 生成带透明边距、精确像素尺寸的 AppIcon.iconset PNG。
// [POS]: 当前品牌图标的导入入口；安装脚本消费由 iconutil 打包的 icns。
// [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("用法: import-icon.swift <源图.png> <iconset目录>") }
let srcURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let src = NSImage(contentsOf: srcURL) else { fatalError("无法读取源图") }
let w = Int(src.size.width), h = Int(src.size.height)
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
src.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

// 蓝色底板包围盒：排除白底纹理和浅灰阴影，保留完整品牌底板。
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        guard let c = rep.colorAt(x: x, y: y) else { continue }
        if c.alphaComponent > 0.5 && c.blueComponent - c.redComponent > 0.2 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
guard minX < maxX && minY < maxY else { fatalError("未找到蓝色图标底板") }
let side = max(maxX - minX, maxY - minY) + 1
print("包围盒:", minX, minY, maxX, maxY, "边长:", side)

guard let cgSource = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError() }
// colorAt 的 y 从顶部起，转成 CG 的底部起点坐标
let cgCropY = Double(h - (maxY + 1))

// Apple Big Sur 模板：1024 画布，内容 824（80.5%），四周 100 边距；蒙版内缩 4px 防白边
let canvas = 1024.0, content = 824.0, pad = (canvas - content) / 2
let inset: Double = 4

let outRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
outRep.size = NSSize(width: canvas, height: canvas)
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: outRep)!.cgContext
ctx.setShouldAntialias(true)
ctx.setAllowsAntialiasing(true)
let target = CGRect(x: pad + inset, y: pad + inset, width: content - inset * 2, height: content - inset * 2)
let mask = CGPath(roundedRect: target, cornerWidth: target.width * 0.24, cornerHeight: target.width * 0.24, transform: nil)
ctx.addPath(mask)
ctx.clip()
let scaleX = target.width / Double(maxX - minX + 1)
let scaleY = target.height / Double(maxY - minY + 1)
ctx.translateBy(x: target.minX - Double(minX) * scaleX, y: target.minY - cgCropY * scaleY)
ctx.scaleBy(x: scaleX, y: scaleY)
ctx.draw(cgSource, in: CGRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

// 输出 iconset 全部尺寸
let composed = NSImage(size: NSSize(width: canvas, height: canvas))
composed.addRepresentation(outRep)
for sidePt in [16.0, 32.0, 128.0, 256.0, 512.0] {
    for scaleF in [1.0, 2.0] {
        let pixel = Int(sidePt * scaleF)
        // 显式创建像素缓冲，避免 lockFocus/显示器倍率使 @2x 产物尺寸失真。
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        composed.draw(in: NSRect(x: 0, y: 0, width: pixel, height: pixel))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else { fatalError("渲染 \(pixel)") }
        let name = scaleF == 1 ? "icon_\(Int(sidePt))x\(Int(sidePt)).png" : "icon_\(Int(sidePt))x\(Int(sidePt))@2x.png"
        try! png.write(to: outDir.appendingPathComponent(name))
        print("wrote", name)
    }
}
