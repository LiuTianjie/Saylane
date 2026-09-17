import AppKit
import Vision

enum ScreenOCRService {
    static func recognize(_ image: NSImage, languages: [String]) async throws -> [ScreenOCRLine] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let initial = try await scan(cgImage, languages: languages)
        guard max(cgImage.width, cgImage.height) > 2200 || ScreenTranslate.isDocument(initial), !initial.isEmpty else {
            return ScreenTranslate.mergeFragments(initial)
        }
        // Vision downsamples a full 5K desktop enough to lose small glyphs.
        // Refine whole text columns at native resolution, with overlapping
        // vertical tiles. Never split a line at an arbitrary horizontal grid.
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let intervals = initial.map { ($0.visionBox.minX * width, $0.visionBox.maxX * width) }.sorted { $0.0 < $1.0 }
        var columns: [(CGFloat, CGFloat)] = []
        for interval in intervals {
            if let last = columns.last, interval.0 <= last.1 + 16 {
                columns[columns.count - 1].1 = max(last.1, interval.1)
            } else { columns.append(interval) }
        }
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
                            let ordinaryWords: Set<String> = ["A", "a", "I", "i", "An", "an", "In", "in", "On", "on", "To", "to", "Of", "of", "As", "as", "Is", "is", "It", "it"]
                            if prefix.count <= 2, !ordinaryWords.contains(prefix), raw[rest].count >= 3,
                               let suffix = try? candidate.boundingBox(for: rest) {
                                text = String(raw[rest])
                                box = suffix.boundingBox
                            }
                        }
                        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                        guard text.count > 2, letters > 1 else { return nil }
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
}
