import CoreGraphics
import Foundation
import Vision

/// One line as the recogniser reports it. Nothing is merged here: whether two
/// fragments on a row belong together is decided later, from the pixels between them.
struct RecognizedLine: Sendable {
    var text: String
    /// Picture pixels, top-left origin.
    var box: CGRect
    var confidence: Float
    var startsListItem: Bool
}

enum Recognizer {
    /// A picture larger than this many points in either direction is read a second time in tiles.
    static let largePicture: CGFloat = 2200

    /// `scale` is picture pixels per point: on a Retina capture the type is
    /// twice as many pixels tall and survives the recogniser's scaling down.
    static func recognize(_ image: CGImage, scale: CGFloat, languages: [String]) throws -> [RecognizedLine] {
        let initial = try scan(image, languages: languages)
        guard CGFloat(max(image.width, image.height)) / max(1, scale) > largePicture else { return initial }
        // Vision scales a large picture down and loses small type. Read every
        // column of text again at its own resolution, in tiles that overlap
        // from top to bottom. A line is never cut at an arbitrary vertical edge.
        let width = CGFloat(image.width), height = CGFloat(image.height)
        struct Tile { var crop: CGRect; var startY: CGFloat; var endY: CGFloat }
        var tiles: [Tile] = []
        let core: CGFloat = 1280
        for column in columns(width: width, initial: initial) {
            let left = max(0, floor(column.0 - 16)), right = min(width, ceil(column.1 + 16))
            for start in stride(from: CGFloat(0), to: height, by: core) {
                let end = min(height, start + core)
                let top = max(0, start - 128), bottom = min(height, end + 128)
                tiles.append(Tile(crop: CGRect(x: left, y: top, width: right - left, height: bottom - top), startY: start, endY: end))
            }
        }
        var perTile = [[RecognizedLine]](repeating: [], count: tiles.count)
        var failure: Error?
        let lock = NSLock()
        perTile.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let results = buffer
            DispatchQueue.concurrentPerform(iterations: tiles.count) { index in
                let tile = tiles[index]
                guard let crop = image.cropping(to: tile.crop) else { return }
                do {
                    results[index] = try scan(crop, languages: languages).compactMap { line in
                        var moved = line
                        moved.box = line.box.offsetBy(dx: tile.crop.minX, dy: tile.crop.minY)
                        // Each line belongs to the tile its middle lies in.
                        return moved.box.midY >= tile.startY && moved.box.midY < tile.endY ? moved : nil
                    }
                } catch {
                    lock.lock(); failure = error; lock.unlock()
                }
            }
        }
        if let failure { throw failure }
        var refined = perTile.flatMap { $0 }
        // What the first reading found and the tiles did not: a line wider than its tile, mostly.
        for line in initial {
            let matched = refined.contains { other in
                let both = line.box.intersection(other.box)
                return !both.isNull && both.height > min(line.box.height, other.box.height) * 0.4
                    && both.width > min(line.box.width, other.box.width) * 0.4
            }
            if !matched { refined.append(line) }
        }
        return refined
    }

    /// The stretches from left to right that hold text. With nothing found the whole width is one.
    static func columns(width: CGFloat, initial: [RecognizedLine]) -> [(CGFloat, CGFloat)] {
        var columns: [(CGFloat, CGFloat)] = initial.isEmpty ? [(0, width)] : []
        for interval in initial.map({ ($0.box.minX, $0.box.maxX) }).sorted(by: { $0.0 < $1.0 }) {
            if let last = columns.last, interval.0 <= last.1 + 16 {
                columns[columns.count - 1].1 = max(last.1, interval.1)
            } else {
                columns.append(interval)
            }
        }
        return columns
    }

    private static func scan(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages.filter { !$0.isEmpty }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let raw = candidate.string
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var box = observation.boundingBox
            let bullet = raw.range(of: #"^\s*[•●◦▪‣·]\s+"#, options: .regularExpression)
            // A leading icon read as a letter or a digit stays a picture.
            if let space = raw.firstIndex(of: " ") {
                let prefix = String(raw[..<space])
                let rest = raw.index(after: space)..<raw.endIndex
                if isLikelyIconPrefix(prefix) || bullet != nil, raw[rest].count >= 2,
                   let suffix = try? candidate.boundingBox(for: rest) {
                    text = String(raw[rest]).trimmingCharacters(in: .whitespaces)
                    box = suffix.boundingBox
                }
            }
            guard shouldKeep(text, confidence: candidate.confidence) else { return nil }
            return RecognizedLine(text: text, box: pixels(box), confidence: candidate.confidence, startsListItem: bullet != nil)
        }
    }

    /// Keep short labels and numbers without turning every icon-shaped glyph
    /// into text. The recogniser's confidence only decides the ambiguous cases:
    /// a single character, a bare number. Ordinary words are always kept.
    static func shouldKeep(_ text: String, confidence: Float) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !scalars.isEmpty else { return false }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        if letters.count >= 2 { return true } // "OK", "AI", "设置"
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
            // commonly the recogniser's reading of a sidebar icon.
            return !["A", "a", "I", "i"].contains(prefix)
                && (scalar.isASCII || CharacterSet.symbols.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar))
        }
        return scalars.allSatisfy { CharacterSet.decimalDigits.contains($0)
            || CharacterSet.symbols.contains($0) || CharacterSet.punctuationCharacters.contains($0) }
    }
}
