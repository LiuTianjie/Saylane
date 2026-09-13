import AppKit
import CoreImage

enum ScreenPinRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Draw translations on the original pixels. Long lines grow downward;
    /// later plates have already been pushed so they do not overlap.
    /// Plate fill is a backdrop blur of the original, not a sampled solid.
    static func composite(
        image: NSImage,
        items: [ScreenLaidOutBlock],
        canvasSize: CGSize,
        overlayEnabled: Bool
    ) -> NSImage {
        guard overlayEnabled, !items.isEmpty,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              canvasSize.width > 0, canvasSize.height > 0 else { return image }
        let sourceSize = image.size
        let scale = sourceSize.width > 0 ? CGFloat(cgImage.width) / sourceSize.width : 1
        let outputWidth = max(1, Int((canvasSize.width * scale).rounded()))
        let outputHeight = max(1, Int((canvasSize.height * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        context.interpolationQuality = .none
        let sourcePixelHeight = CGFloat(cgImage.height)
        let sourcePixelWidth = CGFloat(cgImage.width)
        let extra = CGFloat(outputHeight) - sourcePixelHeight
        let sourceRect = CGRect(x: 0, y: extra, width: sourcePixelWidth, height: sourcePixelHeight)
        context.draw(cgImage, in: sourceRect)
        context.interpolationQuality = .default
        context.textMatrix = .identity
        let canvasHeight = CGFloat(outputHeight)
        let prepared = finishItems(items, image: cgImage, canvasSize: canvasSize)
        let blurred = backdrop(cgImage, radius: blurRadius(prepared, scale: scale))
        for item in prepared where !item.text.isEmpty {
            frost(
                coverRect(item, scale: scale, outputHeight: canvasHeight),
                in: context,
                blurred: blurred,
                sourceRect: sourceRect,
                veil: Self.veil,
                scale: scale
            )
        }
        for item in prepared where !item.text.isEmpty {
            drawPlate(
                item,
                in: context,
                scale: scale,
                outputHeight: canvasHeight,
                blurred: blurred,
                sourceRect: sourceRect
            )
        }
        guard let output = context.makeImage() else { return image }
        return NSImage(cgImage: output, size: canvasSize)
    }

    static func attributes(
        fontSize: CGFloat,
        heading: Bool,
        color: NSColor,
        centered: Bool,
        linePitch: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        if linePitch > fontSize * 1.4 {
            paragraph.minimumLineHeight = linePitch
            paragraph.maximumLineHeight = linePitch
        } else if linePitch > 0 {
            paragraph.maximumLineHeight = linePitch
        }
        return [
            .font: ScreenTranslate.readingFont(size: max(5, fontSize), heading: heading),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private static func finishItems(
        _ items: [ScreenLaidOutBlock],
        image: CGImage,
        canvasSize: CGSize
    ) -> [ScreenLaidOutBlock] {
        guard canvasSize.width > 0, canvasSize.height > 0, !items.isEmpty else { return items }
        let width = image.width
        let height = image.height
        let count = width * height * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { bytes.deallocate() }
        bytes.initialize(repeating: 0, count: count)
        guard let sampler = CGContext(
            data: bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return items }
        sampler.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func pixel(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
            let i = (min(max(0, y), height - 1) * width + min(max(0, x), width - 1)) * 4
            return (CGFloat(bytes[i]) / 255, CGFloat(bytes[i + 1]) / 255, CGFloat(bytes[i + 2]) / 255)
        }
        func pixelBox(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX / canvasSize.width * CGFloat(width),
                y: (1 - rect.maxY / canvasSize.height) * CGFloat(height),
                width: rect.width / canvasSize.width * CGFloat(width),
                height: rect.height / canvasSize.height * CGFloat(height)
            )
        }
        return items.map { item in
            var next = item
            let sample = item.sourceRect.width > 1 ? item.sourceRect : item.rect
            let box = pixelBox(sample)
            let paper = average(pixel: pixel, box: box, imageWidth: width, imageHeight: height)
            next.foreground = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
            next.centered = sampleCentered(
                pixel: pixel,
                box: box,
                imageWidth: width,
                imageHeight: height,
                paperLuma: luma(paper)
            )
            return next
        }
    }

    private static func blurRadius(_ items: [ScreenLaidOutBlock], scale: CGFloat) -> CGFloat {
        let heights = items.map(\.rect.height).filter { $0 > 0 }.sorted()
        let median = heights.isEmpty ? 16 : heights[heights.count / 2]
        return min(36, max(12, median * 0.55 * scale))
    }

    private static func backdrop(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: ci.extent) else { return nil }
        return ciContext.createCGImage(output, from: ci.extent)
    }

    private static func pixelRect(_ rect: CGRect, scale: CGFloat, outputHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: outputHeight - rect.maxY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private static func coverRect(
        _ item: ScreenLaidOutBlock,
        scale: CGFloat,
        outputHeight: CGFloat
    ) -> CGRect {
        let source = item.sourceRect.width > 1 ? item.sourceRect : item.rect
        let padX = max(3 * scale, source.height * 0.16 * scale)
        let padY = max(1.5 * scale, source.height * 0.18 * scale)
        return pixelRect(source, scale: scale, outputHeight: outputHeight).insetBy(dx: -padX, dy: -padY)
    }

    private static let veil = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.42)

    private static func frost(
        _ rect: CGRect,
        in context: CGContext,
        blurred: CGImage?,
        sourceRect: CGRect,
        veil: NSColor,
        scale: CGFloat
    ) {
        guard rect.width > 2, rect.height > 2 else { return }
        let radius = min(5 * scale, rect.height / 2.4)
        context.saveGState()
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.clip()
        if let blurred {
            context.interpolationQuality = .high
            context.draw(blurred, in: sourceRect)
        }
        context.setFillColor(veil.cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    private static func drawPlate(
        _ item: ScreenLaidOutBlock,
        in context: CGContext,
        scale: CGFloat,
        outputHeight: CGFloat,
        blurred: CGImage?,
        sourceRect: CGRect
    ) {
        let plate = pixelRect(item.rect, scale: scale, outputHeight: outputHeight)
        guard plate.width > 2, plate.height > 2 else { return }
        frost(
            plate,
            in: context,
            blurred: blurred,
            sourceRect: sourceRect,
            veil: Self.veil,
            scale: scale
        )
        context.saveGState()
        let radius = min(5 * scale, plate.height / 2.4)
        context.addPath(CGPath(
            roundedRect: plate,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.clip()
        let fontSize = item.fontSize * scale
        let insetX = min(max(2 * scale, fontSize * 0.08), max(1, plate.width * 0.06))
        var textBox = plate.insetBy(dx: insetX, dy: 0)
        if plate.height >= fontSize + 4 * scale {
            let insetY = min(max(1 * scale, fontSize * 0.06), plate.height * 0.10)
            textBox = plate.insetBy(dx: insetX, dy: insetY)
        }
        let innerH = max(1, textBox.height)
        let fittedFont = min(
            fontSize,
            ScreenTranslate.fontSize(lineHeight: innerH / scale, heading: item.isHeading) * scale
        )
        let fittedPitch = min(innerH, max(fittedFont, item.linePitch * scale))
        drawText(
            item.text,
            in: textBox,
            context: context,
            fontSize: fittedFont,
            heading: item.isHeading,
            color: item.foreground.usingColorSpace(.sRGB) ?? item.foreground,
            centered: item.centered,
            linePitch: fittedPitch
        )
        context.restoreGState()
    }

    private static func drawText(
        _ text: String,
        in box: CGRect,
        context: CGContext,
        fontSize: CGFloat,
        heading: Bool,
        color: NSColor,
        centered: Bool,
        linePitch: CGFloat = 0
    ) {
        guard box.width > 1, box.height > 1 else { return }
        let attrs = attributes(
            fontSize: fontSize,
            heading: heading,
            color: color,
            centered: centered,
            linePitch: min(linePitch, box.height)
        )
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        (text as NSString).draw(
            with: box,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func average(
        pixel: (Int, Int) -> (CGFloat, CGFloat, CGFloat),
        box: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> (CGFloat, CGFloat, CGFloat) {
        let minX = max(0, Int(floor(box.minX)))
        let maxX = min(imageWidth - 1, Int(ceil(box.maxX)))
        let minY = max(0, Int(floor(box.minY)))
        let maxY = min(imageHeight - 1, Int(ceil(box.maxY)))
        guard maxX > minX, maxY > minY else { return (1, 1, 1) }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var n: CGFloat = 0
        let xStep = max(1, (maxX - minX) / 12)
        let yStep = max(1, (maxY - minY) / 8)
        for y in stride(from: minY, through: maxY, by: yStep) {
            for x in stride(from: minX, through: maxX, by: xStep) {
                let c = pixel(x, y)
                r += c.0
                g += c.1
                b += c.2
                n += 1
            }
        }
        guard n > 0 else { return (1, 1, 1) }
        return (r / n, g / n, b / n)
    }

    private static func sampleCentered(
        pixel: (Int, Int) -> (CGFloat, CGFloat, CGFloat),
        box: CGRect,
        imageWidth: Int,
        imageHeight: Int,
        paperLuma: CGFloat
    ) -> Bool {
        let minX = max(0, Int(floor(box.minX)))
        let maxX = min(imageWidth - 1, Int(ceil(box.maxX)))
        let minY = max(0, Int(floor(box.minY)))
        let maxY = min(imageHeight - 1, Int(ceil(box.maxY)))
        guard maxX > minX + 1, maxY > minY + 1 else { return false }
        var inkMinX = maxX
        var inkMaxX = minX
        var sawInk = false
        let step = max(1, min(maxX - minX, maxY - minY) / 16)
        for y in stride(from: minY, through: maxY, by: step) {
            for x in stride(from: minX, through: maxX, by: step) {
                if abs(luma(pixel(x, y)) - paperLuma) < 0.22 { continue }
                sawInk = true
                inkMinX = min(inkMinX, x)
                inkMaxX = max(inkMaxX, x)
            }
        }
        let width = CGFloat(max(1, maxX - minX))
        return sawInk
            && CGFloat(inkMinX - minX) > width * 0.18
            && CGFloat(maxX - inkMaxX) > width * 0.16
    }

    private static func luma(_ color: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        0.2126 * color.0 + 0.7152 * color.1 + 0.0722 * color.2
    }
}
