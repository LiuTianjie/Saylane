import AVFoundation
import Foundation
import MLXASR

/// Shared, serial lifetime manager. Apple never loads MLX; switching away drains
/// work, destroys the old model and clears its Metal allocations before proceeding.
enum QwenRuntime {
    // A dedicated worker owns Metal, tokenizer and weights. Destroying the worker
    // also releases driver/Foundation caches that MLX.clearCache cannot reclaim.
    static let shared = LocalSpeechRuntime(factory: { variant in
        if variant.isNative { return try await NativeASRModel.load(variant) }
        return try await QwenWorkerModel.start(variant)
    }, flushMemory: {})
}

// Used only inside the isolated worker process.
enum InProcessQwenRuntime {
    static let shared = LocalSpeechRuntime(factory: { variant in
        let manifest = try variant.manifest()
        try await ASRModelInstaller().verify(manifest)
        try Task.checkCancellation()
        Qwen3ASRSTT.configureMemoryBudget()
        let model = try await Qwen3ASRSTT.loadWithWarmup(from: manifest.directory())
        return LoadedQwenModel(model)
    }, flushMemory: { Qwen3ASRSTT.flushMemoryPool() },
       trimMemory: { Qwen3ASRSTT.trimMemoryPool() })
}

private actor LoadedQwenModel: LoadedSpeechModel {
    private let model: Qwen3ASRSTT
    init(_ model: Qwen3ASRSTT) { self.model = model }
    func transcribe(_ audio: [Float], language: String) async throws -> String {
        return try await transcribe(audio, language: language, context: nil)
    }
    func transcribe(_ audio: [Float], language: String, context: String?) async throws -> String {
        let result = try await model.transcribe(audio: audio, language: language, context: context, maxTokens: 1024)
        return result.text
    }
}

/// Local ASR. SenseVoice emits revising hypotheses while recording; Qwen and Fun-ASR-Nano
/// stay final-pass. Prefix re-decode is not a persistent streaming runtime.
@MainActor final class QwenSpeechEngine: SpeechRecognizing {
    var onPartial: ((String) -> Void)?
    private let variant: SpeechModel
    private let context: String?
    private var locale = Locale(identifier: "zh-CN")
    private var language = "Chinese"
    private var audio = QwenAudioBuffer()
    private var generation = 0
    private var active = false
    private var preview: Task<Void, Never>?

    init(variant: SpeechModel, context: String? = nil) { self.variant = variant; self.context = context }

    func begin(locale: Locale) async throws {
        generation += 1
        let token = generation
        active = false
        preview?.cancel()
        preview = nil
        audio = QwenAudioBuffer()
        self.locale = locale
        guard variant.supports(locale: locale) else { throw ASRModelError.unsupportedLanguage }
        language = try QwenLanguage.name(for: locale)
        try await QwenRuntime.shared.prepare(variant)
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
        preview?.cancel()
        await preview?.value
        preview = nil
        let samples = audio.samples
        audio = QwenAudioBuffer()
        // Truly silent / sub-FFT input must not become hallucinated text.
        guard samples.count >= 400, samples.contains(where: { abs($0) > 0.00001 }) else { return "" }
        let result = try await QwenRuntime.shared.transcribe(samples, language: language, variant: variant, context: context)
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
    }

    private func emitLivePartials(_ token: Int) async {
        var submitted = 0
        while generation == token, active {
            try? await Task.sleep(for: .milliseconds(280))
            guard generation == token, active else { return }
            let samples = audio.samples
            // Wait for a short utterance and enough new audio to justify another process.
            guard samples.count >= 12_800, samples.count - submitted >= 4_800 else { continue }
            submitted = samples.count
            do {
                let result = try await QwenRuntime.shared.transcribe(samples, language: language, variant: variant, context: context)
                guard generation == token, active else { return }
                let text = QwenLanguage.normalize(result, locale: locale).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { onPartial?(text) }
            } catch is CancellationError {
                if generation != token || !active { return }
            } catch {
                if generation != token || !active { return }
            }
        }
    }
}
