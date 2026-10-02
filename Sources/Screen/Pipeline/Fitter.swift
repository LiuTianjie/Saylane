import AppKit
import CoreText

/// Where the translated words go.
struct Placement: Sendable {
    struct Line: Sendable {
        var text: String
        /// Left end of the line and its baseline, picture pixels from the top-left.
        var x: CGFloat
        var baseline: CGFloat
        var width: CGFloat
    }
    var lines: [Line] = []
    /// Points, after any shrinking.
    var size: CGFloat
    var shrink: CGFloat = 1
    var widened = false
    var addedLines = 0
    var truncated = false
}

/// Fit a translation into the place of its source. In order of preference:
/// the same size in the same footprint; the same size using empty space the
/// pixels prove is there (wider, then more lines); a slightly smaller size;
/// and only then a cut with an ellipsis. Never over other content.
enum Fitter {
    static let shrinkSteps: [CGFloat] = [1, 0.96, 0.92, 0.88, 0.84, 0.8, 0.75, 0.7]

    private static func attributed(_ text: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font])
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(text, font: font))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }

    /// Break `text` into lines no wider than `width` points.
    static func wrap(_ text: String, font: NSFont, width: CGFloat) -> [(text: String, width: CGFloat)] {
        let string = attributed(text, font: font)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var result: [(String, CGFloat)] = []
        var offset = 0
        let ns = text as NSString
        while offset < string.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(max(1, width))))
            let piece = ns.substring(with: NSRange(location: offset, length: count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append((piece, Self.width(piece, font: font))) }
            offset += count
        }
        return result
    }

    /// The longest beginning of `text` that fits `width` points with an ellipsis.
    static func truncate(_ text: String, font: NSFont, width: CGFloat) -> String {
        if Self.width(text, font: font) <= width { return text }
        let characters = Array(text)
        var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(characters[..<middle]).trimmingCharacters(in: .whitespaces) + "…"
            if Self.width(candidate, font: font) <= width { low = middle } else { high = middle - 1 }
        }
        return String(characters[..<low]).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// What a translation may occupy, in picture pixels: the source's own footprint and the empty space around it.
    struct Room: Sendable {
        /// The width of the source.
        var column: CGFloat
        /// The widest a line may be: the source plus the proven space on the side it may grow to.
        var wide: CGFloat
        /// How much taller the block may become.
        var growth: CGFloat
        /// A snug container (button, bubble, chip): the text sits in the middle, and may grow both ways.
        var snug: Bool
        /// Baseline to baseline of the source, and from its first baseline to its last.
        var pitch: CGFloat
        var span: CGFloat
    }

    static func room(for block: TextBlock, scale: CGFloat) -> Room {
        let sizePx = block.style.size * scale
        let column = block.rect.width
        let snug = block.free.upSolid && block.free.downSolid
            && abs(block.free.up - block.free.down) <= max(2 * scale, sizePx * 0.3) && block.free.up < sizePx * 2.5
        // Empty space the pixels prove, less a margin where something stopped the scan.
        // Inside a container the source already keeps its own padding; a little of it may be used.
        let margin = sizePx * 0.45, inner = sizePx * 0.12
        func usable(_ free: CGFloat, _ stopped: Bool, _ margin: CGFloat) -> CGFloat { max(0, free - (stopped ? margin : 0)) }
        let side = snug ? sizePx * 0.3 : margin
        let roomRight = usable(block.free.right, block.free.rightEdge, side), roomLeft = usable(block.free.left, block.free.leftEdge, side)
        let roomDown = usable(block.free.down, block.free.downEdge, snug ? inner : margin)
        let roomUp = usable(block.free.up, block.free.upEdge, snug ? inner : margin)
        let wide: CGFloat = switch block.align {
        case .left: column + roomRight
        case .right: column + roomLeft
        case .center: column + 2 * min(roomLeft, roomRight)
        }
        let pitch = block.pitch > 0 ? block.pitch : sizePx * 1.28
        return Room(column: column, wide: wide, growth: snug ? roomUp + roomDown : roomDown, snug: snug,
                    pitch: pitch, span: CGFloat(block.lines.count - 1) * pitch)
    }

    /// Roughly how many characters of a translation fit where the source is, at the source's size
    /// and in as many lines as the source has: the first thing `place` tries. Han, kana and hangul
    /// are one em wide whatever the typeface; for other scripts the width of a typical character
    /// is taken from ordinary words in the block's own font. An estimate: real words are wider or
    /// narrower than typical ones, and a wrapped line seldom ends exactly at the edge.
    static func capacity(_ block: TextBlock, scale: CGFloat, fullWidth: Bool) -> Int {
        let room = Self.room(for: block, scale: scale)
        let advance = fullWidth ? block.style.size : width(typicalWords, font: block.style.font()) / CGFloat(typicalWords.count)
        let perLine = (room.wide / scale + 0.5) / max(1, advance)
        let lines = CGFloat(block.lines.count)
        // Where a line is broken, what is left of it stays empty: a character of Han, about half a word otherwise.
        let lost: CGFloat = fullWidth ? 0.5 : 3
        return max(1, Int(lines == 1 ? perLine : lines * perLine - (lines - 1) * lost))
    }

    private static let typicalWords = "Open the Settings window to change how New Messages are shown"

    /// `only`: the one size step to use, when a group of equals has agreed on it.
    static func place(_ block: TextBlock, scale: CGFloat, only: CGFloat? = nil) -> Placement {
        let text = block.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        var placement = Placement(size: block.style.size)
        guard !text.isEmpty else { return placement }
        let sizePx = block.style.size * scale
        let room = Self.room(for: block, scale: scale)
        let column = room.column, wide = room.wide, growth = room.growth, snug = room.snug
        let sourceLines = block.lines.count

        struct Fit { var lines: [(text: String, width: CGFloat)]; var shrink: CGFloat; var pitch: CGFloat; var width: CGFloat }
        let sourcePitch = room.pitch, span = room.span
        func attempt(_ shrink: CGFloat, _ width: CGFloat, grow: Bool) -> Fit? {
            let font = block.style.font(size: block.style.size * shrink)
            // Half a point of tolerance: the source itself must fit its own width.
            let lines = wrap(text, font: font, width: width / scale + 0.5)
            let natural = sourcePitch * shrink
            if lines.count <= sourceLines { return Fit(lines: lines, shrink: shrink, pitch: natural, width: width) }
            guard grow else { return nil }
            // More lines than the source: set them closer if need be, but never closer than text reads well.
            let needed = (span + growth) / CGFloat(lines.count - 1)
            let tightest = sizePx * shrink * 1.2
            guard needed >= tightest else { return nil }
            return Fit(lines: lines, shrink: shrink, pitch: min(natural, needed), width: width)
        }
        var fit: Fit?
        search: for shrink in only.map({ [$0] }) ?? shrinkSteps {
            for (width, grow) in [(column, false), (wide, false), (column, true), (wide, true)] {
                if let found = attempt(shrink, width, grow: grow) { fit = found; break search }
            }
        }
        if fit == nil {
            // Nothing fits. Small and cut would be the worst of both: stay near
            // the source's size, use every line there is room for, and cut.
            let shrink = only ?? 0.88
            let font = block.style.font(size: block.style.size * shrink)
            let pitch = sizePx * shrink * 1.2
            let allowed = max(1, Int((span + growth) / pitch) + 1)
            var lines = wrap(text, font: font, width: wide / scale + 0.5)
            if lines.count > allowed {
                let rest = lines[(allowed - 1)...].map(\.text).joined(separator: " ")
                let cut = truncate(rest, font: font, width: wide / scale)
                lines = Array(lines[..<(allowed - 1)]) + [(cut, width(cut, font: font))]
                placement.truncated = true
            }
            let fitted = lines.count > 1 ? min(sourcePitch * shrink, (span + growth) / CGFloat(lines.count - 1)) : sourcePitch * shrink
            fit = Fit(lines: lines, shrink: shrink, pitch: max(pitch, fitted), width: wide)
        }
        guard let fit else { return placement }
        placement.shrink = fit.shrink
        placement.size = block.style.size * fit.shrink
        placement.addedLines = max(0, fit.lines.count - sourceLines)
        placement.widened = (fit.lines.map(\.width).max() ?? 0) * scale > column + 1

        var first = block.firstBaseline
        if snug {
            // Keep the middle of the text where the middle of the source was.
            let last = block.lines[block.lines.count - 1].ink.baseline
            first = (block.firstBaseline + last) / 2 - CGFloat(fit.lines.count - 1) * fit.pitch / 2
        }
        for (index, line) in fit.lines.enumerated() {
            let width = line.width * scale
            let x: CGFloat = switch block.align {
            case .left: block.rect.minX
            case .right: block.rect.maxX - width
            case .center: block.rect.midX - width / 2
            }
            placement.lines.append(.init(text: line.text, x: x, baseline: first + CGFloat(index) * fit.pitch, width: width))
        }
        return placement
    }
}
