import AppKit
import Translation

/// The V2 pipeline (`Sources/Screen/Pipeline`) on a picture file, for scoring.
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

        let composed = ScreenPipeline.compose(analysis, translations: Dictionary(uniqueKeysWithValues: zip(wanted, translated)))
        if let image = composed.pixels.cgImage() {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: prefix + ".v2.png"))
        }

        let report: [[String: Any]] = composed.blocks.enumerated().map { index, block in
            let placement = composed.placed.first { $0.index == index }?.placement
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
        let seconds = composed.seconds
        try write(["scale": scale, "ocrLines": analysis.recognized, "blocks": report,
            "seconds": ["ocr": seconds.recognize, "measure": seconds.measure, "blocks": seconds.structure,
                        "translate": translateSeconds, "render": seconds.fit + seconds.render]], to: prefix + ".v2.json")
        print(String(format: "%@: %d lines, %d blocks (%d translated, %d shrunk, %d cut), ocr %.2fs measure %.2fs translate %.2fs render %.2fs",
            prefix, analysis.lines.count, composed.blocks.count, composed.placed.count, composed.shrunk, composed.cut,
            seconds.recognize, seconds.measure, translateSeconds, seconds.fit + seconds.render))
    }

    static func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    static func colour(_ c: RGB) -> [Double] { [Double(c.r), Double(c.g), Double(c.b)] }

    static func write(_ object: [String: Any], to path: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }
}
