import AVFoundation
import Foundation

@MainActor final class FakeSpeech: SpeechRecognizing {
    var onPartial: ((String) -> Void)?
    var feeds = 0
    var finishCount = 0
    var cancels = 0
    var setupDelay = 0
    var finishDelay = 0
    var finalText = "最终结果。"
    var failFinish = false
    func begin(locale: Locale) async throws {
        if setupDelay > 0 { try await Task.sleep(for: .milliseconds(setupDelay)) }
    }
    func feed(_ buffer: AVAudioPCMBuffer) throws { feeds += 1; onPartial?("中间结果") }
    func finish() async throws -> String {
        finishCount += 1
        if finishDelay > 0 { try await Task.sleep(for: .milliseconds(finishDelay)) }
        if failFinish { throw SessionFailure.emptyResult }
        return finalText
    }
    func cancel() async { cancels += 1 }
}
@MainActor final class FakeCapture: AudioCapturing {
    var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    var starts = 0
    func startStream() throws -> AsyncThrowingStream<AudioFrame, Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream<AudioFrame, Error>.makeStream()
        self.continuation = continuation
        return stream
    }
    func emit(_ count: Int) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        for _ in 0..<count {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
            buffer.frameLength = 16
            continuation?.yield(AudioFrame(buffer: buffer))
        }
    }
    func stop() { continuation?.finish() }
}
@MainActor final class FakeTarget: CompositionTarget {
    var isValid = true
    var marked: [String] = []
    var committed: [String] = []
    var cancels = 0
    func setMarked(_ text: String) { marked.append(text) }
    func commit(_ text: String) { committed.append(text) }
    func cancelMarked() { cancels += 1 }
}
@main struct SessionTests {
    @MainActor static func settle(_ milliseconds: Int = 20) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    @MainActor static func main() async {
        var passed = 0
        for _ in 0..<20 {
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            var translations = 0
            c.start(locale: Locale(identifier: "zh-CN"), speech: speech, capture: audio, target: target, passthrough: true) { text in translations += 1; return text }
            await settle(); audio.emit(30); c.release(); c.release(); await settle()
            precondition(speech.feeds == 30 && speech.finishCount == 1)
            precondition(target.committed == ["最终结果。"] && translations == 0 && c.state == .idle)
        }
        passed += 1
        do { // Release while model loads: preserve buffered audio and only finalize once.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            speech.setupDelay = 50
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: true) { $0 }
            await settle(5); audio.emit(7); c.release(); await settle(100)
            precondition(speech.feeds == 7 && target.committed.count == 1); passed += 1
        }
        do { // Press/release in the same tick must not start a lingering microphone.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: true) { $0 }
            c.release(); await settle()
            precondition(audio.starts == 0 && target.committed.isEmpty && c.state == .idle); passed += 1
        }
        for stage in ["setup", "listening", "finalizing"] {
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            speech.setupDelay = stage == "setup" ? 80 : 0
            speech.finishDelay = 80
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: true) { $0 }
            await settle(); audio.emit(1)
            if stage == "finalizing" { c.release(); await settle(5) }
            c.cancel(); c.cancel(); await settle(100)
            precondition(target.committed.isEmpty && target.cancels == 1 && c.state == .idle); passed += 1
        }
        do { // Old delayed final/partial must not contaminate a new session.
            let c = SessionCoordinator(), oldSpeech = FakeSpeech(), oldAudio = FakeCapture(), oldTarget = FakeTarget()
            oldSpeech.finishDelay = 80
            c.start(locale: .current, speech: oldSpeech, capture: oldAudio, target: oldTarget, passthrough: true) { $0 }
            await settle(); c.release(); await settle(5); c.cancel()
            let fresh = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            fresh.finalText = "new"
            c.start(locale: .current, speech: fresh, capture: audio, target: target, passthrough: true) { $0 }
            oldSpeech.onPartial?("stale")
            await settle(); audio.emit(1); c.release(); await settle(120)
            precondition(oldTarget.committed.isEmpty && target.committed == ["new"]); passed += 1
        }
        do { // Lost target cannot receive even the final result.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            var errors = 0; c.onError = { _ in errors += 1 }
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: true) { $0 }
            await settle(); target.isValid = false; c.release(); await settle()
            precondition(target.committed.isEmpty && errors == 1); passed += 1
        }
        do { // Translation failure cannot submit an older preview/source instead.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            var errors = 0; c.onError = { _ in errors += 1 }
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: false) { _ in throw SessionFailure.timeout }
            await settle(); c.release(); await settle()
            precondition(target.committed.isEmpty && errors == 1 && c.state == .idle); passed += 1
        }
        do { // Cancel in-flight translation; no late output or new-target write.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: false) { _ in
                try? await Task.sleep(for: .milliseconds(100)); return "late"
            }
            await settle(); c.release(); await settle(10); c.cancel(); await settle(120)
            precondition(target.committed.isEmpty); passed += 1
        }
        do {
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: false) { _ in "English final." }
            await settle(); audio.emit(2); c.release(); await settle(250)
            precondition(target.committed == ["English final."]); passed += 1
        }
        do { // Live translation must appear before release, then final replaces it once.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: false) { "EN:" + $0 }
            await settle(); speech.onPartial?("第一句")
            await settle(30)
            precondition(target.marked == ["EN:第一句"] && target.committed.isEmpty && c.state == .listening)
            speech.onPartial?("第一句，第二句")
            await settle(150)
            precondition(target.marked.last == "EN:第一句，第二句" && target.committed.isEmpty)
            c.release(); await settle(180)
            precondition(target.committed == ["EN:最终结果。"]); passed += 1
        }
        do { // Continuous ASR updates coalesce to newest full hypothesis, not stale words.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            var requests: [String] = []
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: false) { text in
                requests.append(text); try await Task.sleep(for: .milliseconds(40)); return "EN:" + text
            }
            await settle(); speech.onPartial?("one"); await settle(10)
            speech.onPartial?("two"); speech.onPartial?("three"); speech.onPartial?("three")
            await settle(240)
            precondition(requests == ["one", "three"] && target.marked.last == "EN:three")
            c.cancel(); passed += 1
        }
        do { // Corrections reach marked text during uninterrupted speech, before release.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: false) { "EN:" + $0 }
            await settle()
            for text in ["我想", "我想去上海", "我想去深圳", "我想去深圳开会"] {
                speech.onPartial?(text)
                await settle(25)
                precondition(target.marked.last == "EN:" + text && target.committed.isEmpty)
            }
            c.release(); await settle(100)
            precondition(target.committed == ["EN:最终结果。"]); passed += 1
        }
        do { // Cancelling visible marked text never commits it.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: false) { "EN:" + $0 }
            await settle(); speech.onPartial?("preview"); await settle(20)
            precondition(!target.marked.isEmpty)
            c.cancel(); await settle(160)
            precondition(target.committed.isEmpty && target.cancels == 1); passed += 1
        }
        do { // Optional editor receives the ORIGINAL and ordinary final draft, once.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            var calls = 0
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: false,
                polish: { original, draft in
                    calls += 1
                    precondition(original == "最终结果。" && draft == "ordinary translation")
                    return "polished translation"
                }) { _ in "ordinary translation" }
            await settle(); speech.onPartial?("temporary"); await settle(30)
            precondition(calls == 0 && target.committed.isEmpty)
            c.release(); await settle(160)
            precondition(calls == 1 && target.committed == ["polished translation"]); passed += 1
        }
        for empty in [false, true] { // Errors/empty outputs retain ordinary text, warn once.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            var warnings = 0; c.onError = { _ in warnings += 1 }
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: true,
                polish: { _, _ in if empty { return " " }; throw SessionFailure.timeout }) { $0 }
            await settle(); c.release(); await settle(40)
            precondition(target.committed == ["最终结果。"] && warnings == 1); passed += 1
        }
        do { // A provider ignoring cancellation cannot delay fallback or overwrite it later.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: true,
                polish: { _, _ in
                    await withCheckedContinuation { cont in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.18) { cont.resume() }
                    }
                    return "late AI output"
                }, polishTimeout: 0.025) { $0 }
            await settle(); c.release(); await settle(75)
            precondition(target.committed == ["最终结果。"] && c.state == .idle)
            await settle(200); precondition(target.committed.count == 1); passed += 1
        }
        for lost in [false, true] { // Esc/focus change during final editing never submits.
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: true,
                polish: { _, _ in try? await Task.sleep(for: .milliseconds(100)); return "AI output" }) { $0 }
            await settle(); c.release(); await settle(15)
            if lost { target.isValid = false } else { c.cancel() }
            await settle(150)
            precondition(target.committed.isEmpty && c.state == .idle); passed += 1
        }
        for outcome in [CompletionFeedback.ordinary, .polished, .unchanged, .polishFailed, .polishTimedOut] {
            let c = SessionCoordinator(), speech = FakeSpeech(), audio = FakeCapture(), target = FakeTarget()
            var feedback: [CompletionFeedback] = []
            var states: [SessionState] = []
            c.onState = { states.append($0) }
            c.onCompletion = { value in
                precondition(!target.committed.isEmpty, "Feedback must follow commit")
                feedback.append(value)
            }
            let polish: ((String, String) async throws -> String)? = outcome == .ordinary ? nil : { _, draft in
                if outcome == .polishTimedOut { try await Task.sleep(for: .seconds(1)) }
                if outcome == .polishFailed { throw SessionFailure.emptyResult }
                return outcome == .unchanged ? draft : "AI changed"
            }
            c.start(locale: .current, speech: speech, capture: audio, target: target, passthrough: true,
                    polish: polish, polishTimeout: 0.03) { $0 }
            await settle(); c.release(); await settle(120)
            precondition(feedback == [outcome])
            precondition(states.contains(.polishing) == (outcome != .ordinary))
            passed += 1
        }
        print("PASS: \(passed) session scenarios, including 20 consecutive drain/commit cycles")
    }
}
