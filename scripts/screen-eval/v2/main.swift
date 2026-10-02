import AppKit
import Translation

/// The V2 pipeline (`Sources/Screen/Pipeline`) on a picture file, for scoring.
///
///   v2 <image.png> <scale> <source> <target> <out-prefix> [--lines] [--precise <table.json>]
///
/// Writes <out-prefix>.v2.png and <out-prefix>.v2.json in the schema of `baseline`.
/// With --lines every recognised line is reported as its own block and nothing
/// is translated: this scores the measuring stage alone.
/// With --precise the whole-screen translation runs as well, a table standing in
/// for the language model ({"source text": "translation", "a brand": null}; no
/// endpoint is called), and its request, its answer and its picture are written
/// beside the others as <out-prefix>.precise.*.
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
        if args.contains("--lines") {
            let found = try ScreenPipeline.measureLines(cg, pixels: pixels, scale: scale,
                languages: ScreenTranslate.ocrLanguageHints(source: source, target: target))
            let blocks: [[String: Any]] = found.lines.map { line in
                ["original": line.text, "translation": "", "size": Double(line.style.size),
                 "bold": line.style.weight.rawValue >= 600, "weight": line.style.weight.rawValue,
                 "face": line.style.face.rawValue, "background": line.ink.background.name,
                 "color": colour(line.style.color), "lineRects": [rect(line.ink.rect)],
                 "baseline": Double(line.ink.baseline), "stem": Double(line.ink.stem), "smoothed": line.style.smoothed]
            }
            try write(["scale": scale, "blocks": blocks], to: prefix + ".v2.json")
            print(String(format: "%@: %d/%d lines measured, ocr %.2fs measure %.2fs", prefix, found.lines.count, found.recognized,
                found.seconds.recognize, found.seconds.measure))
            return
        }
        guard let analysis = try ScreenPipeline.analyze(cg, scale: scale, source: source, target: target) else { fatalError("unreadable picture") }

        let translateStart = CFAbsoluteTimeGetCurrent()
        let engine = TranslationEngine()
        try await engine.prepareInstalled(source: source.translationLanguage, target: target.translationLanguage)
        guard engine.isReady else { fatalError("translation pair \(args[3]) → \(args[4]) is not installed") }
        let wanted = analysis.blocks.indices.filter { analysis.blocks[$0].translate }
        let translated = try await engine.translateBatch(wanted.map { analysis.blocks[$0].original })
        let translateSeconds = CFAbsoluteTimeGetCurrent() - translateStart

        let quick = Dictionary(uniqueKeysWithValues: zip(wanted, translated))
        let composed = ScreenPipeline.compose(analysis, translations: quick)
        // What a language model would be told about each block.
        let requests = PreciseTranslation.requests(analysis.blocks, scale: scale, target: target)
        let asked = Dictionary(uniqueKeysWithValues: requests.flatMap { $0 }.map { ($0.block, $0) })
        if let image = composed.pixels.cgImage() {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: prefix + ".v2.png"))
        }

        let report: [[String: Any]] = composed.blocks.enumerated().map { index, block in
            let placement = composed.placed.first { $0.index == index }?.placement
            return [
                "original": block.original, "translation": block.translation, "translated": block.translate,
                "role": asked[index]?.role.rawValue ?? "", "maxChars": asked[index]?.maxChars ?? 0,
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
        let seconds = composed.seconds
        try write(["scale": scale, "ocrLines": analysis.recognized, "blocks": report,
            "seconds": ["ocr": seconds.recognize, "measure": seconds.measure, "blocks": seconds.structure,
                        "translate": translateSeconds, "render": seconds.fit + seconds.render]], to: prefix + ".v2.json")
        print(String(format: "%@: %d lines, %d blocks (%d translated, %d shrunk, %d cut), ocr %.2fs measure %.2fs translate %.2fs render %.2fs",
            prefix, analysis.lines.count, composed.blocks.count, composed.placed.count, composed.shrunk, composed.cut,
            seconds.recognize, seconds.measure, translateSeconds, seconds.fit + seconds.render))
        if let flag = args.firstIndex(of: "--precise"), flag + 1 < args.count {
            try await precise(table: args[flag + 1], analysis: analysis, requests: requests, quick: quick,
                              source: source, target: target, prefix: prefix)
        }
    }

    /// What went out and what came back, for writing down afterwards.
    actor Exchanges {
        var all: [(request: String, answer: String)] = []
        func add(_ request: String, _ answer: String) { all.append((request, answer)) }
    }

    /// The precise path as the application runs it, with a table for a model:
    ///   <prefix>.precise.request.json  the user message as it would be sent (several: a blank line between)
    ///   <prefix>.precise.answer.json   what came back
    ///   <prefix>.precise.png           the quick translation with the precise one over it
    ///   <prefix>.precise.json          block by block: role, max_chars, both translations, how it was set
    static func precise(table path: String, analysis: ScreenPipeline.Analysis, requests: [[PreciseTranslation.Item]],
                        quick: [Int: String], source: AppLanguage, target: AppLanguage, prefix: String) async throws {
        guard let table = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else {
            fatalError("\(path): expected {\"source text\": \"translation\", \"a brand\": null}")
        }
        let items = requests.flatMap { $0 }
        let strangers = table.keys.filter { key in !items.contains { $0.text == key } }.sorted()
        let canned = ScreenPreciseTranslator.canned(table.mapValues { $0 as? String })
        let exchanges = Exchanges()
        let translator = ScreenPreciseTranslator(transport: { system, user in
            let answer = try await canned(system, user)
            await exchanges.add(user, answer)
            return answer
        })
        let outcome = await translator.translate(requests, source: source, target: target)
        let sent = await exchanges.all.sorted { $0.request < $1.request }
        try sent.map(\.request).joined(separator: "\n\n").write(toFile: prefix + ".precise.request.json", atomically: true, encoding: .utf8)
        try sent.map(\.answer).joined(separator: "\n\n").write(toFile: prefix + ".precise.answer.json", atomically: true, encoding: .utf8)

        let merged = PreciseTranslation.merge(quick, outcome.accepted)
        let composed = ScreenPipeline.compose(analysis, translations: merged)
        if let image = composed.pixels.cgImage() {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: prefix + ".precise.png"))
        }
        let report: [[String: Any]] = items.map { item in
            let placement = composed.placed.first { $0.index == item.block }?.placement
            let verdict = outcome.accepted.kept.contains(item.block) ? "keep" : outcome.accepted.translations[item.block] != nil ? "precise" : "quick"
            return ["id": item.id, "role": item.role.rawValue, "maxChars": item.maxChars, "original": item.text,
                    "quick": quick[item.block] ?? "", "set": merged[item.block] ?? "", "from": verdict,
                    "shrink": Double(placement?.shrink ?? 1), "truncated": placement?.truncated ?? false,
                    "sourceRect": rect(analysis.blocks[item.block].rect)]
        }
        try write(["blocks": report, "requests": outcome.requests, "rejected": outcome.accepted.rejected,
                   "failure": outcome.failure.map { "\($0)" } ?? ""], to: prefix + ".precise.json")
        print(String(format: "%@: precise — %d request(s) for %d blocks, %d translated, %d kept, %d rejected, %d over max_chars; set: %d shrunk, %d cut%@",
            prefix, outcome.requests, items.count, outcome.accepted.translations.count, outcome.accepted.kept.count,
            outcome.accepted.rejected, outcome.accepted.long, composed.shrunk, composed.cut,
            strangers.isEmpty ? "" : "; not on this screen: \(strangers)"))
    }

    static func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    static func colour(_ c: RGB) -> [Double] { [Double(c.r), Double(c.g), Double(c.b)] }

    static func write(_ object: [String: Any], to path: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }
}
