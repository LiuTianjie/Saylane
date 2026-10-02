import CoreGraphics
import Foundation

/// What lies behind a line of text.
enum Background: Sendable {
    /// One colour.
    case flat(RGB)
    /// A smooth ramp: colour = origin + dx·x + dy·y, x/y in picture pixels.
    case smooth(origin: RGB, dx: RGB, dy: RGB)
    /// A picture or video frame; `typical` is only a rough colour.
    case complex(typical: RGB)

    func color(x: Int, y: Int) -> RGB {
        switch self {
        case .flat(let c): return c
        case .smooth(let o, let dx, let dy): return o + dx * Float(x) + dy * Float(y)
        case .complex(let c): return c
        }
    }

    var name: String {
        switch self { case .flat: "flat"; case .smooth: "smooth"; case .complex: "complex" }
    }
}

/// One line of text as the pixels show it.
struct LineInk: Sendable {
    /// The analysed window in picture pixels.
    var window: PixelRect
    /// Ink coverage 0...1 for every pixel of `window`, row-major.
    var coverage: [Float]
    /// Tight ink rectangle, sub-pixel edges, picture pixels.
    var rect: CGRect
    /// Where the glyphs stand, picture pixels from the top.
    var baseline: CGFloat
    var background: Background
    var color: RGB
    /// Typical horizontal run of ink across a stroke, in pixels.
    var stem: CGFloat
    /// Share of ink columns whose lowest ink is on the baseline. Low for CJK.
    var baselineSupport: Float
    /// Runs of ink separated by word-sized gaps, left to right.
    var blobs: [Blob] = []
    /// An icon or badge at this end of the line was left out.
    var trimmedLeading = false, trimmedTrailing = false
    /// Width in pixels of what was left out at each end.
    var trimmedLeadingWidth: CGFloat = 0, trimmedTrailingWidth: CGFloat = 0
    /// Over a picture: how far a pixel's colour may be from the text's and still count.
    var reach: Float = 0
    /// Height of the tallest upright stroke of the line, from the amount of ink in its column.
    var strokeHeight: CGFloat = 0

    struct Blob: Sendable {
        var minX: CGFloat, maxX: CGFloat
        /// Top and bottom of the tallest ink in the run, sub-pixel.
        var top: CGFloat, bottom: CGFloat
        var color: RGB
        /// Typical horizontal run of ink as a share of the run's width: strokes are thin, a filled icon or badge is not.
        var solidity: Float
        /// The background right around this run.
        var paper: RGB
        /// How far the run's tallest upright stroke rises from the baseline, in pixels.
        /// Taken from the amount of ink in a column, which does not depend on where
        /// the glyph falls on the pixel grid the way an edge position does.
        var rise: CGFloat = 0
    }

    var ascent: CGFloat { baseline - rect.minY }

    @inline(__always) func alpha(_ x: Int, _ y: Int) -> Float {
        guard x >= window.minX, x < window.maxX, y >= window.minY, y < window.maxY else { return 0 }
        return coverage[(y - window.minY) * window.width + (x - window.minX)]
    }
}

enum InkAnalyzer {
    /// Measure the line that a recogniser reported at `box` (picture pixels, top-left origin).
    /// `paper` forces the background colour; `text` forces the text colour over a picture.
    static func measure(_ image: PixelImage, box: CGRect, paper: RGB? = nil, text: (colour: RGB, reach: Float)? = nil) -> LineInk? {
        let h = box.height
        guard h >= 4, box.width >= 2 else { return nil }
        let window = PixelRect(CGRect(x: box.minX - h * 0.5, y: box.minY - h * 0.45,
            width: box.width + h, height: h * 1.9), in: image.bounds)
        guard window.width > 2, window.height > 2 else { return nil }

        let background = paper.map { Background.flat($0) } ?? estimateBackground(image, window: window, box: box)
        // Distance from the background, per pixel.
        var distance = [Float](repeating: 0, count: window.width * window.height)
        for y in window.minY..<window.maxY {
            for x in window.minX..<window.maxX {
                distance[(y - window.minY) * window.width + (x - window.minX)] =
                    image[x, y].distance(to: background.color(x: x, y: y))
            }
        }
        // Full ink = the strongest contrast found inside the reported box.
        let inner = PixelRect(box, in: window)
        var inside: [Float] = []
        inside.reserveCapacity(inner.width * inner.height)
        for y in inner.minY..<inner.maxY {
            for x in inner.minX..<inner.maxX {
                inside.append(distance[(y - window.minY) * window.width + (x - window.minX)])
            }
        }
        var coverage: [Float]
        var textColour: RGB?
        var reach: Float = 0
        if case .complex = background {
            // Over a picture there is no background colour to measure against.
            // The text is the one colour that stays the same across the line.
            guard let found = text ?? textCluster(image, box: inner) else { return nil }
            textColour = found.colour
            reach = found.reach
            coverage = [Float](repeating: 0, count: window.width * window.height)
            for y in window.minY..<window.maxY {
                for x in window.minX..<window.maxX {
                    // Half-way between the text's colour and its surroundings is half covered.
                    let d = image[x, y].distance(to: found.colour)
                    coverage[(y - window.minY) * window.width + (x - window.minX)] = max(0, min(1, 1.15 - 1.3 * d / found.reach))
                }
            }
        } else {
            let full = percentile(inside, 0.985)
            guard full >= 24 else { return nil }   // nothing readable here
            let noise: Float = { if case .flat = background { return 6 } else { return 14 } }()
            coverage = distance.map { d -> Float in
                d <= noise ? 0 : min(1, (d - noise) / max(1, full - noise))
            }
        }

        if textColour == nil {
            // Letters are islands in their paper. Whatever is not paper and reaches the
            // edge of the window (the page outside a button, a neighbouring line, an
            // icon cut by the window) is not this line's ink.
            let w = window.width, hgt = window.height
            var outside = [Bool](repeating: false, count: w * hgt)
            var stack: [Int] = []
            func seedIfInk(_ x: Int, _ y: Int) {
                let i = y * w + x
                if !outside[i], coverage[i] >= 0.3 { outside[i] = true; stack.append(i) }
            }
            for x in 0..<w { seedIfInk(x, 0); seedIfInk(x, hgt - 1) }
            for y in 0..<hgt { seedIfInk(0, y); seedIfInk(w - 1, y) }
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                if x > 0 { seedIfInk(x - 1, y) }
                if x < w - 1 { seedIfInk(x + 1, y) }
                if y > 0 { seedIfInk(x, y - 1) }
                if y < hgt - 1 { seedIfInk(x, y + 1) }
            }
            for i in coverage.indices where outside[i] { coverage[i] = 0 }
        }
        var ink = LineInk(window: window, coverage: coverage, rect: .zero, baseline: 0,
            background: background, color: RGB(r: 0, g: 0, b: 0), stem: 0, baselineSupport: 0)
        ink.reach = reach

        // Rows: start in the middle of the box and grow while there is ink,
        // bridging gaps no taller than the dot of an i.
        let columns = PixelRect(CGRect(x: box.minX - h * 0.25, y: box.minY, width: box.width + h * 0.5, height: h), in: window)
        func rowInk(_ y: Int) -> Float {
            var best: Float = 0
            for x in columns.minX..<columns.maxX { best = max(best, ink.alpha(x, y)) }
            return best
        }
        let present: Float = 0.3
        // A row inked nearly from end to end is the edge of a button, a pill or a
        // highlight (or an underline), not letters. Only looked for away from the middle of the box.
        func isEdgeRow(_ y: Int) -> Bool {
            guard CGFloat(y) < box.minY + h * 0.15 || CGFloat(y) > box.maxY - h * 0.15 else { return false }
            var inked = 0
            for x in columns.minX..<columns.maxX where ink.alpha(x, y) >= 0.5 { inked += 1 }
            return inked * 4 >= columns.width * 3
        }
        let centre = Int(box.midY)
        var seed: Int?
        for offset in 0...max(1, Int(h * 0.3)) {
            if centre + offset < window.maxY, rowInk(centre + offset) >= present { seed = centre + offset; break }
            if centre - offset >= window.minY, rowInk(centre - offset) >= present { seed = centre - offset; break }
        }
        guard let seed else { return nil }
        let bridge = max(1, Int((h * 0.13).rounded()))
        let limitTop = max(window.minY, Int(floor(box.minY - h * 0.22)))
        let limitBottom = min(window.maxY - 1, Int(ceil(box.maxY + h * 0.22)))
        var top = seed, bottom = seed, gap = 0
        var y = seed - 1
        while y >= limitTop, gap <= bridge, !isEdgeRow(y) {
            if rowInk(y) >= present { top = y; gap = 0 } else { gap += 1 }
            y -= 1
        }
        gap = 0
        y = seed + 1
        while y <= limitBottom, gap <= bridge, !isEdgeRow(y) {
            if rowInk(y) >= present { bottom = y; gap = 0 } else { gap += 1 }
            y += 1
        }
        guard bottom - top >= 2 else { return nil }

        // Columns: everything inked in those rows, bridging word spaces.
        func columnInk(_ x: Int) -> Float {
            var best: Float = 0
            for y in top...bottom { best = max(best, ink.alpha(x, y)) }
            return best
        }
        let wordGap = max(2, Int((CGFloat(bottom - top) * 1.1).rounded()))
        var left = Int(box.midX), right = Int(box.midX)
        var inkColumns: [Int] = []
        for x in max(window.minX, Int(box.minX))..<min(window.maxX, Int(ceil(box.maxX))) where columnInk(x) >= present {
            inkColumns.append(x)
        }
        guard let first = inkColumns.first, let last = inkColumns.last else { return nil }
        left = first; right = last
        gap = 0
        var x = left - 1
        let letterGap = max(2, Int((CGFloat(bottom - top + 1) * 0.3).rounded()))
        _ = wordGap
        // Beyond the reported box, a column inked from top to bottom is a container's side, not a letter.
        func isEdgeColumn(_ x: Int) -> Bool {
            var inked = 0
            for y in top...bottom where ink.alpha(x, y) >= 0.5 { inked += 1 }
            return inked * 10 >= (bottom - top + 1) * 9
        }
        while x >= window.minX, gap <= letterGap, !isEdgeColumn(x) {
            if columnInk(x) >= present { left = x; gap = 0 } else { gap += 1 }
            x -= 1
        }
        gap = 0
        x = right + 1
        while x < window.maxX, gap <= letterGap, !isEdgeColumn(x) {
            if columnInk(x) >= present { right = x; gap = 0 } else { gap += 1 }
            x += 1
        }

        // Ink outside the line (neighbouring lines in the window) is not this line's.
        for wy in 0..<window.height {
            for wx in 0..<window.width {
                let px = wx + window.minX, py = wy + window.minY
                if px < left - 1 || px > right + 1 || py < top - 1 || py > bottom + 1 { coverage[wy * window.width + wx] = 0 }
            }
        }
        ink.coverage = coverage

        // Sub-pixel edges: the outermost row/column is partly covered.
        var topEdge = CGFloat(top) + CGFloat(1 - min(1, rowInk(top)))
        var bottomEdge = CGFloat(bottom) + CGFloat(min(1, rowInk(bottom)))
        let leftEdge = CGFloat(left) + CGFloat(1 - min(1, columnInk(left)))
        let rightEdge = CGFloat(right) + CGFloat(min(1, columnInk(right)))

        // Per column: where the ink starts and ends.
        var bottoms: [Int: Int] = [:]
        var bottomEdges: [(row: Int, edge: CGFloat)] = []
        var topEdges: [CGFloat] = []
        var inkedColumns = 0
        for x in left...right {
            var lastRow: Int?, firstRow: Int?
            for y in top...bottom where ink.alpha(x, y) >= 0.5 {
                if firstRow == nil { firstRow = y }
                lastRow = y
            }
            guard let lastRow, let firstRow else { continue }
            inkedColumns += 1
            bottoms[lastRow, default: 0] += 1
            bottomEdges.append((lastRow, CGFloat(lastRow) + CGFloat(ink.alpha(x, lastRow)) + CGFloat(ink.alpha(x, lastRow + 1))))
            topEdges.append(CGFloat(firstRow) + 1 - CGFloat(ink.alpha(x, firstRow)) - CGFloat(ink.alpha(x, firstRow - 1)))
        }
        guard inkedColumns > 0, let mode = bottoms.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }) else { return nil }
        let near = bottomEdges.filter { abs($0.row - mode.key) <= 1 }.map(\.edge)
        ink.baseline = median(near) ?? CGFloat(mode.key + 1)
        ink.baselineSupport = Float(near.count) / Float(inkedColumns)
        // The true top is the tallest glyph.
        if let tallest = topEdges.min() { topEdge = tallest }
        if bottomEdge < ink.baseline { bottomEdge = ink.baseline }
        ink.rect = CGRect(x: leftEdge, y: topEdge, width: rightEdge - leftEdge, height: bottomEdge - topEdge)

        // Stroke thickness: horizontal runs through the body of the glyphs.
        let bodyTop = top + Int(CGFloat(mode.key - top) * 0.3), bodyBottom = max(top + 1, mode.key - 1)
        var runs: [Float] = []
        if bodyBottom > bodyTop {
            for y in bodyTop...bodyBottom {
                var run: Float = 0
                for x in (left - 1)...(right + 1) {
                    let a = ink.alpha(x, y)
                    if a > 0.12 { run += a } else { if run > 0.35 { runs.append(run) }; run = 0 }
                }
                if run > 0.35 { runs.append(run) }
            }
        }
        ink.stem = CGFloat(percentile(runs, 0.35))

        // Colour of the stroke cores, un-mixed from the background where strokes are thin.
        var cores: [RGB] = []
        for y in top...bottom {
            for x in left...right {
                let a = ink.alpha(x, y)
                guard a >= 0.75 else { continue }
                let paper = background.color(x: x, y: y)
                cores.append(paper + (image[x, y] - paper) * (1 / a))
            }
        }
        if let textColour { cores = [textColour] }
        if cores.isEmpty { return nil }
        ink.color = RGB(r: median(cores.map(\.r))!, g: median(cores.map(\.g))!, b: median(cores.map(\.b))!).clamped

        // Words, and what is not a word: a dense or oversized run at either end
        // of the line is an icon or a badge the recogniser swept in. It keeps its pixels.
        var words = blobs(of: ink, image: image, left: left, right: right, top: top, bottom: bottom)
        func isForeign(_ blob: LineInk.Blob, among others: [LineInk.Blob]) -> Bool {
            guard others.count >= 1 else { return false }
            let heights = others.map { $0.bottom - $0.top }.sorted()
            let typical = heights[heights.count / 2]
            let height = blob.bottom - blob.top, width = blob.maxX - blob.minX
            // Filled, and not like the words beside it: small bold Han glyphs are nearly filled too,
            // but they share the words' colour and height.
            let colours = others.map(\.color)
            let usual = RGB(r: median(colours.map(\.r))!, g: median(colours.map(\.g))!, b: median(colours.map(\.b))!)
            if blob.solidity >= 0.7, width >= typical * 0.5, blob.color.distance(to: usual) > 40 || height > typical * 1.2 { return true }
            // Taller than the words: needs several words to compare with, one neighbour is no measure.
            if others.count >= 2, height > typical * 1.45, width < typical * 2.2 { return true }
            return false
        }
        if ProcessInfo.processInfo.environment["V2_DEBUG"] != nil {
            print("  runs", words.map { "\(Int($0.minX))-\(Int($0.maxX)) h\(String(format: "%.1f", $0.bottom - $0.top)) s\(String(format: "%.2f", $0.solidity))" })
        }
        var trimmed = false
        while words.count >= 2, isForeign(words[0], among: Array(words.dropFirst())) {
            ink.trimmedLeadingWidth += words[0].maxX - words[0].minX
            words.removeFirst(); trimmed = true; ink.trimmedLeading = true
        }
        while words.count >= 2, isForeign(words[words.count - 1], among: Array(words.dropLast())) {
            ink.trimmedTrailingWidth += words[words.count - 1].maxX - words[words.count - 1].minX
            words.removeLast(); trimmed = true; ink.trimmedTrailing = true
        }
        // Mostly ink is not text: the box was edged by what surrounds a filled
        // button, and the button itself was taken for the letters. Its paper is the
        // colour most of the box is made of.
        if paper == nil, text == nil {
            var inked = 0
            for y in top...bottom { for x in left...right where ink.alpha(x, y) >= 0.5 { inked += 1 } }
            if inked * 10 > (right - left + 1) * (bottom - top + 1) * 6 {
                var bins: [Int: (count: Int, r: Float, g: Float, b: Float)] = [:]
                for y in inner.minY..<inner.maxY {
                    for x in inner.minX..<inner.maxX {
                        let c = image[x, y]
                        let key = (Int(c.r) >> 4) << 8 | (Int(c.g) >> 4) << 4 | (Int(c.b) >> 4)
                        var bin = bins[key] ?? (0, 0, 0, 0)
                        bin.count += 1; bin.r += c.r; bin.g += c.g; bin.b += c.b
                        bins[key] = bin
                    }
                }
                if let most = bins.values.max(by: { $0.count < $1.count }) {
                    let fill = RGB(r: most.r / Float(most.count), g: most.g / Float(most.count), b: most.b / Float(most.count))
                    if fill.distance(to: background.color(x: left, y: top)) > 20 { return measure(image, box: box, paper: fill) }
                }
            }
        }
        // Column ink: for an upright stroke, the ink in its column divided by the
        // column's fullest pixel is the stroke's length, wherever the pixel grid falls.
        let baselineRow = Int(ink.baseline.rounded(.down))
        func columnMass(_ x: Int, upTo last: Int) -> CGFloat? {
            var sum: Float = 0, peak: Float = 0
            for y in top...min(bottom, last) { let a = ink.alpha(x, y); sum += a; peak = max(peak, a) }
            // The partly covered row under the last full one belongs to the stroke too.
            if last + 1 <= bottom + 1 { sum += ink.alpha(x, last + 1) < 0.5 ? ink.alpha(x, last + 1) : 0 }
            guard peak >= 0.8 else { return nil }
            return CGFloat(sum / peak)
        }
        for index in words.indices {
            var best: CGFloat = 0
            for x in Int(words[index].minX)..<Int(words[index].maxX) {
                // Only strokes that stand on the baseline: a descender would add its tail.
                var lowest = top
                for y in top...bottom where ink.alpha(x, y) >= 0.5 { lowest = y }
                guard abs(lowest + 1 - Int(ink.baseline.rounded())) <= 1, let mass = columnMass(x, upTo: lowest) else { continue }
                best = max(best, mass)
            }
            words[index].rise = best > 0 ? best : ink.baseline - words[index].top
        }
        _ = baselineRow
        var tallest: CGFloat = 0
        if let firstWord = words.first, let lastWord = words.last {
            for x in Int(firstWord.minX)..<Int(lastWord.maxX) { if let mass = columnMass(x, upTo: bottom) { tallest = max(tallest, mass) } }
        }
        ink.strokeHeight = tallest > 0 ? tallest : ink.rect.height
        ink.blobs = words
        if paper == nil, case .flat(let assumed) = background, !words.isEmpty {
            let local = RGB(r: median(words.map { $0.paper.r })!, g: median(words.map { $0.paper.g })!, b: median(words.map { $0.paper.b })!)
            let agree = words.allSatisfy { $0.paper.distance(to: local) <= 12 }
            if agree, local.distance(to: assumed) > 10, let again = measure(image, box: box, paper: local) { return again }
        }
        if trimmed, let firstRun = words.first, let lastRun = words.last {
            let keepMin = Int(firstRun.minX), keepMax = Int(lastRun.maxX)
            for wy in 0..<window.height {
                for wx in 0..<window.width where wx + window.minX < keepMin || wx + window.minX >= keepMax {
                    ink.coverage[wy * window.width + wx] = 0
                }
            }
            let newTop = words.map { $0.top }.min()!
            let newBottom = max(ink.baseline, words.map { $0.bottom }.max()!)
            ink.rect = CGRect(x: firstRun.minX, y: newTop, width: lastRun.maxX - firstRun.minX, height: newBottom - newTop)
        }
        return ink
    }

    private static func blobs(of ink: LineInk, image: PixelImage, left: Int, right: Int, top: Int, bottom: Int) -> [LineInk.Blob] {
        let gap = max(2, Int((CGFloat(bottom - top + 1) * 0.24).rounded()))
        var result: [LineInk.Blob] = []
        var start: Int?, empty = 0, lastInk = left
        func close(_ from: Int, _ to: Int) {
            var topEdge = CGFloat.greatestFiniteMagnitude, bottomEdge = -CGFloat.greatestFiniteMagnitude
            var colours: [RGB] = []
            var covered: Float = 0
            var firstRow = bottom, lastRow = top
            for x in from...to {
                var columnFirst: Int?, columnLast: Int?
                for y in top...bottom {
                    let a = ink.alpha(x, y)
                    covered += a
                    guard a >= 0.5 else { continue }
                    if columnFirst == nil { columnFirst = y }
                    columnLast = y
                    if a >= 0.75 {
                        let paper = ink.background.color(x: x, y: y)
                        colours.append(paper + (image[x, y] - paper) * (1 / a))
                    }
                }
                guard let columnFirst, let columnLast else { continue }
                firstRow = min(firstRow, columnFirst); lastRow = max(lastRow, columnLast)
                topEdge = min(topEdge, CGFloat(columnFirst) + 1 - CGFloat(ink.alpha(x, columnFirst)) - CGFloat(ink.alpha(x, columnFirst - 1)))
                bottomEdge = max(bottomEdge, CGFloat(columnLast) + CGFloat(ink.alpha(x, columnLast)) + CGFloat(ink.alpha(x, columnLast + 1)))
            }
            guard topEdge < bottomEdge else { return }
            let colour = colours.isEmpty ? ink.color
                : RGB(r: median(colours.map(\.r))!, g: median(colours.map(\.g))!, b: median(colours.map(\.b))!)
            _ = covered
            var runs: [Float] = []
            var papers: [RGB] = []
            for y in firstRow...max(firstRow, lastRow) {
                var run: Float = 0
                for x in from...to {
                    let a = ink.alpha(x, y)
                    if a >= 0.3 { run += 1 } else {
                        if run > 0 { runs.append(run) }
                        run = 0
                        if a <= 0.2 { papers.append(image[x, y]) }
                    }
                }
                if run > 0 { runs.append(run) }
            }
            for y in [firstRow - 2, lastRow + 2] where y >= 0 && y < image.height {
                for x in from...to where ink.alpha(x, y) <= 0.2 { papers.append(image[x, y]) }
            }
            let paper = papers.isEmpty ? ink.background.color(x: from, y: firstRow)
                : RGB(r: median(papers.map(\.r))!, g: median(papers.map(\.g))!, b: median(papers.map(\.b))!)
            // A filled shape is thick both ways; a glyph, however dense, is made of thin strokes one way or the other.
            var falls: [Float] = []
            for x in from...to {
                var run: Float = 0
                for y in firstRow...max(firstRow, lastRow) {
                    if ink.alpha(x, y) >= 0.3 { run += 1 } else { if run > 0 { falls.append(run) }; run = 0 }
                }
                if run > 0 { falls.append(run) }
            }
            let across = percentile(runs, 0.5) / Float(to - from + 1)
            let down = percentile(falls, 0.5) / Float(max(1, lastRow - firstRow + 1))
            result.append(.init(minX: CGFloat(from), maxX: CGFloat(to + 1), top: topEdge, bottom: bottomEdge,
                color: colour, solidity: min(across, down), paper: paper))
        }
        for x in left...right {
            var inked = false
            for y in top...bottom where ink.alpha(x, y) >= 0.3 { inked = true; break }
            if inked {
                if start == nil { start = x }
                lastInk = x; empty = 0
            } else if let from = start {
                empty += 1
                if empty >= gap { close(from, lastInk); start = nil }
            }
        }
        if let from = start { close(from, lastInk) }
        return result
    }

    /// The colour of text drawn over a picture. Three colour clusters of the
    /// box; the text is the lightest or the darkest one, tight in colour and
    /// running the width of the line. When both qualify (white letters with a
    /// black outline), the outline is the one that hugs the other.
    private static func textCluster(_ image: PixelImage, box: PixelRect) -> (colour: RGB, reach: Float)? {
        guard box.width >= 4, box.height >= 4 else { return nil }
        let w = box.width, h = box.height
        var colours: [RGB] = []
        colours.reserveCapacity(w * h)
        for y in box.minY..<box.maxY { for x in box.minX..<box.maxX { colours.append(image[x, y]) } }
        let byLuma = colours.map(\.luma).sorted()
        func near(_ luma: Float) -> RGB { colours.min { abs($0.luma - luma) < abs($1.luma - luma) }! }
        var centres = [near(byLuma[byLuma.count / 20]), near(byLuma[byLuma.count / 2]), near(byLuma[byLuma.count - 1 - byLuma.count / 20])]
        var assignment = [UInt8](repeating: 0, count: colours.count)
        for _ in 0..<8 {
            var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: 3), counts = [Float](repeating: 0, count: 3)
            for (index, colour) in colours.enumerated() {
                var best = 0
                for k in 1..<3 where colour.distance(to: centres[k]) < colour.distance(to: centres[best]) { best = k }
                assignment[index] = UInt8(best)
                sums[best] = sums[best] + colour; counts[best] += 1
            }
            for k in 0..<3 where counts[k] > 0 { centres[k] = sums[k] * (1 / counts[k]) }
        }
        struct Candidate { var k: Int; var score: Float; var hugging: Float; var rim: Float }
        let rimRows = max(1, h / 12)
        var candidates: [Candidate] = []
        for k in [0, 2] {
            let other = UInt8(2 - k)
            var count = 0, spread: Float = 0, minX = w, maxX = 0, touching = 0, onRim = 0
            for y in 0..<h {
                for x in 0..<w where assignment[y * w + x] == UInt8(k) {
                    count += 1
                    if y < rimRows || y >= h - rimRows { onRim += 1 }
                    spread += colours[y * w + x].distance(to: centres[k])
                    minX = min(minX, x); maxX = max(maxX, x)
                    var touches = false
                    for (dx, dy) in [(-2, 0), (2, 0), (0, -2), (0, 2), (-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < w, ny < h, assignment[ny * w + nx] == other { touches = true; break }
                    }
                    if touches { touching += 1 }
                }
            }
            let share = Float(count) / Float(colours.count)
            guard count > 0, share >= 0.04, share <= 0.6, Float(maxX - minX) / Float(w) >= 0.6 else { continue }
            // Share of the cluster lying on the top and bottom rim of the box, against what an even spread would give.
            let rim = Float(onRim) / Float(count) / (Float(2 * rimRows) / Float(h))
            candidates.append(.init(k: k, score: spread / Float(count), hugging: Float(touching) / Float(count), rim: rim))
        }
        guard var best = candidates.min(by: { $0.score < $1.score }) else { return nil }
        if candidates.count == 2 {
            let a = candidates[0], b = candidates[1]
            // Text is set to stand out: a cluster that is merely the picture's own
            // shade (or a soft shadow on it) lies close to the middle cluster.
            let da = centres[a.k].distance(to: centres[1]), db = centres[b.k].distance(to: centres[1])
            if max(da, db) > min(da, db) * 1.6 { best = da > db ? a : b }
            // Letters stay clear of the rim of their box; a background, an outline or a shadow does not.
            else if abs(a.rim - b.rim) > 0.25 { best = a.rim < b.rim ? a : b }
            else if abs(a.hugging - b.hugging) > 0.15 { best = a.hugging < b.hugging ? a : b }
        }
        let others = (0..<3).filter { $0 != best.k }.map { centres[$0].distance(to: centres[best.k]) }.min() ?? 120
        return (centres[best.k], max(40, others))
    }

    /// Flat when most of the window is one colour, smooth when a plane explains
    /// the non-ink pixels, otherwise a picture.
    static func estimateBackground(_ image: PixelImage, window: PixelRect, box: CGRect? = nil) -> Background {
        // The paper is what the line's own box is edged with: a label in a small
        // button or chip sits on the button's colour, whatever surrounds the button.
        if let box {
            let band = max(2, box.height * 0.12)
            let outer = PixelRect(box.insetBy(dx: -2, dy: -2), in: window), inner = PixelRect(box.insetBy(dx: band, dy: band), in: window)
            var bins: [Int: (count: Int, r: Float, g: Float, b: Float)] = [:]
            var ring: [RGB] = []
            for y in outer.minY..<outer.maxY {
                for x in outer.minX..<outer.maxX where !(x >= inner.minX && x < inner.maxX && y >= inner.minY && y < inner.maxY) {
                    let c = image[x, y]
                    ring.append(c)
                    let key = (Int(c.r) >> 4) << 8 | (Int(c.g) >> 4) << 4 | (Int(c.b) >> 4)
                    var bin = bins[key] ?? (0, 0, 0, 0)
                    bin.count += 1; bin.r += c.r; bin.g += c.g; bin.b += c.b
                    bins[key] = bin
                }
            }
            if let top = bins.values.max(by: { $0.count < $1.count }), !ring.isEmpty {
                let mode = RGB(r: top.r / Float(top.count), g: top.g / Float(top.count), b: top.b / Float(top.count))
                // One colour, not a stretch of a gradient or a picture: nearly all of the rim within a hair of it.
                let close = ring.filter { $0.distance(to: mode) <= 6 }
                if close.count * 10 >= ring.count * 6 {
                    let sum = close.reduce(RGB(r: 0, g: 0, b: 0)) { $0 + $1 }
                    return .flat(sum * (1 / Float(close.count)))
                }
            }
        }
        // Most common colour, 16 levels per channel.
        var bins: [Int: (count: Int, r: Float, g: Float, b: Float)] = [:]
        let total = window.width * window.height
        for y in window.minY..<window.maxY {
            for x in window.minX..<window.maxX {
                let c = image[x, y]
                let key = (Int(c.r) >> 4) << 8 | (Int(c.g) >> 4) << 4 | (Int(c.b) >> 4)
                var bin = bins[key] ?? (0, 0, 0, 0)
                bin.count += 1; bin.r += c.r; bin.g += c.g; bin.b += c.b
                bins[key] = bin
            }
        }
        let top = bins.values.max { $0.count < $1.count }!
        let mode = RGB(r: top.r / Float(top.count), g: top.g / Float(top.count), b: top.b / Float(top.count))
        var close = 0
        for y in window.minY..<window.maxY {
            for x in window.minX..<window.maxX where image[x, y].distance(to: mode) <= 10 { close += 1 }
        }
        if Float(close) / Float(total) >= 0.45 {
            // Refine: mean of the pixels close to the mode.
            var sum = RGB(r: 0, g: 0, b: 0), n: Float = 0
            for y in window.minY..<window.maxY {
                for x in window.minX..<window.maxX where image[x, y].distance(to: mode) <= 10 {
                    sum = sum + image[x, y]; n += 1
                }
            }
            return .flat(sum * (1 / n))
        }
        // Robust plane: fit, drop the worst third (ink), fit again.
        var samples: [(x: Float, y: Float, c: RGB)] = []
        let step = max(1, min(window.width, window.height) / 40)
        for y in stride(from: window.minY, to: window.maxY, by: step) {
            for x in stride(from: window.minX, to: window.maxX, by: step) {
                samples.append((Float(x), Float(y), image[x, y]))
            }
        }
        var plane = fitPlane(samples)
        for _ in 0..<3 {
            let residuals = samples.map { $0.c.distance(to: plane.0 + plane.1 * $0.x + plane.2 * $0.y) }
            let cut = percentile(residuals, 0.6)
            let kept = zip(samples, residuals).filter { $0.1 <= cut }.map(\.0)
            guard kept.count >= 12 else { break }
            plane = fitPlane(kept)
        }
        let residuals = samples.map { $0.c.distance(to: plane.0 + plane.1 * $0.x + plane.2 * $0.y) }
        if percentile(residuals, 0.5) <= 4, percentile(residuals, 0.75) <= 10 { return .smooth(origin: plane.0, dx: plane.1, dy: plane.2) }
        return .complex(typical: mode)
    }

    /// Least squares c = o + dx·x + dy·y per channel.
    private static func fitPlane(_ samples: [(x: Float, y: Float, c: RGB)]) -> (RGB, RGB, RGB) {
        let n = Double(samples.count)
        guard n >= 3 else { return (samples.first?.c ?? RGB(r: 0, g: 0, b: 0), RGB(r: 0, g: 0, b: 0), RGB(r: 0, g: 0, b: 0)) }
        let mx = samples.reduce(0.0) { $0 + Double($1.x) } / n, my = samples.reduce(0.0) { $0 + Double($1.y) } / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        var sx = [0.0, 0.0, 0.0], sy = [0.0, 0.0, 0.0], mean = [0.0, 0.0, 0.0]
        for s in samples {
            let dx = Double(s.x) - mx, dy = Double(s.y) - my
            sxx += dx * dx; sxy += dx * dy; syy += dy * dy
            let c = [Double(s.c.r), Double(s.c.g), Double(s.c.b)]
            for k in 0..<3 { sx[k] += dx * c[k]; sy[k] += dy * c[k]; mean[k] += c[k] / n }
        }
        let det = sxx * syy - sxy * sxy
        var a = [0.0, 0.0, 0.0], b = [0.0, 0.0, 0.0]
        if abs(det) > 1e-6 {
            for k in 0..<3 { a[k] = (sx[k] * syy - sy[k] * sxy) / det; b[k] = (sy[k] * sxx - sx[k] * sxy) / det }
        }
        let origin = RGB(r: Float(mean[0] - a[0] * mx - b[0] * my), g: Float(mean[1] - a[1] * mx - b[1] * my),
            b: Float(mean[2] - a[2] * mx - b[2] * my))
        return (origin, RGB(r: Float(a[0]), g: Float(a[1]), b: Float(a[2])), RGB(r: Float(b[0]), g: Float(b[1]), b: Float(b[2])))
    }
}
