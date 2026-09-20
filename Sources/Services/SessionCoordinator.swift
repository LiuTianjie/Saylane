import AVFoundation
import Foundation
import Observation

/// An owned PCM snapshot, never the engine's reusable tap storage.
struct AudioFrame: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

@MainActor protocol SpeechRecognizing: AnyObject {
    var onPartial: ((SpeechHypothesis) -> Void)? { get set }
    func begin(locale: Locale) async throws
    func feed(_ buffer: AVAudioPCMBuffer) throws
    func finish() async throws -> String
    func cancel() async
}

@MainActor protocol AudioCapturing: AnyObject {
    func startStream() throws -> AsyncThrowingStream<AudioFrame, Error>
    func stop()
}

@MainActor protocol CompositionTarget: AnyObject {
    var isValid: Bool { get }
    func setMarked(_ text: String)
    func commit(_ text: String)
    func cancelMarked()
}

enum SessionFailure: LocalizedError {
    case targetLost, emptyResult, audioOverflow, timeout
    var errorDescription: String? {
        switch self {
        case .targetLost: return "输入目标已改变，本次听写已取消。"
        case .emptyResult: return "没有识别到语音，请检查麦克风后重试。"
        case .audioOverflow: return "音频处理跟不上录音，本次已取消。请重试或使用更轻的模型。"
        case .timeout: return "处理超时，本次已取消。请检查模型状态后重试。"
        }
    }
}

/// One actor owns state, PCM conversion, output revision and the captured IMK target.
@MainActor @Observable
final class SessionCoordinator {
    private(set) var state: SessionState = .idle
    var onState: ((SessionState) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    var onPreview: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onCompletion: ((CompletionFeedback) -> Void)?
    var onMetrics: ((SpeechSessionMetrics) -> Void)?
    private var run: Run?
    private let now: () -> TimeInterval
    private let previewInterval: TimeInterval

    init(previewInterval: TimeInterval = 0.08,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.previewInterval = max(0, previewInterval)
        self.now = now
    }

    private final class Run {
        let id = UUID()
        let speech: any SpeechRecognizing
        let capture: any AudioCapturing
        let target: any CompositionTarget
        let translate: (String) async throws -> String
        /// Final-only text repair. Revisable hypotheses must not repeatedly pass
        /// through semantic deletion, self-correction and phonetic replacement.
        let refine: ((String) -> String)?
        let polish: ((String, String) async throws -> String)?
        let polishTimeout: Double
        let passthrough: Bool
        var stopRequested = false
        var lastPartial: String?
        var setup: Task<Void, Never>?
        var pump: Task<Void, Error>?
        var preview: Task<Void, Never>?
        var finish: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var pendingPreview: String?
        var pendingHypothesis: SpeechHypothesis?
        var presentation: Task<Void, Never>?
        var lastPresentedAt: TimeInterval?
        var lastHypothesis = ""
        let startedAt: TimeInterval
        var metrics: SpeechSessionMetrics
        init(speech: any SpeechRecognizing, capture: any AudioCapturing,
             target: any CompositionTarget, passthrough: Bool, refine: ((String) -> String)?,
             polish: ((String, String) async throws -> String)?, polishTimeout: Double,
             model: String, startedAt: TimeInterval,
             translate: @escaping (String) async throws -> String) {
            self.speech = speech; self.capture = capture; self.target = target
            self.passthrough = passthrough; self.translate = translate; self.refine = refine
            self.polish = polish; self.polishTimeout = polishTimeout
            self.startedAt = startedAt
            self.metrics = SpeechSessionMetrics(sessionID: id, model: model)
        }
    }

    func start(locale: Locale, speech: any SpeechRecognizing, capture: any AudioCapturing,
               target: any CompositionTarget, passthrough: Bool, refine: ((String) -> String)? = nil,
               polish: ((String, String) async throws -> String)? = nil, polishTimeout: Double = 8,
               model: String = "unspecified",
               translate: @escaping (String) async throws -> String) {
        guard run == nil, target.isValid else { return }
        let context = Run(speech: speech, capture: capture, target: target, passthrough: passthrough,
                          refine: refine, polish: polish, polishTimeout: polishTimeout,
                          model: model, startedAt: now(), translate: translate)
        run = context
        transition(.preparing)
        speech.onPartial = { [weak self, weak context] hypothesis in
            guard let self, let context, self.isCurrent(context), !context.stopRequested else { return }
            self.receive(hypothesis, for: context)
        }
        armDeadline(context, seconds: 20)
        context.setup = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.isCurrent(context) else { return }
                if context.stopRequested { self.cancel(); return }
                // Capture immediately, buffering owned audio while the installed model loads.
                let stream = try capture.startStream()
                self.mark("captureStarted", for: context)
                try await speech.begin(locale: locale)
                guard self.isCurrent(context) else { await speech.cancel(); return }
                self.mark("recognizerReady", for: context)
                context.pump = Task {
                    do {
                        for try await frame in stream {
                            try Task.checkCancellation()
                            guard self.isCurrent(context), target.isValid else { throw SessionFailure.targetLost }
                            self.mark("firstAudioFed", for: context)
                            if frame.buffer.format.sampleRate > 0 {
                                context.metrics.audioMS += Double(frame.buffer.frameLength) / frame.buffer.format.sampleRate * 1000
                            }
                            try speech.feed(frame.buffer)
                            self.onLevel?(AudioLevel.normalized(from: frame.buffer))
                        }
                    } catch {
                        if self.isCurrent(context) { self.cancel(error: error.localizedDescription) }
                        throw error
                    }
                }
                self.transition(.listening)
                self.armDeadline(context, seconds: 180)
                if context.stopRequested { self.finalize(context) }
            } catch {
                if self.isCurrent(context) { self.cancel(error: error.localizedDescription) }
            }
        }
    }

    func release() {
        guard let context = run, !context.stopRequested else { return }
        context.stopRequested = true
        mark("released", for: context)
        context.presentation?.cancel()
        context.pendingHypothesis = nil
        // Stop the tap even if setup is still pending; no post-release audio is recorded.
        context.capture.stop()
        if state == .listening { finalize(context) }
    }

    func cancel(error: String? = nil) {
        guard let context = run else { return }
        // Invalidate before any await or client callback; old work cannot affect a new run.
        run = nil
        transition(.cancelling)
        context.capture.stop()
        context.setup?.cancel(); context.pump?.cancel(); context.preview?.cancel()
        context.finish?.cancel(); context.deadline?.cancel(); context.presentation?.cancel()
        context.speech.onPartial = nil
        context.target.cancelMarked()
        Task { await context.speech.cancel() }
        transition(.idle)
        completeMetrics(context, outcome: error == nil ? "cancelled" : "failed")
        if let error { onError?(error) }
    }

    private func isCurrent(_ context: Run) -> Bool { run === context }

    private func receive(_ hypothesis: SpeechHypothesis, for context: Run) {
        guard context.target.isValid else { cancel(error: SessionFailure.targetLost.localizedDescription); return }
        let text = hypothesis.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mark("firstHypothesis", for: context)
        context.metrics.hypothesisCount += 1
        let common = zip(context.lastHypothesis, text).prefix { $0 == $1 }.count
        context.metrics.revisedCharacterCount += max(0, context.lastHypothesis.count - common)
        context.metrics.stableCharacterCount = hypothesis.stableText.count
        context.lastHypothesis = text
        context.pendingHypothesis = hypothesis
        let elapsed = context.lastPresentedAt.map { now() - $0 } ?? previewInterval
        if elapsed >= previewInterval {
            context.presentation?.cancel()
            context.presentation = nil
            presentPending(context)
        } else if context.presentation == nil {
            // A fixed deadline coalesces bursts without starving continuous speech.
            // The first hypothesis is immediate; never freeze an unconfirmed prefix.
            let delay = previewInterval - elapsed
            context.presentation = Task { [weak self, weak context] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, let context, self.isCurrent(context), !context.stopRequested else { return }
                context.presentation = nil
                self.presentPending(context)
            }
        }
    }

    private func presentPending(_ context: Run) {
        guard let hypothesis = context.pendingHypothesis else { return }
        context.pendingHypothesis = nil
        context.lastPresentedAt = now()
        preview(hypothesis.text, for: context)
    }

    private func preview(_ text: String, for context: Run) {
        guard context.target.isValid else { cancel(error: SessionFailure.targetLost.localizedDescription); return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != context.lastPartial else { return }
        context.lastPartial = text
        if context.passthrough {
            showMarked(text, for: context)
            return
        }
        // One translation at a time; coalesce pending text without starving continuous speech.
        context.pendingPreview = text
        guard context.preview == nil else { return }
        context.preview = Task { [weak self] in
            guard let self else { return }
            defer { context.preview = nil }
            while let text = context.pendingPreview {
                context.pendingPreview = nil
                do {
                    // First preview starts immediately. While it runs, pending text
                    // is replaced by the newest full hypothesis, not queued per word.
                    let translated = try await context.translate(text)
                    guard !Task.isCancelled, self.isCurrent(context), !context.stopRequested else { return }
                    guard context.target.isValid else { throw SessionFailure.targetLost }
                    self.showMarked(translated, for: context)
                    // Translation itself bounds concurrency. Process the latest pending
                    // hypothesis immediately instead of adding latency after every result.
                } catch {
                    if Task.isCancelled { return }
                    // Final translation is authoritative. Never commit an old preview on failure.
                    if self.isCurrent(context) { self.onError?("实时翻译暂不可用，松开后会重试：\(error.localizedDescription)") }
                    return
                }
            }
        }
    }

    private func finalize(_ context: Run) {
        guard isCurrent(context), context.finish == nil else { return }
        transition(.finalizing)
        context.capture.stop()
        context.pendingPreview = nil
        context.preview?.cancel()
        context.presentation?.cancel()
        context.pendingHypothesis = nil
        armDeadline(context, seconds: 20)
        context.finish = Task { [weak self] in
            guard let self else { return }
            do {
                // Drain every queued frame before ending the recognizer's input stream.
                try await context.pump?.value
                try Task.checkCancellation()
                let recognized = try await context.speech.finish().trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.isCurrent(context), !Task.isCancelled else { return }
                self.mark("recognitionFinished", for: context)
                guard !recognized.isEmpty else { throw SessionFailure.emptyResult }
                // An utterance that was nothing but fillers still commits what was heard.
                let refined = (context.refine?(recognized) ?? recognized).trimmingCharacters(in: .whitespacesAndNewlines)
                let source = refined.isEmpty ? recognized : refined
                // Serialize final translation after the previous in-flight preview.
                await context.preview?.value
                try Task.checkCancellation()
                let output = context.passthrough ? source : try await context.translate(source)
                guard self.isCurrent(context), !Task.isCancelled else { return }
                guard context.target.isValid else { throw SessionFailure.targetLost }
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SessionFailure.emptyResult }
                if let polish = context.polish {
                    self.transition(.polishing)
                    // Ordinary output remains visible as marked text during optional editing.
                    self.showMarked(output, for: context)
                    context.deadline?.cancel()
                    context.deadline = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(context.polishTimeout)) } catch { return }
                        guard let self, self.isCurrent(context) else { return }
                        // Do not await a provider that ignores cancellation. Detach this run
                        // before committing the fallback; its late result cannot write again.
                        context.finish?.cancel()
                        self.commit(output, context: context, warning: "AI 润色超时，已保留普通结果。", feedback: .polishTimedOut)
                    }
                    do {
                        let polished = try await polish(source, output).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard self.isCurrent(context), !Task.isCancelled else { return }
                        guard !polished.isEmpty else { throw SessionFailure.emptyResult }
                        self.commit(polished, context: context, feedback: polished == output ? .unchanged : .polished)
                    } catch is PolishRejected {
                        guard self.isCurrent(context), !Task.isCancelled else { return }
                        self.commit(output, context: context, warning: "AI 改动过大，已保留本地结果。", feedback: .polishRejected)
                    } catch {
                        guard self.isCurrent(context), !Task.isCancelled else { return }
                        // Do not log a provider response: it may contain dictated text.
                        self.commit(output, context: context, warning: "AI 润色未完成，已保留普通结果；请检查模型配置或网络。", feedback: .polishFailed)
                    }
                } else {
                    self.commit(output, context: context)
                }
            } catch {
                if self.isCurrent(context) { self.cancel(error: error.localizedDescription) }
            }
        }
    }

    private func commit(_ output: String, context: Run, warning: String? = nil, feedback: CompletionFeedback = .ordinary) {
        guard isCurrent(context) else { return }
        guard context.target.isValid else { cancel(error: SessionFailure.targetLost.localizedDescription); return }
        // Invalidate before calling the IMK client to prevent reentrant/late commits.
        run = nil
        context.deadline?.cancel()
        context.speech.onPartial = nil
        context.target.commit(output)
        transition(.idle)
        onCommit?()
        onCompletion?(feedback)
        mark("committed", for: context)
        completeMetrics(context, outcome: "committed")
        if let warning { onError?(warning) }
    }

    private func showMarked(_ text: String, for context: Run) {
        mark("firstPreview", for: context)
        context.metrics.previewCount += 1
        context.target.setMarked(text)
        onPreview?(text.count)
    }

    private func mark(_ stage: String, for context: Run) {
        if context.metrics.elapsedMS[stage] == nil {
            context.metrics.elapsedMS[stage] = max(0, now() - context.startedAt) * 1000
        }
    }

    private func completeMetrics(_ context: Run, outcome: String) {
        mark("ended", for: context)
        context.metrics.outcome = outcome
        onMetrics?(context.metrics)
    }

    private func transition(_ value: SessionState) { state = value; onState?(value) }
    private func armDeadline(_ context: Run, seconds: Int) {
        context.deadline?.cancel()
        context.deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.isCurrent(context) else { return }
            self.cancel(error: SessionFailure.timeout.localizedDescription)
        }
    }
}
