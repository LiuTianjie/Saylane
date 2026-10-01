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

@MainActor private final class Platform {
    var front: String? = "editor"
    var frontPID: pid_t? = 1234
    var trace: [String] = []
    var environment: VoiceInputEnvironment {
        VoiceInputEnvironment(
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
    var sessions: [UUID] = []
    var ended: [UUID] = []
    func sink(inFront bundleID: String?, session: UUID) -> VoiceTextSink {
        requestedBundles.append(bundleID)
        sessions.append(session)
        return VoiceTextSink(
            attached: { self.imkAttached },
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
            copy: { self.copied.append($0) },
            end: { self.ended.append(session) })
    }
}

@MainActor private final class Host: VoiceSessionHost {
    var prefs = Preferences()
    var readinessState = Readiness()
    var voiceReadiness: Readiness { readinessState }
    let writer = Writer()
    var speeches: [Speech] = []
    var notices: [UserNotice] = []
    var completions: [Bool] = []
    var onState: (() -> Void)?
    var onEnd: (() -> Void)?
    /// A panel that has the keyboard without being the application in front.
    var panel: String?
    init() {
        prefs.sourceLanguage = .zhHans; prefs.targetLanguage = .zhHans
        prefs.overlayEnabled = false
        prefs.voiceCuesEnabled = false
        readinessState.permissions.microphone = .granted
        readinessState.models.speechReady = true
        readinessState.models.translationReady = true
        readinessState.inputSource = .init(installedLocation: true, installed: true, enabled: true, selected: true)
    }
    var refreshes = 0
    func refreshInputSourceStatus() { refreshes += 1 }
    func makeSpeechEngine() -> any SpeechRecognizing { let speech = Speech(); speeches.append(speech); return speech }
    func makeRefine() -> ((String) -> String)? { nil }
    func makePolish() -> ((String, String) async throws -> String)? { nil }
    func keyboardOwner(front bundleID: String?) -> String? { panel ?? bundleID }
    var microphoneRequests = 0
    func requestMicrophoneForDictation() { microphoneRequests += 1 }
    func textSink(inFront bundleID: String?, session: UUID) -> VoiceTextSink { writer.sink(inFront: bundleID, session: session) }
    func post(_ notice: UserNotice) { notices.append(notice) }
    func voiceSessionDidEnd(committed: Bool) { completions.append(committed); onEnd?() }
    func voiceSessionStateDidChange() { onState?() }
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
        do { // The talk key through the real router and its timers: a tap never opens
             // the microphone, an abandoned hold closes it, a real hold dictates.
            let f = Fixture()
            let router = InputEventRouter()
            router.updateContext { $0.trigger = .rightCommand; $0.switchEnabled = false; $0.globalEventsCanBeConsumed = true }
            f.host.onState = { router.updateContext {
                $0.isListening = f.voice.isListening
                $0.voiceCapturing = f.voice.isCapturing
            } }
            router.onAction = { action in
                switch action {
                case .voice(.prewarm): f.voice.arm()
                case .voice(.discard): f.voice.disarm()
                case .voice(.start): f.voice.press()
                case .voice(.stop): f.voice.release()
                case .voice(.cancel): f.voice.cancel()
                case .voice(.interrupt): f.voice.interrupt()
                default: break
                }
            }
            func command(_ down: Bool) -> InputEvent {
                .init(source: .imk, type: .flagsChanged, keyCode: UInt16(kVK_RightCommand),
                      flags: down ? UInt64(NSEvent.ModifierFlags.command.rawValue) | PushToTalkHotkey.rightCommand.deviceMask : 0,
                      isRepeat: false, timestamp: ProcessInfo.processInfo.systemUptime)
            }
            // A tap: nothing at all.
            _ = router.feed(command(true))
            try await Task.sleep(for: .milliseconds(40))
            _ = router.feed(command(false))
            try await Task.sleep(for: .milliseconds(350))
            precondition(f.audio.starts == 0 && f.host.speeches.isEmpty, "a tap opened the microphone")
            // Held past the prewarm but released before it counts: the microphone closes, nothing is kept.
            _ = router.feed(command(true))
            try await settleUntil { f.audio.running }
            f.audio.emit(7)
            _ = router.feed(command(false))
            precondition(!f.audio.running && f.host.speeches.isEmpty && !f.voice.isListening)
            // ⌘C: the key arrives while the hold is pending. Still nothing.
            _ = router.feed(command(true))
            _ = router.feed(.init(source: .imk, type: .keyDown, keyCode: UInt16(kVK_ANSI_C),
                                  flags: UInt64(NSEvent.ModifierFlags.command.rawValue), isRepeat: false,
                                  timestamp: ProcessInfo.processInfo.systemUptime))
            try await Task.sleep(for: .milliseconds(380))
            _ = router.feed(command(false))
            precondition(f.audio.starts == 1 && !f.voice.isListening, "a chord started a dictation")
            // A real hold.
            _ = router.feed(command(true))
            try await settleUntil { f.audio.running }
            f.audio.emit(2)
            try await settleUntil { f.voice.state == .listening }
            _ = router.feed(command(false))
            try await settleUntil { !f.voice.isListening }
            precondition(f.audio.starts == 2 && f.host.speeches.first?.feeds == 2,
                         "an abandoned hold contaminated the next preroll")
            precondition(f.writer.inserted == ["voice result"])
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
            precondition(f.writer.ended == f.writer.sessions && f.writer.sessions.count == 1,
                         "the input method is told once that the dictation is over")
            precondition(f.voice.sessionID == nil)
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
        do { // The microphone has never been asked for: the first hold asks, and nothing is recorded or reported twice.
            let f = Fixture()
            f.host.readinessState.permissions.microphone = .notDetermined
            f.voice.press()
            precondition(!f.voice.isListening && !f.audio.running && f.host.speeches.isEmpty)
            precondition(f.host.microphoneRequests == 1 && f.host.notices.isEmpty && f.host.completions == [false])
            precondition(f.host.refreshes == 1, "what is remembered is checked once more before refusing")
            passed += 1
        }
        do { // A start that may go ahead does not wait for the system's permission answers.
            let f = Fixture()
            try await dictate(f)
            precondition(f.host.refreshes == 0 && f.writer.inserted == ["voice result"])
            passed += 1
        }
        do { // Another input method being the current one is no reason to refuse: the key got here.
            let f = Fixture()
            f.host.readinessState.inputSource = .init(installedLocation: true, installed: true, enabled: true, selected: false)
            f.host.readinessState.globalInvokeAvailable = false
            f.writer.imkAttached = false
            try await dictate(f)
            precondition(f.writer.pasted == ["voice result"] && f.host.notices.isEmpty, "\(f.host.notices)")
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
        do { // Our own windows are ordinary targets: the same routes, nothing special.
            let f = Fixture()
            f.platform.front = "saylane"
            try await dictate(f)
            precondition(f.writer.requestedBundles == ["saylane"] && f.writer.inserted == ["voice result"])
            passed += 1
        }
        do { // A panel (Spotlight, a launcher) has the keyboard without being in front: the dictation is its own.
            let f = Fixture()
            f.host.panel = "launcher"
            try await dictate(f) {
                precondition(f.voice.targetBundleID == "launcher")
                // The application behind it being "activated" again is not a switch away from itself.
                f.voice.frontmostAppChanged(to: "editor", pid: 1234)
                precondition(f.audio.running)
            }
            precondition(f.writer.requestedBundles == ["launcher"] && f.writer.inserted == ["voice result"])
            precondition(f.writer.pasted.isEmpty && f.writer.copied.isEmpty && f.host.notices.isEmpty)
            passed += 1
        }
        do { // The panel closed before the text was ready: the keyboard is back in the application
             // behind it, and that is not where this was said. Kept, not pasted.
            let f = Fixture()
            f.host.panel = "launcher"
            try await dictate(f) { f.writer.imkAttached = false }
            precondition(f.writer.inserted.isEmpty && f.writer.pasted.isEmpty && f.writer.copied == ["voice result"])
            precondition(f.host.notices.count == 1 && f.host.notices[0].level == .transient)
            passed += 1
        }
        do { // Another application coming to the front ends a panel's dictation like any other.
            let f = Fixture()
            f.host.panel = "launcher"
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.platform.front = "anotherEditor"; f.platform.frontPID = 5678
            f.voice.frontmostAppChanged(to: "anotherEditor", pid: 5678)
            precondition(!f.audio.running, "switching applications must stop the microphone")
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.inserted.isEmpty && f.writer.pasted.isEmpty && f.writer.copied == ["voice result"])
            passed += 1
        }
        do { // A key or a click right after the start: the press was a shortcut. Nothing is written or kept.
            let f = Fixture()
            f.voice.press(); f.audio.emit(4)
            try await settleUntil { f.voice.state == .listening }
            f.voice.interrupt()
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.inserted.isEmpty && f.writer.pasted.isEmpty && f.writer.copied.isEmpty)
            precondition(f.host.notices.isEmpty && f.host.completions == [false] && f.writer.ended.count == 1)
            passed += 1
        }
        do { // The same slip well into a dictation: what was said is kept, but not written at a caret that may have moved.
            let f = Fixture()
            f.voice.policy.interruptGrace = 0.05
            f.voice.press(); f.audio.emit(4)
            try await settleUntil { f.voice.state == .listening }
            try await Task.sleep(for: .milliseconds(90))
            f.voice.interrupt()
            precondition(!f.audio.running, "an interruption stops the microphone at once")
            try await settleUntil { !f.voice.isListening }
            precondition(f.writer.inserted.isEmpty && f.writer.pasted.isEmpty && f.writer.copied == ["voice result"])
            precondition(f.host.notices.count == 1 && f.host.notices[0].level == .transient)
            precondition(f.voice.lastDictation == "voice result")
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
            router.updateContext { $0.trigger = .f20; $0.tapToTalk = true; $0.globalEventsCanBeConsumed = true }
            f.host.onState = { router.updateContext {
                $0.isListening = f.voice.isListening
                $0.voiceCapturing = f.voice.isCapturing
            } }
            f.host.onEnd = { router.reset(); router.updateContext { $0.isListening = false; $0.voiceCapturing = false } }
            router.onAction = { action in
                switch action {
                case .voice(.start): f.voice.press()
                case .voice(.stop): f.voice.release()
                case .voice(.cancel): f.voice.cancel()
                default: break
                }
            }
            func key(_ code: UInt16, _ type: NSEvent.EventType, _ time: Double) -> InputEvent {
                .init(source: .tap, type: type, keyCode: code, flags: 0, isRepeat: false, timestamp: time)
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
        print("PASS: \(passed) voice-controller scenarios: talk key through the router, input-method / paste / pasteboard delivery, lost and late clients, quick release, focus, panels, interruptions, toggle/Esc")
    }
}
