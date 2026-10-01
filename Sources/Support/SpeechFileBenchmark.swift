import AVFoundation
import Foundation

/// Explicit file-replay diagnostic. Unlike normal session telemetry, this report
/// includes transcripts so a user-provided reference corpus can be scored.
@MainActor enum SpeechFileBenchmark {
    struct Run: Codable {
        let iteration: Int
        let model: String
        let locale: String
        let realtime: Bool
        let audioMS: Double
        let setupMS: Double
        let firstHypothesisMS: Double?
        let finalizeMS: Double
        let totalMS: Double
        let hypothesisCount: Int
        let revisedCharacterCount: Int
        let text: String
        /// When each hypothesis arrived, counted from the first audio fed.
        var partials: [Partial] = []
        var file: String?
    }
    struct Partial: Codable {
        let ms: Double
        let text: String
    }

    static func run(fileURL: URL, locale: Locale, model: String, realtime: Bool, repetitions: Int,
                    makeEngine: () -> any SpeechRecognizing) async throws -> [Run] {
        var reports: [Run] = []
        for iteration in 1...repetitions {
            let file = try AVAudioFile(forReading: fileURL)
            let engine = makeEngine()
            let started = ProcessInfo.processInfo.systemUptime
            var firstHypothesis: Double?
            var count = 0, revised = 0
            var previous = ""
            var partials: [Partial] = []
            var feedingStarted = started
            engine.onPartial = { result in
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let current = ProcessInfo.processInfo.systemUptime
                if firstHypothesis == nil { firstHypothesis = (current - feedingStarted) * 1000 }
                partials.append(Partial(ms: (current - feedingStarted) * 1000, text: result.text))
                count += 1
                let common = zip(previous, result.text).prefix { $0 == $1 }.count
                revised += max(0, previous.count - common)
                previous = result.text
            }
            do {
                try await engine.begin(locale: locale)
                feedingStarted = ProcessInfo.processInfo.systemUptime
                let setupMS = (feedingStarted - started) * 1000
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else {
                        throw SpeechEngineError.invalidFormat
                    }
                    try file.read(into: buffer)
                    try engine.feed(buffer)
                    if realtime {
                        // Pace against an absolute audio clock; decode time must not
                        // accumulate as artificial pauses between input buffers.
                        let due = feedingStarted + Double(file.framePosition) / file.processingFormat.sampleRate
                        let remaining = due - ProcessInfo.processInfo.systemUptime
                        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                    } else { await Task.yield() }
                }
                let released = ProcessInfo.processInfo.systemUptime
                let text = try await engine.finish()
                let ended = ProcessInfo.processInfo.systemUptime
                reports.append(Run(iteration: iteration, model: model, locale: locale.identifier,
                                   realtime: realtime,
                                   audioMS: Double(file.length) / file.processingFormat.sampleRate * 1000,
                                   setupMS: setupMS, firstHypothesisMS: firstHypothesis,
                                   finalizeMS: (ended - released) * 1000, totalMS: (ended - started) * 1000,
                                   hypothesisCount: count, revisedCharacterCount: revised, text: text,
                                   partials: partials, file: fileURL.lastPathComponent))
            } catch {
                await engine.cancel()
                throw error
            }
        }
        return reports
    }
}
