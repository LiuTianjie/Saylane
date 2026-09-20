import AVFoundation
import Foundation

/// Local ASR. All local models emit revising hypotheses by re-decoding the growing
/// recording; this is not incremental streaming. Reuse only an exact full-audio
/// decode on release; preserve Qwen's resident worker between requests.
@MainActor final class QwenSpeechEngine: SpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)?
    private let variant: SpeechModel
    private let context: String?
    private let runtime: LocalSpeechRuntime
    private let previewInterval: Duration
    private var inFlightSamples: Int?
    private var lastDecoded: (samples: Int, text: String)?
    private var locale = Locale(identifier: "zh-CN")
    private var language = "Chinese"
    private var audio = QwenAudioBuffer()
    private var generation = 0
    private var active = false
    private var preview: Task<Void, Never>?

    init(variant: SpeechModel, context: String? = nil, runtime: LocalSpeechRuntime,
         previewInterval: Duration? = nil) {
        self.variant = variant
        self.context = context
        self.runtime = runtime
        self.previewInterval = previewInterval ?? variant.livePartialPoll
    }

    func begin(locale: Locale) async throws {
        generation += 1
        let token = generation
        active = false
        preview?.cancel()
        preview = nil
        inFlightSamples = nil
        lastDecoded = nil
        audio = QwenAudioBuffer()
        self.locale = locale
        guard variant.supports(locale: locale) else { throw ASRModelError.unsupportedLanguage }
        language = try QwenLanguage.name(for: locale)
        try await runtime.prepare(variant)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        active = true
        if variant.emitsLivePartial {
            preview = Task { await self.emitLivePartials(token) }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) throws {
        guard active else { throw CancellationError() }
        try audio.append(buffer)
    }

    func finish() async throws -> String {
        guard active else { throw CancellationError() }
        active = false
        let token = generation
        let samples = audio.samples
        // Interrupt an idle poll immediately. Native batch helpers can also
        // preempt stale work; killing Qwen would discard its resident model.
        // A decode of exactly this recording is already a valid final pass.
        if inFlightSamples == nil || (variant.preemptsLivePartial && inFlightSamples != samples.count) {
            preview?.cancel()
        }
        await preview?.value
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        preview = nil
        audio = QwenAudioBuffer()
        // Do not use a shorter prefix as the final result, even by one frame.
        guard samples.count >= 400, samples.contains(where: { abs($0) > 0.00001 }) else { return "" }
        if let decoded = lastDecoded, decoded.samples == samples.count, !decoded.text.isEmpty {
            return decoded.text
        }
        let result = try await runtime.transcribe(samples, language: language, variant: variant, context: context)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        return QwenLanguage.normalize(result, locale: locale).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        generation += 1
        active = false
        preview?.cancel()
        await preview?.value
        preview = nil
        audio = QwenAudioBuffer()
        lastDecoded = nil
        inFlightSamples = nil
    }

    private func emitLivePartials(_ token: Int) async {
        var submitted = 0
        while generation == token, active {
            do { try await Task.sleep(for: previewInterval) } catch { return }
            guard generation == token, active, !Task.isCancelled else { return }
            let samples = audio.samples
            // Wait for a short utterance and enough new audio to justify another decode.
            let minSamples = variant == .senseVoice ? 12_800 : 16_000
            let minDelta = variant == .senseVoice ? 4_800 : 8_000
            guard samples.count >= minSamples, samples.count - submitted >= minDelta else { continue }
            guard samples.contains(where: { abs($0) > 0.00001 }) else { continue }
            submitted = samples.count
            inFlightSamples = samples.count
            defer { if generation == token { inFlightSamples = nil } }
            do {
                let result = try await runtime.transcribe(samples, language: language, variant: variant, context: context)
                guard generation == token, !Task.isCancelled else { return }
                let text = QwenLanguage.normalize(result, locale: locale).trimmingCharacters(in: .whitespacesAndNewlines)
                lastDecoded = (samples.count, text)
                guard active else { return }
                if !text.isEmpty { onPartial?(SpeechHypothesis(volatileText: text)) }
            } catch is CancellationError {
                if generation != token || !active { return }
            } catch {
                if generation != token || !active { return }
            }
        }
    }
}
