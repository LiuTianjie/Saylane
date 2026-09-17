import AppKit
import Translation
import CoreML

/// Real OCR and local translation; no stub text or external polish service.
@main struct ScreenTranslationPreview {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 || args.count == 3, let loaded = NSImage(contentsOfFile: args[0]),
            let pixels = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fatalError("usage: screen-translation-preview source.png output-directory")
        }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = NSImage(cgImage: pixels, size: CGSize(width: pixels.width / 2, height: pixels.height / 2))
        let start = CFAbsoluteTimeGetCurrent()
        var lines = try await ScreenOCRService.recognize(image, languages: ["en-US", "en", "zh-Hans"])
        if let path = ProcessInfo.processInfo.environment["SAYLANE_FONT_WEIGHT_NATIVE_MODEL"] {
            let service = ScreenFontWeightService(modelURL: URL(fileURLWithPath: path))
            lines = try await service.annotate(lines, pixels: pixels)
            precondition(lines.allSatisfy { $0.boldScore != nil }, "Native model must actually run")
        }
        let recognized = CFAbsoluteTimeGetCurrent()
        var paragraphs = ScreenTranslate.groupParagraphs(from: lines, canvasSize: image.size)
        let engine = TranslationEngine()
        try await engine.prepareInstalled(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
        guard engine.isReady else { fatalError("Local English/Chinese translation model is not installed") }
        print("Recognized \(lines.count) lines / \(paragraphs.count) paragraphs; translating...")
        fflush(stdout)
        let translations = try await engine.translateBatch(paragraphs.map(\.original))
        for index in paragraphs.indices { paragraphs[index].translation = translations[index] }
        for index in paragraphs.indices {
            if let text = ScreenTranslate.navigationTranslation(for: index, paragraphs: paragraphs,
                canvasSize: image.size, source: .en, target: .zhHans) { paragraphs[index].translation = text }
        }
        if pixels.width == 1630 && pixels.height == 2050 {
            precondition(paragraphs.count == 12, "Nine body paragraphs and three headings must remain separate")
            let fonts = ScreenTranslate.paragraphFonts(paragraphs, canvasSize: image.size)
            let bodyFonts = paragraphs.indices.filter { paragraphs[$0].lineCount > 1 }.map { fonts[$0] }
            precondition((bodyFonts.max() ?? 0) - (bodyFonts.min() ?? 0) < 0.1,
                "Document body font must be consistent")
        }
        if pixels.width == 990 && pixels.height == 802 {
            let bullets = paragraphs.filter { $0.sourceLines.first?.startsListItem == true }
            precondition(bullets.count == 3, "All three source list items must remain independent")
            precondition(bullets.allSatisfy { !$0.isHeading }, "Ordinary bullet text must not be made bold")
            let fonts = ScreenTranslate.paragraphFonts(paragraphs, canvasSize: image.size)
            let body = paragraphs.indices.filter { paragraphs[$0].original != "Codex for Open Source" }.map { fonts[$0] }
            precondition(body.max()! - body.min()! < 0.1, "Source body and bullet font sizes agree")
        }
        let translated = CFAbsoluteTimeGetCurrent()
        var rawItems = ScreenTranslate.layoutPlates(paragraphs, canvasSize: image.size)
        // Offline experiment only: production never reads this environment variable
        // or the prototype model. Predictions come from original image crops.
        if let path = ProcessInfo.processInfo.environment["SAYLANE_FONT_WEIGHT_EXPERIMENT"] {
            struct PredictionFile: Decodable {
                struct Row: Decodable { let text: String; let bold_probability: Double }
                let rows: [Row]
            }
            let predictions = try JSONDecoder().decode(PredictionFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            for index in rawItems.indices where paragraphs.indices.contains(index) {
                let scores = paragraphs[index].sourceLines.compactMap { line in
                    predictions.rows.first { $0.text == line.text }?.bold_probability
                }.sorted()
                guard !scores.isEmpty else { continue }
                let score = scores[scores.count / 2]
                if score >= 0.9 { rawItems[index].isHeading = true }
                else if score <= 0.1 { rawItems[index].isHeading = false }
            }
        }
        let items = ScreenPinRenderer.prepareItems(rawItems, image: pixels, canvasSize: image.size)
        for i in items.indices {
            for j in items.indices where j > i {
                let hit = items[i].rect.intersection(items[j].rect)
                precondition(hit.isNull || hit.width <= 0 || hit.height <= 0, "Visible translated rectangles overlap")
            }
        }
        print("PASS: zero overlapping translation rectangles; \(items.filter { $0.rect.isEmpty }.count) blocks available only in full-text reader")
        // Rectangle separation alone is not visual acceptance: a nonempty
        // plate may erase the source while failing to draw even one whole line.
        let blank = items.filter { item in
            guard !item.rect.isEmpty else { return false }
            let inset = ScreenTranslate.textInsets(fontSize: item.fontSize)
            return !ScreenTranslate.inkLines(text: item.text, fontSize: item.fontSize,
                width: max(1, item.rect.width - inset.width * 2), heading: item.isHeading,
                linePitch: item.linePitch).contains { line in
                    inset.height + line.baseline - line.ink.maxY >= -0.01 &&
                    inset.height + line.baseline - line.ink.minY <= item.rect.height + 0.01
                }
        }
        let overflow = items.filter { !$0.rect.isEmpty && $0.textContentHeight > $0.rect.height + 0.5 }
        let expectedOCR: [String]
        switch (pixels.width, pixels.height) {
        case (1630, 2050): expectedOCR = ["Attention mechanisms have become", "Model Architecture"]
        case (2404, 2098): expectedOCR = ["郑鑫锟", "I don't seem to see", "local computing Models"]
        default: expectedOCR = []
        }
        let recognizedText = lines.map(\.text).joined(separator: " ")
        let missingOCR = expectedOCR.filter { !recognizedText.localizedCaseInsensitiveContains($0) }
        let diagnostics = "Missing fixture OCR anchors: \(missingOCR); Suppressed blocks: \(items.filter { $0.rect.isEmpty }.count); blank plates: \(blank.count); overflow blocks: \(overflow.count)"
        print(diagnostics)
        try lines.map { "\($0.visionBox)\t\($0.text)" }.joined(separator: "\n")
            .write(to: directory.appendingPathComponent("ocr.txt"), atomically: true, encoding: .utf8)
        let output = ScreenPinRenderer.composite(image: image, items: items, canvasSize: image.size, overlayEnabled: true)
        let rendered = CFAbsoluteTimeGetCurrent()
        let cgOutput = output.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        try NSBitmapImageRep(cgImage: cgOutput).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("translated.png"))
        let protected: [CGRect]
        switch (pixels.width, pixels.height) {
        case (5120, 2578):
            protected = [CGRect(x: 1330, y: 1465, width: 120, height: 40),
                CGRect(x: 2820, y: 870, width: 100, height: 110),
                CGRect(x: 2040, y: 2390, width: 700, height: 150)]
        case (5116, 2422):
            // Black Post button edge, Grok illustration, main feed avatar.
            protected = [CGRect(x: 1330, y: 1460, width: 110, height: 35),
                CGRect(x: 2040, y: 1430, width: 180, height: 220),
                CGRect(x: 1890, y: 385, width: 35, height: 35)]
        case (2404, 2098):
            // Chat avatar, blank composer and green bubble edge.
            protected = [CGRect(x: 2290, y: 222, width: 45, height: 50),
                CGRect(x: 700, y: 1750, width: 900, height: 220),
                CGRect(x: 2200, y: 222, width: 30, height: 80)]
        default: protected = []
        }
        var changedProtectedRows = 0
        if !protected.isEmpty {
            func rgba(_ image: CGImage) -> Data {
                var data = Data(count: image.width * image.height * 4)
                data.withUnsafeMutableBytes { bytes in
                    let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                return data
            }
            let originalBytes = rgba(pixels), outputBytes = rgba(cgOutput)
            originalBytes.withUnsafeBytes { original in
                outputBytes.withUnsafeBytes { output in
                    for region in protected {
                        for y in Int(region.minY)..<Int(region.maxY) {
                            let offset = (y * pixels.width + Int(region.minX)) * 4
                            if memcmp(original.baseAddress! + offset, output.baseAddress! + offset, Int(region.width) * 4) != 0 {
                                changedProtectedRows += 1
                            }
                        }
                    }
                }
            }
            print("Protection patch changed rows: \(changedProtectedRows)")
        }
        let rows = zip(paragraphs, items).map { paragraph, item in
            String(format: "font=%.1f box=(%.1f,%.1f,%.1f,%.1f) textHeight=%.1f\n%@\n%@\n", item.fontSize,
                item.sourceRect.minX, item.sourceRect.minY, item.sourceRect.width, item.sourceRect.height,
                item.textContentHeight, paragraph.original, paragraph.translation) + "viewport=\(item.rect)\n"
        }
        let timings = String(format: "OCR %.2fs, model preparation + batch translation %.2fs, export render %.2fs", recognized - start, translated - recognized, rendered - translated)
        try (timings + "\nProtection patch changed rows: \(changedProtectedRows)\n" + diagnostics + "\nBlank plate text:\n" + blank.map(\.text).joined(separator: "\n") + "\n\n" + rows.joined(separator: "\n")).write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(timings)
        print(directory.appendingPathComponent("translated.png").path)
        if args.last == "--strict", changedProtectedRows > 0 || !missingOCR.isEmpty || !blank.isEmpty || items.contains(where: { $0.rect.isEmpty }) {
            fputs("FAIL: OCR, visibility or protected pixel checks; artifacts retained for inspection\n", stderr)
            exit(1)
        }
    }
}
