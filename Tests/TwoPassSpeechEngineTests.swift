import AVFoundation
import Foundation

@MainActor final class ScriptedLive: SegmentingSpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)?
    var onSegment: ((Double, String) -> Void)?
    var failBegin = false
    var feeds = 0
    var cancels = 0
    /// Settled when the recording ends: (end, text).
    var atFinish: [(Double, String)] = []
    var said = ""
    func begin(locale: Locale) async throws { if failBegin { throw SpeechEngineError.unsupportedLocale } }
    func feed(_ buffer: AVAudioPCMBuffer) throws { feeds += 1 }
    func settle(_ end: Double, _ text: String) { said += text; onSegment?(end, text) }
    func finish() async throws -> String {
        try await Task.sleep(for: .milliseconds(5))
        for (end, text) in atFinish { settle(end, text) }
        return said
    }
    func cancel() async { cancels += 1 }
}

@MainActor final class Solo: SpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)?
    var began = 0
    func begin(locale: Locale) async throws { began += 1 }
    func feed(_ buffer: AVAudioPCMBuffer) throws {}
    func finish() async throws -> String { "模型独自听写。" }
    func cancel() async {}
}

/// What the second pass was asked to do, from any thread.
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var lengths: [Int] = []
    private var running = 0
    private(set) var overlapped = false
    func enter(_ count: Int) { lock.lock(); lengths.append(count); running += 1; if running > 1 { overlapped = true }; lock.unlock() }
    func leave() { lock.lock(); running -= 1; lock.unlock() }
    var seconds: [Double] { lock.lock(); defer { lock.unlock() }; return lengths.map { (Double($0) / 16_000 * 10).rounded() / 10 } }
}

@main struct TwoPassTests {
    static let locale = Locale(identifier: "zh-CN")

    @MainActor static func second(of level: Float = 0.2) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = level * sin(Float(i) * 0.05) }
        return buffer
    }

    @MainActor static func engine(_ live: ScriptedLive, calls: Calls = Calls(), solo: Solo? = nil,
                                  prepareFails: Bool = false, budget: Double = 5, delay: Int = 5,
                                  answer: @escaping @Sendable (Int) throws -> String) -> TwoPassSpeechEngine {
        TwoPassSpeechEngine(live: live,
            prepare: { _ in if prepareFails { throw ASRModelError.missing } },
            transcribe: { samples, _, _ in
                calls.enter(samples.count)
                defer { calls.leave() }
                try await Task.sleep(for: .milliseconds(delay))
                return try answer(samples.count)
            },
            makeSolo: { solo ?? Solo() }, budget: { _ in budget })
    }

    @MainActor static func main() async throws {
        var passed = 0
        func check(_ condition: Bool, _ what: String) { precondition(condition, what); passed += 1 }

        do { // A sentence: the system's recognizer shows it, the model writes it.
            let live = ScriptedLive(), calls = Calls()
            live.atFinish = [(3, "他受到了黄根诚的欢迎。")]
            let e = engine(live, calls: calls) { _ in "他受到了黄根成的欢迎。" }
            var previews: [String] = []
            e.onPartial = { previews.append($0.text) }
            try await e.begin(locale: locale)
            for _ in 0..<3 { try e.feed(second()) }
            live.onPartial?(SpeechHypothesis(volatileText: "他受到了"))
            let text = try await e.finish()
            check(text == "他受到了黄根成的欢迎。", "the model's text is written")
            check(previews == ["他受到了"], "the preview is the system recognizer's")
            check(calls.seconds == [3.0] && live.feeds == 3, "the whole recording goes to the model once")
        }
        do { // The model spells numbers out; the system's way of writing them is kept.
            let live = ScriptedLive(); live.atFinish = [(3, "这个输入法在 M1芯片的机器上")]
            let e = engine(live) { _ in "这个输入法在M一芯片的机器上。" }
            try await e.begin(locale: locale)
            for _ in 0..<3 { try e.feed(second()) }
            check(try await e.finish() == "这个输入法在M1芯片的机器上。", "numbers are written the way the system writes them")
        }
        do { // The model fails: what the system's recognizer heard is written.
            let live = ScriptedLive(); live.atFinish = [(2, "你好，世界。")]
            let e = engine(live) { _ in throw ASRModelError.missing }
            try await e.begin(locale: locale)
            for _ in 0..<2 { try e.feed(second()) }
            check(try await e.finish() == "你好，世界。", "a failed second pass falls back")
        }
        do { // The model is too slow.
            let live = ScriptedLive(); live.atFinish = [(2, "你好，世界。")]
            let e = engine(live, budget: 0.05, delay: 400) { _ in "迟到的结果。" }
            try await e.begin(locale: locale)
            for _ in 0..<2 { try e.feed(second()) }
            let started = Date()
            check(try await e.finish() == "你好，世界。", "a slow second pass falls back")
            check(Date().timeIntervalSince(started) < 0.3, "and does not hold the text back")
            await e.cancel()
        }
        do { // Nothing was said: a model asked about noise invents words; they are not written.
            let live = ScriptedLive()
            let e = engine(live) { _ in "谢谢观看。" }
            try await e.begin(locale: locale)
            for _ in 0..<2 { try e.feed(second(of: 0.001)) }
            check(try await e.finish() == "", "silence stays silent")
        }
        do { // A long dictation: stretches go to the model while it is being spoken.
            let live = ScriptedLive(), calls = Calls()
            let e = engine(live, calls: calls) { count in count > 16_000 * 10 ? "第一段，说了很久。" : "第二段。" }
            try await e.begin(locale: locale)
            for _ in 0..<6 { try e.feed(second()) }
            live.settle(5.5, "第一句")
            check(calls.seconds.isEmpty, "a short stretch waits")
            for _ in 0..<8 { try e.feed(second()) }
            live.settle(13.5, "说了很久")
            try await Task.sleep(for: .milliseconds(40))
            check(calls.seconds == [13.5], "a sentence end past twelve seconds hands the stretch over")
            for _ in 0..<3 { try e.feed(second()) }
            live.atFinish = [(17, "第二段")]
            let text = try await e.finish()
            check(calls.seconds == [13.5, 3.5], "only the rest is left at the release")
            check(text == "第一段，说了很久。第二段。", "the stretches are joined in order")
            check(!calls.overlapped, "one decode at a time")
        }
        do { // No pause for a long time: the stretch is cut before the buffer is full.
            let live = ScriptedLive(), calls = Calls()
            let e = engine(live, calls: calls) { _ in "一段" }
            try await e.begin(locale: locale)
            for _ in 0..<40 { try e.feed(second()) }
            live.atFinish = [(40, "一直说一直说")]
            let text = try await e.finish()
            check(calls.seconds == [26.0, 14.0], "forty seconds without a pause are two stretches")
            check(text == "一段一段", "and both are written")
        }
        do { // A stretch failed in the middle of a long dictation: its own fallback is used.
            let live = ScriptedLive()
            let e = engine(live) { count in if count > 16_000 * 10 { throw ASRModelError.missing }; return "结尾。" }
            try await e.begin(locale: locale)
            for _ in 0..<13 { try e.feed(second()) }
            live.settle(13, "开头很长，")
            for _ in 0..<2 { try e.feed(second()) }
            live.atFinish = [(15, "结尾")]
            check(try await e.finish() == "开头很长，结尾。", "a failed stretch is written the way the system heard it")
        }
        do { // No system recognizer for the language: the model alone.
            let live = ScriptedLive(), solo = Solo(); live.failBegin = true
            let e = engine(live, solo: solo) { _ in "" }
            try await e.begin(locale: locale)
            try e.feed(second())
            check(try await e.finish() == "模型独自听写。" && solo.began == 1, "the model works alone")
        }
        do { // The model cannot be loaded: the system's recognizer alone.
            let live = ScriptedLive(), calls = Calls(); live.atFinish = [(1, "只有系统识别。")]
            let e = engine(live, calls: calls, prepareFails: true) { _ in "不该出现" }
            try await e.begin(locale: locale)
            try e.feed(second())
            check(try await e.finish() == "只有系统识别。" && calls.seconds.isEmpty, "no model, no second pass")
        }
        do { // Cancelling waits for the decode in flight instead of killing the model's process.
            let live = ScriptedLive(), calls = Calls()
            let e = engine(live, calls: calls, delay: 60) { _ in "……" }
            try await e.begin(locale: locale)
            for _ in 0..<13 { try e.feed(second()) }
            live.settle(13, "很长的一段")
            try await Task.sleep(for: .milliseconds(10))
            let started = Date()
            await e.cancel()
            check(Date().timeIntervalSince(started) > 0.03 && live.cancels == 1, "cancel lets the decode end")
        }
        check(TwoPassSpeechEngine.terms(in: "我用的是 iPhone 15 Pro系统是 iOS 18，接口是 USB-C，还有 iphone 15 pro 和 A17") == ["iPhone 15 Pro", "iOS 18", "USB-C", "A17"],
              "the Latin terms of a text: \(TwoPassSpeechEngine.terms(in: "我用的是 iPhone 15 Pro系统是 iOS 18，接口是 USB-C，还有 iphone 15 pro 和 A17"))")
        check(TwoPassSpeechEngine.terms(in: "今天下午三点开会。").isEmpty, "none in plain Chinese")
        let quiet = TwoPassSpeechEngine.leveled([0.01, -0.02, 0.005]), loud = TwoPassSpeechEngine.leveled([0.2, -0.4])
        check(abs(quiet[1] + 0.3) < 0.001 && loud == [0.2, -0.4], "a quiet stretch is brought up, an ordinary one is left alone")
        check(TwoPassSpeechEngine.leveled([0.0001, 0]) == [0.0001, 0], "silence is not amplified")
        check(TwoPassSpeechEngine.join(["你好。", "世界。"]) == "你好。世界。", "Chinese joins as it is")
        check(TwoPassSpeechEngine.join(["Hello there.", "Next one"]) == "Hello there. Next one", "English gets a space")
        check(TwoPassSpeechEngine.join(["用 Mac", "写字"]) == "用 Mac写字", "no space before Chinese")
        print("TwoPassSpeechEngineTests: \(passed) checks passed")
    }
}
