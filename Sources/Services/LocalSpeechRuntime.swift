import Foundation

protocol LoadedSpeechModel: AnyObject, Sendable {
    func diagnostics() async -> String
    func transcribe(_ audio: [Float], language: String) async throws -> String
}

extension LoadedSpeechModel { func diagnostics() async -> String { "" } }

/// A single owner of a single model. Lifecycle tasks return Void, never a model:
/// completed Task results must not keep weights alive after a model switch.
actor LocalSpeechRuntime {
    typealias Factory = @Sendable (SpeechModel) async throws -> any LoadedSpeechModel
    private let factory: Factory
    private let flushMemory: @Sendable () -> Void
    private let trimMemory: @Sendable () -> Void
    private var model: (any LoadedSpeechModel)?
    private var selected: SpeechModel?
    private var generation = UUID()
    private var loading: (id: UUID, variant: SpeechModel, task: Task<Void, Error>)?
    private var tail: Task<Void, Error>?
    private var inference: Task<String, Error>?
    private var attemptedLoad = false

    init(factory: @escaping Factory, flushMemory: @escaping @Sendable () -> Void,
         trimMemory: @escaping @Sendable () -> Void = {}) {
        self.factory = factory
        self.flushMemory = flushMemory
        self.trimMemory = trimMemory
    }

    func prepare(_ variant: SpeechModel) async throws {
        try Task.checkCancellation()
        if selected == variant, model != nil { return }
        if loading?.variant != variant {
            loading?.task.cancel()
            inference?.cancel()
            let predecessor = tail
            let previousInference = inference
            let token = UUID()
            generation = token
            selected = nil
            // Serialize load → release → load even when actor callers are reentrant.
            let task = Task.detached(priority: .userInitiated) {
                _ = await predecessor?.result
                _ = await previousInference?.result
                try Task.checkCancellation()
                try await self.replace(with: variant)
            }
            loading = (token, variant, task)
            tail = task
        }
        guard let request = loading else { throw ASRModelError.missing }
        do {
            // Readiness callers share this load. Only a switch/unload cancels it;
            // cancelling one settings-view waiter must not cancel another waiter.
            try await request.task.value
            try Task.checkCancellation()
            guard generation == request.id else { throw CancellationError() }
            selected = variant
            loading = nil
        } catch {
            if generation == request.id, !Task.isCancelled { loading = nil }
            throw error
        }
    }

    func unload() async {
        generation = UUID()
        selected = nil
        loading?.task.cancel()
        inference?.cancel()
        let predecessor = tail
        let previousInference = inference
        loading = nil
        inference = nil
        // Cleanup is not cancelled with its caller. Next load must await this tail.
        let task: Task<Void, Error> = Task.detached(priority: .userInitiated) {
            _ = await predecessor?.result
            _ = await previousInference?.result
            await self.releaseResources()
        }
        tail = task
        _ = await task.result
    }

    func transcribe(_ audio: [Float], language: String, variant: SpeechModel) async throws -> String {
        try Task.checkCancellation()
        guard selected == variant, model != nil, inference == nil else { throw ASRModelError.missing }
        let token = generation
        let task = Task.detached(priority: .userInitiated) {
            do {
                let text = try await self.runInference(audio, language: language)
                await self.trimResources()
                return text
            } catch {
                await self.trimResources()
                throw error
            }
        }
        inference = task
        defer { if generation == token { inference = nil } }
        let text: String
        do {
            text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            // A cancelled/timed-out worker is disposable, never advertise it as ready.
            if generation == token { await unload() }
            throw error
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        return text
    }

    func diagnostics() async -> String { await model?.diagnostics() ?? "unloaded" }

    private func replace(with variant: SpeechModel) async throws {
        inference = nil // The predecessor inference has drained before replacement.
        releaseResources()
        attemptedLoad = true
        do {
            try await loadResource(variant)
        } catch {
            // loadResource has returned: any partially loaded local model is now gone.
            releaseResources()
            throw error
        }
    }

    private func loadResource(_ variant: SpeechModel) async throws {
        let resource = try await factory(variant)
        try Task.checkCancellation()
        model = resource
    }

    private func runInference(_ audio: [Float], language: String) async throws -> String {
        try Task.checkCancellation()
        guard let model else { throw ASRModelError.missing }
        return try await model.transcribe(audio, language: language)
    }

    private func trimResources() { trimMemory() }

    private func releaseResources() {
        model = nil
        // Do not initialize Metal at all for users who only ever choose Apple.
        if attemptedLoad { flushMemory() }
    }
}
