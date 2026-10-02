import AppKit
import Translation

/// Prototype of the V2 pipeline on a picture file.
///
///   v2 <image.png> <scale> <source> <target> <out-prefix> [--lines]
///
/// Writes <out-prefix>.v2.png and <out-prefix>.v2.json in the schema of `baseline`.
/// With --lines every recognised line is reported as its own block and nothing
/// is translated: this scores the measuring stage alone.
@main struct V2 {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        if args.count >= 2, args[1] == "--probe" {
            // How the reference rasteriser behaves: does smoothing change the ink, and by how much?
            for size in [13.0, 14.0, 16.0] {
                for scale in [1.0, 2.0] {
                    for smoothed in [true, false] {
                        for name in ["system", "Helvetica Neue"] {
                            let font = name == "system" ? NSFont.systemFont(ofSize: size) : NSFont(name: name, size: size)!
                            guard let drawn = Rasterizer.render("Track your work, set milestones", font: font, scale: scale, smoothed: smoothed),
                                  let ink = InkAnalyzer.measure(drawn.image, box: drawn.box) else { continue }
                            let rises = ink.blobs.map(\.rise).sorted()
                            let rise = rises[min(rises.count - 1, Int(Double(rises.count) * 0.75))]
                            print(String(format: "%@ %2.0fpt @%.0fx smoothed=%@  edge ascent %.3f em  column rise %.3f em  stem %.2f px", name.padding(toLength: 14, withPad: " ", startingAt: 0),
                                size, scale, smoothed ? "yes" : "no ", ink.ascent / (size * scale), rise / (size * scale), ink.stem))
                        }
                    }
                }
            }
            return
        }
        guard args.count >= 6, let scale = Double(args[2]),
              let source = AppLanguage(rawValue: args[3]), let target = AppLanguage(rawValue: args[4]),
              let loaded = NSImage(contentsOfFile: args[1]),
              let cg = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixels = PixelImage(cg) else {
            fatalError("usage: v2 <image.png> <scale> <source> <target> <out-prefix> [--lines]")
        }
        let prefix = args[5]
        let canvas = CGSize(width: Double(cg.width), height: Double(cg.height))
        let pointImage = NSImage(cgImage: cg, size: CGSize(width: canvas.width / scale, height: canvas.height / scale))
        let start = CFAbsoluteTimeGetCurrent()
        _ = (canvas, pointImage)
        let recognised = try Recognizer.recognize(cg,
            languages: ScreenTranslate.ocrLanguageHints(source: source, target: target))
        let afterOCR = CFAbsoluteTimeGetCurrent()

        func measure(_ text: String, _ box: CGRect, confidence: Float, list: Bool) -> MeasuredLine? {
            guard let ink = InkAnalyzer.measure(pixels, box: box) else { return nil }
            // An icon swept into the line is not part of its words.
            var words = text.split(separator: " ").map(String.init)
            // Words that belonged to what was left out: by its share of the line's width, at least an icon read as a letter.
            let total = ink.rect.width + ink.trimmedLeadingWidth + ink.trimmedTrailingWidth
            let characters = CGFloat(max(1, words.reduce(0) { $0 + $1.count }))
            if ink.trimmedLeading {
                var budget = characters * ink.trimmedLeadingWidth / total * 1.15
                if words.count >= 2, words[0].count <= 2 { budget = max(budget, CGFloat(words[0].count)) }
                while words.count >= 2, CGFloat(words[0].count) <= budget { budget -= CGFloat(words[0].count); words.removeFirst() }
            }
            if ink.trimmedTrailing {
                var budget = characters * ink.trimmedTrailingWidth / total * 1.15
                if words.count >= 2, words[words.count - 1].count <= 2 { budget = max(budget, CGFloat(words[words.count - 1].count)) }
                while words.count >= 2, CGFloat(words[words.count - 1].count) <= budget { budget -= CGFloat(words[words.count - 1].count); words.removeLast() }
            }
            let cleaned = words.joined(separator: " ")
            if ProcessInfo.processInfo.environment["V2_DEBUG"] != nil {
                print("line", text, "box", box.integral, "ink", ink.rect.integral, "blobs", ink.blobs.map { "\(Int($0.minX))-\(Int($0.maxX)) s\(String(format: "%.2f", $0.solidity))" },
                    "trim", ink.trimmedLeading, ink.trimmedTrailing, ink.background.name)
            }
            guard let style = StyleEstimator.estimate(text: cleaned, ink: ink, scale: scale) else { return nil }
            return MeasuredLine(text: cleaned, box: box, ink: ink, style: style, confidence: confidence, startsListItem: list)
        }
        var lines: [MeasuredLine] = []
        for found in recognised {
            guard let line = measure(found.text, found.box, confidence: found.confidence, list: found.startsListItem) else { continue }
            // Two chips or two buttons read as one line: the paper changes between the words.
            var words = line.text.split(separator: " ").map(String.init)
            let runs = line.ink.blobs
            if runs.count >= 2, words.count == 1, StyleEstimator.hanShare(line.text) >= 0.9 {
                // Han without spaces: every glyph is as wide as the next, so share the characters out by width.
                let characters = Array(line.text)
                let total = runs.reduce(0) { $0 + ($1.maxX - $1.minX) }
                var shared: [String] = [], used = 0
                for (index, run) in runs.enumerated() {
                    let count = index == runs.count - 1 ? characters.count - used
                        : min(characters.count - used, max(1, Int((CGFloat(characters.count) * (run.maxX - run.minX) / total).rounded())))
                    shared.append(String(characters[used..<(used + max(0, count))]))
                    used += max(0, count)
                }
                if shared.allSatisfy({ !$0.isEmpty }) { words = shared }
            }
            var pieces: [(text: String, box: CGRect)] = []
            var onOneColour = false
            if case .flat = line.ink.background { onOneColour = true }
            // Chips side by side each have their own paper. A sentence with a highlighted
            // word in it does not: most of it lies on the paper around the line.
            var lineColour = RGB(r: 0, g: 0, b: 0)
            if case .flat(let colour) = line.ink.background { lineColour = colour }
            let apart = runs.allSatisfy { $0.paper.distance(to: lineColour) > 10 }
                || runs.filter { $0.paper.distance(to: lineColour) > 10 }.count * 2 >= runs.count && runs.count == 2
            if onOneColour, apart, runs.count >= 2, runs.count == words.count {
                var start = 0
                for index in 1...runs.count {
                    let boundary = index == runs.count || runs[index].paper.distance(to: runs[index - 1].paper) > 16
                    guard boundary else { continue }
                    let box = CGRect(x: runs[start].minX, y: line.box.minY, width: runs[index - 1].maxX - runs[start].minX, height: line.box.height)
                    pieces.append((words[start..<index].joined(separator: " "), box))
                    start = index
                }
            }
            if pieces.count >= 2 {
                lines += pieces.compactMap { measure($0.text, $0.box, confidence: found.confidence, list: false) }
            } else {
                lines.append(line)
            }
        }
        lines = Fragments.join(lines, image: pixels, scale: scale) { text, box in
            measure(text, box, confidence: 1, list: false)
        }
        let afterMeasure = CFAbsoluteTimeGetCurrent()

        if args.contains("--lines") {
            let blocks: [[String: Any]] = lines.map { line in
                ["original": line.text, "translation": "", "size": Double(line.style.size),
                 "bold": line.style.weight.rawValue >= 600, "weight": line.style.weight.rawValue,
                 "face": line.style.face.rawValue, "background": line.ink.background.name,
                 "color": colour(line.style.color), "lineRects": [rect(line.ink.rect)],
                 "baseline": Double(line.ink.baseline), "stem": Double(line.ink.stem), "smoothed": line.style.smoothed]
            }
            try write(["scale": scale, "blocks": blocks], to: prefix + ".v2.json")
            print(String(format: "%@: %d/%d lines measured, ocr %.2fs measure %.2fs", prefix, lines.count, recognised.count,
                afterOCR - start, afterMeasure - afterOCR))
            return
        }

        var blocks = BlockBuilder.build(lines, image: pixels, scale: scale)
        StyleClusters.unify(&blocks)
        let targetIsHan = [.zhHans, .zhHant, .ja, .ko].contains(target)
        for index in blocks.indices {
            let text = blocks[index].original
            let han = StyleEstimator.hanShare(text)
            let alreadyTarget = targetIsHan ? han >= 0.5 : han == 0 && [.zhHans, .zhHant, .ja, .ko].contains(source)
            let confident = blocks[index].lines.allSatisfy { $0.confidence >= ScreenTranslate.minimumOCRConfidence }
            blocks[index].translate = confident && !alreadyTarget && Prose.shouldTranslate(text)
                && blocks[index].style.face != .mono
                && !(blocks[index].lines.count == 1 && CodeText.looksLikeCode(text))
        }
        // The rest of a line of code is code: a fragment beside one that is kept is kept too.
        for index in blocks.indices where blocks[index].translate {
            let own = blocks[index]
            let beside = blocks.contains { other in
                !other.translate && (other.style.face == .mono || CodeText.looksLikeCode(other.original))
                    && abs(other.firstBaseline - own.firstBaseline) <= own.style.size * scale * 0.2
                    && abs(other.style.size - own.style.size) / own.style.size < 0.12
            }
            if beside, own.lines.count == 1 { blocks[index].translate = false }
        }
        let afterBlocks = CFAbsoluteTimeGetCurrent()

        let engine = TranslationEngine()
        try await engine.prepareInstalled(source: source.translationLanguage, target: target.translationLanguage)
        guard engine.isReady else { fatalError("translation pair \(args[3]) → \(args[4]) is not installed") }
        let wanted = blocks.indices.filter { blocks[$0].translate }
        let translated = try await engine.translateBatch(wanted.map { blocks[$0].original })
        for (index, text) in zip(wanted, translated) { blocks[index].translation = text }
        let afterTranslate = CFAbsoluteTimeGetCurrent()

        // Fit each block; then let sets of equals agree on one size.
        var placements: [Int: Placement] = [:]
        for index in blocks.indices where blocks[index].translate && !blocks[index].translation.isEmpty
            && blocks[index].translation != blocks[index].original {
            placements[index] = Fitter.place(blocks[index], scale: scale)
        }
        for group in StyleClusters.groups(blocks, scale: scale) where group.count >= 2 {
            // What had to be cut does not drag its equals down with it.
            let shrinks = group.compactMap { placements[$0] }.filter { !$0.truncated }.map(\.shrink)
            // One label in a tight pill does not make a whole list smaller.
            guard let smallest = shrinks.min(), smallest < 1, shrinks.filter({ $0 < 1 }).count * 5 >= shrinks.count * 2 else { continue }
            for index in group where placements[index] != nil && !placements[index]!.truncated && placements[index]!.shrink != smallest {
                placements[index] = Fitter.place(blocks[index], scale: scale, only: smallest)
            }
        }
        var output = pixels
        var placed: [(block: TextBlock, placement: Placement)] = []
        for index in blocks.indices {
            guard let placement = placements[index] else { continue }
            // A translation that would show next to nothing is worse than the original.
            let shown = placement.lines.map(\.text).joined().count
            if placement.truncated, shown * 3 < blocks[index].translation.count + 3 { blocks[index].translate = false; continue }
            for line in blocks[index].lines { Eraser.erase(line.ink, in: &output, scale: scale) }
            placed.append((blocks[index], placement))
        }
        Compositor.draw(placed, on: &output, scale: scale)
        let afterRender = CFAbsoluteTimeGetCurrent()
        if let image = output.cgImage() {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: prefix + ".v2.png"))
        }

        let report: [[String: Any]] = blocks.map { block in
            let placement = placed.first { $0.block.rect == block.rect }?.placement
            return [
                "original": block.original, "translation": block.translation, "translated": block.translate,
                "size": Double(block.style.size), "bold": block.style.weight.rawValue >= 600, "weight": block.style.weight.rawValue,
                "face": block.style.face.rawValue, "color": colour(block.style.color), "align": block.align.rawValue,
                "background": block.background.name, "sourceRect": rect(block.rect),
                "lineRects": block.lines.map { rect($0.ink.rect) }, "lineTexts": block.lines.map(\.text),
                "lines": block.lines.count, "pitch": Double(block.pitch),
                "free": ["left": Double(block.free.left), "right": Double(block.free.right), "up": Double(block.free.up), "down": Double(block.free.down),
                         "upSolid": block.free.upSolid, "downSolid": block.free.downSolid,
                         "leftEdge": block.free.leftEdge, "rightEdge": block.free.rightEdge],
                "blobs": block.lines.map { $0.ink.blobs.map { [Double($0.minX), Double($0.maxX), Double($0.solidity)] } },
                "placedLines": placement?.lines.map { ["text": $0.text, "x": Double($0.x), "baseline": Double($0.baseline), "width": Double($0.width)] } ?? [],
                "shrink": Double(placement?.shrink ?? 1), "widened": placement?.widened ?? false, "truncated": placement?.truncated ?? false,
            ]
        }
        try write(["scale": scale, "ocrLines": recognised.count, "blocks": report,
            "seconds": ["ocr": afterOCR - start, "measure": afterMeasure - afterOCR, "blocks": afterBlocks - afterMeasure,
                        "translate": afterTranslate - afterBlocks, "render": afterRender - afterTranslate]], to: prefix + ".v2.json")
        let shrunk = placed.filter { $0.placement.shrink < 1 }.count, cut = placed.filter(\.placement.truncated).count
        print(String(format: "%@: %d lines, %d blocks (%d translated, %d shrunk, %d cut), ocr %.2fs measure %.2fs translate %.2fs render %.2fs",
            prefix, lines.count, blocks.count, placed.count, shrunk, cut, afterOCR - start, afterMeasure - afterOCR,
            afterTranslate - afterBlocks, afterRender - afterTranslate))
    }

    static func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    static func colour(_ c: RGB) -> [Double] { [Double(c.r), Double(c.g), Double(c.b)] }

    static func write(_ object: [String: Any], to path: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }
}
