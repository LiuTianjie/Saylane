import AppKit
import CoreText

enum Face: String, Sendable { case sans, serif, mono }

enum Weight: Int, Sendable, CaseIterable {
    case regular = 400, medium = 500, semibold = 600, bold = 700

    var system: NSFont.Weight {
        switch self { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold }
    }
}

/// How a line of text is set, as far as the pixels can tell.
struct TextStyle: Sendable {
    /// Points (picture pixels / scale).
    var size: CGFloat
    var weight: Weight
    var face: Face
    var color: RGB
    /// Whether the source was drawn with macOS font smoothing (slightly heavier strokes).
    var smoothed: Bool

    func font(size override: CGFloat? = nil) -> NSFont {
        Fonts.font(face: face, weight: weight, size: override ?? size)
    }
}

enum Fonts {
    static func font(face: Face, weight: Weight, size: CGFloat) -> NSFont {
        switch face {
        case .sans:
            return NSFont.systemFont(ofSize: size, weight: weight.system)
        case .serif:
            // Times for Latin; Han falls back to Songti through the cascade.
            let name = weight.rawValue >= 600 ? "Times New Roman Bold" : "Times New Roman"
            let base = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight.system)
            let songti = NSFontDescriptor(fontAttributes: [.name: weight.rawValue >= 600 ? "Songti SC Bold" : "Songti SC Regular"])
            let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [songti]])
            return NSFont(descriptor: descriptor, size: size) ?? base
        case .mono:
            return NSFont(name: weight.rawValue >= 600 ? "Menlo Bold" : "Menlo", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight.system)
        }
    }
}

enum Rasterizer {
    /// Draw one line the way the compositor will, for measuring. Returns the
    /// picture and the box a recogniser would report for the line.
    static func render(_ text: String, font: NSFont, scale: CGFloat, smoothed: Bool,
                       ink: RGB = RGB(r: 0, g: 0, b: 0), paper: RGB = RGB(r: 255, g: 255, b: 255)) -> (image: PixelImage, box: CGRect)? {
        let color = NSColor(srgbRed: CGFloat(ink.r / 255), green: CGFloat(ink.g / 255), blue: CGFloat(ink.b / 255), alpha: 1)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: font, .foregroundColor: color]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pad = ceil(font.pointSize * 0.6)
        let w = Int(ceil((width + pad * 2) * scale)), h = Int(ceil((ascent + descent + pad * 2) * scale))
        guard w > 4, h > 4, w < 16_000, h < 2_000 else { return nil }
        var image = PixelImage(width: w, height: h, fill: paper)
        let ok = image.data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.scaleBy(x: scale, y: scale)
            context.setShouldSmoothFonts(smoothed)
            // Applications put baselines on whole device pixels; do the same, so the
            // reference meets the pixel grid the way the source did.
            context.textPosition = CGPoint(x: pad, y: ((pad + descent) * scale).rounded() / scale)
            CTLineDraw(line, context)
            return true
        }
        guard ok else { return nil }
        return (image, CGRect(x: pad * scale, y: pad * scale, width: width * scale, height: (ascent + descent) * scale))
    }
}

enum StyleEstimator {
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
    }

    static func hanShare(_ text: String) -> Double {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return 0 }
        return Double(scalars.filter(isHan).count) / Double(scalars.count)
    }

    /// A stroke width within this (log ratio) of the regular face's is regular.
    private static let plainEnough: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["V2_PLAIN"] ?? "") ?? 0.08)

    /// How the height of a word is read off its ink; "mass" is an experiment kept for the scoring harness.
    private static let riseMode = ProcessInfo.processInfo.environment["V2_RISE"] ?? "edge"

    private static func inkBounds(_ text: String, font: NSFont) -> CGRect {
        CTLineGetImageBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), nil)
    }

    /// The height that says how big the type is: for Latin, how far the words
    /// rise above the baseline (the typical word, so one icon or one odd glyph
    /// does not decide); for Han, the full height of the ink.
    private static func extent(_ ink: LineInk, han: Bool) -> CGFloat {
        let mode = riseMode
        if han { return mode == "mass" ? ink.strokeHeight : ink.rect.height }
        let rises = (mode == "mass" ? ink.blobs.map(\.rise) : ink.blobs.map { ink.baseline - $0.top }).filter { $0 > 0 }.sorted()
        guard !rises.isEmpty else { return ink.ascent }
        // Upper quartile: most words carry a capital or an ascender, some are all x-height.
        return rises[min(rises.count - 1, Int(Double(rises.count) * 0.75))]
    }

    /// Size, face, weight and colour of one measured line. The reference is
    /// always the same words drawn and measured the same way, so what the
    /// rasteriser and the measuring add cancels out.
    static func estimate(text: String, ink: LineInk, scale: CGFloat) -> TextStyle? {
        let han = hanShare(text)
        let isHanLine = han >= 0.3
        let paper: RGB = { if case .flat(let c) = ink.background { return c }; return ink.color.luma > 128 ? RGB(r: 0, g: 0, b: 0) : RGB(r: 255, g: 255, b: 255) }()
        let widthPt = ink.rect.width / scale

        // First guess from outlines.
        var size: CGFloat = 100
        for _ in 0..<2 {
            let bounds = inkBounds(text, font: NSFont.systemFont(ofSize: size))
            let reference = isHanLine ? bounds.height : bounds.maxY
            guard reference > 0.5 else { return nil }
            size = (isHanLine ? ink.rect.height : ink.ascent) / scale * size / reference
        }
        guard size >= 4, size <= 400 else { return nil }

        // Face: only on clear evidence from the width of the line.
        var face = Face.sans
        if !isHanLine, text.count >= 6 {
            func widthError(_ font: NSFont) -> CGFloat {
                var probe = size
                var bounds = inkBounds(text, font: NSFont(descriptor: font.fontDescriptor, size: probe) ?? font)
                guard bounds.maxY > 0.5 else { return 1 }
                probe = ink.ascent / scale * probe / bounds.maxY
                bounds = inkBounds(text, font: NSFont(descriptor: font.fontDescriptor, size: probe) ?? font)
                return abs(bounds.width - widthPt) / widthPt
            }
            let sans = min(widthError(NSFont.systemFont(ofSize: size)), widthError(NSFont.systemFont(ofSize: size, weight: .semibold)))
            let serif = min(widthError(Fonts.font(face: .serif, weight: .regular, size: size)),
                            widthError(Fonts.font(face: .serif, weight: .bold, size: size)))
            let mono = widthError(Fonts.font(face: .mono, weight: .regular, size: size))
            if mono < 0.035, sans > 0.10 { face = .mono }
            else if serif < 0.04, sans > serif + 0.06 { face = .serif }
        }

        // Size: draw the same words, measure them the same way, compare.
        func reference(_ size: CGFloat, weight: Weight, smoothed: Bool, text: String) -> LineInk? {
            guard let rendered = Rasterizer.render(text, font: Fonts.font(face: face, weight: weight, size: size),
                scale: scale, smoothed: smoothed, ink: ink.color, paper: paper) else { return nil }
            return InkAnalyzer.measure(rendered.image, box: rendered.box)
        }
        let source = extent(ink, han: isHanLine)
        for _ in 0..<2 {
            guard let drawn = reference(size, weight: .regular, smoothed: true, text: text) else { break }
            let other = extent(drawn, han: isHanLine)
            guard other > 1 else { break }
            var next = size * source / other
            if han >= 0.9, text.count >= 2, drawn.rect.width > 1 {
                // Every Han glyph advances one em whatever the typeface; faces differ in how much of the em they fill.
                let byWidth = size * ink.rect.width / drawn.rect.width
                if abs(byWidth - next) / next <= 0.2 { next = byWidth }
            }
            let change = abs(next - size) / size
            size = next
            if change < 0.03 { break }
        }
        guard size >= 4, size <= 400 else { return nil }

        // Weight and smoothing: the variant whose strokes are as thick as the source's.
        var weight = Weight.regular
        var smoothed = true
        if ink.stem > 0.2 {
            var best: (error: CGFloat, weight: Weight, smoothed: Bool)?
            let sample = String(text.prefix(40))
            search: for candidate in Weight.allCases {
                for smoothing in [true, false] {
                    guard let drawn = reference(size, weight: candidate, smoothed: smoothing, text: sample), drawn.stem > 0.2 else { continue }
                    // A slight preference for the plain variants, so noise does not invent medium text.
                    let penalty: CGFloat = (candidate == .medium ? 0.05 : 0) + (smoothing ? 0 : 0.02)
                    let error = abs(log(drawn.stem / ink.stem)) + penalty
                    if best == nil || error < best!.error { best = (error, candidate, smoothing) }
                    // Most text is plain: strokes as thick as the regular face's settle it without drawing the other six.
                    if candidate == .regular, error < Self.plainEnough { break search }
                }
            }
            if let best { weight = best.weight; smoothed = best.smoothed }
        }
        return TextStyle(size: size, weight: weight, face: face, color: ink.color, smoothed: smoothed)
    }
}
