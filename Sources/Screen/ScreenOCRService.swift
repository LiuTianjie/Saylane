import AppKit
import Vision

enum ScreenOCRService {
    static func recognize(_ image: NSImage, languages: [String]) async throws -> [ScreenOCRLine] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let initial = try await scan(cgImage, languages: languages)
        guard max(cgImage.width, cgImage.height) > 2200 || ScreenTranslate.isDocument(initial) else {
            return ScreenTranslate.mergeFragments(initial)
        }
        // Vision downsamples a full 5K desktop enough to lose small glyphs.
        // Refine whole text columns at native resolution, with overlapping
        // vertical tiles. Never split a line at an arbitrary horizontal grid.
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let columns = refinementColumns(width: width, initial: initial)
        struct Tile {
            let crop: CGRect
            let startY: CGFloat
            let endY: CGFloat
        }
        var tiles: [Tile] = []
        let coreHeight: CGFloat = 1280
        for column in columns {
            let left = max(0, floor(column.0 - 16))
            let right = min(width, ceil(column.1 + 16))
            for start in stride(from: CGFloat(0), to: height, by: coreHeight) {
                let end = min(height, start + coreHeight)
                let top = max(0, start - 128)
                let bottom = min(height, end + 128)
                tiles.append(Tile(crop: CGRect(x: left, y: top, width: right - left, height: bottom - top), startY: start, endY: end))
            }
        }
        var refined: [ScreenOCRLine] = []
        // Four workers bound memory and CPU use; each request owns its image.
        for start in stride(from: 0, to: tiles.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(tiles[start..<min(tiles.count, start + 4)])
            let results = try await withThrowingTaskGroup(of: [ScreenOCRLine].self) { group in
                for tile in batch {
                    group.addTask {
                        guard let crop = cgImage.cropping(to: tile.crop) else { return [] }
                        let lines = try await scan(crop, languages: languages)
                        return lines.compactMap { line in
                            var result = line
                            let local = line.visionBox
                            let centerY = tile.crop.minY + (1 - local.midY) * tile.crop.height
                            guard centerY >= tile.startY, centerY < tile.endY else { return nil }
                            result.visionBox = CGRect(x: (tile.crop.minX + local.minX * tile.crop.width) / width,
                                y: (height - tile.crop.maxY + local.minY * tile.crop.height) / height,
                                width: local.width * tile.crop.width / width, height: local.height * tile.crop.height / height)
                            return result
                        }
                    }
                }
                var results: [ScreenOCRLine] = []
                for try await lines in group { results += lines }
                return results
            }
            refined += results
        }
        // Retain broad-pass detections only where refinement found no matching
        // line. This also covers an unusually wide line crossing a crop edge.
        for line in initial {
            let matched = refined.contains { other in
                let intersection = line.visionBox.intersection(other.visionBox)
                return !intersection.isNull && intersection.height > min(line.visionBox.height, other.visionBox.height) * 0.4
                    && intersection.width > min(line.visionBox.width, other.visionBox.width) * 0.4
            }
            if !matched { refined.append(line) }
        }
        return ScreenTranslate.mergeFragments(refined)
    }

    private static func scan(_ image: CGImage, languages: [String]) async throws -> [ScreenOCRLine] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error { continuation.resume(throwing: error); return }
                    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                    let lines: [ScreenOCRLine] = observations.compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        let raw = candidate.string
                        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        var box = observation.boundingBox
                        // Preserve a leading bullet/icon/number as source pixels.
                        // Vision can read a magnifier as Q or a profile icon as 8.
                        if let space = raw.firstIndex(of: " ") {
                            let prefix = String(raw[..<space])
                            let rest = raw.index(after: space)..<raw.endIndex
                            if isLikelyIconPrefix(prefix), raw[rest].count >= 3,
                               let suffix = try? candidate.boundingBox(for: rest) {
                                text = String(raw[rest])
                                box = suffix.boundingBox
                            }
                        }
                        guard shouldKeep(text, confidence: candidate.confidence) else { return nil }
                        return ScreenOCRLine(text: text, visionBox: box, confidence: candidate.confidence,
                            startsListItem: raw.range(of: #"^\s*[•●◦▪‣·]\s+"#, options: .regularExpression) != nil)
                    }
                    continuation.resume(returning: lines)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = languages.filter { !$0.isEmpty }
                do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Keep short UI labels and numeric values without turning every icon-shaped
    /// glyph into text. Vision confidence is only used for the ambiguous one-
    /// character and numeric cases; ordinary words keep the existing behavior.
    static func shouldKeep(_ text: String, confidence: VNConfidence) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !scalars.isEmpty else { return false }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        if letters.count >= 2 { return true } // “OK”, “AI”, “设置”
        if let letter = letters.first, letters.count == 1, letter.value > 0x7f { return confidence >= 0.45 }
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }
        let numericPunctuation = CharacterSet(charactersIn: ".,:%+-/年月日时分秒")
        if !digits.isEmpty,
           scalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) || numericPunctuation.contains($0) }) {
            return confidence >= 0.60
        }
        return false
    }

    static func isLikelyIconPrefix(_ prefix: String) -> Bool {
        let scalars = prefix.unicodeScalars
        guard !scalars.isEmpty else { return false }
        if scalars.count == 1 {
            let scalar = scalars[scalars.startIndex]
            // A/I are real words; a lone digit, symbol or other ASCII letter is
            // commonly Vision's reading of a sidebar icon.
            return !["A", "a", "I", "i"].contains(prefix)
                && (scalar.isASCII || CharacterSet.symbols.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar))
        }
        return scalars.allSatisfy { CharacterSet.decimalDigits.contains($0)
            || CharacterSet.symbols.contains($0) || CharacterSet.punctuationCharacters.contains($0) }
    }

    /// Native-resolution refinement columns.  An empty broad OCR result on a
    /// large image still needs a full-width pass; otherwise small text that was
    /// missed once can never be recovered.  Kept pure for regression tests.
    static func refinementColumns(width: CGFloat, initial: [ScreenOCRLine]) -> [(CGFloat, CGFloat)] {
        let intervals = initial
            .map { ($0.visionBox.minX * width, $0.visionBox.maxX * width) }
            .sorted { $0.0 < $1.0 }
        var columns: [(CGFloat, CGFloat)] = initial.isEmpty ? [(0, width)] : []
        for interval in intervals {
            if let last = columns.last, interval.0 <= last.1 + 16 {
                columns[columns.count - 1].1 = max(last.1, interval.1)
            } else {
                columns.append(interval)
            }
        }
        return columns
    }
}
