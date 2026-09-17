import AppKit
import CoreImage
import CoreText

enum ScreenPinRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Context has a top-left origin. Native view and export use identical
    /// glyph baselines so neither can clip away the bottom half of CJK text.
    static func drawInk(_ item: ScreenLaidOutBlock, in context: CGContext, visibleRange: ClosedRange<CGFloat>? = nil) {
        let inset = ScreenTranslate.textInsets(fontSize: item.fontSize)
        let width = max(1, item.rect.width - inset.width * 2)
        let lines = ScreenTranslate.inkLines(text: item.text, fontSize: item.fontSize, width: width,
            heading: item.isHeading, linePitch: item.linePitch, color: item.foreground)
        for line in lines {
            let top = inset.height + line.baseline - line.ink.maxY
            let bottom = inset.height + line.baseline - line.ink.minY
            if let visibleRange, (top < visibleRange.lowerBound - 0.01 || bottom > visibleRange.upperBound + 0.01) { continue }
            let offset = item.centered ? CGFloat(CTLineGetPenOffsetForFlush(line.line, 0.5, Double(width))) : 0
            context.saveGState()
            context.translateBy(x: inset.width + offset, y: inset.height + line.baseline)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line.line, context)
            context.restoreGState()
        }
    }

    /// Copy the source-anchored overlay at the original pixel scale.
    static func composite(
        image: NSImage,
        items: [ScreenLaidOutBlock],
        canvasSize: CGSize,
        overlayEnabled: Bool
    ) -> NSImage {
        guard overlayEnabled, !items.isEmpty,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              canvasSize.width > 0, canvasSize.height > 0 else { return image }
        let canvasSize = CGSize(width: canvasSize.width,
            height: ScreenTranslate.contentHeight(items: items, canvasHeight: image.size.height))
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
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        context.interpolationQuality = .default
        context.textMatrix = .identity
        let canvasHeight = CGFloat(outputHeight)
        let prepared = finishItems(items, image: cgImage, canvasSize: image.size)
        let blurred = backdrop(cgImage, radius: blurRadius(prepared, scale: scale))
        for item in prepared where !item.text.isEmpty {
            drawPlate(
                item,
                in: context,
                scale: scale,
                outputHeight: canvasHeight,
                blurred: blurred
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
        let font = ScreenTranslate.readingFont(size: max(5, fontSize), heading: heading)
        let pitch = max(linePitch, ceil(font.ascender - font.descender + font.leading))
        paragraph.minimumLineHeight = pitch
        paragraph.maximumLineHeight = pitch
        return [
            .font: ScreenTranslate.readingFont(size: max(5, fontSize), heading: heading),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    /// Create the fixed blurred backdrop used by live block views. The bitmap
    /// renderer computes this per composite; live views compute it once and
    /// crop the same bitmap for every progressive block.
    static func blurredBackdrop(
        image: CGImage,
        items: [ScreenLaidOutBlock],
        canvasSize: CGSize
    ) -> CGImage? {
        guard canvasSize.width > 0, !items.isEmpty else { return nil }
        let scale = CGFloat(image.width) / canvasSize.width
        return backdrop(image, radius: blurRadius(items, scale: scale))
    }

    /// Sample the source paper and alignment for live block views.
    static func prepareItems(
        _ items: [ScreenLaidOutBlock],
        image: CGImage,
        canvasSize: CGSize
    ) -> [ScreenLaidOutBlock] {
        finishItems(items, image: image, canvasSize: canvasSize)
    }

    private static func finishItems(
        _ items: [ScreenLaidOutBlock],
        image: CGImage,
        canvasSize: CGSize
    ) -> [ScreenLaidOutBlock] {
        guard canvasSize.width > 0, canvasSize.height > 0, !items.isEmpty else { return items }
        let sampleScale = min(1, 1024 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * sampleScale))
        let height = max(1, Int(CGFloat(image.height) * sampleScale))
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
                y: rect.minY / canvasSize.height * CGFloat(height),
                width: rect.width / canvasSize.width * CGFloat(width),
                height: rect.height / canvasSize.height * CGFloat(height)
            )
        }
        // A downsampled edge can smear a glyph into an otherwise empty gutter.
        // Verify only the tiny missing strip at native resolution before giving
        // the first line its full ink height; never infer that space is empty.
        func uniformNativeStrip(_ rect: CGRect, paper: (CGFloat, CGFloat, CGFloat)) -> Bool {
            let sx = CGFloat(image.width) / canvasSize.width, sy = CGFloat(image.height) / canvasSize.height
            let crop = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).integral
            guard crop.width > 0, crop.height > 0, crop.minX >= 0, crop.minY >= 0,
                crop.maxX <= CGFloat(image.width), crop.maxY <= CGFloat(image.height),
                let piece = image.cropping(to: crop) else { return false }
            let w = piece.width, h = piece.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            return data.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
                let bytes = raw.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    let delta = abs(CGFloat(bytes[i]) / 255 - paper.0)
                        + abs(CGFloat(bytes[i + 1]) / 255 - paper.1) + abs(CGFloat(bytes[i + 2]) / 255 - paper.2)
                    if delta > 0.18 { return false }
                }
                return true
            }
        }
        let styled = items.map { item in
            if item.isFinalLayout { return item }
            var next = item
            let sample = item.sourceRect.width > 1 ? item.sourceRect : item.rect
            let box = pixelBox(sample)
            let paper = average(pixel: pixel, box: box, imageWidth: width, imageHeight: height)
            next.background = NSColor(
                srgbRed: paper.0,
                green: paper.1,
                blue: paper.2,
                alpha: 1
            )
            next.foreground = luma(paper) > 0.58
                ? NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
                : NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
            let sourceBottom = min(height - 1, max(0, Int(ceil(box.maxY))))
            let left = min(width - 1, max(0, Int(ceil(box.minX))))
            let right = min(width - 1, max(left, Int(floor(box.maxX))))
            // Never infer empty space from OCR alone: an image/button may not
            // contain recognized text. A uniform paper scan stops at its pixels.
            let edgeSamples = [pixel(left - 2, Int(box.midY)), pixel(right + 2, Int(box.midY)),
                pixel(Int(box.midX), Int(box.minY) - 2), pixel(Int(box.midX), sourceBottom + 2)]
                .sorted { luma($0) < luma($1) }
            let paperPixel = edgeSamples[edgeSamples.count / 2]
            func isInk(_ x: Int, _ y: Int) -> Bool {
                let c = pixel(x, y)
                return abs(c.0 - paperPixel.0) + abs(c.1 - paperPixel.1) + abs(c.2 - paperPixel.2) > 0.06
            }
            let sourceTop = max(0, Int(floor(box.minY)))
            var extendedRight = right
            let rightLimit = min(width - 1, right + max(0, Int(box.height * 6)))
            if rightLimit > right {
                for x in (right + 1)...rightLimit {
                    if (sourceTop...sourceBottom).contains(where: { isInk(x, $0) }) { break }
                    extendedRight = x
                }
            }
            let safeRight = max(right, extendedRight - 2)
            var top = sourceTop
            let topLimit = max(0, sourceTop - max(0, Int(box.height)))
            if sourceTop > topLimit {
                for y in stride(from: sourceTop - 1, through: topLimit, by: -1) {
                    if (left...safeRight).contains(where: { isInk($0, y) }) { break }
                    top = y
                }
            }
            var bottom = sourceBottom
            let bottomLimit = min(height - 1, sourceBottom + max(0, Int(box.height * 3)))
            if bottomLimit > sourceBottom {
                for y in (sourceBottom + 1)...bottomLimit {
                    if (left...safeRight).contains(where: { isInk($0, y) }) { break }
                    bottom = y
                }
            }
            let up = max(0, CGFloat(sourceTop - top - 1) / CGFloat(height) * canvasSize.height)
            let down = max(0, CGFloat(bottom - sourceBottom - 1) / CGFloat(height) * canvasSize.height)
            let extraWidth = max(0, CGFloat(safeRight - right) / CGFloat(width) * canvasSize.width)
            let available = CGRect(x: sample.minX, y: sample.minY - up,
                width: sample.width + (next.preservesColumnWidth ? 0 : extraWidth), height: sample.height + up + down)
            let bounded = ScreenTranslate.boundedViewport(source: sample, proposed: available,
                neighbors: items.map { $0.sourceRect.width > 1 ? $0.sourceRect : $0.rect })
            next = ScreenTranslate.fitViewport(next, available: bounded)
            let inset = ScreenTranslate.textInsets(fontSize: next.fontSize)
            if let first = ScreenTranslate.inkLines(text: next.text, fontSize: next.fontSize,
                width: max(1, next.rect.width - inset.width * 2), heading: next.isHeading, linePitch: next.linePitch).first {
                let required = ceil(first.baseline - first.ink.minY + inset.height * 2)
                let missing = required - next.rect.height
                if missing > 0, missing < sample.height * 0.75 {
                    let strip = CGRect(x: next.rect.minX, y: next.rect.maxY, width: next.rect.width, height: missing)
                    if uniformNativeStrip(strip, paper: paperPixel) {
                        let expanded = bounded.union(strip)
                        let safe = ScreenTranslate.boundedViewport(source: sample, proposed: expanded,
                            neighbors: items.map(\.sourceRect))
                        next = ScreenTranslate.fitViewport(next, available: safe)
                    }
                }
            }
            next.centered = sampleCentered(
                pixel: pixel,
                box: box,
                imageWidth: width,
                imageHeight: height,
                paperLuma: luma(paper)
            )
            return next
        }
        return ScreenTranslate.nonOverlapping(styled)
    }

    private static func blurRadius(_ items: [ScreenLaidOutBlock], scale: CGFloat) -> CGFloat {
        let heights = items.map { $0.sourceRect.height > 1 ? $0.sourceRect.height : $0.rect.height }
            .filter { $0 > 0 }
            .sorted()
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

    private static func drawPlate(
        _ item: ScreenLaidOutBlock,
        in context: CGContext,
        scale: CGFloat,
        outputHeight: CGFloat,
        blurred: CGImage?
    ) {
        let plate = pixelRect(item.rect, scale: scale, outputHeight: outputHeight)
        guard plate.width > 2, plate.height > 2 else { return }
        context.saveGState()
        let radius = min(5 * scale, plate.height / 2.4)
        context.addPath(CGPath(
            roundedRect: plate,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.clip()
        let source = item.sourceRect.width > 1 ? item.sourceRect : item.rect
        let crop = CGRect(x: source.minX * scale, y: source.minY * scale,
            width: source.width * scale, height: source.height * scale).integral
        let light = luma((item.background.redComponent, item.background.greenComponent, item.background.blueComponent)) > 0.58
        if let pixels = blurred?.cropping(to: crop) {
            context.draw(pixels, in: plate)
            context.setFillColor((light ? NSColor.white.withAlphaComponent(0.42) : NSColor.black.withAlphaComponent(0.34)).cgColor)
        } else {
            context.setFillColor(item.background.cgColor)
        }
        context.fill(plate)
        context.translateBy(x: plate.minX, y: plate.maxY + item.textScrollOffset * scale)
        context.scaleBy(x: scale, y: -scale)
        drawInk(item, in: context, visibleRange: item.textScrollOffset...(item.textScrollOffset + item.rect.height))
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
            options: [.usesLineFragmentOrigin, .usesFontLeading],
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
