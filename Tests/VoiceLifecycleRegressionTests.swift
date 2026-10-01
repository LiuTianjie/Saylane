import AVFoundation
import Foundation

@MainActor private final class Capture: AudioCapturing {
    var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    var starts = 0
    var running = false
    func startStream() throws -> AsyncThrowingStream<AudioFrame, Error> {
        starts += 1
        running = true
        let pair = AsyncThrowingStream<AudioFrame, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func emit(_ count: Int) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        for _ in 0..<count {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            buffer.frameLength = 160
            memset(buffer.floatChannelData![0], 0, 160 * MemoryLayout<Float>.size)
            continuation?.yield(AudioFrame(buffer: buffer))
        }
    }
    func stop() { running = false; continuation?.finish() }
}

@MainActor private final class Recognizer: SpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)?
    var feeds = 0
    func begin(locale: Locale) async throws { try await Task.sleep(for: .milliseconds(20)) }
    func feed(_ buffer: AVAudioPCMBuffer) throws { feeds += 1 }
    func finish() async throws -> String { feeds > 0 ? "captured speech" : "" }
    func cancel() async {}
}

@MainActor private final class Target: CompositionTarget {
    var isValid = true
    var committed: [String] = []
    var failCommit = false
    func setMarked(_ text: String) {}
    func commit(_ text: String) throws {
        if failCommit { throw SessionFailure.insertionFailed }
        committed.append(text)
    }
    func cancelMarked() {}
}

@main struct VoiceLifecycleRegressionTests {
    @MainActor static func main() async throws {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            print("\(ok ? "PASS" : "FAIL"): \(label)")
            if !ok { failures.append(label) }
        }
        // Release closes hardware immediately but must drain frames already
        // queued by its callback, including frames the MainActor pump has not seen.
        do {
            let source = Capture()
            let capture = PrerollCapture(underlying: source)
            try capture.arm()
            source.emit(4)
            try await Task.sleep(for: .milliseconds(20))
            let stream = try capture.startStream()
            source.emit(3)
            capture.stop()
            var count = 0
            for try await _ in stream { count += 1 }
            check(count == 7 && !source.running, "release drains all 7 preroll and queued frames (received \(count))")
        }
        // A key-up can arrive while the IMK client is being attached. Starting
        // the coordinator and immediately releasing must preserve that utterance.
        do {
            let source = Capture()
            let capture = PrerollCapture(underlying: source)
            try capture.arm()
            source.emit(5)
            try await Task.sleep(for: .milliseconds(20))
            let session = SessionCoordinator(), speech = Recognizer(), target = Target()
            session.start(locale: Locale(identifier: "zh-CN"), speech: speech, capture: capture,
                          target: target, passthrough: true) { $0 }
            session.release()
            for _ in 0..<100 where session.state != .idle { try await Task.sleep(for: .milliseconds(5)) }
            check(speech.feeds == 5 && target.committed == ["captured speech"] && source.starts == 1 && !source.running,
                  "release before recognizer setup preserves buffered utterance (fed \(speech.feeds))")
        }
        // Discard is a different operation: a modifier chord must throw away
        // all pending audio and be reusable without replaying that old audio.
        do {
            let source = Capture(), target = Target()
            let capture = PrerollCapture(underlying: source)
            try capture.arm()
            source.emit(5)
            try await Task.sleep(for: .milliseconds(20))
            capture.discard()
            let session = SessionCoordinator(), speech = Recognizer()
            session.start(locale: Locale(identifier: "zh-CN"), speech: speech, capture: capture,
                          target: target, passthrough: true) { $0 }
            try await Task.sleep(for: .milliseconds(30))
            source.emit(1)
            try await Task.sleep(for: .milliseconds(10))
            session.release()
            for _ in 0..<100 where session.state != .idle { try await Task.sleep(for: .milliseconds(5)) }
            check(speech.feeds == 1 && source.starts == 2, "discard never replays old preroll into another utterance")
        }
        // A slow recognizer may not silently lose words when the relay fills.
        do {
            let source = Capture()
            let capture = PrerollCapture(underlying: source)
            let stream = try capture.startStream()
            source.emit(513)
            // Wait for the relay to observe the 513th frame and close the
            // producer. A fixed sleep made this a scheduler-speed test.
            for _ in 0..<500 where source.running {
                try await Task.sleep(for: .milliseconds(1))
            }
            capture.stop()
            var overflow = false
            do { for try await _ in stream {} }
            catch SessionFailure.audioOverflow { overflow = true }
            check(overflow && !source.running, "preroll relay reports overflow instead of silently losing audio")
        }
        do { // A rejected insertion is a failure, never a successful dictation.
            let source = Capture(), speech = Recognizer(), target = Target(), session = SessionCoordinator()
            target.failCommit = true
            var successes = 0, errors = 0
            var outcome: String?
            session.onCommit = { successes += 1 }
            session.onError = { _ in errors += 1 }
            session.onMetrics = { outcome = $0.outcome }
            session.start(locale: Locale(identifier: "zh-CN"), speech: speech, capture: source,
                          target: target, passthrough: true) { $0 }
            source.emit(1)
            session.release()
            for _ in 0..<100 where session.state != .idle { try await Task.sleep(for: .milliseconds(5)) }
            check(successes == 0 && errors == 1 && outcome == "failed" && target.committed.isEmpty,
                  "failed text insertion never reports a successful commit")
        }
        if !failures.isEmpty { exit(1) }
    }
}
