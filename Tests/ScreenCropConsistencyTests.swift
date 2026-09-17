import AppKit
import Vision

@main struct ScreenCropConsistencyTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
            let source = NSImage(contentsOfFile: CommandLine.arguments[1]),
            let pixels = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let cropped = pixels.cropping(to: CGRect(x: 1300, y: 100, width: 480, height: 1400)) else { fatalError("Expected the supplied 5120px X screenshot") }
        func measure(_ image: CGImage) async throws -> [String: CGFloat] {
            let canvas = NSImage(cgImage: image, size: CGSize(width: image.width / 2, height: image.height / 2))
            let lines = try await ScreenOCRService.recognize(canvas, languages: ["en-US", "en", "zh-Hans"])
            let paragraphs = ScreenTranslate.groupParagraphs(from: lines, canvasSize: canvas.size)
            let fonts = ScreenTranslate.paragraphFonts(paragraphs, canvasSize: canvas.size)
            return Dictionary(zip(paragraphs.map(\.original), fonts), uniquingKeysWith: { first, _ in first })
        }
        let full = try await measure(pixels)
        let tight = try await measure(cropped)
        let labels = ["Home", "Explore", "Notifications", "Follow", "Chat", "Grok", "History", "Creator Studio", "Premium", "Profile", "More"]
        var failures: [String] = []
        for label in labels {
            guard let a = full[label], let b = tight[label] else { failures.append("missing \(label): full=\(full[label] as Any), crop=\(tight[label] as Any)"); continue }
            print(String(format: "%@: full %.2f pt / tight %.2f pt", label, a, b))
            if abs(a - b) > 2 { failures.append("\(label) changed font") }
        }
        fflush(stdout)
        precondition(failures.isEmpty, failures.joined(separator: "; "))
        print("PASS: all 11 navigation labels survive both captures with font differences below 2 pt")
    }
}
