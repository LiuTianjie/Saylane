import CoreGraphics
import Foundation

enum Alignment: String, Sendable { case left, center, right }

struct MeasuredLine: Sendable {
    var text: String
    var box: CGRect
    var ink: LineInk
    var style: TextStyle
    var confidence: Float
    var startsListItem: Bool
}

/// Verified empty background around a rectangle, in pixels on each side.
struct FreeSpace: Sendable {
    var left: CGFloat = 0, right: CGFloat = 0, up: CGFloat = 0, down: CGFloat = 0
    /// Whether the scan stopped at something drawn (true) or ran into the picture's border (false).
    var leftEdge = false, rightEdge = false, upEdge = false, downEdge = false
    /// Whether what stopped the scan above and below is a boundary running the
    /// whole width (the edge of a button, a bubble, a field) rather than more text.
    var upSolid = false, downSolid = false
}

/// Lines that are set as one piece of text.
struct TextBlock: Sendable {
    var lines: [MeasuredLine]
    var style: TextStyle
    var rect: CGRect
    var align: Alignment = .left
    /// Baseline to baseline, pixels; 0 for a single line.
    var pitch: CGFloat = 0
    var free = FreeSpace()
    var background: Background
    var translate = true
    var original = ""
    var translation = ""

    var firstBaseline: CGFloat { lines[0].ink.baseline }
}

enum Space {
    /// How far the background continues beside `rect` before anything else is drawn.
    /// On one colour: until a pixel leaves that colour. On a gradient or a
    /// picture: until an edge, a step between neighbouring pixels.
    static func around(_ rect: CGRect, in image: PixelImage, background: Background, limit: CGFloat, soft: Int = 2) -> FreeSpace {
        // Step over the faint rim of anti-aliasing around the ink before scanning.
        let x0 = max(0, Int(floor(rect.minX)) - soft), x1 = min(image.width - 1, Int(ceil(rect.maxX)) - 1 + soft)
        let y0 = max(0, Int(floor(rect.minY)) - soft), y1 = min(image.height - 1, Int(ceil(rect.maxY)) - 1 + soft)
        guard x1 >= x0, y1 >= y0 else { return FreeSpace() }
        var flat: RGB?
        if case .flat(let colour) = background { flat = colour }
        func clear(_ x: Int, _ y: Int, from px: Int, _ py: Int) -> Bool {
            if let flat { return image[x, y].distance(to: flat) <= 9 }
            return image[x, y].distance(to: image[px, py]) <= 11
        }
        func columnClear(_ x: Int, from previous: Int) -> Bool {
            for y in y0...y1 where !clear(x, y, from: previous, y) { return false }
            return true
        }
        // A rounded corner cuts into the ends of a row long before the edge itself does.
        let corner = min((x1 - x0) / 8, max(3, (y1 - y0 + 1) * 2 / 3))
        let rx0 = x0 + corner, rx1 = max(x0 + corner, x1 - corner)
        func rowClear(_ y: Int, from previous: Int) -> Bool {
            for x in rx0...rx1 where !clear(x, y, from: x, previous) { return false }
            return true
        }
        var free = FreeSpace()
        let reach = Int(limit)
        var x = x1 + 1
        while x < image.width, x - x1 <= reach, columnClear(x, from: x - 1) { x += 1 }
        free.right = CGFloat(x - x1 - 1); free.rightEdge = x < image.width && x - x1 <= reach
        x = x0 - 1
        while x >= 0, x0 - x <= reach, columnClear(x, from: x + 1) { x -= 1 }
        free.left = CGFloat(x0 - x - 1); free.leftEdge = x >= 0 && x0 - x <= reach
        var y = y1 + 1
        while y < image.height, y - y1 <= reach, rowClear(y, from: y - 1) { y += 1 }
        free.down = CGFloat(y - y1 - 1); free.downEdge = y < image.height && y - y1 <= reach
        func solid(_ y: Int, from previous: Int) -> Bool {
            var changed = 0
            for x in rx0...rx1 where !clear(x, y, from: x, previous) { changed += 1 }
            return changed * 10 >= (rx1 - rx0 + 1) * 8
        }
        // An edge is anti-aliased: look at the stopping row and the one behind it.
        if free.downEdge { free.downSolid = solid(y, from: y - 1) || (y + 1 < image.height && solid(y + 1, from: y - 1)) }
        y = y0 - 1
        while y >= 0, y0 - y <= reach, rowClear(y, from: y + 1) { y -= 1 }
        free.up = CGFloat(y0 - y - 1); free.upEdge = y >= 0 && y0 - y <= reach
        if free.upEdge { free.upSolid = solid(y, from: y + 1) || (y - 1 >= 0 && solid(y - 1, from: y + 1)) }
        return free
    }
}

enum Fragments {
    /// Join pieces of one line that the recogniser reported separately, when
    /// nothing but the same background lies between them. Two chips, two table
    /// cells or a label beside a value stay apart.
    static func join(_ lines: [MeasuredLine], image: PixelImage, scale: CGFloat,
                     remeasure: (String, CGRect) -> MeasuredLine?) -> [MeasuredLine] {
        var rest = lines.sorted { $0.ink.rect.minX < $1.ink.rect.minX }
        var result: [MeasuredLine] = []
        while !rest.isEmpty {
            var current = rest.removeFirst()
            var grew = true
            while grew {
                grew = false
                for (index, other) in rest.enumerated() {
                    let size = current.style.size * scale
                    let gap = other.ink.rect.minX - current.ink.rect.maxX
                    guard gap > -1, gap <= size * 1.5, abs(other.ink.baseline - current.ink.baseline) <= size * 0.12 else { continue }
                    let ratio = other.style.size / current.style.size
                    guard ratio > 0.88, ratio < 1.14, current.style.color.distance(to: other.style.color) < 60 else { continue }
                    guard case .flat(let a) = current.ink.background, case .flat(let b) = other.ink.background, a.distance(to: b) <= 10 else { continue }
                    let free = Space.around(current.ink.rect, in: image, background: current.ink.background, limit: size * 2)
                    guard free.right >= gap - 3 else { continue }
                    guard let merged = remeasure(current.text + " " + other.text, current.box.union(other.box)) else { continue }
                    current = merged
                    current.startsListItem = lines.first { $0.box == current.box }?.startsListItem ?? current.startsListItem
                    rest.remove(at: index)
                    grew = true
                    break
                }
            }
            result.append(current)
        }
        return result
    }
}

enum BlockBuilder {
    static let terminal: Set<Character> = [".", "!", "?", "。", "！", "？", ":", "：", ";", "；", "…"]

    /// Group measured lines into blocks. `scale` is pixels per point.
    static func build(_ measured: [MeasuredLine], image: PixelImage, scale: CGFloat) -> [TextBlock] {
        let lines = measured.sorted { $0.ink.baseline == $1.ink.baseline ? $0.ink.rect.minX < $1.ink.rect.minX : $0.ink.baseline < $1.ink.baseline }
        var groups: [[MeasuredLine]] = []
        for line in lines {
            var joined = false
            // The nearest block above that this line continues.
            for index in groups.indices.reversed() {
                if canJoin(groups[index], line, image: image, scale: scale) {
                    groups[index].append(line)
                    joined = true
                    break
                }
            }
            if !joined { groups.append([line]) }
        }
        // Over a picture, a short line may have picked its outline for its text. Its block knows better.
        for index in groups.indices where groups[index].count >= 2 {
            guard let longest = groups[index].max(by: { $0.text.count < $1.text.count }),
                  case .complex = longest.ink.background, longest.ink.reach > 0 else { continue }
            for member in groups[index].indices where groups[index][member].style.color.distance(to: longest.style.color) > 60 {
                let line = groups[index][member]
                guard let ink = InkAnalyzer.measure(image, box: line.box, text: (longest.ink.color, longest.ink.reach)) else { continue }
                groups[index][member].ink = ink
                groups[index][member].style = longest.style
            }
        }
        var blocks = groups.map { group -> TextBlock in
            let rect = group.dropFirst().reduce(group[0].ink.rect) { $0.union($1.ink.rect) }
            let sizes = group.map(\.style.size).sorted()
            var style = group[0].style
            style.size = sizes[sizes.count / 2]
            let bold = group.filter { $0.style.weight.rawValue >= 600 }.count * 2 > group.count
            let weights = group.map(\.style.weight.rawValue).sorted()
            style.weight = Weight(rawValue: weights[weights.count / 2]) ?? (bold ? .bold : .regular)
            style.color = RGB(r: median(group.map(\.style.color.r))!, g: median(group.map(\.style.color.g))!, b: median(group.map(\.style.color.b))!)
            style.smoothed = group.filter(\.style.smoothed).count * 2 >= group.count
            let faces = Dictionary(grouping: group, by: \.style.face).max { $0.value.count < $1.value.count }
            style.face = faces?.key ?? .sans
            var block = TextBlock(lines: group, style: style, rect: rect, background: group[0].ink.background)
            let baselines = group.map(\.ink.baseline)
            let gaps = zip(baselines.dropFirst(), baselines).map { $0 - $1 }.sorted()
            block.pitch = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
            block.original = ScreenTranslate.joinParagraphLines(group.map(\.text))
            block.free = Space.around(rect, in: image, background: block.background, limit: style.size * scale * 40)
            return block
        }
        assignAlignment(&blocks, scale: scale)
        return blocks
    }

    private static func canJoin(_ group: [MeasuredLine], _ next: MeasuredLine, image: PixelImage, scale: CGFloat) -> Bool {
        let previous = group[group.count - 1]
        if next.startsListItem { return false }
        let size = previous.style.size * scale
        // Two or three characters are too few to measure a style from; go by colour and place.
        let brief = next.text.count <= 3
        let ratio = next.style.size / previous.style.size
        guard brief || (ratio > 0.87 && ratio < 1.15) else { return false }
        guard brief || (previous.style.weight.rawValue >= 600) == (next.style.weight.rawValue >= 600) else { return false }
        var overPicture = false
        if case .complex = previous.ink.background { overPicture = true }
        guard (brief && overPicture) || previous.style.color.distance(to: next.style.color) < 60 else { return false }
        guard brief || previous.style.face == next.style.face else { return false }
        if case .flat(let a) = previous.ink.background, case .flat(let b) = next.ink.background, a.distance(to: b) > 12 { return false }

        let step = next.ink.baseline - previous.ink.baseline
        guard step > size * 0.9, step < size * 2.1 else { return false }
        if group.count >= 2 {
            let pitch = previous.ink.baseline - group[group.count - 2].ink.baseline
            guard abs(step - pitch) <= pitch * 0.14 else { return false }
        }
        let a = previous.ink.rect, b = next.ink.rect
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        guard overlap > min(a.width, b.width) * 0.5 else { return false }
        let groupLeft = group.map(\.ink.rect.minX).min()!, groupRight = group.map(\.ink.rect.maxX).max()!
        let aligned = abs(b.minX - groupLeft) < size * 1.2 || abs(b.midX - (groupLeft + groupRight) / 2) < size * 1.2
            || abs(b.maxX - groupRight) < size * 0.6
        guard aligned else { return false }

        // Wrapped text or stacked labels? The line above was broken because the
        // next word did not fit. If it would have fit, these are separate items,
        // unless the sentence visibly runs on.
        let han = StyleEstimator.hanShare(next.text) >= 0.3
        let firstWord: CGFloat = han ? size : (next.ink.blobs.first.map { $0.maxX - $0.minX } ?? size) + size * 0.3
        let free = Space.around(a, in: image, background: previous.ink.background, limit: size * 30)
        // A boundary between the two lines: they sit in different containers.
        if free.downSolid, free.down < b.minY - a.maxY - 2 { return false }
        // Each hugged by its own container (two pills, two tags): their right edges differ.
        let below = Space.around(b, in: image, background: next.ink.background, limit: size * 30)
        if free.rightEdge, below.rightEdge, free.right < size * 1.5, below.right < size * 1.5,
           abs((a.maxX + free.right) - (b.maxX + below.right)) > size * 0.5 { return false }
        let padding = min(free.left, size * 1.5)
        let room = max(free.right, groupRight - a.maxX)
        let forced = room < firstWord + padding * 0.5
        let trimmed = previous.text.trimmingCharacters(in: .whitespaces)
        let runsOn: Bool = {
            guard let last = trimmed.last, !terminal.contains(last) else { return false }
            if han { return trimmed.count >= 8 }
            guard let first = next.text.trimmingCharacters(in: .whitespaces).first else { return false }
            return first.isLowercase || last == "," || last == "-"
        }()
        return forced || runsOn
    }

    private static func assignAlignment(_ blocks: inout [TextBlock], scale: CGFloat) {
        for index in blocks.indices {
            let block = blocks[index]
            let size = block.style.size * scale
            let tolerance = max(1.5 * scale, size * 0.12)
            if block.lines.count >= 2 {
                func spread(_ values: [CGFloat]) -> CGFloat { (values.max() ?? 0) - (values.min() ?? 0) }
                let lefts = spread(block.lines.map(\.ink.rect.minX))
                let centers = spread(block.lines.map(\.ink.rect.midX))
                let rights = spread(block.lines.map(\.ink.rect.maxX))
                if lefts <= tolerance * 1.5 || lefts <= min(centers, rights) { blocks[index].align = .left }
                else if centers <= rights { blocks[index].align = .center }
                else { blocks[index].align = .right }
                continue
            }
            // A single line: what do its neighbours above and below line up on?
            var left = 0, center = 0, right = 0, closeCenter = 0
            for (other, peer) in blocks.enumerated() where other != index {
                let distance = max(peer.rect.minY - block.rect.maxY, block.rect.minY - peer.rect.maxY)
                guard distance > -size * 0.2, distance < size * 8 else { continue }
                guard abs(peer.style.size - block.style.size) / block.style.size < 0.25 else { continue }
                if abs(peer.rect.minX - block.rect.minX) <= tolerance { left += 1 }
                else if abs(peer.rect.maxX - block.rect.maxX) <= tolerance { right += 1 }
                else if abs(peer.rect.midX - block.rect.midX) <= tolerance {
                    center += 1
                    if distance < size * 2.5 { closeCenter += 1 }
                }
            }
            // A shared right edge is rarely an accident; a shared centre between
            // two unrelated lines is, unless they are neighbours.
            if right > left, right >= center, right >= 2 || left == 0 { blocks[index].align = .right; continue }
            if center > left, center > right, center >= 2 || closeCenter >= 1 { blocks[index].align = .center; continue }
            if left > 0 { blocks[index].align = .left; continue }
            // No neighbours: where does it sit in its container?
            let free = block.free
            if free.leftEdge, free.rightEdge, abs(free.left - free.right) <= max(2 * scale, min(free.left, free.right) * 0.18) {
                blocks[index].align = .center
            } else if free.right <= size * 2.5, free.right < free.left * 0.35 {
                // Close to the right side of its container (or of the capture) and far from the left.
                blocks[index].align = .right
            }
        }
    }
}

enum StyleClusters {
    /// Text of one style measures a little differently from line to line. Give
    /// blocks that are clearly the same style the same size, so equals look equal.
    static func unify(_ blocks: inout [TextBlock]) {
        var clusters: [[Int]] = []
        let order = blocks.indices.sorted { blocks[$0].style.size < blocks[$1].style.size }
        for index in order {
            let style = blocks[index].style
            if let found = clusters.firstIndex(where: { members in
                let sizes = members.map { blocks[$0].style.size }.sorted()
                let middle = sizes[sizes.count / 2]
                let peer = blocks[members[0]].style
                return abs(style.size - middle) / middle <= 0.06 && peer.face == style.face
                    && peer.color.distance(to: style.color) <= 28
            }) { clusters[found].append(index) } else { clusters.append([index]) }
        }
        for members in clusters where members.count >= 2 {
            // Longer text measures better: weigh by length.
            var weighted: [(size: CGFloat, weight: Int)] = members.map { (blocks[$0].style.size, max(1, blocks[$0].original.count)) }
            weighted.sort { $0.size < $1.size }
            let total = weighted.reduce(0) { $0 + $1.weight }
            var running = 0
            var middle = weighted[weighted.count / 2].size
            for entry in weighted { running += entry.weight; if running * 2 >= total { middle = entry.size; break } }
            let reliable = members.filter { blocks[$0].original.count > 3 }
            let bold = reliable.filter { blocks[$0].style.weight.rawValue >= 600 }.count * 2 > reliable.count
            let weights = reliable.map { blocks[$0].style.weight.rawValue }.sorted()
            for index in members {
                blocks[index].style.size = middle
                if blocks[index].original.count <= 3, !reliable.isEmpty {
                    blocks[index].style.weight = Weight(rawValue: weights[weights.count / 2]) ?? (bold ? .semibold : .regular)
                }
            }
        }
    }

    /// Blocks that read as one set: the same style, stacked on a shared edge or
    /// standing on one row. They shrink together or not at all.
    static func groups(_ blocks: [TextBlock], scale: CGFloat) -> [[Int]] {
        var parent = Array(blocks.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        for a in blocks.indices {
            for b in blocks.indices where b > a {
                let x = blocks[a], y = blocks[b]
                guard abs(x.style.size - y.style.size) < 0.01, x.style.face == y.style.face,
                      (x.style.weight.rawValue >= 600) == (y.style.weight.rawValue >= 600) else { continue }
                let size = x.style.size * scale, tolerance = max(1.5 * scale, size * 0.12)
                let apart = max(y.rect.minY - x.rect.maxY, x.rect.minY - y.rect.maxY)
                let stacked = apart < size * 4 && (abs(x.rect.minX - y.rect.minX) <= tolerance
                    || abs(x.rect.maxX - y.rect.maxX) <= tolerance || abs(x.rect.midX - y.rect.midX) <= tolerance)
                let sameRow = abs(x.firstBaseline - y.firstBaseline) <= size * 0.15
                    && max(y.rect.minX - x.rect.maxX, x.rect.minX - y.rect.maxX) < size * 12
                if stacked || sameRow { parent[root(a)] = root(b) }
            }
        }
        return Dictionary(grouping: blocks.indices, by: root).values.map { Array($0) }
    }
}

enum Prose {
    /// Whether a block is language to translate. A sentence stays a sentence
    /// even with a symbol or an identifier in it; short strings fall back to the
    /// shipping heuristics for code, numbers and paths.
    static func shouldTranslate(_ text: String) -> Bool {
        let unquoted = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’「」『』"))
        let scalars = unquoted.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard scalars.count >= 2 else { return false }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let words = unquoted.split(separator: " ").count
        let han = scalars.filter(StyleEstimator.isHan).count
        if Double(letters) / Double(scalars.count) >= 0.7, words >= 6 || han >= 8, !CodeText.looksLikeCode(unquoted) { return true }
        return ScreenTranslate.shouldReplace(unquoted) && !CodeText.looksLikeCode(unquoted)
    }
}

enum CodeText {
    private static let keywords: Set<String> = ["return", "import", "export", "const", "let", "var", "function", "class",
        "def", "else", "async", "await", "func", "struct", "enum", "public", "private", "static", "void", "new", "from"]

    /// Source code, identifiers and markup are shown as they are.
    static func looksLikeCode(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        for mark in ["({", "})", "() {", "=>", "==", "!=", "&&", "||", "::", "</", "/>", "();", "){", "};"] where t.contains(mark) { return true }
        if let last = t.last, "{};".contains(last), t.count < 80 { return true }
        // kebab-case and snake_case identifiers, with or without a value: font-size, font-size: 12px;
        if t.range(of: #"^[a-z][a-z0-9]*([-_][a-z0-9]+)+-?(:.*)?$"#, options: .regularExpression) != nil { return true }
        // call(…) or object.member on a camelCase or dotted name
        if t.range(of: #"\b[a-z]+[A-Z]\w*\s*\("#, options: .regularExpression) != nil { return true }
        if t.range(of: #"\b\w+\.\w+\("#, options: .regularExpression) != nil { return true }
        let words = t.split(separator: " ").map(String.init)
        if words.count <= 2, let first = words.first, keywords.contains(first) { return true }
        return false
    }
}
