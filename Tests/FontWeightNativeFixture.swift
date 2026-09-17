import AppKit
import CoreText

// Independent, native renderer holdout. These pixels are never training data.
@main struct FontWeightNativeFixture {
    static func main() throws {
        let width = 1600, height = 1000
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.white.setFill(); CGRect(x: 0,y: 0,width: width,height: height).fill()
        var rows: [String] = [], labels: [[String: Any]] = []
        let texts = ["6 months of ChatGPT Pro, which includes Codex", "Maintainers review requests and maintain releases.",
            "这些正文大小相同，粗细应该独立判断。", "A short sentence at a different zoom level.", "0123456789 Source symbols and punctuation."]
        for row in 0..<10 {
            let size = CGFloat([14,18,22,26,30][row % 5])
            for column in 0..<2 {
                let text = texts[row % 5]
                let origin = CGPoint(x: 30 + column * 800, y: 910 - row * 95)
                let font = NSFont.systemFont(ofSize: size, weight: column == 0 ? .regular : .bold)
                let attributes: [NSAttributedString.Key: Any] = [.font:font, .foregroundColor: row < 5 ? NSColor.black : NSColor.white]
                if row >= 5 {
                    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
                    CGRect(x: column*800, y: 890-row*95, width:800,height:85).fill()
                }
                let value = NSAttributedString(string:text,attributes:attributes)
                let line = CTLineCreateWithAttributedString(value)
                let cg = context.cgContext
                cg.textMatrix = .identity; cg.textPosition = origin; CTLineDraw(line,cg)
                let ink = CTLineGetImageBounds(line,nil).offsetBy(dx: origin.x,dy:origin.y)
                let normalized = CGRect(x:ink.minX/CGFloat(width),y:ink.minY/CGFloat(height),width:ink.width/CGFloat(width),height:ink.height/CGFloat(height))
                rows.append("(\(normalized.minX), \(normalized.minY), \(normalized.width), \(normalized.height))\t\(text)")
                labels.append(["text":text,"bold":column == 1,"fontSize":size,"dark":row>=5])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let base = URL(fileURLWithPath:"build/font-weight/native")
        try rep.representation(using:.png,properties:[:])!.write(to:base.appendingPathExtension("png"))
        try rows.joined(separator:"\n").write(to:base.appendingPathExtension("txt"),atomically:true,encoding:.utf8)
        try JSONSerialization.data(withJSONObject:labels,options:.prettyPrinted).write(to:base.appendingPathExtension("labels.json"))
    }
}
