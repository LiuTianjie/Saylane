import CoreGraphics
import Foundation

/// A colour in 0...255 per channel, sRGB.
struct RGB: Sendable, Equatable {
    var r: Float, g: Float, b: Float

    static func - (a: RGB, b: RGB) -> RGB { RGB(r: a.r - b.r, g: a.g - b.g, b: a.b - b.b) }
    static func + (a: RGB, b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
    static func * (a: RGB, k: Float) -> RGB { RGB(r: a.r * k, g: a.g * k, b: a.b * k) }
    var length: Float { (r * r + g * g + b * b).squareRoot() }
    func distance(to other: RGB) -> Float { (self - other).length }
    var luma: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var clamped: RGB { RGB(r: min(255, max(0, r)), g: min(255, max(0, g)), b: min(255, max(0, b))) }
}

/// Integer pixel rectangle, top-left origin, `maxX`/`maxY` exclusive.
struct PixelRect: Sendable, Equatable {
    var minX: Int, minY: Int, maxX: Int, maxY: Int
    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    /// The pixels a rectangle touches, grown by `pad`, kept inside `bounds`.
    init(_ rect: CGRect, pad: CGFloat = 0, in bounds: PixelRect) {
        minX = max(bounds.minX, Int(floor(rect.minX - pad)))
        minY = max(bounds.minY, Int(floor(rect.minY - pad)))
        maxX = min(bounds.maxX, Int(ceil(rect.maxX + pad)))
        maxY = min(bounds.maxY, Int(ceil(rect.maxY + pad)))
    }

    var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
}

/// The screenshot as bytes: RGBA, 8 bits, sRGB, row 0 at the top.
struct PixelImage: @unchecked Sendable {
    let width: Int
    let height: Int
    var data: [UInt8]

    var bounds: PixelRect { PixelRect(minX: 0, minY: 0, maxX: width, maxY: height) }

    init(width: Int, height: Int, fill: RGB = RGB(r: 255, g: 255, b: 255)) {
        self.width = width
        self.height = height
        data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            data[i * 4] = UInt8(fill.r); data[i * 4 + 1] = UInt8(fill.g); data[i * 4 + 2] = UInt8(fill.b)
        }
    }

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard ok else { return nil }
    }

    @inline(__always) subscript(x: Int, y: Int) -> RGB {
        get {
            let i = (y * width + x) * 4
            return RGB(r: Float(data[i]), g: Float(data[i + 1]), b: Float(data[i + 2]))
        }
        set {
            let i = (y * width + x) * 4
            let c = newValue.clamped
            data[i] = UInt8(c.r.rounded()); data[i + 1] = UInt8(c.g.rounded()); data[i + 2] = UInt8(c.b.rounded())
        }
    }

    func cgImage() -> CGImage? {
        var copy = data
        return copy.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .makeImage()
        }
    }
}

func median<T: Comparable>(_ values: [T]) -> T? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
}

func percentile(_ values: [Float], _ q: Float) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * q)))]
}
