import AVFoundation
import Foundation

private actor Decoder: LoadedSpeechModel {
    var requests: [Int] = []
    var delay: Duration
    let emptyFirst: Bool
    init(delay: Duration = .milliseconds(15), emptyFirst: Bool = false) {
        self.delay = delay; self.emptyFirst = emptyFirst
    }
    func transcribe(_ audio: [Float], language: String) async throws -> String {
        requests.append(audio.count)
        let first = requests.count == 1
        try await Task.sleep(for: delay)
        return emptyFirst && first ? "" : "samples=\(audio.count)"
    }
    func counts() -> [Int] { requests }
}

private struct InjectedPreviewFailure: Error {}

private actor PreviewRecoveryProbe {
    private var loads = 0
    private var requests: [Int] = []

    func noteLoad() { loads += 1 }

    func decode(_ samples: Int) async throws -> String {
        requests.append(samples)
        if requests.count == 1 {
            // Keep the preview in flight until `finish()` has started. This covers
            // key-up racing with a decoder failure, not only a failure observed
            // while the engine is still listening.
            try await Task.sleep(for: .milliseconds(60))
            throw InjectedPreviewFailure()
        }
        return "samples=\(samples)"
    }

    func snapshot() -> (loads: Int, requests: [Int]) { (loads, requests) }
}

private actor PreviewRecoveryDecoder: LoadedSpeechModel {
    let probe: PreviewRecoveryProbe
    init(probe: PreviewRecoveryProbe) { self.probe = probe }
    func transcribe(_ audio: [Float], language: String) async throws -> String {
        try await probe.decode(audio.count)
    }
}

@main struct LocalSpeechEngineTests {
    @MainActor static func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<1000 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("condition timed out")
    }
    static func pcm(_ samples: Int, silent: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples))!
        buffer.frameLength = AVAudioFrameCount(samples)
        buffer.floatChannelData![0].update(repeating: silent ? 0 : 0.1, count: samples)
        return buffer
    }
    @MainActor static func main() async throws {
        var passed = 0
        for variant in [SpeechModel.qwen4bit, .senseVoice, .funASRNano] {
            do { // Completed full-audio previews are reused; sleeping poll is interrupted.
                let decoder = Decoder()
                let runtime = LocalSpeechRuntime(factory: { _ in decoder }, flushMemory: {})
                let engine = QwenSpeechEngine(variant: variant, runtime: runtime, previewInterval: .milliseconds(5))
                var previews = 0
                engine.onPartial = { hypothesis in
                    precondition(hypothesis.stableText.isEmpty)
                    previews += 1
                }
                try await engine.begin(locale: Locale(identifier: "zh-CN"))
                try engine.feed(pcm(16000))
                await waitUntil { previews == 1 }
                let final = try await engine.finish()
                let requests = await decoder.counts()
                precondition(final == "samples=16000" && requests == [16000])
                // Cache cannot escape into the next utterance.
                try await engine.begin(locale: Locale(identifier: "zh-CN"))
                try engine.feed(pcm(800))
                let next = try await engine.finish()
                precondition(next == "samples=800")
                await runtime.unload(); passed += 1
            }
            for tail in [0, 80] { // Reuse in-flight exact input; decode every additional sample.
                let decoder = Decoder(delay: .milliseconds(80))
                let runtime = LocalSpeechRuntime(factory: { _ in decoder }, flushMemory: {})
                let engine = QwenSpeechEngine(variant: variant, runtime: runtime, previewInterval: .milliseconds(5))
                try await engine.begin(locale: Locale(identifier: "zh-CN"))
                try engine.feed(pcm(16000))
                await waitUntil { await decoder.counts().count == 1 }
                if tail > 0 { try engine.feed(pcm(tail)) }
                let final = try await engine.finish()
                let requests = await decoder.counts()
                precondition(final == "samples=\(16000 + tail)")
                precondition(requests == (tail == 0 ? [16000] : [16000, 16080]))
                await runtime.unload(); passed += 1
            }
        }
        do { // finish cannot wait for an idle 60-second preview timer.
            let decoder = Decoder()
            let runtime = LocalSpeechRuntime(factory: { _ in decoder }, flushMemory: {})
            let engine = QwenSpeechEngine(variant: .qwen4bit, runtime: runtime, previewInterval: .seconds(60))
            try await engine.begin(locale: .current)
            try engine.feed(pcm(800))
            let start = ProcessInfo.processInfo.systemUptime
            let final = try await engine.finish()
            precondition(final == "samples=800" && ProcessInfo.processInfo.systemUptime - start < 1)
            await runtime.unload(); passed += 1
        }
        do { // Empty preview must not poison the final decode cache.
            let decoder = Decoder(emptyFirst: true)
            let runtime = LocalSpeechRuntime(factory: { _ in decoder }, flushMemory: {})
            let engine = QwenSpeechEngine(variant: .qwen4bit, runtime: runtime, previewInterval: .milliseconds(5))
            try await engine.begin(locale: .current)
            try engine.feed(pcm(16000))
            await waitUntil { await decoder.counts().count == 1 }
            try await Task.sleep(for: .milliseconds(30))
            let final = try await engine.finish()
            let requests = await decoder.counts()
            precondition(final == "samples=16000" && requests.count == 2)
            await runtime.unload(); passed += 1
        }
        do { // A failed in-flight preview is reloaded and decoded again for the final result.
            let probe = PreviewRecoveryProbe()
            let runtime = LocalSpeechRuntime(factory: { _ in
                await probe.noteLoad()
                return PreviewRecoveryDecoder(probe: probe)
            }, flushMemory: {})
            let engine = QwenSpeechEngine(variant: .qwen4bit, runtime: runtime, previewInterval: .milliseconds(5))
            try await engine.begin(locale: Locale(identifier: "zh-CN"))
            try engine.feed(pcm(16000))
            await waitUntil { await probe.snapshot().requests.count == 1 }
            let final: String
            do {
                final = try await engine.finish()
            } catch {
                preconditionFailure("final recognition did not recover from the failed preview: \(error)")
            }
            let snapshot = await probe.snapshot()
            precondition(final == "samples=16000")
            precondition(snapshot.loads == 2 && snapshot.requests == [16000, 16000],
                         "failed preview must reload once for final recognition: \(snapshot)")
            await runtime.unload(); passed += 1
        }
        do { // A cancelled finish cannot start a new decode after the preview drains.
            let decoder = Decoder(delay: .milliseconds(100))
            let runtime = LocalSpeechRuntime(factory: { _ in decoder }, flushMemory: {})
            let engine = QwenSpeechEngine(variant: .qwen4bit, runtime: runtime, previewInterval: .milliseconds(5))
            var previews = 0; engine.onPartial = { _ in previews += 1 }
            try await engine.begin(locale: .current)
            try engine.feed(pcm(16000))
            await waitUntil { await decoder.counts().count == 1 }
            try engine.feed(pcm(80))
            let finishing = Task { try await engine.finish() }
            await Task.yield()
            await engine.cancel()
            do { _ = try await finishing.value; preconditionFailure("cancelled finish succeeded") }
            catch is CancellationError { }
            let requests = await decoder.counts()
            precondition(requests.count == 1 && previews == 0)
            await runtime.unload(); passed += 1
        }
        do { // Silent input is never sent for final recognition.
            let decoder = Decoder()
            let runtime = LocalSpeechRuntime(factory: { _ in decoder }, flushMemory: {})
            let engine = QwenSpeechEngine(variant: .senseVoice, runtime: runtime, previewInterval: .milliseconds(5))
            try await engine.begin(locale: Locale(identifier: "zh-CN"))
            try engine.feed(pcm(16000, silent: true))
            try await Task.sleep(for: .milliseconds(30))
            let final = try await engine.finish()
            let requests = await decoder.counts()
            precondition(final.isEmpty && requests.isEmpty)
            await runtime.unload(); passed += 1
        }
        print("PASS: \(passed) local speech scenarios: exact-audio reuse, trailing frames, idle poll, cancellation, empty results, cache isolation")
    }
}
