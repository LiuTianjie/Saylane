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
