import CoreGraphics
import Foundation

/// A still picture of one display, read for regions, answering in AppKit screen points.
struct ScreenRegionMap: Sendable {
    let finder: ScreenRegionFinder
    /// The display's frame in AppKit coordinates.
    let frame: CGRect
    /// Picture pixels per point.
    let pixelScale: CGFloat

    init?(image: CGImage, frame: CGRect) {
        guard frame.width > 0, let pixels = PixelImage(image) else { return nil }
        pixelScale = CGFloat(image.width) / frame.width
        finder = ScreenRegionFinder(pixels, scale: pixelScale)
        self.frame = frame
    }

    /// The region under `point`, kept inside `limit` (the window there); both in AppKit points.
    func region(at point: CGPoint, within limit: CGRect) -> CGRect? {
        let limit = limit.intersection(frame)
        guard !limit.isNull, limit.contains(point) else { return nil }
        let p = (x: Int((point.x - frame.minX) * pixelScale), y: Int((frame.maxY - point.y) * pixelScale))
        let l = PixelRect(minX: Int(((limit.minX - frame.minX) * pixelScale).rounded()),
                          minY: Int(((frame.maxY - limit.maxY) * pixelScale).rounded()),
                          maxX: Int(((limit.maxX - frame.minX) * pixelScale).rounded()),
                          maxY: Int(((frame.maxY - limit.minY) * pixelScale).rounded()))
        guard let r = finder.region(around: p, within: l) else { return nil }
        return CGRect(x: frame.minX + CGFloat(r.minX) / pixelScale,
                      y: frame.maxY - CGFloat(r.maxY) / pixelScale,
                      width: CGFloat(r.width) / pixelScale,
                      height: CGFloat(r.height) / pixelScale)
    }
}

/// Finds the region under the pointer on a still picture of the screen, the way screenshot
/// tools offer one: a card, a field, a bubble, a sidebar, or a paragraph or table on a plain
/// page. The picture is read once when the selection opens; each hover is a quick lookup.
///
/// Three kinds of region are read off colour edges:
/// - outlines: four straight edge lines closing around the point (cards, panels, fields);
/// - fills: one patch of colour, rounded or not, that the point sits on (bubbles, buttons);
/// - text blocks: ink grouped by the spacing between lines and paragraphs, inside the
///   container found above, when that container holds more than one block.
struct ScreenRegionFinder: @unchecked Sendable {
    let width: Int
    let height: Int
    /// Picture pixels per point; every size below is in points.
    let scale: Int
    /// Running count of horizontal edges along each row (`width + 1` per row).
    private let rowSums: [UInt16]
    /// Running count of vertical edges down each column (`height + 1` per column).
    private let columnSums: [UInt16]
    /// Straight horizontal edge runs per row and vertical runs per column.
    private let rows: [[Run]]
    private let columns: [[Run]]
    /// Summed-area table of ink (any edge), `(width + 1) * (height + 1)`.
    private let ink: [Int32]
    /// Fill index per pixel, and the fills.
    private let labels: [Int32]
    private let fills: [Fill]

    struct Run: Equatable { var start: Int, end: Int }

    struct Fill: Equatable {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var count: Int
        var area: Int { (maxX - minX) * (maxY - minY) }
    }

    static let edgeThreshold: Float = 14
    /// Shortest straight edge (points) that can be a side of an outline.
    static let minimumRun = 7
    static let gapTolerance = 1
    /// Share of a side that must be an edge line.
    static let coverage: Float = 0.88
    static let minimumSize = (width: 36, height: 16)
    static let candidatesPerSide = 160
    /// Share of a fill's box its pixels must cover (text and icons inside leave holes).
    static let fillShare: Float = 0.45
    /// Ink this close (points) belongs to the same block: across a line, and between lines.
    static let blockGap = (horizontal: 14, vertical: 9)
    static let blockPadding = 6

    init(_ image: PixelImage, scale: CGFloat) {
        let w = image.width, h = image.height
        width = w
        height = h
        let s = max(1, Int(scale.rounded()))
        self.scale = s
        var horizontal = [Bool](repeating: false, count: w * h)
        var vertical = [Bool](repeating: false, count: w * h)
        let threshold = Self.edgeThreshold * Self.edgeThreshold
        image.data.withUnsafeBufferPointer { px in
            @inline(__always) func distance2(_ a: Int, _ b: Int) -> Float {
                let dr = Float(px[a]) - Float(px[b])
                let dg = Float(px[a + 1]) - Float(px[b + 1])
                let db = Float(px[a + 2]) - Float(px[b + 2])
                return dr * dr + dg * dg + db * db
            }
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    if y + 1 < h, distance2(i, i + w * 4) > threshold { horizontal[y * w + x] = true }
                    if x + 1 < w, distance2(i, i + 4) > threshold { vertical[y * w + x] = true }
                }
            }
        }
        let minimumRun = Self.minimumRun * s
        let gap = Self.gapTolerance * s
        var rowSums = [UInt16](repeating: 0, count: (w + 1) * h)
        var rows = [[Run]](repeating: [], count: h)
        for y in 0..<h {
            var sum: UInt16 = 0
            for x in 0..<w {
                if horizontal[y * w + x] { sum &+= 1 }
                rowSums[y * (w + 1) + x + 1] = sum
            }
            rows[y] = Self.runs(count: w, minimum: minimumRun, gap: gap) { horizontal[y * w + $0] }
        }
        var columnSums = [UInt16](repeating: 0, count: (h + 1) * w)
        var columns = [[Run]](repeating: [], count: w)
        for x in 0..<w {
            var sum: UInt16 = 0
            for y in 0..<h {
                if vertical[y * w + x] { sum &+= 1 }
                columnSums[x * (h + 1) + y + 1] = sum
            }
            columns[x] = Self.runs(count: h, minimum: minimumRun, gap: gap) { vertical[$0 * w + x] }
        }
        var ink = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var line: Int32 = 0
            for x in 0..<w {
                let i = y * w + x
                if horizontal[i] || vertical[i] { line += 1 }
                ink[(y + 1) * (w + 1) + x + 1] = ink[y * (w + 1) + x + 1] + line
            }
        }
        self.rowSums = rowSums
        self.columnSums = columnSums
        self.rows = rows
        self.columns = columns
        self.ink = ink
        (labels, fills) = Self.labelFills(width: w, height: h, horizontal: horizontal, vertical: vertical)
    }

    // MARK: The answer

    /// The region to offer for `point` inside `limit` (the window under the pointer),
    /// both in picture pixels with the origin at the top left.
    func region(around point: (x: Int, y: Int), within limit: PixelRect) -> PixelRect? {
        let limit = PixelRect(minX: max(0, limit.minX), minY: max(0, limit.minY),
                              maxX: min(width, limit.maxX), maxY: min(height, limit.maxY))
        guard !limit.isEmpty, point.x >= limit.minX, point.x < limit.maxX,
              point.y >= limit.minY, point.y < limit.maxY else { return nil }
        let container = smaller(smaller(outline(around: point, within: limit), fill(around: point, within: limit)),
                                band(around: point, within: limit)) ?? limit
        guard let block = textBlock(around: point, within: container) else { return container }
        // A small container (a card, a field, a bubble) is itself the unit; so is one whose
        // text is all one block.
        if container.width * container.height <= 4 * block.width * block.height { return container }
        let inner = PixelRect(minX: container.minX + 2 * scale, minY: container.minY + 2 * scale,
                              maxX: container.maxX - 2 * scale, maxY: container.maxY - 2 * scale)
        if inkSum(block) * 10 >= inkSum(inner) * 9 { return container }
        return block
    }

    private func smaller(_ a: PixelRect?, _ b: PixelRect?) -> PixelRect? {
        switch (a, b) {
        case let (a?, b?): return a.width * a.height <= b.width * b.height ? a : b
        case let (a?, nil): return a
        default: return b
        }
    }

    // MARK: Outlines

    /// The smallest rectangle around `point` closed by edge lines on all four sides (or
    /// by the limit). The rectangle lies inside the lines.
    func outline(around point: (x: Int, y: Int), within limit: PixelRect) -> PixelRect? {
        let k = Self.candidatesPerSide
        let minW = Self.minimumSize.width * scale, minH = Self.minimumSize.height * scale
        // A horizontal edge in row y lies between rows y and y + 1.
        var tops: [Int] = [], bottoms: [Int] = [], lefts: [Int] = [], rights: [Int] = []
        var y = point.y - 1
        while y >= limit.minY, tops.count < k {
            if rows[y].contains(where: { $0.start <= point.x && $0.end > point.x }) { tops.append(y + 1) }
            y -= 1
        }
        tops.append(limit.minY)
        y = point.y
        while y < limit.maxY - 1, bottoms.count < k {
            if rows[y].contains(where: { $0.start <= point.x && $0.end > point.x }) { bottoms.append(y + 1) }
            y += 1
        }
        bottoms.append(limit.maxY)
        var x = point.x - 1
        while x >= limit.minX, lefts.count < k {
            if columns[x].contains(where: { $0.start <= point.y && $0.end > point.y }) { lefts.append(x + 1) }
            x -= 1
        }
        lefts.append(limit.minX)
        x = point.x
        while x < limit.maxX - 1, rights.count < k {
            if columns[x].contains(where: { $0.start <= point.y && $0.end > point.y }) { rights.append(x + 1) }
            x += 1
        }
        rights.append(limit.maxX)

        var best: PixelRect?
        var bestArea = Int.max
        // Candidates are ordered nearest first: once a box reaches the best area, later
        // candidates on that side only make it larger.
        for top in tops {
            for bottom in bottoms where bottom - top >= minH {
                if (bottom - top) * minW >= bestArea { break }
                for left in lefts {
                    if (bottom - top) * (point.x - left + 1) >= bestArea { break }
                    for right in rights where right - left >= minW {
                        let area = (bottom - top) * (right - left)
                        if area >= bestArea { break }
                        guard side(top, isTop: true, left, right, limit),
                              side(bottom, isTop: false, left, right, limit),
                              wall(left, isLeft: true, top, bottom, limit),
                              wall(right, isLeft: false, top, bottom, limit) else { continue }
                        best = PixelRect(minX: left, minY: top, maxX: right, maxY: bottom)
                        bestArea = area
                    }
                }
            }
        }
        return best
    }

    /// Rounded corners leave the ends of a side without an edge; only the middle must be straight.
    private func cornerInset(_ length: Int) -> Int { min(7 * scale, length / 6) }

    private func side(_ edgeY: Int, isTop: Bool, _ left: Int, _ right: Int, _ limit: PixelRect) -> Bool {
        if (isTop && edgeY == limit.minY) || (!isTop && edgeY == limit.maxY) { return true }
        let row = edgeY - 1
        let inset = cornerInset(right - left)
        let a = left + inset, b = right - inset
        return max(rowCoverage(row, a, b), rowCoverage(row - 1, a, b), rowCoverage(row + 1, a, b)) >= Self.coverage
    }

    private func wall(_ edgeX: Int, isLeft: Bool, _ top: Int, _ bottom: Int, _ limit: PixelRect) -> Bool {
        if (isLeft && edgeX == limit.minX) || (!isLeft && edgeX == limit.maxX) { return true }
        let column = edgeX - 1
        let inset = cornerInset(bottom - top)
        let a = top + inset, b = bottom - inset
        return max(columnCoverage(column, a, b), columnCoverage(column - 1, a, b), columnCoverage(column + 1, a, b)) >= Self.coverage
    }

    private func rowCoverage(_ y: Int, _ x0: Int, _ x1: Int) -> Float {
        guard y >= 0, y < height, x1 > x0 else { return 0 }
        let base = y * (width + 1)
        return Float(rowSums[base + x1] - rowSums[base + x0]) / Float(x1 - x0)
    }

    private func columnCoverage(_ x: Int, _ y0: Int, _ y1: Int) -> Float {
        guard x >= 0, x < width, y1 > y0 else { return 0 }
        let base = x * (height + 1)
        return Float(columnSums[base + y1] - columnSums[base + y0]) / Float(y1 - y0)
    }

    private static func runs(count: Int, minimum: Int, gap: Int, isEdge: (Int) -> Bool) -> [Run] {
        var result: [Run] = []
        var start = -1, lastEdge = -1
        for i in 0..<count where isEdge(i) {
            if start >= 0, i - lastEdge > gap + 1 {
                if lastEdge + 1 - start >= minimum { result.append(Run(start: start, end: lastEdge + 1)) }
                start = i
            } else if start < 0 {
                start = i
            }
            lastEdge = i
        }
        if start >= 0, lastEdge + 1 - start >= minimum { result.append(Run(start: start, end: lastEdge + 1)) }
        return result
    }

    // MARK: Bands

    /// A strip between two horizontal lines of the same extent, with no side walls:
    /// a table row, a list row, a section between dividers.
    func band(around point: (x: Int, y: Int), within limit: PixelRect) -> PixelRect? {
        let minW = Self.minimumSize.width * 3 * scale, minH = Self.minimumSize.height * scale
        let tolerance = 3 * scale
        var above: [Run] = [], aboveY: [Int] = []
        var y = point.y - 1
        while y >= limit.minY, above.count < Self.candidatesPerSide {
            if let run = rows[y].first(where: { $0.start <= point.x && $0.end > point.x && $0.end - $0.start >= minW }) {
                above.append(run); aboveY.append(y + 1)
            }
            y -= 1
        }
        y = point.y
        var checked = 0
        while y < limit.maxY - 1, checked < Self.candidatesPerSide {
            if let run = rows[y].first(where: { $0.start <= point.x && $0.end > point.x && $0.end - $0.start >= minW }) {
                checked += 1
                let bottom = y + 1
                for (i, top) in aboveY.enumerated() where bottom - top >= minH {
                    let a = above[i]
                    if abs(a.start - run.start) <= tolerance, abs(a.end - run.end) <= tolerance {
                        return PixelRect(minX: max(limit.minX, min(a.start, run.start)), minY: top,
                                         maxX: min(limit.maxX, max(a.end, run.end)), maxY: bottom)
                    }
                }
            }
            y += 1
        }
        return nil
    }

    // MARK: Fills

    /// The smallest patch of one colour that the point sits on or next to.
    func fill(around point: (x: Int, y: Int), within limit: PixelRect) -> PixelRect? {
        let r = 6 * scale
        let minW = Self.minimumSize.width * scale, minH = Self.minimumSize.height * scale
        var seen = Set<Int32>()
        var best: Fill?
        for y in max(limit.minY, point.y - r)..<min(limit.maxY, point.y + r + 1) {
            for x in max(limit.minX, point.x - r)..<min(limit.maxX, point.x + r + 1) {
                let label = labels[y * width + x]
                guard seen.insert(label).inserted else { continue }
                let f = fills[Int(label)]
                guard f.minX <= point.x, f.maxX > point.x, f.minY <= point.y, f.maxY > point.y,
                      f.maxX - f.minX >= minW, f.maxY - f.minY >= minH,
                      Float(f.count) >= Self.fillShare * Float(f.area),
                      f.minX >= limit.minX, f.minY >= limit.minY, f.maxX <= limit.maxX, f.maxY <= limit.maxY,
                      f.area < best?.area ?? .max else { continue }
                best = f
            }
        }
        return best.map { PixelRect(minX: $0.minX, minY: $0.minY, maxX: $0.maxX, maxY: $0.maxY) }
    }

    private static func labelFills(width w: Int, height h: Int, horizontal: [Bool], vertical: [Bool]) -> ([Int32], [Fill]) {
        let n = w * h
        var parent = [Int32](repeating: 0, count: n)
        parent.withUnsafeMutableBufferPointer { p in
            for i in 0..<n { p[i] = Int32(i) }
            @inline(__always) func find(_ i: Int) -> Int {
                var r = i
                while Int(p[r]) != r { r = Int(p[r]) }
                var c = i
                while Int(p[c]) != r { let next = Int(p[c]); p[c] = Int32(r); c = next }
                return r
            }
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    if x + 1 < w, !vertical[i] {
                        let a = find(i), b = find(i + 1)
                        if a != b { p[max(a, b)] = Int32(min(a, b)) }
                    }
                    if y + 1 < h, !horizontal[i] {
                        let a = find(i), b = find(i + w)
                        if a != b { p[max(a, b)] = Int32(min(a, b)) }
                    }
                }
            }
            // Roots are always the smallest index of their set, so one forward pass flattens.
            for i in 0..<n { p[i] = p[Int(p[i])] }
        }
        var index = [Int32](repeating: -1, count: n)
        var fills: [Fill] = []
        var labels = [Int32](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let root = Int(parent[i])
                var f = index[root]
                if f < 0 {
                    f = Int32(fills.count)
                    index[root] = f
                    fills.append(Fill(minX: x, minY: y, maxX: x + 1, maxY: y + 1, count: 0))
                }
                labels[i] = f
                let k = Int(f)
                if x < fills[k].minX { fills[k].minX = x }
                if x + 1 > fills[k].maxX { fills[k].maxX = x + 1 }
                fills[k].maxY = y + 1
                fills[k].count += 1
            }
        }
        return (labels, fills)
    }

    // MARK: Text blocks

    private func inkSum(_ r: PixelRect) -> Int {
        guard !r.isEmpty else { return 0 }
        let s = width + 1
        return Int(ink[r.maxY * s + r.maxX] - ink[r.minY * s + r.maxX] - ink[r.maxY * s + r.minX] + ink[r.minY * s + r.minX])
    }

    /// The ink near the point, grown over gaps narrower than `blockGap`, kept inside `container`.
    func textBlock(around point: (x: Int, y: Int), within container: PixelRect) -> PixelRect? {
        // Stay off the container's own border lines.
        let inner = PixelRect(minX: container.minX + 2 * scale, minY: container.minY + 2 * scale,
                              maxX: container.maxX - 2 * scale, maxY: container.maxY - 2 * scale)
        guard !inner.isEmpty else { return nil }
        let gx = Self.blockGap.horizontal * scale, gy = Self.blockGap.vertical * scale
        func clip(_ r: PixelRect) -> PixelRect {
            PixelRect(minX: max(inner.minX, r.minX), minY: max(inner.minY, r.minY),
                      maxX: min(inner.maxX, r.maxX), maxY: min(inner.maxY, r.maxY))
        }
        // Start from the nearest ink: the pointer is often between characters or lines.
        var seed = PixelRect(minX: 0, minY: 0, maxX: 0, maxY: 0)
        for reach in [4, 8, 14] {
            let r = reach * scale
            seed = clip(PixelRect(minX: point.x - r, minY: point.y - r, maxX: point.x + r + 1, maxY: point.y + r + 1))
            if !seed.isEmpty, inkSum(seed) > 0 { break }
        }
        guard !seed.isEmpty, inkSum(seed) > 0 else { return nil }
        var box = tightInk(seed)
        while true {
            var grown = box
            let left = clip(PixelRect(minX: box.minX - gx, minY: box.minY, maxX: box.minX, maxY: box.maxY))
            if inkSum(left) > 0 { grown.minX = tightInk(left).minX }
            let right = clip(PixelRect(minX: box.maxX, minY: box.minY, maxX: box.maxX + gx, maxY: box.maxY))
            if inkSum(right) > 0 { grown.maxX = tightInk(right).maxX }
            let up = clip(PixelRect(minX: box.minX, minY: box.minY - gy, maxX: box.maxX, maxY: box.minY))
            if inkSum(up) > 0 { grown.minY = tightInk(up).minY }
            let down = clip(PixelRect(minX: box.minX, minY: box.maxY, maxX: box.maxX, maxY: box.maxY + gy))
            if inkSum(down) > 0 { grown.maxY = tightInk(down).maxY }
            if grown == box { break }
            box = grown
        }
        let pad = Self.blockPadding * scale
        let padded = PixelRect(minX: max(container.minX, box.minX - pad), minY: max(container.minY, box.minY - pad),
                               maxX: min(container.maxX, box.maxX + pad), maxY: min(container.maxY, box.maxY + pad))
        guard padded.width >= Self.minimumSize.width * scale, padded.height >= Self.minimumSize.height * scale else { return nil }
        return padded
    }

    /// The smallest box holding all the ink in `r` (which must hold some).
    private func tightInk(_ r: PixelRect) -> PixelRect {
        var out = r
        while out.minX < out.maxX, inkSum(PixelRect(minX: out.minX, minY: out.minY, maxX: out.minX + 1, maxY: out.maxY)) == 0 { out.minX += 1 }
        while out.maxX > out.minX, inkSum(PixelRect(minX: out.maxX - 1, minY: out.minY, maxX: out.maxX, maxY: out.maxY)) == 0 { out.maxX -= 1 }
        while out.minY < out.maxY, inkSum(PixelRect(minX: out.minX, minY: out.minY, maxX: out.maxX, maxY: out.minY + 1)) == 0 { out.minY += 1 }
        while out.maxY > out.minY, inkSum(PixelRect(minX: out.minX, minY: out.maxY - 1, maxX: out.maxX, maxY: out.maxY)) == 0 { out.maxY -= 1 }
        return out
    }
}
