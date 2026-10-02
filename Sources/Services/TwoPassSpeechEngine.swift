import AVFoundation
import Foundation

/// A recognizer that also says where each settled stretch of text ends in the recording.
@MainActor protocol SegmentingSpeechRecognizing: SpeechRecognizing {
    var onSegment: ((_ end: Double, _ text: String) -> Void)? { get set }
}

/// Two passes, the way cloud dictation does it, on this Mac. The system's
/// recognizer shows the words while they are spoken; the downloaded model,
/// which gets far more of them right, writes the text. On 150 recordings of
/// real speech the system's recognizer got 5.2% of the characters wrong and
/// Qwen3-ASR 2.0%; a ten-second sentence takes the model a third of a second.
///
/// A long dictation is handed to the model in stretches that end where the
/// system's recognizer settled a sentence, so that only the last stretch is
/// left to do when the key is released. If the model fails or takes too long,
/// what the system's recognizer heard is written instead.
@MainActor final class TwoPassSpeechEngine: SpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)? {
        didSet { solo?.onPartial = onPartial }
    }

    /// The second pass over one stretch of 16 kHz mono audio. `hints` are the
    /// Latin-letter terms the system's recognizer heard in it.
    typealias Transcribe = @Sendable ([Float], Locale, [String]) async throws -> String
    /// Whether the model is told which terms the system's recognizer heard.
    /// Off: on 54 real sentences with numbers and names it changed three, one
    /// for the better ("802.11G") and one for the worse (the system's
    /// mishearing "Scooter" replaced the model's correct "Scotturb").
    var hintsEnabled = false
    private var lastLiveText = ""

    private let live: any SegmentingSpeechRecognizing
    private let prepare: (Locale) async throws -> Void
    private var locale = Locale(identifier: "zh-CN")
    private let transcribe: Transcribe
    private let makeSolo: () -> any SpeechRecognizing
    private let budget: (Double) -> Double
    /// The model on its own, when the system has no recognizer for the language.
    private var solo: (any SpeechRecognizing)?

    private var audio = QwenAudioBuffer()
    /// Samples already handed to the second pass.
    private var dropped = 0
    /// What the system's recognizer settled since the last cut: the text to fall back on.
    private var liveSinceCut = ""
    private var pieces: [Piece] = []
    private var queue: Task<Void, Never>?
    /// For diagnostics: the length in seconds of each stretch handed to the second pass.
    var onStretch: ((Double) -> Void)?
    /// For diagnostics: who wrote the final text, and how long the last stretch took.
    var onOutcome: ((String) -> Void)?
    private var generation = 0
    private var active = false
    /// The model being made ready; a dictation does not wait for it to start.
    private var preparation: Task<Bool, Never>?

    /// A stretch is handed over once this much audio has gathered and a sentence has ended.
    static let stretchSeconds = 12.0
    /// With no sentence end in sight it is handed over anyway before the buffer is full.
    static let hardCutSeconds = 26.0
    /// How long the last stretch may take before the system's text is written instead.
    nonisolated static func budget(_ audioSeconds: Double) -> Double { 2.5 + audioSeconds * 0.2 }

    private final class Piece {
        var text: String?
        var failed = false
        let fallback: String?
        init(fallback: String?) { self.fallback = fallback }
    }

    init(live: any SegmentingSpeechRecognizing, prepare: @escaping (Locale) async throws -> Void,
         transcribe: @escaping Transcribe, makeSolo: @escaping () -> any SpeechRecognizing,
         budget: @escaping (Double) -> Double = TwoPassSpeechEngine.budget) {
        self.budget = budget
        self.live = live
        self.prepare = prepare
        self.transcribe = transcribe
        self.makeSolo = makeSolo
    }

    func begin(locale: Locale) async throws {
        generation += 1
        let token = generation
        active = false
        audio = QwenAudioBuffer()
        // `queue` is kept: a decode still running from the last dictation ends before the next one starts.
        dropped = 0; liveSinceCut = ""; pieces = []; solo = nil
        self.locale = locale
        lastLiveText = ""
        do {
            live.onPartial = { [weak self] hypothesis in
                self?.lastLiveText = hypothesis.text
                self?.onPartial?(hypothesis)
            }
            live.onSegment = { [weak self] end, text in self?.settled(end: end, text: text, token: token) }
            try await live.begin(locale: locale)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No system recognizer for this language: the model works alone, as it did before.
            guard generation == token else { throw CancellationError() }
            let solo = makeSolo()
            solo.onPartial = onPartial
            self.solo = solo
            try await solo.begin(locale: locale)
            return
        }
        guard generation == token else { throw CancellationError() }
        // Normally the model is loaded already. When it is not, the words still
        // appear at once; if it cannot be loaded they are written as the system heard them.
        let prepare = self.prepare
        preparation = Task {
            do { try await prepare(locale); return true } catch { return false }
        }
        active = true
    }

    func feed(_ buffer: AVAudioPCMBuffer) throws {
        if let solo { try solo.feed(buffer); return }
        guard active else { throw CancellationError() }
        try live.feed(buffer)
        do {
            try audio.append(buffer)
        } catch is SpeechLengthLimitReached {
            cut(at: audio.samples.count, fallback: nil)
            try? audio.append(buffer)
        }
        if Double(audio.samples.count) / QwenAudioBuffer.sampleRate >= Self.hardCutSeconds {
            cut(at: audio.samples.count, fallback: nil)
        }
    }

    func finish() async throws -> String {
        if let solo { return LatinWriting.tidied(try await solo.finish(), system: "") }
        guard active else { throw CancellationError() }
        active = false
        let token = generation
        let tail = audio.samples
        audio = QwenAudioBuffer()
        let tailSeconds = Double(tail.count) / QwenAudioBuffer.sampleRate
        // The recording is complete: the last stretch starts now, while the system's recognizer finishes.
        let last: Piece? = tail.count >= 400 && tail.contains(where: { abs($0) > 0.00001 })
            ? enqueue(tail, fallback: nil, heard: lastLiveText + liveSinceCut) : nil
        let released = ProcessInfo.processInfo.systemUptime
        let liveText = try await live.finish()
        guard generation == token else { throw CancellationError() }
        let liveTail = liveSinceCut
        func report(_ writer: String) {
            onOutcome?(String(format: "%@ stretches=%d last=%.1fs waited=%.0fms", writer, pieces.count, tailSeconds,
                              (ProcessInfo.processInfo.systemUptime - released) * 1000))
        }
        // Never leave a decode running into the next dictation: a new request would cancel it.
        let finished = await drain(within: budget(tailSeconds))
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        // Nothing was said, as far as the system's recognizer can tell: a model asked to transcribe noise invents words.
        guard !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { report("nothing-heard"); return "" }
        guard finished else { report("system:model-too-slow"); return liveText }
        var parts: [String] = []
        for piece in pieces where piece !== last {
            if let fallback = piece.fallback, fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let text = piece.text, !piece.failed else {
                guard let fallback = piece.fallback else { report("system:model-failed"); return liveText }
                parts.append(fallback)
                continue
            }
            parts.append(text)
        }
        if let last {
            if liveTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The system's recognizer heard nothing in the last stretch.
            } else if let text = last.text, !last.failed {
                parts.append(text)
            } else {
                parts.append(liveTail)
                report("system:model-failed")
                return Self.written(Self.join(parts), system: liveText)
            }
        }
        report("model")
        let result = Self.join(parts)
        return result.isEmpty ? liveText : Self.written(result, system: liveText)
    }

    /// The model's text the way it is written: letters said one by one stand
    /// together ("APP"), names keep their own spelling ("ChatGPT"), and numbers
    /// are digits where the system's recognizer heard the same number ("M1", "36G").
    nonisolated static func written(_ model: String, system: String) -> String {
        NumeralFormat.followingSystem(model: LatinWriting.tidied(model, system: system), system: system)
    }

    func cancel() async {
        generation += 1
        active = false
        if let solo { await solo.cancel(); self.solo = nil }
        await live.cancel()
        // The decode in flight is left to end by itself: cancelling it would end the model's process.
        await queue?.value
        audio = QwenAudioBuffer()
        pieces = []
        liveSinceCut = ""
    }

    // MARK: - Stretches

    private func settled(end: Double, text: String, token: Int) {
        guard generation == token else { return }
        liveSinceCut += text
        guard active else { return }
        let index = Int(end * QwenAudioBuffer.sampleRate) - dropped
        guard index > 0, Double(index) / QwenAudioBuffer.sampleRate >= Self.stretchSeconds else { return }
        cut(at: min(index, audio.samples.count), fallback: liveSinceCut)
    }

    /// Hand the audio up to `index` to the second pass and keep the rest.
    private func cut(at index: Int, fallback: String?) {
        let samples = audio.samples
        guard index > 0, index <= samples.count else { return }
        let rest = Array(samples[index...])
        audio = QwenAudioBuffer()
        audio.restore(rest)
        dropped += index
        liveSinceCut = ""
        let stretch = Array(samples[..<index])
        guard stretch.contains(where: { abs($0) > 0.00001 }) else { return }
        _ = enqueue(stretch, fallback: fallback, heard: fallback ?? lastLiveText)
    }

    /// One decode at a time, in order.
    private func enqueue(_ samples: [Float], fallback: String?, heard: String) -> Piece {
        let hints = hintsEnabled ? Self.terms(in: heard) : []
        let piece = Piece(fallback: fallback)
        pieces.append(piece)
        onStretch?(Double(samples.count) / QwenAudioBuffer.sampleRate)
        let previous = queue
        let transcribe = self.transcribe
        let locale = self.locale
        let preparation = self.preparation
        queue = Task { [weak self] in
            await previous?.value
            guard await preparation?.value == true else { piece.failed = true; return }
            do {
                let text = try await transcribe(Self.leveled(samples), locale, hints)
                guard self != nil else { return }
                piece.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                piece.failed = true
            }
        }
        return piece
    }

    /// The terms written in Latin letters in a text ("iPhone 15 Pro", "USB-C"), at most twelve.
    nonisolated static func terms(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9+#.\\-]*(?: ?[A-Za-z0-9][A-Za-z0-9+#.\\-]*)*") else { return [] }
        var seen = Set<String>(), result: [String] = []
        let string = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let term = string.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
            guard term.count >= 2, seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == 12 { break }
        }
        return result
    }

    /// A quiet recording is brought up to an ordinary level before the model
    /// hears it (30 dB below ordinary speech costs the model about a fifth more
    /// mistakes; nothing is gained above that). Never more than 30 times.
    nonisolated static func leveled(_ samples: [Float]) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.0005, peak < 0.1 else { return samples }
        let gain = min(0.3 / peak, 30)
        return samples.map { $0 * gain }
    }

    /// Wait for every stretch, at most `seconds`. False when time ran out.
    private func drain(within seconds: Double) async -> Bool {
        guard let queue else { return true }
        // Not a task group: a group would wait for the decode it is trying not to wait for.
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        Task { await queue.value; continuation.yield(true) }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            continuation.yield(false)
        }
        var finished = true
        for await first in stream { finished = first; break }
        timer.cancel()
        return finished
    }

    /// Chinese joins as it is; words written with spaces get one between the stretches.
    static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if let last = result.unicodeScalars.last, let first = part.unicodeScalars.first,
               last.properties.isAlphabetic || CharacterSet.decimalDigits.contains(last) || ".,!?;:".unicodeScalars.contains(last),
               !isIdeographic(last), !isIdeographic(first) {
                result += " "
            }
            result += part
        }
        return result
    }

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
    }
}
