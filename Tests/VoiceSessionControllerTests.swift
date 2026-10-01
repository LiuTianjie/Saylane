import AppKit
import AVFoundation
import Carbon.HIToolbox

@MainActor private final class Audio: AudioCapturing {
    var starts = 0
    var running = false
    var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    func startStream() throws -> AsyncThrowingStream<AudioFrame, Error> {
        let pair = AsyncThrowingStream<AudioFrame, Error>.makeStream()
        continuation = pair.continuation
        starts += 1; running = true
        return pair.stream
    }
    func emit(_ count: Int = 3) {
        guard running else { return }
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

@MainActor private final class Speech: SpeechRecognizing {
    var onPartial: ((SpeechHypothesis) -> Void)?
    var feeds = 0
    func partial(_ text: String) { onPartial?(SpeechHypothesis(volatileText: text)) }
    func begin(locale: Locale) async throws { try await Task.sleep(for: .milliseconds(10)) }
    func feed(_ buffer: AVAudioPCMBuffer) throws { feeds += 1 }
    func finish() async throws -> String { feeds > 0 ? "voice result" : "" }
    func cancel() async {}
}

@MainActor private final class Destination: CompositionTarget {
    var isValid = true
    var commits: [String] = []
    func setMarked(_ text: String) {}
    func commit(_ text: String) { commits.append(text) }
    func cancelMarked() {}
}

@MainActor private final class Platform {
    var front: String? = "editor"
    var frontPID: pid_t? = 1234
    var trace: [String] = []
    var environment: VoiceInputEnvironment {
        VoiceInputEnvironment(ownBundleID: "saylane",
            frontmostBundleID: { self.front }, frontmostPID: { self.frontPID },
            trace: { self.trace.append("\($0) \($1)") })
    }
}

/// The three ways a dictation can be written, each switchable per scenario.
@MainActor private final class Writer {
    var imkAttached = true
    var pasteAllowed = true
    var marked: [String] = []
    var clears = 0
    var inserted: [String] = []
    var pasted: [String] = []
    var copied: [String] = []
    var requestedBundles: [String?] = []
    func sink(inFront bundleID: String?) -> VoiceTextSink {
        requestedBundles.append(bundleID)
        return VoiceTextSink(
            setMarked: { text in
                guard self.imkAttached else { return false }
                self.marked.append(text); return true
            },
            clearMarked: { self.clears += 1 },
            insert: { text in
                guard self.imkAttached else { return false }
                self.inserted.append(text); return true
            },
            paste: { text in
                guard self.pasteAllowed else { return false }
                self.pasted.append(text); return true
            },
            copy: { self.copied.append($0) })
    }
}

@MainActor private final class Host: VoiceSessionHost {
    var prefs = Preferences()
    var readinessState = Readiness()
    var isVoiceTrialActive = false
    let writer = Writer()
    let trialTarget = Destination()
    var speeches: [Speech] = []
    var notices: [UserNotice] = []
    var completions: [Bool] = []
    var trialCaptures = 0
    var onState: (() -> Void)?
    var onEnd: (() -> Void)?
    init() {
        prefs.sourceLanguage = .zhHans; prefs.targetLanguage = .zhHans
        prefs.overlayEnabled = false
        readinessState.permissions.microphone = .granted
        readinessState.models.speechReady = true
        readinessState.models.translationReady = true
        readinessState.inputSource = .init(installedLocation: true, installed: true, enabled: true, selected: true)
    }
    func refreshInputSourceStatus() {}
    func makeSpeechEngine() -> any SpeechRecognizing { let speech = Speech(); speeches.append(speech); return speech }
    func makeRefine() -> ((String) -> String)? { nil }
    func makePolish() -> ((String, String) async throws -> String)? { nil }
    func textSink(inFront bundleID: String?) -> VoiceTextSink { writer.sink(inFront: bundleID) }
    func settingsCaptureTarget() -> (any CompositionTarget)? { trialCaptures += 1; return trialTarget }
    func post(_ notice: UserNotice) { notices.append(notice) }
    func voiceSessionDidEnd(committed: Bool) { completions.append(committed); onEnd?() }
    func voiceSessionStateDidChange() { onState?() }
    func commitPinyinBeforeVoice() {}
    func translate(_ text: String) async throws -> String { text }
}

@MainActor private final class Fixture {
    let platform = Platform()
    let audio = Audio()
    let host = Host()
    let voice: VoiceSessionController
    var writer: Writer { host.writer }
    init() {
        let audio = self.audio
        voice = VoiceSessionController(coordinator: SessionCoordinator(previewInterval: 0),
            overlay: OverlayController(displaysPanel: false),
            environment: platform.environment, makeCapture: { PrerollCapture(underlying: audio, limit: $0) })
        voice.host = host
    }
}

@main struct VoiceSessionControllerTests {
    @MainActor static func settleUntil(_ predicate: () -> Bool, limit: Int = 150) async throws {
        for _ in 0..<limit {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(predicate(), "state transition timed out")
    }

    /// Press, speak, release, and wait for the session to end.
    @MainActor private static func dictate(_ f: Fixture, during: () -> Void = {}) async throws {
        f.voice.press(); f.audio.emit(4)
        try await settleUntil { f.voice.state == .listening }
        during()
        f.voice.release()
        try await settleUntil { !f.voice.isListening }
    }

    @MainActor static func main() async throws {
        var passed = 0
        do { // An abandoned right-Command hold stops mic/preroll immediately.
            let f = Fixture()
            let router = InputEventRouter()
            router.updateContext { $0.trigger = .rightCommand; $0.globalEventsCanBeConsumed = true }
            f.host.onState = { router.updateContext {
                $0.isListening = f.voice.isListening
                $0.voiceCapturing = f.voice.isCapturing
            } }
            router.onAction = { action in
                switch action {
                case .voice(.armHold), .voice(.armTap): f.voice.arm()
                case .voice(.disarm): f.voice.disarm()
                case .voice(.press): f.voice.press()
                case .voice(.release): f.voice.release()
                case .voice(.cancel): f.voice.cancel()
                default: break
                }
            }
            func command(_ down: Bool) -> InputEvent {
                .init(source: .imk, type: .flagsChanged, keyCode: UInt16(kVK_RightCommand),
                      flags: down ? UInt64(NSEvent.ModifierFlags.command.rawValue) | PushToTalkHotkey.rightCommand.deviceMask : 0,
                      isRepeat: false, timestamp: ProcessInfo.processInfo.systemUptime)
            }
            _ = router.feed(command(true)); f.audio.emit(7)
            try await Task.sleep(for: .milliseconds(15))
            _ = router.feed(command(false))
            precondition(!f.audio.running && f.host.speeches.isEmpty)
            _ = router.feed(command(true)); f.audio.emit(2)
            try await settleUntil { f.voice.state == .listening }
            _ = router.feed(command(false))
            try await settleUntil { !f.voice.isListening }
            precondition(f.audio.starts == 2 && f.host.speeches.first?.feeds == 2,
                         "a short earlier tap contaminated the next preroll")
            passed += 1
        }
        do { // Attached IMK client: preview as marked text, final text inserted through it.
            let f = Fixture()
            var states: [SessionState] = []
            f.host.onState = { states.append(f.voice.state) }
            try await dictate(f) { f.host.speeches[0].partial("voice") }
            precondition(f.writer.marked == ["voice"] && f.writer.inserted == ["voice result"])
            precondition(f.writer.pasted.isEmpty && f.writer.copied.isEmpty && f.host.notices.isEmpty)
            precondition(states.contains(.preparing) && states.contains(.listening) && states.last == .idle)
            precondition(f.host.completions == [true] && !f.audio.running && f.host.speeches[0].feeds == 4)
            precondition(f.writer.requestedBundles == ["editor"] && f.voice.lastDictation == "voice result")
            passed += 1
        }
        do { // No IMK client (another input source, or an app that never attaches): paste, at once.
            let f = Fixture()
            f.writer.imkAttached = false
            f.host.readinessState.inputSource.selected = false
            f.host.readinessState.globalInvokeAvailable = true
            f.voice.press()
            precondition(f.voice.isListening, "a press without an IMK client must start immediately")
            f.audio.emit(4)
            try await settleUntil { f.voice.state == .listening }
            f.host.speeches[0].partial("voice")
            f.voice.release()
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.pasted == ["voice result"] && f.writer.inserted.isEmpty && f.writer.marked.isEmpty)
            precondition(f.writer.copied.isEmpty && f.host.notices.isEmpty && f.host.completions == [true])
            passed += 1
        }
        do { // Neither route: the text is kept on the pasteboard and the user is told how to fix it.
            let f = Fixture()
            f.writer.imkAttached = false; f.writer.pasteAllowed = false
            try await dictate(f)
            precondition(f.writer.copied == ["voice result"] && f.writer.pasted.isEmpty && f.writer.inserted.isEmpty)
            precondition(f.host.notices.count == 1 && f.host.notices[0].level == .actionable
                         && f.host.notices[0].destination == .permissions)
            precondition(f.host.completions == [true] && f.voice.lastDictation == "voice result")
            passed += 1
        }
        do { // Accessibility is allowed but the keystroke could not be posted: no permission nag.
            let f = Fixture()
            f.writer.imkAttached = false; f.writer.pasteAllowed = false
            f.host.readinessState.permissions.accessibility = true
            try await dictate(f)
            precondition(f.writer.copied == ["voice result"])
            precondition(f.host.notices.count == 1 && f.host.notices[0].level == .transient)
            passed += 1
        }
        do { // The client goes away mid-utterance (click, focus move): keep recording, paste the result.
            let f = Fixture()
            try await dictate(f) {
                f.host.speeches[0].partial("voice")
                f.writer.imkAttached = false
                f.host.speeches[0].partial("voice res")
            }
            precondition(f.writer.marked == ["voice"] && f.writer.inserted.isEmpty)
            precondition(f.writer.pasted == ["voice result"] && f.host.completions == [true])
            passed += 1
        }
        do { // A preview still showing when IMK stops accepting writes is withdrawn before pasting.
            let f = Fixture()
            f.voice.press(); f.audio.emit(4)
            try await settleUntil { f.voice.state == .listening }
            f.host.speeches[0].partial("voice")
            f.voice.release()
            f.writer.imkAttached = false
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.clears == 1 && f.writer.pasted == ["voice result"])
            passed += 1
        }
        do { // The client attaches after the press: the final text still goes through it.
            let f = Fixture()
            f.writer.imkAttached = false
            try await dictate(f) { f.writer.imkAttached = true }
            precondition(f.writer.inserted == ["voice result"] && f.writer.pasted.isEmpty)
            passed += 1
        }
        do { // Key-up before the recognizer is ready stops hardware but keeps the utterance.
            let f = Fixture()
            f.voice.press(); f.audio.emit(5); f.voice.release()
            precondition(!f.audio.running, "key-up must stop the microphone at once")
            try await settleUntil { !f.voice.isListening }
            precondition(f.host.speeches.first?.feeds == 5 && f.writer.inserted == ["voice result"] && f.audio.starts == 1)
            passed += 1
        }
        do { // A dictation is never written into another application, and never thrown away either.
            let f = Fixture()
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.platform.front = "anotherEditor"; f.platform.frontPID = 5678
            f.voice.frontmostAppChanged(to: "anotherEditor", pid: 5678)
            precondition(!f.audio.running, "switching applications must stop the microphone")
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.inserted.isEmpty && f.writer.pasted.isEmpty && f.writer.copied == ["voice result"])
            precondition(f.host.notices.count == 1 && f.host.notices[0].level == .transient)
            precondition(f.voice.lastDictation == "voice result" && f.host.completions == [true])
            passed += 1
        }
        do { // Even if the activation notification is missed, the result is not written elsewhere.
            let f = Fixture()
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.platform.frontPID = 5678
            f.voice.release()
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.inserted.isEmpty && f.writer.pasted.isEmpty && f.writer.copied == ["voice result"])
            passed += 1
        }
        do { // Coming back before the result is ready writes it where it belongs.
            let f = Fixture()
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.platform.frontPID = 5678
            f.voice.frontmostAppChanged(to: "anotherEditor", pid: 5678)
            f.platform.frontPID = 1234
            f.voice.frontmostAppChanged(to: "editor", pid: 1234)
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.inserted == ["voice result"] && f.writer.copied.isEmpty && f.host.notices.isEmpty)
            passed += 1
        }
        do { // A blocked start records nothing and reports the reason once.
            let f = Fixture()
            f.host.readinessState.models.speechReady = false
            f.voice.press()
            precondition(!f.voice.isListening && !f.audio.running && f.host.speeches.isEmpty)
            precondition(f.host.notices.count == 1 && f.host.completions == [false])
            passed += 1
        }
        do { // Only the focused trial page may capture speech into the settings field.
            let f = Fixture()
            f.platform.front = "saylane"; f.host.isVoiceTrialActive = true; f.writer.imkAttached = false
            try await dictate(f)
            precondition(f.host.trialCaptures == 1 && f.writer.requestedBundles.isEmpty)
            precondition(f.host.trialTarget.commits == ["voice result"] && f.writer.pasted.isEmpty)
            passed += 1
        }
        do { // Opening Saylane settings ends an editor session without writing into the settings window.
            let f = Fixture()
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.platform.front = "saylane"; f.platform.frontPID = 9999
            f.voice.frontmostAppChanged(to: "saylane", pid: 9999)
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.inserted.isEmpty && f.writer.pasted.isEmpty && f.writer.copied == ["voice result"])
            passed += 1
        }
        do { // Router + voice, with state updates exactly as the composition root wires them.
            let f = Fixture()
            let router = InputEventRouter()
            router.updateContext { $0.trigger = .f20; $0.tapToTalk = true }
            f.host.onState = { router.updateContext {
                $0.isListening = f.voice.isListening
                $0.voiceCapturing = f.voice.isCapturing
                $0.globalEventsCanBeConsumed = true
            } }
            f.host.onEnd = { router.reset(); router.updateContext { $0.isListening = false; $0.voiceCapturing = false } }
            router.onAction = { action in
                switch action {
                case .voice(.press): f.voice.press()
                case .voice(.release): f.voice.release()
                case .voice(.cancel): f.voice.cancel()
                default: break
                }
            }
            func key(_ code: UInt16, _ type: NSEvent.EventType, _ time: Double) -> InputEvent {
                .init(source: .imk, type: type, keyCode: code, flags: 0, isRepeat: false, timestamp: time)
            }
            _ = router.feed(key(UInt16(kVK_F20), .keyDown, 1))
            _ = router.feed(key(UInt16(kVK_F20), .keyUp, 1.05))
            f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            precondition(router.context.isListening)
            _ = router.feed(key(UInt16(kVK_F20), .keyDown, 2))
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.inserted.count == 1 && !router.context.isListening)
            _ = router.feed(key(UInt16(kVK_F20), .keyUp, 2.05))
            _ = router.feed(key(UInt16(kVK_F20), .keyDown, 3))
            precondition(f.voice.isListening && router.context.isListening)
            _ = router.feed(key(UInt16(kVK_Escape), .keyDown, 3.1))
            try await settleUntil { !f.voice.isListening }
            precondition(!f.audio.running && !router.context.isListening && f.writer.inserted.count == 1)
            passed += 1
        }
        print("PASS: \(passed) voice-controller scenarios: IMK, paste and pasteboard delivery, lost and late clients, quick release, focus, trial routing, toggle/Esc")
    }
}
