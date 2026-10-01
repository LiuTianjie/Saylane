import AVFoundation
import Foundation

@MainActor final class ScriptedCapture: AudioCapturing {
    var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    var starts = 0
    var stops = 0
    func startStream() throws -> AsyncThrowingStream<AudioFrame, Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream<AudioFrame, Error>.makeStream()
        self.continuation = continuation
        return stream
    }
    func emit(_ count: Int, frames: AVAudioFrameCount = 4800) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        for _ in 0..<count {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            continuation?.yield(AudioFrame(buffer: buffer))
        }
    }
    func stop() { stops += 1; continuation?.finish() }
}

@main struct PrerollCaptureTests {
    @MainActor static func settle(_ milliseconds: Int = 20) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    @MainActor static func main() async {
        // Audio captured before the session asks for the stream is replayed first, then live audio follows.
        do {
            let underlying = ScriptedCapture()
            let preroll = PrerollCapture(underlying: underlying, limit: 3)
            try! preroll.arm()
            precondition(underlying.starts == 1 && preroll.isArmed)
            underlying.emit(5)
            await settle()
            precondition(abs(preroll.bufferedDuration - 0.5) < 0.001, "\(preroll.bufferedDuration)")
            let stream = try! preroll.startStream()
            var received = 0
            let reader = Task { for try await _ in stream { received += 1 } }
            await settle()
            precondition(received == 5, "buffered frames replay first: \(received)")
            underlying.emit(3)
            await settle()
            precondition(received == 8, "live frames follow: \(received)")
            preroll.stop()
            _ = try? await reader.value
            precondition(underlying.stops >= 1)
        }
        // The ring is bounded: only the newest `limit` seconds survive.
        do {
            let underlying = ScriptedCapture()
            let preroll = PrerollCapture(underlying: underlying, limit: 1)
            try! preroll.arm()
            underlying.emit(30) // 3 s at 0.1 s per frame
            await settle()
            precondition(preroll.bufferedDuration <= 1.0 + 0.11, "\(preroll.bufferedDuration)")
            let stream = try! preroll.startStream()
            var received = 0
            let reader = Task { for try await _ in stream { received += 1 } }
            await settle()
            precondition(received <= 11 && received >= 10, "\(received)")
            preroll.stop(); _ = try? await reader.value
        }
        // Discarding releases the microphone and forgets the audio; starting afterwards re-arms.
        do {
            let underlying = ScriptedCapture()
            let preroll = PrerollCapture(underlying: underlying, limit: 3)
            try! preroll.arm()
            underlying.emit(2)
            await settle()
            preroll.discard()
            precondition(!preroll.isArmed && preroll.bufferedDuration == 0 && underlying.stops == 1)
            let stream = try! preroll.startStream()
            precondition(underlying.starts == 2)
            var received = 0
            let reader = Task { for try await _ in stream { received += 1 } }
            underlying.emit(1)
            await settle()
            precondition(received == 1)
            preroll.stop(); _ = try? await reader.value
        }
        // A capture failure before the session starts surfaces when the stream is requested.
        do {
            let underlying = ScriptedCapture()
            let preroll = PrerollCapture(underlying: underlying, limit: 3)
            try! preroll.arm()
            underlying.continuation?.finish(throwing: SessionFailure.audioOverflow)
            await settle()
            do { _ = try preroll.startStream(); fatalError("failure must propagate") } catch {}
        }
        // Works as the session's capture: SessionCoordinator drains preroll into the recognizer.
        do {
            let underlying = ScriptedCapture()
            let preroll = PrerollCapture(underlying: underlying, limit: 3)
            try! preroll.arm()
            underlying.emit(4)
            await settle()
            let c = SessionCoordinator(), speech = CountingSpeech(), target = CountingTarget()
            c.start(locale: .current, speech: speech, capture: preroll, target: target, passthrough: true) { $0 }
            await settle(40)
            precondition(speech.feeds == 4, "preroll fed to recognizer: \(speech.feeds)")
            underlying.emit(2)
            await settle()
            precondition(speech.feeds == 6)
            c.release()
            await settle(60)
            precondition(target.committed == ["done"])
        }
        print("PASS: preroll replay, bounded ring, discard, failure propagation and coordinator integration")
    }
}

@MainActor final class CountingSpeech: SpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)?
    var feeds = 0
    func begin(locale: Locale) async throws {}
    func feed(_ buffer: AVAudioPCMBuffer) throws { feeds += 1 }
    func finish() async throws -> String { "done" }
    func cancel() async {}
}
@MainActor final class CountingTarget: CompositionTarget {
    var isValid = true
    var committed: [String] = []
    func setMarked(_ text: String) {}
    func commit(_ text: String) { committed.append(text) }
    func cancelMarked() {}
}
