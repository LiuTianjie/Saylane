import Foundation

/// Monotonic timings and counts only. Never contains audio or dictated text.
struct SpeechSessionMetrics: Codable, Sendable {
    let sessionID: UUID
    let model: String
    var outcome = "running"
    var elapsedMS: [String: Double] = [:]
    var audioMS: Double = 0
    var hypothesisCount = 0
    var previewCount = 0
    var revisedCharacterCount = 0
    var stableCharacterCount = 0

    var logValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
    }
}
