import AppKit
import Translation

/// The shipping screen-translation pipeline, run on a picture file, so its
/// result can be scored against the page's own truth.
///
///   baseline <image.png> <scale> <source> <target> <out-prefix>
///
/// Writes <out-prefix>.current.png and <out-prefix>.current.json. Rectangles
/// are in picture pixels, top-left origin; font sizes in points (pixels / scale).
/// The font-weight model is not loaded here (it needs the built bundle), so
/// weight comes from the heading rule alone.
@main struct Baseline {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let scale = Double(args[2]),
              let source = AppLanguage(rawValue: args[3]), let target = AppLanguage(rawValue: args[4]),
              let loaded = NSImage(contentsOfFile: args[1]),
              let pixels = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fatalError("usage: baseline <image.png> <scale> <source> <target> <out-prefix>")
        }
        let image = NSImage(cgImage: pixels, size: CGSize(width: Double(pixels.width) / scale, height: Double(pixels.height) / scale))
        let start = CFAbsoluteTimeGetCurrent()
        let lines = try await ScreenOCRService.recognize(image,
            languages: ScreenTranslate.ocrLanguageHints(source: source, target: target))
        let recognized = CFAbsoluteTimeGetCurrent()
        var paragraphs = ScreenTranslate.groupParagraphs(from: lines, canvasSize: image.size)
        let engine = TranslationEngine()
        try await engine.prepareInstalled(source: source.translationLanguage, target: target.translationLanguage)
        guard engine.isReady else { fatalError("translation pair \(args[3]) → \(args[4]) is not installed") }
        let translations = try await engine.translateBatch(paragraphs.map(\.original))
        for index in paragraphs.indices { paragraphs[index].translation = translations[index] }
        for index in paragraphs.indices {
            if let text = ScreenTranslate.navigationTranslation(for: index, paragraphs: paragraphs,
                canvasSize: image.size, source: source, target: target) { paragraphs[index].translation = text }
        }
        let translated = CFAbsoluteTimeGetCurrent()
        let raw = ScreenTranslate.layoutPlates(paragraphs, canvasSize: image.size)
        let items = ScreenPinRenderer.prepareItems(raw, image: pixels, canvasSize: image.size)
        let output = ScreenPinRenderer.composite(image: image, items: items, canvasSize: image.size, overlayEnabled: true)
        let rendered = CFAbsoluteTimeGetCurrent()
        let cg = output.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: args[5] + ".current.png"))

        func px(_ rect: CGRect) -> [Double] { [rect.minX * scale, rect.minY * scale, rect.width * scale, rect.height * scale] }
        // layoutPlates drops paragraphs with an empty translation; join by source rectangle.
        var blocks: [[String: Any]] = []
        for item in items {
            guard let paragraph = paragraphs.first(where: {
                let rect = ScreenTranslate.topLeftRect(visionBox: $0.visionBox, canvasSize: image.size)
                return abs(rect.minX - item.sourceRect.minX) < 0.01 && abs(rect.minY - item.sourceRect.minY) < 0.01
            }) else { continue }
            blocks.append([
                "original": paragraph.original, "translation": item.text, "size": Double(item.fontSize),
                "bold": item.isHeading, "lines": paragraph.lineCount, "centered": item.centered,
                "sourceRect": px(item.sourceRect), "rect": px(item.rect),
                "overflow": item.textContentHeight > item.rect.height + 0.5,
                "hidden": item.rect.isEmpty,
                "lineRects": paragraph.sourceLines.map { px(ScreenTranslate.topLeftRect(visionBox: $0.visionBox, canvasSize: image.size)) },
                "lineTexts": paragraph.sourceLines.map(\.text),
            ])
        }
        let report: [String: Any] = [
            "scale": scale, "ocrLines": lines.count, "paragraphs": paragraphs.count, "blocks": blocks,
            "seconds": ["ocr": recognized - start, "translate": translated - recognized, "render": rendered - translated],
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[5] + ".current.json"))
        print(String(format: "%@: %d lines, %d blocks, ocr %.2fs translate %.2fs render %.2fs", args[5], lines.count,
            blocks.count, recognized - start, translated - recognized, rendered - translated))
    }
}
