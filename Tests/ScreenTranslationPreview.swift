import AppKit
import Translation

/// Real OCR and local translation; no stub text or external polish service.
@main struct ScreenTranslationPreview {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, let loaded = NSImage(contentsOfFile: args[0]),
            let pixels = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fatalError("usage: screen-translation-preview source.png output-directory")
        }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = NSImage(cgImage: pixels, size: CGSize(width: pixels.width / 2, height: pixels.height / 2))
        let start = CFAbsoluteTimeGetCurrent()
        let lines = try await ScreenOCRService.recognize(image, languages: ["en-US", "en", "zh-Hans"])
        let recognized = CFAbsoluteTimeGetCurrent()
        var paragraphs = ScreenTranslate.groupParagraphs(from: lines)
        let engine = TranslationEngine()
        try await engine.prepareInstalled(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
        guard engine.isReady else { fatalError("Local English/Chinese translation model is not installed") }
        print("Recognized \(lines.count) lines / \(paragraphs.count) paragraphs; translating...")
        fflush(stdout)
        let translations = try await engine.translateBatch(paragraphs.map(\.original))
        for index in paragraphs.indices { paragraphs[index].translation = translations[index] }
        let translated = CFAbsoluteTimeGetCurrent()
        let items = ScreenTranslate.layoutPlates(paragraphs, canvasSize: image.size)
        let output = ScreenPinRenderer.composite(image: image, items: items, canvasSize: image.size, overlayEnabled: true)
        let rendered = CFAbsoluteTimeGetCurrent()
        let cgOutput = output.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        try NSBitmapImageRep(cgImage: cgOutput).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("translated.png"))
        if pixels.width == 5120 && pixels.height == 2578 {
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
            // Areas in the supplied fixture: left side of the black Post
            // button, avatar inside the link card, and the large post image.
            let protected = [CGRect(x: 1330, y: 1465, width: 120, height: 40),
                CGRect(x: 2820, y: 870, width: 100, height: 110),
                CGRect(x: 2040, y: 2390, width: 700, height: 150)]
            originalBytes.withUnsafeBytes { original in
                outputBytes.withUnsafeBytes { output in
                    for region in protected {
                        for y in Int(region.minY)..<Int(region.maxY) {
                            let offset = (y * pixels.width + Int(region.minX)) * 4
                            precondition(memcmp(original.baseAddress! + offset, output.baseAddress! + offset, Int(region.width) * 4) == 0,
                                "Buttons and images must remain pixel-identical")
                        }
                    }
                }
            }
            print("PASS: black button, card avatar, and post image remain pixel-identical")
        }
        let rows = zip(paragraphs, items).map { paragraph, item in
            String(format: "font=%.1f box=(%.1f,%.1f,%.1f,%.1f) textHeight=%.1f\n%@\n%@\n", item.fontSize,
                item.sourceRect.minX, item.sourceRect.minY, item.sourceRect.width, item.sourceRect.height,
                item.textContentHeight, paragraph.original, paragraph.translation)
        }
        let timings = String(format: "OCR %.2fs, model preparation + batch translation %.2fs, export render %.2fs", recognized - start, translated - recognized, rendered - translated)
        try (timings + "\n\n" + rows.joined(separator: "\n")).write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(timings)
        print(directory.appendingPathComponent("translated.png").path)
    }
}
