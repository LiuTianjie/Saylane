import CoreGraphics
import Foundation

@main struct ScreenRegionFinderTests {
    static func box(_ image: inout PixelImage, _ r: PixelRect, border: RGB?, fill: RGB?) {
        for y in r.minY..<r.maxY {
            for x in r.minX..<r.maxX {
                let edge = x == r.minX || x == r.maxX - 1 || y == r.minY || y == r.maxY - 1
                if edge, let border { image[x, y] = border } else if let fill { image[x, y] = fill }
            }
        }
    }

    static func text(_ image: inout PixelImage, x: Int, y: Int, width: Int) {
        // Glyph-like strokes: 6 px tall bars with gaps, like a line of text.
        var cx = x
        while cx + 4 <= x + width {
            for dy in 0..<10 { for dx in 0..<3 { image[cx + dx, y + dy] = RGB(r: 30, g: 30, b: 30) } }
            cx += 7
        }
    }

    static func main() {
        var image = PixelImage(width: 800, height: 600)
        let grey = RGB(r: 200, g: 200, b: 200)
        // A bordered card with a line of text.
        let card = PixelRect(minX: 100, minY: 100, maxX: 400, maxY: 160)
        box(&image, card, border: grey, fill: nil)
        text(&image, x: 120, y: 125, width: 200)
        // A tinted bubble without a border.
        let bubble = PixelRect(minX: 500, minY: 100, maxX: 700, maxY: 150)
        box(&image, bubble, border: nil, fill: RGB(r: 235, g: 240, b: 250))
        text(&image, x: 520, y: 120, width: 120)
        // Two paragraphs on the plain page, far apart.
        text(&image, x: 100, y: 300, width: 400)
        text(&image, x: 100, y: 316, width: 300)
        text(&image, x: 100, y: 450, width: 400)
        // A table row: two full-width rules and no side walls.
        for x in 450..<780 { image[x, 360] = grey; image[x, 400] = grey }
        text(&image, x: 470, y: 375, width: 100)

        let finder = ScreenRegionFinder(image, scale: 1)
        let all = image.bounds

        let onCard = finder.region(around: (x: 200, y: 130), within: all)
        precondition(onCard == PixelRect(minX: 101, minY: 101, maxX: 399, maxY: 159), "card: \(String(describing: onCard))")

        let onBubble = finder.region(around: (x: 600, y: 125), within: all)
        precondition(onBubble == bubble, "bubble: \(String(describing: onBubble))")

        // Between two lines of the first paragraph: the paragraph, not the page or the other paragraph.
        guard let paragraph = finder.region(around: (x: 200, y: 312), within: all) else { fatalError("no paragraph") }
        precondition(paragraph.minY <= 300 && paragraph.maxY >= 326 && paragraph.maxY < 440, "paragraph: \(paragraph)")
        precondition(paragraph.minX <= 100 && paragraph.maxX < 520, "paragraph: \(paragraph)")

        guard let row = finder.region(around: (x: 520, y: 380), within: all) else { fatalError("no row") }
        precondition(row.minY == 361 && row.maxY == 400 && row.minX == 450, "row: \(row)")

        // Inside a window limit the answer never leaves it.
        let window = PixelRect(minX: 90, minY: 280, maxX: 560, maxY: 500)
        if let inWindow = finder.region(around: (x: 200, y: 312), within: window) {
            precondition(inWindow.minX >= 90 && inWindow.maxX <= 560 && inWindow.minY >= 280 && inWindow.maxY <= 500)
        }

        // Points map back to AppKit coordinates on a Retina display.
        var retina = PixelImage(width: 400, height: 300)
        box(&retina, PixelRect(minX: 100, minY: 100, maxX: 300, maxY: 160), border: grey, fill: nil)
        let map = ScreenRegionMap(image: retina.cgImage()!, frame: CGRect(x: 0, y: 0, width: 200, height: 150))!
        let r = map.region(at: CGPoint(x: 100, y: 85), within: CGRect(x: 0, y: 0, width: 200, height: 150))
        precondition(r == CGRect(x: 50.5, y: 70.5, width: 99, height: 29), "retina: \(String(describing: r))")

        print("screen region finder ok")
    }
}
