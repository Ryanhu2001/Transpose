import AppKit
import Foundation

// Transpose: one drawn serif T in system blue on a quiet, cool-white tile.
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

// This contour matches TransposeBrand.outline in native/Sources/TransposeNative/ui/BrandMark.swift.
func tMark(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 17, y: 86))
    path.addCurve(to: CGPoint(x: 35, y: 85), control1: CGPoint(x: 23, y: 84), control2: CGPoint(x: 29, y: 85))
    path.addLine(to: CGPoint(x: 75, y: 85))
    path.addCurve(to: CGPoint(x: 86, y: 89), control1: CGPoint(x: 80, y: 85), control2: CGPoint(x: 83, y: 87))
    path.addLine(to: CGPoint(x: 81, y: 67))
    path.addLine(to: CGPoint(x: 77, y: 67))
    path.addCurve(to: CGPoint(x: 58, y: 78), control1: CGPoint(x: 76, y: 76), control2: CGPoint(x: 68, y: 78))
    path.addLine(to: CGPoint(x: 55, y: 27))
    path.addCurve(to: CGPoint(x: 61, y: 18), control1: CGPoint(x: 55, y: 21), control2: CGPoint(x: 57, y: 19))
    path.addLine(to: CGPoint(x: 65, y: 16))
    path.addLine(to: CGPoint(x: 65, y: 12))
    path.addLine(to: CGPoint(x: 34, y: 12))
    path.addLine(to: CGPoint(x: 34, y: 16))
    path.addLine(to: CGPoint(x: 39, y: 18))
    path.addCurve(to: CGPoint(x: 44, y: 27), control1: CGPoint(x: 43, y: 19), control2: CGPoint(x: 44, y: 22))
    path.addLine(to: CGPoint(x: 47, y: 78))
    path.addCurve(to: CGPoint(x: 24, y: 67), control1: CGPoint(x: 36, y: 78), control2: CGPoint(x: 28, y: 76))
    path.addLine(to: CGPoint(x: 20, y: 64))
    path.addLine(to: CGPoint(x: 15, y: 64))
    path.closeSubpath()
    var transform = CGAffineTransform(a: rect.width / 100, b: 0, c: 0,
                                     d: rect.height / 100, tx: rect.minX, ty: rect.minY)
    return path.copy(using: &transform) ?? path
}

func drawIcon(size: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 76, width: 880, height: 880), xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x243247, alpha: 0.13)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -15)
    shadow.set()
    color(0xF5F7FA).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xFEFEFF), color(0xF6F8FB), color(0xEAF0F6)])?.draw(in: tile, angle: -90)
    color(0xFFFFFF, alpha: 0.86).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    context.cgContext.saveGState()
    context.cgContext.addPath(tMark(in: CGRect(x: 137, y: 125, width: 750, height: 750)))
    context.cgContext.clip()
    if let blue = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [color(0x087DF2).cgColor, color(0x0876E8).cgColor] as CFArray,
                             locations: [0, 1]) {
        context.cgContext.drawLinearGradient(blue, start: CGPoint(x: 512, y: 850),
                                            end: CGPoint(x: 512, y: 200),
                                            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    context.cgContext.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (size, filename) in variants {
    guard let data = drawIcon(size: size) else {
        fputs("Cannot render icon at \(size) px\n", stderr)
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(filename), options: .atomic)
}
