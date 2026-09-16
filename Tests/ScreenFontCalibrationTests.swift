import AppKit
import Vision

@main struct ScreenFontCalibrationTests {
    static func main() async throws {
        let width = 1800, height = 1100
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let samples: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("Home", 24, 50, 950), ("Explore", 24, 50, 850), ("Following", 24, 50, 750),
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
        let paragraphs = ScreenTranslate.groupParagraphs(from: lines)
        let fonts = ScreenTranslate.paragraphFonts(paragraphs, canvasSize: source.size)
        for (index, paragraph) in paragraphs.enumerated() {
            guard let sample = samples.min(by: { abs($0.2 / CGFloat(width) - paragraph.visionBox.minX) + abs(($0.3 + $0.1) / CGFloat(height) - paragraph.visionBox.midY) < abs($1.2 / CGFloat(width) - paragraph.visionBox.minX) + abs(($1.3 + $1.1) / CGFloat(height) - paragraph.visionBox.midY) }) else { continue }
            print("\(paragraph.original): expected \(sample.1), estimated \(fonts[index])")
            fflush(stdout)
            precondition(abs(fonts[index] - sample.1) / sample.1 < 0.22, "Font estimate must match rendered source size")
        }
        let chineseLines = try await ScreenOCRService.recognize(source, languages: ["zh-Hans", "en-US"])
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
