import AppKit
import Foundation

@main struct ScreenPinRendererTests {
    static func main() {
        let canvas = CGSize(width: 200, height: 80)
        let image = makeImage(width: 200, height: 80) { ctx, width, height in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 28, width: 160, height: 22))
        }

        var line = ScreenOCRLine(
            text: "Hello",
            visionBox: CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.28)
        )
        line.translation = "你好"
        let items = ScreenTranslate.layoutPlates([line], canvasSize: canvas)
        precondition(items.count == 1)

        let backdrop = ScreenPinRenderer.blurredBackdrop(
            image: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!,
            items: items,
            canvasSize: canvas
        )
        precondition(backdrop?.width == 200 && backdrop?.height == 80, "Live blur backdrop keeps source dimensions")

        let original = ScreenPinRenderer.composite(
            image: image, items: items, canvasSize: canvas, overlayEnabled: false
        )
        let translated = ScreenPinRenderer.composite(
            image: image, items: items, canvasSize: canvas, overlayEnabled: true
        )
        precondition(original.tiffRepresentation != translated.tiffRepresentation, "Overlay must change the bitmap")
        precondition(translated.size.width == canvas.width)

        let pixels = Pixels(image: translated)
        precondition(pixels.luma(2, 2) > 0.9, "Corner pixels must stay original paper")
        precondition(pixels.luma(pixels.width - 3, pixels.height - 3) > 0.9, "Opposite corner must stay original paper")

        let plate = items[0].rect
        let insideX = Int(plate.minX + plate.width / 2)
        let insideY = Int(plate.midY)
        let insideLuma = pixels.luma(insideX, pixels.height - 1 - insideY)
        precondition(insideLuma > 0.25, "Frosted plate must cover the original black glyphs")
        let edgeLuma = pixels.luma(Int(plate.minX + 3), pixels.height - 1 - insideY)
        precondition(abs(edgeLuma - insideLuma) > 0.01, "Backdrop retains source variation instead of becoming a flat sheet")

        var tight = ScreenOCRLine(
            text: "A full window chat line",
            visionBox: CGRect(x: 0.40, y: 0.50, width: 0.45, height: 0.022)
        )
        tight.translation = "整窗里这一行也必须看得见字"
        let tightCanvas = CGSize(width: 1000, height: 800)
        let tightItems = ScreenTranslate.layoutPlates([tight], canvasSize: tightCanvas)
        precondition(tightItems.count == 1)
        let tightPage = makeImage(width: 1000, height: 800) { ctx, width, height in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let tightRendered = ScreenPinRenderer.composite(
            image: tightPage, items: tightItems, canvasSize: tightCanvas, overlayEnabled: true
        )
        let tightPixels = Pixels(image: tightRendered)
        var darkGlyphs = 0
        for y in 0..<tightPixels.height {
            for x in stride(from: 0, to: tightPixels.width, by: 2) {
                if tightPixels.luma(x, y) < 0.35 { darkGlyphs += 1 }
            }
        }
        precondition(darkGlyphs > 20, "A tight full-window line box must still paint glyphs, not empty frost")

        var title = ScreenOCRLine(text: "Title", visionBox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.08))
        title.translation = "标题"
        var body = ScreenOCRLine(text: "Body text that is longer", visionBox: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.035))
        body.translation = "更长的正文"
        let sized = ScreenTranslate.layoutPlates([title, body], canvasSize: CGSize(width: 1000, height: 800))
        precondition(sized[0].fontSize > sized[1].fontSize, "Heading keeps its own larger size")

        let growing = ScreenTranslate.expandAndStack([
            ScreenLaidOutBlock(text: String(repeating: "完整译文保持字号。", count: 30),
                rect: CGRect(x: 20, y: 10, width: 160, height: 20),
                fontSize: 18, linePitch: 24, isHeading: false)
        ])
        let marker = makeImage(width: 400, height: 160) { ctx, width, height in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 180, y: 20, width: 20, height: 20))
        }
        marker.size = canvas // Retina: two pixels per point.
        let exported = ScreenPinRenderer.composite(image: marker, items: growing, canvasSize: canvas, overlayEnabled: true)
        precondition(exported.size == canvas, "Export keeps exact source geometry")
        let exportedPixels = Pixels(image: exported)
        precondition(exportedPixels.luma(190, 130) < 0.1,
            "The image below a long translation stays intact at its original position")
        precondition(exportedPixels.width == 400 && exportedPixels.height == 160, "Copy keeps Retina scale")
        let dark = makeImage(width: 640, height: 360) { ctx, width, height in
            ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 480, y: 30, width: 120, height: 80))
        }
        let darkBlocks = ScreenTranslate.expandAndStack([20, 46, 72].map { y in
            ScreenLaidOutBlock(text: String(repeating: "深色背景的完整长译文", count: 12),
                rect: CGRect(x: 20, y: y, width: 180, height: 20), fontSize: 16, isHeading: false)
        })
        let darkPrepared = ScreenPinRenderer.prepareItems(darkBlocks,
            image: dark.cgImage(forProposedRect: nil, context: nil, hints: nil)!, canvasSize: dark.size)
        precondition(darkPrepared.allSatisfy { $0.foreground.redComponent > 0.8 })
        for i in darkPrepared.indices {
            for j in darkPrepared.indices where j > i {
                let hit = darkPrepared[i].rect.intersection(darkPrepared[j].rect)
                precondition(hit.isNull || hit.width <= 0 || hit.height <= 0)
            }
        }
        let darkOutput = Pixels(image: ScreenPinRenderer.composite(image: dark, items: darkPrepared,
            canvasSize: dark.size, overlayEnabled: true))
        let darkSource = Pixels(image: dark)
        let before = darkSource.rgb(520, 50), after = darkOutput.rgb(520, 50)
        precondition(abs(before.0 - after.0) + abs(before.1 - after.1) + abs(before.2 - after.2) < 0.01,
            "Dark-mode media remains unchanged")
        print("PASS: original pixels, stable text, unchanged source pixels and Retina export")
    }

    private static func makeImage(
        width: Int,
        height: Int,
        draw: (CGContext, Int, Int) -> Void
    ) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        draw(ctx, width, height)
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: width, height: height))
    }
}

private struct Pixels {
    let width: Int
    let height: Int
    let bytes: UnsafeMutablePointer<UInt8>

    init(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fatalError("missing cgImage")
        }
        width = cg.width
        height = cg.height
        bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        bytes.initialize(repeating: 0, count: width * height * 4)
        let ctx = CGContext(
            data: bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
        let i = (min(max(0, y), height - 1) * width + min(max(0, x), width - 1)) * 4
        return (CGFloat(bytes[i]) / 255, CGFloat(bytes[i + 1]) / 255, CGFloat(bytes[i + 2]) / 255)
    }

    func luma(_ x: Int, _ y: Int) -> CGFloat {
        let c = rgb(x, y)
        return 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    }
}
