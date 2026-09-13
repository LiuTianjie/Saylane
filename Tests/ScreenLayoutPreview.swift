import AppKit
import Foundation
import Vision

/// Renders per-line plates onto a captured page so we can judge size and layout.
/// Usage: screen-preview <input> <output-dir>
@main struct ScreenLayoutPreview {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            fputs("usage: screen-preview <input-image> <output-dir>\n", stderr)
            exit(2)
        }
        let input = URL(fileURLWithPath: args[0])
        let outputDir = URL(fileURLWithPath: args[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        guard let image = NSImage(contentsOf: input),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fputs("could not read \(input.path)\n", stderr)
            exit(1)
        }
        let canvas = CGSize(width: cgImage.width, height: cgImage.height)
        let source = NSImage(cgImage: cgImage, size: canvas)

        var lines = (try? await recognize(cgImage)) ?? []
        lines = ScreenTranslate.mergeFragments(lines)
        print("ocr lines: \(lines.count)")
        let medianNorm = lines.map(\.visionBox.height).sorted().dropFirst(lines.count / 2).first ?? 0.02
        var kept = 0
        var skipped = 0
        for i in lines.indices {
            if ScreenTranslate.shouldReplace(lines[i], medianHeight: medianNorm) {
                kept += 1
            } else {
                skipped += 1
            }
        }
        print("replaceable: \(kept)  left as pixels: \(skipped)")

        var identity = lines
        for i in identity.indices where ScreenTranslate.shouldReplace(identity[i], medianHeight: medianNorm) {
            identity[i].translation = identity[i].text
        }
        write(source: source, lines: identity, canvas: canvas, to: outputDir.appendingPathComponent("identity.png"))

        var stub = lines
        for i in stub.indices where ScreenTranslate.shouldReplace(stub[i], medianHeight: medianNorm) {
            stub[i].translation = stubChinese(stub[i].text)
        }
        write(source: source, lines: stub, canvas: canvas, to: outputDir.appendingPathComponent("stub-zh.png"))

        let heights = lines.map { ScreenTranslate.topLeftRect(visionBox: $0.visionBox, canvasSize: canvas).height }.sorted()
        let medianH = heights.isEmpty ? 0 : heights[heights.count / 2]
        print(String(format: "median line height: %.1f", medianH))
        for (index, line) in lines.enumerated() {
            let box = ScreenTranslate.topLeftRect(visionBox: line.visionBox, canvasSize: canvas)
            let flag = ScreenTranslate.shouldReplace(line, medianHeight: medianNorm) ? "text" : "skip"
            print(String(
                format: "%2d [%@] y=%.1f h=%.1f font=%.1f conf=%.2f  %@",
                index,
                flag,
                box.minY,
                box.height,
                ScreenTranslate.fontSize(lineHeight: box.height),
                line.confidence,
                line.text
            ))
        }
        print("wrote \(outputDir.path)")
    }

    private static func write(
        source: NSImage,
        lines: [ScreenOCRLine],
        canvas: CGSize,
        to url: URL
    ) {
        let items = ScreenTranslate.layoutPlates(lines, canvasSize: canvas)
        let output = CGSize(
            width: canvas.width,
            height: ScreenTranslate.contentHeight(items: items, canvasHeight: canvas.height)
        )
        let rendered = ScreenPinRenderer.composite(
            image: source,
            items: items,
            canvasSize: output,
            overlayEnabled: true
        )
        guard let out = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
        print("plates \(items.count) -> \(url.lastPathComponent)")
    }

    private static func stubChinese(_ english: String) -> String {
        let seed = "在这项工作中我们使用多头注意力，让模型同时关注不同位置的表示子空间。"
        let n = max(2, (english.count * 2) / 5)
        if n <= seed.count { return String(seed.prefix(n)) }
        var text = ""
        while text.count < n { text += seed }
        return String(text.prefix(n))
    }

    private static func recognize(_ cgImage: CGImage) async throws -> [ScreenOCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines: [ScreenOCRLine] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return ScreenOCRLine(
                        text: text,
                        visionBox: observation.boundingBox,
                        confidence: candidate.confidence
                    )
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US", "zh-Hans"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
