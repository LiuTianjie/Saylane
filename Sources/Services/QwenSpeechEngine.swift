import AVFoundation
import Foundation
import MLXASR

/// Shared, serial lifetime manager. Apple never loads MLX; switching away drains
/// work, destroys the old model and clears its Metal allocations before proceeding.
enum QwenRuntime {
    // A dedicated worker owns Metal, tokenizer and weights. Destroying the worker
    // also releases driver/Foundation caches that MLX.clearCache cannot reclaim.
    static let shared = LocalSpeechRuntime(factory: { variant in
        try await QwenWorkerModel.start(variant)
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
        let result = try await model.transcribe(audio: audio, language: language, maxTokens: 1024)
        return result.text
    }
}

/// Offline final-pass ASR. Does not simulate streaming by repeatedly decoding prefixes.
@MainActor final class QwenSpeechEngine: SpeechRecognizing {
    var onPartial: ((String) -> Void)?
    private let variant: SpeechModel
    private var locale = Locale(identifier: "zh-CN")
    private var language = "Chinese"
    private var audio = QwenAudioBuffer()
    private var generation = 0
    private var active = false

    init(variant: SpeechModel) { self.variant = variant }

    func begin(locale: Locale) async throws {
        generation += 1
        let token = generation
        active = false
        audio = QwenAudioBuffer()
        self.locale = locale
        language = try QwenLanguage.name(for: locale)
        try await QwenRuntime.shared.prepare(variant)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        active = true
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
        audio = QwenAudioBuffer()
        // Truly silent / sub-FFT input must not become hallucinated text.
        guard samples.count >= 400, samples.contains(where: { abs($0) > 0.00001 }) else { return "" }
        let result = try await QwenRuntime.shared.transcribe(samples, language: language, variant: variant)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        return QwenLanguage.normalize(result, locale: locale).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        generation += 1
        active = false
        audio = QwenAudioBuffer()
    }
}
