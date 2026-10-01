import AppKit
import Vision

@main struct ScreenFontCalibrationTests {
    static func main() async throws {
        // OCR admission is intentionally broader than translation replacement:
        // short controls and numeric values must survive recognition even when a
        // later translation policy keeps numeric values as source pixels.
        for text in ["设置", "OK", "AI"] {
            precondition(ScreenOCRService.shouldKeep(text, confidence: 0.9), "Short UI label was discarded: \(text)")
        }
        for text in ["13", "2026", "12:30", "3.14", "50%", "2026年9月30日"] {
            precondition(ScreenOCRService.shouldKeep(text, confidence: 0.9), "Numeric OCR value was discarded: \(text)")
        }
        precondition(!ScreenOCRService.shouldKeep("13", confidence: 0.2), "Low-confidence icon-like digits should stay filtered")
        precondition(!ScreenOCRService.shouldKeep("Q", confidence: 0.99), "A lone ASCII glyph is still too ambiguous")
        for word in ["AI", "Go", "No", "OK"] {
            precondition(!ScreenOCRService.isLikelyIconPrefix(word), "A real short word was stripped as an icon: \(word)")
        }
        for glyph in ["Q", "8", "•"] {
            precondition(ScreenOCRService.isLikelyIconPrefix(glyph), "Icon-like prefix was not recognized: \(glyph)")
        }
        let blankColumns = ScreenOCRService.refinementColumns(width: 5_120, initial: [])
        precondition(blankColumns.count == 1 && blankColumns[0].0 == 0 && blankColumns[0].1 == 5_120,
                     "A large image with an empty broad OCR pass still needs one full-width refinement column")
        let broadLines = [
            ScreenOCRLine(text: "left one", visionBox: CGRect(x: 0.10, y: 0.8, width: 0.20, height: 0.03)),
            ScreenOCRLine(text: "left two", visionBox: CGRect(x: 0.302, y: 0.7, width: 0.18, height: 0.03)),
            ScreenOCRLine(text: "right", visionBox: CGRect(x: 0.72, y: 0.7, width: 0.18, height: 0.03)),
        ]
        let mergedColumns = ScreenOCRService.refinementColumns(width: 2_000, initial: broadLines)
        precondition(mergedColumns.count == 2,
                     "Nearby detections should share a refinement column without joining a distant column")
        precondition(abs(mergedColumns[0].0 - 200) < 0.01 && abs(mergedColumns[0].1 - 964) < 0.01)
        precondition(abs(mergedColumns[1].0 - 1_440) < 0.01 && abs(mergedColumns[1].1 - 1_800) < 0.01)

        let width = 1800, height = 1100
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let samples: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("Home", 24, 50, 950), ("Explore", 24, 50, 850), ("Following", 24, 50, 750),
            ("设置", 24, 50, 650), ("OK", 24, 50, 550), ("AI", 24, 50, 450), ("13", 24, 50, 350),
            ("same lowercase size", 18, 430, 950), ("Quick Typography", 18, 430, 850),
            ("BODY TEXT WITH CAPS", 18, 430, 750), ("同样大小的中文正文", 18, 430, 650),
            ("Small caption", 12, 1200, 950), ("A smaller label", 12, 1200, 850)
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (text, size, x, y) in samples {
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size * 2), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()!
        let source = NSImage(cgImage: image, size: CGSize(width: width / 2, height: height / 2))
        let lines = try await ScreenOCRService.recognize(source, languages: ["en-US", "zh-Hans"])
        for text in ["OK", "13"] {
            precondition(lines.contains(where: { $0.text == text }), "Real OCR dropped short fixture: \(text); got \(lines.map(\.text))")
        }
        precondition(lines.contains(where: { $0.text == "AI" || $0.text == "Al" }),
                     "Real OCR dropped the two-letter fixture; got \(lines.map(\.text))")
        let paragraphs = ScreenTranslate.groupParagraphs(from: lines)
        let fonts = ScreenTranslate.paragraphFonts(paragraphs, canvasSize: source.size)
        for (index, paragraph) in paragraphs.enumerated() {
            guard let sample = samples.min(by: { abs($0.2 / CGFloat(width) - paragraph.visionBox.minX) + abs(($0.3 + $0.1) / CGFloat(height) - paragraph.visionBox.midY) < abs($1.2 / CGFloat(width) - paragraph.visionBox.minX) + abs(($1.3 + $1.1) / CGFloat(height) - paragraph.visionBox.midY) }) else { continue }
            print("\(paragraph.original): expected \(sample.1), estimated \(fonts[index])")
            fflush(stdout)
            precondition(abs(fonts[index] - sample.1) / sample.1 < 0.22, "Font estimate must match rendered source size")
        }
        let chineseLines = try await ScreenOCRService.recognize(source, languages: ["zh-Hans", "en-US"])
        precondition(chineseLines.contains(where: { $0.text == "设置" }),
                     "Chinese-priority OCR dropped a two-character control; got \(chineseLines.map(\.text))")
        guard let chinese = chineseLines.first(where: { $0.text.contains("中文") }) else { fatalError("Chinese source OCR must be exercised") }
        let chineseParagraph = ScreenTranslate.groupParagraphs(from: [chinese])
        let chineseFont = ScreenTranslate.paragraphFonts(chineseParagraph, canvasSize: source.size)[0]
        print("Chinese: expected 18, estimated \(chineseFont)")
        precondition(abs(chineseFont - 18) / 18 < 0.22)
        precondition(paragraphs.count >= 8, "The real OCR fixture must recognize every style group")
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: "build/tests/font-calibration-source.png"))
        print("PASS: real OCR source-size calibration across navigation, body, Chinese, and captions")
    }
}
