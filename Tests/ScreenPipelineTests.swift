import AppKit
import CoreText

/// The pipeline on pictures drawn here, so the truth is known: what size,
/// weight and colour each line has, and what the paper under it looks like.
@main struct ScreenPipelineTests {
    struct Sample { var text: String; var size: CGFloat; var weight: NSFont.Weight; var color: NSColor; var origin: CGPoint }

    static func picture(scale: CGFloat) -> CGImage {
        let width = 760.0, height = 300.0
        let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A button: its own paper.
        context.setFillColor(NSColor(srgbRed: 0.04, green: 0.48, blue: 1, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 40, y: 40, width: 150, height: 36), cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        for sample in samples {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample.text, attributes: [
                .font: NSFont.systemFont(ofSize: sample.size, weight: sample.weight), .foregroundColor: sample.color]))
            context.textPosition = CGPoint(x: sample.origin.x, y: (sample.origin.y * scale).rounded() / scale)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }

    static let samples = [
        Sample(text: "Privacy and security settings", size: 26, weight: .bold, color: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1), origin: CGPoint(x: 40, y: 230)),
        Sample(text: "Choose which applications may read the screen while you work.", size: 14, weight: .regular,
               color: NSColor(srgbRed: 0.35, green: 0.35, blue: 0.38, alpha: 1), origin: CGPoint(x: 40, y: 190)),
        Sample(text: "Allow access", size: 14, weight: .semibold, color: .white, origin: CGPoint(x: 70, y: 53)),
    ]

    static func main() throws {
        var passed = 0
        func check(_ condition: Bool, _ what: String) { precondition(condition, what); passed += 1 }

        for scale in [1.0, 2.0] as [CGFloat] {
            let image = picture(scale: scale)
            guard let analysis = try ScreenPipeline.analyze(image, scale: scale, source: .en, target: .zhHans) else { fatalError("no analysis") }
            func block(_ word: String) -> (index: Int, block: TextBlock)? {
                analysis.blocks.enumerated().first { $0.element.original.contains(word) }.map { ($0.offset, $0.element) }
            }
            guard let title = block("Privacy"), let body = block("Choose"), let button = block("Allow") else {
                fatalError("@\(scale)x: lines not found in \(analysis.blocks.map(\.original))")
            }
            let label = "@\(Int(scale))x"
            // Size from the pixels, not from the recogniser's box.
            check(abs(title.block.style.size - 26) / 26 < 0.05, "\(label) title size \(title.block.style.size)")
            check(abs(body.block.style.size - 14) / 14 < 0.07, "\(label) body size \(body.block.style.size)")
            check(abs(button.block.style.size - 14) / 14 < 0.09, "\(label) button size \(button.block.style.size)")
            check(title.block.style.weight.rawValue >= 600 && body.block.style.weight.rawValue <= 500, "\(label) weights \(title.block.style.weight) \(body.block.style.weight)")
            check(title.block.style.color.luma < 60 && button.block.style.color.luma > 200, "\(label) colours")
            if case .flat(let paper) = button.block.background {
                check(paper.b > 200 && paper.r < 60, "\(label) the button's own paper is its background: \(paper)")
            } else { check(false, "\(label) button background \(button.block.background.name)") }
            check(title.block.translate && body.block.translate && button.block.translate, "\(label) all three are text to translate")

            // Translated in place: strokes gone, paper back, the new text where the old was.
            let composed = ScreenPipeline.compose(analysis, translations: [title.index: "隐私与安全设置", body.index: "选择哪些应用可以在你工作时读取屏幕。", button.index: "允许访问"])
            check(composed.placed.count == 3 && composed.cut == 0, "\(label) three blocks placed, none cut")
            let out = composed.pixels, before = analysis.pixels
            check(out.width == before.width && out.height == before.height, "\(label) the picture keeps its size")
            // The English title ran far to the right of where the Chinese one ends: that stretch is paper again.
            let titleRect = title.block.rect
            let farRight = (x: Int(titleRect.maxX - 6 * scale), y: Int(titleRect.midY))
            var inked = false
            for dx in -Int(8 * scale)...0 where before[farRight.x + dx, farRight.y].luma < 128 { inked = true }
            check(inked, "\(label) there was ink at the end of the English title")
            var clean = true
            for dx in -Int(8 * scale)...0 where out[farRight.x + dx, farRight.y].luma < 245 { clean = false }
            check(clean, "\(label) and it is erased")
            // The button is still blue beside its label, and nothing else in the picture moved.
            let beside = out[Int(46 * scale), Int((300 - 58) * scale)]
            check(beside.b > 200 && beside.r < 60, "\(label) the button keeps its colour: \(beside)")
            let corner = out[Int(700 * scale), Int(280 * scale)]
            check(corner.luma > 250, "\(label) untouched paper stays untouched")
            // Same type size for the translation as for the original.
            let placed = composed.placed.first { $0.index == title.index }!
            check(placed.placement.shrink == 1, "\(label) the Chinese title is set at the original size")
        }

        // Tiles for a large picture follow the columns of text.
        let lines = [RecognizedLine(text: "a", box: CGRect(x: 100, y: 0, width: 400, height: 20), confidence: 1, startsListItem: false),
                     RecognizedLine(text: "b", box: CGRect(x: 505, y: 40, width: 200, height: 20), confidence: 1, startsListItem: false),
                     RecognizedLine(text: "c", box: CGRect(x: 1500, y: 40, width: 300, height: 20), confidence: 1, startsListItem: false)]
        let columns = Recognizer.columns(width: 2560, initial: lines)
        check(columns.count == 2 && columns[0].0 == 100 && columns[0].1 == 705 && columns[1].0 == 1500, "columns \(columns)")
        check(Recognizer.columns(width: 2560, initial: []).count == 1, "nothing found: the whole width is read again")
        check(Recognizer.shouldKeep("OK", confidence: 0.3) && !Recognizer.shouldKeep("7", confidence: 0.4) && Recognizer.shouldKeep("12:30", confidence: 0.7), "what counts as text")
        check(Recognizer.isLikelyIconPrefix("Q") && !Recognizer.isLikelyIconPrefix("A") && Recognizer.isLikelyIconPrefix("8"), "icons read as letters")

        print("ScreenPipelineTests: \(passed) checks passed")
    }
}
