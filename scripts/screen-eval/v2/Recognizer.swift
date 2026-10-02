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
    static func recognize(_ image: CGImage, languages: [String]) throws -> [RecognizedLine] {
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
                if ScreenOCRService.isLikelyIconPrefix(prefix) || bullet != nil, raw[rest].count >= 2,
                   let suffix = try? candidate.boundingBox(for: rest) {
                    text = String(raw[rest]).trimmingCharacters(in: .whitespaces)
                    box = suffix.boundingBox
                }
            }
            guard ScreenOCRService.shouldKeep(text, confidence: candidate.confidence) else { return nil }
            return RecognizedLine(text: text, box: pixels(box), confidence: candidate.confidence, startsListItem: bullet != nil)
        }
    }
}
