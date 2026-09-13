import AppKit
import Vision

enum ScreenOCRService {
    static func recognize(_ image: NSImage, languages: [String]) async throws -> [ScreenOCRLine] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let unsortedLines: [ScreenOCRLine] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return ScreenOCRLine(
                        text: text,
                        visionBox: observation.boundingBox,
                        confidence: candidate.confidence
                    )
                }
                continuation.resume(returning: ScreenTranslate.mergeFragments(unsortedLines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let filtered = languages.filter { !$0.isEmpty }
            if !filtered.isEmpty {
                request.recognitionLanguages = filtered
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
