import AppKit
import Foundation

// The application icon: Saylane's mark — a speech bubble with a text cursor,
// what is said lands at the caret — on a dark tile, the cursor in the brand's
// coral. Same geometry as the input-menu icon (scripts/generate-input-icon.swift).
// Writes AppIcon.png (1024), the iconset and AppIcon.icns into Sources/Resources.

let resources = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/Resources")
let size = 1024.0

/// The rounded square of macOS icons: 824 pt of the 1024 canvas, corners that
/// run into the sides without a kink (a superellipse).
func tile(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, n = 5.0
    for step in 0...720 {
        let t = Double(step) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func draw(_ context: CGContext) {
    let rgb = CGColorSpaceCreateDeviceRGB()
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: rgb, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                              CGFloat(hex & 0xff) / 255, alpha])!
    }
    let frame = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = tile(in: frame)

    // A soft shadow under the tile, as system icons have.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
    context.addPath(shape)
    context.setFillColor(color(0x17181c))
    context.fillPath()
    context.restoreGState()

    // The tile: charcoal, a little lighter at the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: rgb, colors: [color(0x30323a), color(0x131417)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: frame.maxY), end: CGPoint(x: 0, y: frame.minY), options: [])
    context.restoreGState()

    // The mark, on the menu icon's 16-unit grid (y up), scaled into the tile.
    let unit = 36.0
    let originX = size / 2 - 8 * unit, originY = size / 2 - 8.25 * unit
    func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: originX + x * unit, y: originY + y * unit) }
    let bubble = CGMutablePath()
    bubble.addRoundedRect(in: CGRect(origin: point(1, 4.25), size: CGSize(width: 14 * unit, height: 10.75 * unit)),
                          cornerWidth: 3.5 * unit, cornerHeight: 3.5 * unit)
    bubble.addLines(between: [point(3.75, 4.3), point(3.25, 1.5), point(7.25, 4.3)])
    bubble.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.28))
    context.addPath(bubble)
    context.setFillColor(color(0xf7f7fa))
    context.fillPath(using: .winding)
    context.restoreGState()

    // The text cursor, in coral.
    let stem = 0.75, serif = 2.125, thickness = 1.25, high = 12.5, low = 6.75
    let cursor = CGMutablePath()
    cursor.addLines(between: [
        point(8 - serif, high), point(8 + serif, high), point(8 + serif, high - thickness), point(8 + stem, high - thickness),
        point(8 + stem, low + thickness), point(8 + serif, low + thickness), point(8 + serif, low), point(8 - serif, low),
        point(8 - serif, low + thickness), point(8 - stem, low + thickness), point(8 - stem, high - thickness),
        point(8 - serif, high - thickness),
    ])
    cursor.closeSubpath()
    context.addPath(cursor)
    context.setFillColor(color(0xe9705b))
    context.fillPath()
}

func render(pixels: Int) -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.scaleBy(x: Double(pixels) / size, y: Double(pixels) / size)
    draw(context)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

try render(pixels: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("PASS: AppIcon.png, AppIcon.iconset and AppIcon.icns written to \(resources.path)")
