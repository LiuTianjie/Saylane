import AppKit
import CoreText

enum Eraser {
    /// Remove a line's strokes from the picture and put its background back.
    /// Only pixels under the strokes (and a thin rim for anti-aliasing) change.
    static func erase(_ line: LineInk, in image: inout PixelImage, scale: CGFloat) {
        let window = line.window
        // Over a picture the rim also has to take the outline or shadow drawn around the letters.
        var rim = max(1, Int(scale.rounded()))
        if case .complex = line.background { rim = max(2, Int((line.rect.height * 0.14).rounded())) }
        var mask = [Bool](repeating: false, count: window.width * window.height)
        for wy in 0..<window.height {
            for wx in 0..<window.width where line.coverage[wy * window.width + wx] >= 0.08 {
                for dy in -rim...rim {
                    for dx in -rim...rim {
                        let x = wx + dx, y = wy + dy
                        if x >= 0, y >= 0, x < window.width, y < window.height { mask[y * window.width + x] = true }
                    }
                }
            }
        }
        switch line.background {
        case .flat(let colour):
            for wy in 0..<window.height {
                for wx in 0..<window.width where mask[wy * window.width + wx] {
                    image[wx + window.minX, wy + window.minY] = colour
                }
            }
        case .smooth, .complex:
            fill(mask, window: window, in: &image)
        }
    }

    /// Fill masked pixels from their surroundings, coarse to fine (push-pull).
    private static func fill(_ mask: [Bool], window: PixelRect, in image: inout PixelImage) {
        struct Level { var w: Int; var h: Int; var c: [RGB]; var weight: [Float] }
        var base = Level(w: window.width, h: window.height, c: [], weight: [])
        base.c.reserveCapacity(base.w * base.h)
        for wy in 0..<base.h {
            for wx in 0..<base.w {
                let known = !mask[wy * base.w + wx]
                base.c.append(known ? image[wx + window.minX, wy + window.minY] : RGB(r: 0, g: 0, b: 0))
                base.weight.append(known ? 1 : 0)
            }
        }
        var levels = [base]
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let fine = levels.last!
            let w = max(1, (fine.w + 1) / 2), h = max(1, (fine.h + 1) / 2)
            var coarse = Level(w: w, h: h, c: [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: w * h), weight: [Float](repeating: 0, count: w * h))
            for y in 0..<h {
                for x in 0..<w {
                    var sum = RGB(r: 0, g: 0, b: 0), total: Float = 0
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let fx = x * 2 + dx, fy = y * 2 + dy
                            guard fx < fine.w, fy < fine.h else { continue }
                            let k = fine.weight[fy * fine.w + fx]
                            sum = sum + fine.c[fy * fine.w + fx] * k; total += k
                        }
                    }
                    if total > 0 { coarse.c[y * w + x] = sum * (1 / total); coarse.weight[y * w + x] = min(1, total) }
                }
            }
            levels.append(coarse)
        }
        for index in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[index + 1]
            for y in 0..<levels[index].h {
                for x in 0..<levels[index].w where levels[index].weight[y * levels[index].w + x] < 1 {
                    // Bilinear sample of the coarser level.
                    let fx = (Float(x) + 0.5) / 2 - 0.5, fy = (Float(y) + 0.5) / 2 - 0.5
                    let x0 = max(0, min(coarse.w - 1, Int(floor(fx)))), y0 = max(0, min(coarse.h - 1, Int(floor(fy))))
                    let x1 = min(coarse.w - 1, x0 + 1), y1 = min(coarse.h - 1, y0 + 1)
                    let tx = max(0, min(1, fx - Float(x0))), ty = max(0, min(1, fy - Float(y0)))
                    let top = coarse.c[y0 * coarse.w + x0] * (1 - tx) + coarse.c[y0 * coarse.w + x1] * tx
                    let bottom = coarse.c[y1 * coarse.w + x0] * (1 - tx) + coarse.c[y1 * coarse.w + x1] * tx
                    let k = levels[index].weight[y * levels[index].w + x]
                    levels[index].c[y * levels[index].w + x] = levels[index].c[y * levels[index].w + x] * k + (top * (1 - ty) + bottom * ty) * (1 - k)
                    levels[index].weight[y * levels[index].w + x] = 1
                }
            }
        }
        for wy in 0..<window.height {
            for wx in 0..<window.width where mask[wy * window.width + wx] {
                image[wx + window.minX, wy + window.minY] = levels[0].c[wy * window.width + wx]
            }
        }
    }
}

enum Compositor {
    /// Draw the placed lines onto the (already erased) picture.
    static func draw(_ items: [(block: TextBlock, placement: Placement)], on image: inout PixelImage, scale: CGFloat) {
        let width = image.width, height = image.height
        image.data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Points, so the system font picks the optical size the source used.
            context.scaleBy(x: scale, y: scale)
            for (block, placement) in items {
                let font = block.style.font(size: placement.size)
                let c = block.style.color
                let color = NSColor(srgbRed: CGFloat(c.r / 255), green: CGFloat(c.g / 255), blue: CGFloat(c.b / 255), alpha: 1)
                context.setShouldSmoothFonts(block.style.smoothed)
                if case .complex = block.background {
                    // Over a picture, a soft edge of the opposite tone keeps the words readable.
                    let tone: CGFloat = c.luma > 128 ? 0 : 1
                    context.setShadow(offset: .zero, blur: max(1.5, placement.size * 0.14),
                        color: CGColor(srgbRed: tone, green: tone, blue: tone, alpha: 0.9))
                } else {
                    context.setShadow(offset: .zero, blur: 0, color: nil)
                }
                for line in placement.lines {
                    let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line.text,
                        attributes: [.font: font, .foregroundColor: color]))
                    // Baselines on whole device pixels, as applications draw them.
                    context.textPosition = CGPoint(x: line.x / scale, y: (CGFloat(height) - line.baseline.rounded()) / scale)
                    CTLineDraw(ct, context)
                }
            }
        }
    }
}
