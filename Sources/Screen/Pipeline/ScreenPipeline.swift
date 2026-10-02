import AppKit
import CoreGraphics
import Foundation

/// Screen translation in place: the text keeps its position, size, weight and
/// colour; only the strokes are erased and the translation is set where the
/// original was. Design and measurements: `docs/SCREEN_TRANSLATE_V2.md`.
///
///     analyze  — recognise, measure from the pixels, build blocks   (no translation needed)
///     compose  — fit the translations, erase the strokes, draw      (once the translations are there)
///
/// Both are plain functions on values and run off the main actor.
enum ScreenPipeline {
    struct Analysis: Sendable {
        /// Picture pixels per point.
        var scale: CGFloat
        var pixels: PixelImage
        var lines: [MeasuredLine]
        /// In reading order. `translate` says which ones are to be translated.
        var blocks: [TextBlock]
        var recognized: Int
        var seconds = Seconds()
    }

    struct Seconds: Sendable {
        var recognize = 0.0, measure = 0.0, structure = 0.0, fit = 0.0, render = 0.0
    }

    struct Composition: Sendable {
        var pixels: PixelImage
        /// The blocks as they ended up: one whose translation would show next to nothing keeps its original.
        var blocks: [TextBlock]
        var placed: [Placed]
        var seconds: Seconds

        struct Placed: Sendable {
            var index: Int
            var placement: Placement
        }

        var shrunk: Int { placed.filter { $0.placement.shrink < 1 }.count }
        var cut: Int { placed.filter(\.placement.truncated).count }
    }

    static let debug = ProcessInfo.processInfo.environment["V2_DEBUG"] != nil

    // MARK: - Analyze

    /// Recognise and measure every line; nothing is grouped or judged yet.
    static func measureLines(_ image: CGImage, pixels: PixelImage, scale: CGFloat,
                             languages: [String]) throws -> (lines: [MeasuredLine], recognized: Int, seconds: Seconds) {
        var seconds = Seconds()
        let start = CFAbsoluteTimeGetCurrent()
        let recognised = try Recognizer.recognize(image, scale: scale, languages: languages)
        let afterOCR = CFAbsoluteTimeGetCurrent()
        seconds.recognize = afterOCR - start

        // Every recognised line is measured on its own: one core each.
        var perLine = [[MeasuredLine]](repeating: [], count: recognised.count)
        perLine.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let results = buffer
            DispatchQueue.concurrentPerform(iterations: recognised.count) { index in
                results[index] = measured(recognised[index], pixels: pixels, scale: scale)
            }
        }
        var lines = perLine.flatMap { $0 }
        lines = Fragments.join(lines, image: pixels, scale: scale) { text, box in
            measure(text, box, confidence: 1, list: false, pixels: pixels, scale: scale)
        }
        seconds.measure = CFAbsoluteTimeGetCurrent() - afterOCR
        return (lines, recognised.count, seconds)
    }

    static func analyze(_ image: CGImage, scale: CGFloat, source: AppLanguage, target: AppLanguage) throws -> Analysis? {
        guard let pixels = PixelImage(image) else { return nil }
        let found = try measureLines(image, pixels: pixels, scale: scale,
                                     languages: ScreenTranslate.ocrLanguageHints(source: source, target: target))
        let start = CFAbsoluteTimeGetCurrent()
        var blocks = BlockBuilder.build(found.lines, image: pixels, scale: scale)
        StyleClusters.unify(&blocks)
        let eastAsian: [AppLanguage] = [.zhHans, .zhHant, .ja, .ko]
        let targetIsHan = eastAsian.contains(target)
        for index in blocks.indices {
            let text = blocks[index].original
            let han = StyleEstimator.hanShare(text)
            let alreadyTarget = targetIsHan ? han >= 0.5 : han == 0 && eastAsian.contains(source)
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
        var seconds = found.seconds
        seconds.structure = CFAbsoluteTimeGetCurrent() - start
        return Analysis(scale: scale, pixels: pixels, lines: found.lines, blocks: blocks, recognized: found.recognized, seconds: seconds)
    }

    // MARK: - Compose

    /// `translations` by block index. A block without one, or whose translation says the same, stays as it is.
    static func compose(_ analysis: Analysis, translations: [Int: String]) -> Composition {
        let scale = analysis.scale
        var blocks = analysis.blocks
        for (index, text) in translations where blocks.indices.contains(index) { blocks[index].translation = text }
        let start = CFAbsoluteTimeGetCurrent()

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
        let afterFit = CFAbsoluteTimeGetCurrent()

        var output = analysis.pixels
        var placed: [Composition.Placed] = []
        for index in blocks.indices {
            guard let placement = placements[index] else { continue }
            // A translation that would show next to nothing is worse than the original.
            let shown = placement.lines.map(\.text).joined().count
            if placement.truncated, shown * 3 < blocks[index].translation.count + 3 { blocks[index].translate = false; continue }
            for line in blocks[index].lines { Eraser.erase(line.ink, in: &output, scale: scale) }
            placed.append(.init(index: index, placement: placement))
        }
        Compositor.draw(placed.map { (blocks[$0.index], $0.placement) }, on: &output, scale: scale)
        var seconds = analysis.seconds
        seconds.fit = afterFit - start
        seconds.render = CFAbsoluteTimeGetCurrent() - afterFit
        return Composition(pixels: output, blocks: blocks, placed: placed, seconds: seconds)
    }

    // MARK: - One recognised line

    /// The line, or the pieces it falls into when two chips or two buttons were read as one.
    private static func measured(_ found: RecognizedLine, pixels: PixelImage, scale: CGFloat) -> [MeasuredLine] {
        guard let line = measure(found.text, found.box, confidence: found.confidence, list: found.startsListItem,
                                 pixels: pixels, scale: scale) else { return [] }
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
            return pieces.compactMap { measure($0.text, $0.box, confidence: found.confidence, list: false, pixels: pixels, scale: scale) }
        }
        return [line]
    }

    private static func measure(_ text: String, _ box: CGRect, confidence: Float, list: Bool,
                                pixels: PixelImage, scale: CGFloat) -> MeasuredLine? {
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
        if debug {
            print("line", text, "box", box.integral, "ink", ink.rect.integral, "blobs", ink.blobs.map { "\(Int($0.minX))-\(Int($0.maxX)) s\(String(format: "%.2f", $0.solidity))" },
                "trim", ink.trimmedLeading, ink.trimmedTrailing, ink.background.name)
        }
        guard let style = StyleEstimator.estimate(text: cleaned, ink: ink, scale: scale) else { return nil }
        return MeasuredLine(text: cleaned, box: box, ink: ink, style: style, confidence: confidence, startsListItem: list)
    }
}
