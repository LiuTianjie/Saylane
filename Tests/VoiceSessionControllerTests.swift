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
    static let ownSource = "saylane.voice"
    var source = ownSource
    var front: String? = "editor"
    var frontPID: pid_t? = 1234
    var enabled = true
    var selections = 0
    var recoveries = 0
    var restored: [String] = []
    var applyOwnImmediately = true
    var applyASCIIImmediately = true
    var applyRestoreImmediately = true
    var ownSelectionSucceeds = true
    var restoreSelectionSucceeds = true
    var onSelect: (() -> Void)?
    var trace: [String] = []
    var environment: VoiceInputEnvironment {
        VoiceInputEnvironment(ownBundleID: "saylane", ownInputSourceID: Self.ownSource,
            frontmostBundleID: { self.front }, frontmostPID: { self.frontPID },
            currentInputSource: { self.source }, inputSourceEnabled: { self.enabled },
            inputSourceSelected: { self.source == Self.ownSource },
            selectOwnInputSource: {
                self.selections += 1
                guard self.ownSelectionSucceeds else { return false }
                if self.applyOwnImmediately { self.source = Self.ownSource; self.onSelect?() }
                return true
            },
            selectInputSource: {
                self.restored.append($0)
                guard self.restoreSelectionSucceeds else { return false }
                if self.applyRestoreImmediately { self.source = $0 }
                return true
            },
            asciiInputSourceID: { "ABC" },
            selectASCIILayout: {
                self.recoveries += 1
                if self.applyASCIIImmediately { self.source = "ABC" }
                return true
            },
            trace: { self.trace.append("\($0) \($1)") })
    }
}

@MainActor private final class Host: VoiceSessionHost {
    var prefs = Preferences()
    var readinessState = Readiness()
    var isVoiceTrialActive = false
    var hasIMKClient = true
    var clientBundleID: String? = "editor"
    var clientGeneration = 1
    var keyboardInputRevision: UInt64 = 0
    let target = Destination(), trialTarget = Destination()
    var speeches: [Speech] = []
    var notices: [UserNotice] = []
    var completions: [Bool] = []
    var trialCaptures = 0
    var normalCaptures = 0
    var onState: (() -> Void)?
    var onEnd: (() -> Void)?
    let platform: Platform
    init(_ platform: Platform) {
        self.platform = platform
        prefs.sourceLanguage = .zhHans; prefs.targetLanguage = .zhHans
        prefs.overlayEnabled = false
        readinessState.permissions.microphone = .granted
        readinessState.models.speechReady = true
        readinessState.models.translationReady = true
        refreshInputSourceStatus()
    }
    func refreshInputSourceStatus() {
        readinessState.inputSource = .init(installedLocation: true, installed: true, enabled: platform.enabled,
                                           selected: platform.source == Platform.ownSource)
    }
    func makeSpeechEngine() -> any SpeechRecognizing { let speech = Speech(); speeches.append(speech); return speech }
    func makeRefine() -> ((String) -> String)? { nil }
    func makePolish() -> ((String, String) async throws -> String)? { nil }
    func captureTarget() -> (any CompositionTarget)? { normalCaptures += 1; return hasIMKClient ? target : nil }
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
    let host: Host
    let voice: VoiceSessionController
    init(wait: TimeInterval = 0.4) {
        host = Host(platform)
        var policy = VoicePolicy.standard
        policy.clientWait = wait
        let audio = self.audio
        voice = VoiceSessionController(overlay: OverlayController(displaysPanel: false), policy: policy,
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

    @MainActor static func main() async throws {
        var passed = 0
        do { // An abandoned right-Command hold stops mic/preroll immediately.
            let f = Fixture()
            let router = InputEventRouter()
            router.updateContext { $0.trigger = .rightCommand; $0.globalEventsCanBeConsumed = true }
            f.host.onState = { router.updateContext {
                $0.isListening = f.voice.isListening || f.voice.isWaking
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
        do {
            let f = Fixture()
            var states: [SessionState] = []
            f.host.onState = { states.append(f.voice.state) }
            f.voice.press(); f.audio.emit(7)
            try await settleUntil { f.voice.state == .listening }
            f.voice.release()
            try await settleUntil { !f.voice.isListening }
            precondition(f.host.target.commits == ["voice result"] && f.host.speeches[0].feeds == 7)
            precondition(states.contains(.preparing) && states.contains(.listening) && states.last == .idle)
            precondition(f.host.completions == [true] && !f.audio.running)
            passed += 1
        }
        do { // Key-up before the IMK client attaches must stop hardware but preserve its audio.
            let f = Fixture()
            f.platform.source = "otherIME"; f.host.hasIMKClient = false
            f.voice.press(); f.audio.emit(5); f.voice.release()
            precondition(!f.audio.running, "key-up must stop the microphone even during wake-up")
            f.host.hasIMKClient = true
            try await settleUntil { !f.voice.isWaking && !f.voice.isListening }
            try await settleUntil { f.platform.source == "otherIME" }
            precondition(f.host.speeches.first?.feeds == 5 && f.host.target.commits == ["voice result"])
            precondition(f.platform.source == "otherIME" && f.platform.restored == ["otherIME"] && f.audio.starts == 1)
            passed += 1
        }
        do { // Re-selecting the same source cannot recover a stale client; one real transition can.
            let f = Fixture()
            f.host.hasIMKClient = false
            f.platform.onSelect = { if f.platform.recoveries > 0 { f.host.hasIMKClient = true } }
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.voice.release()
            try await settleUntil { !f.voice.isListening }
            precondition(f.platform.recoveries == 1 && f.host.target.commits.count == 1)
            passed += 1
        }
        do {
            let f = Fixture(wait: 0.15)
            f.platform.source = "otherIME"; f.host.hasIMKClient = false
            f.voice.press()
            try await settleUntil { !f.voice.isWaking }
            try await settleUntil { f.platform.source == "otherIME" }
            precondition(f.host.target.commits.isEmpty && f.host.notices.count == 1)
            precondition(f.platform.source == "otherIME" && !f.audio.running && f.host.completions == [false])
            passed += 1
        }
        do { // Changing apps while attaching must never start in the newly focused app.
            let f = Fixture()
            f.host.hasIMKClient = false
            f.voice.press(); f.audio.emit()
            f.platform.front = "anotherEditor"
            f.voice.frontmostAppChanged(to: "anotherEditor")
            precondition(!f.voice.isWaking && !f.audio.running && f.host.speeches.isEmpty)
            passed += 1
        }
        do { // Detachment during a globally started recording is a real target loss.
            let f = Fixture()
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.host.target.isValid = false
            f.voice.targetLost()
            try await settleUntil { !f.voice.isListening }
            precondition(!f.voice.isListening && !f.audio.running && f.host.target.commits.isEmpty)
            passed += 1
        }
        do { // A manual source switch while waking is user intent; never fight it or restore over it.
            let f = Fixture()
            f.platform.source = "otherIME"; f.host.hasIMKClient = false
            f.voice.press()
            try await Task.sleep(for: .milliseconds(80))
            f.platform.source = "userChosenIME"
            f.voice.inputSourceChanged()
            try await settleUntil { !f.voice.isWaking && !f.voice.isListening }
            precondition(f.platform.source == "userChosenIME" && f.platform.restored.isEmpty && !f.audio.running)
            passed += 1
        }
        do { // A delayed accepted TIS request is issued once, never every polling tick.
            let f = Fixture(wait: 0.7)
            f.platform.source = "otherIME"; f.platform.applyOwnImmediately = false
            f.voice.press()
            try await Task.sleep(for: .milliseconds(220))
            precondition(f.platform.selections == 1, "wake selection stormed: \(f.platform.selections)")
            f.platform.source = Platform.ownSource
            f.voice.inputSourceChanged()
            try await settleUntil { f.voice.state == .listening }
            f.audio.emit(); f.voice.release()
            try await settleUntil { !f.voice.isListening }
            passed += 1
        }
        do { // A third source inside the delayed transition window is user intent.
            let f = Fixture(wait: 0.5)
            f.platform.source = "otherIME"; f.platform.applyOwnImmediately = false
            f.voice.press()
            try await Task.sleep(for: .milliseconds(30))
            f.platform.source = "userChosenIME"
            f.voice.inputSourceChanged()
            try await settleUntil { !f.voice.isWaking }
            try await Task.sleep(for: .milliseconds(100))
            precondition(f.platform.source == "userChosenIME" && f.platform.selections == 1
                         && f.platform.restored.isEmpty && f.host.speeches.isEmpty)
            passed += 1
        }
        do { // A reconnect must observe the ASCII source before selecting Saylane back.
            let f = Fixture(wait: 0.5)
            f.host.hasIMKClient = false; f.platform.applyASCIIImmediately = false
            f.voice.press()
            try await settleUntil({ f.platform.recoveries == 1 }, limit: 120)
            try await settleUntil { !f.voice.isWaking }
            precondition(f.platform.selections == 0 && f.host.speeches.isEmpty,
                         "bridge selected back before the out transition was observed")
            passed += 1
        }
        do { // A failed bridge-back request must not strand selection on ABC.
            let f = Fixture(wait: 0.55)
            f.host.hasIMKClient = false
            // The dedicated back request fails; the bounded generic unwind may
            // still return to the source that owned selection before bridging.
            f.platform.ownSelectionSucceeds = false
            f.voice.press()
            try await settleUntil({ f.platform.recoveries == 1 }, limit: 120)
            try await settleUntil { !f.voice.isWaking }
            precondition(f.platform.source != "ABC", "failed reconnect stranded the user on the bridge source")
            passed += 1
        }
        do { // TIS accepted ABC can land AFTER our reconnect timeout has expired.
            let f = Fixture(wait: 0.3)
            f.host.hasIMKClient = false; f.platform.applyASCIIImmediately = false
            f.voice.press()
            try await settleUntil { f.platform.recoveries == 1 }
            try await settleUntil { !f.voice.isWaking }
            f.platform.source = "ABC"
            f.voice.inputSourceChanged()
            precondition(f.platform.source == Platform.ownSource,
                         "late accepted bridge request stranded the user on ABC")
            precondition(f.platform.restored == [Platform.ownSource])
            passed += 1
        }
        do { // A cancelled accepted wake cannot steal the next app's input source.
            let f = Fixture(wait: 0.6)
            f.platform.source = "otherIME"; f.platform.applyOwnImmediately = false
            f.voice.press()
            f.platform.front = "anotherEditor"; f.platform.frontPID = 5678
            f.platform.source = "newAppIME"
            f.voice.frontmostAppChanged(to: "anotherEditor", pid: 5678)
            f.platform.source = Platform.ownSource
            f.voice.inputSourceChanged()
            precondition(f.platform.source == "newAppIME" && f.host.speeches.isEmpty)
            passed += 1
        }
        do { // A manual source switch during recording cancels without switching the user back.
            let f = Fixture()
            f.platform.source = "otherIME"
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.platform.source = "userChosenIME"
            f.voice.inputSourceChanged()
            try await settleUntil { !f.voice.isListening }
            precondition(f.platform.source == "userChosenIME" && f.platform.restored.isEmpty)
            passed += 1
        }
        do { // A late notification for our completed wake transition is harmless.
            let f = Fixture()
            f.platform.source = "otherIME"
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            precondition(f.platform.source == Platform.ownSource)
            f.voice.inputSourceChanged()
            precondition(f.voice.state == .listening && f.audio.running)
            f.voice.release()
            try await settleUntil { !f.voice.isListening }
            precondition(f.host.target.commits == ["voice result"])
            passed += 1
        }
        do { // A queued restore cannot overwrite a later manual source choice.
            let f = Fixture(wait: 0.7)
            f.platform.source = "otherIME"; f.platform.applyRestoreImmediately = false
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.voice.release()
            try await settleUntil { !f.voice.isListening }
            try await settleUntil { f.platform.restored.count == 1 }
            f.platform.source = "userChosenIME"
            f.voice.inputSourceChanged()
            try await Task.sleep(for: .milliseconds(450))
            precondition(f.platform.source == "userChosenIME" && f.platform.restored.count == 1)
            passed += 1
        }
        do { // A timeout is retryable; it is not the same as a user interruption.
            let f = Fixture(wait: 0.7)
            f.platform.source = "otherIME"; f.platform.applyRestoreImmediately = false
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.voice.release()
            try await settleUntil { !f.voice.isListening }
            try await settleUntil({ f.platform.restored.count == 3 }, limit: 220)
            precondition(f.platform.source == Platform.ownSource)
            passed += 1
        }
        do { // Switching applications while a restore is pending stops its retries.
            let f = Fixture(wait: 0.7)
            f.platform.source = "otherIME"; f.platform.applyRestoreImmediately = false
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.voice.release()
            try await settleUntil { !f.voice.isListening }
            try await settleUntil { f.platform.restored.count == 1 }
            f.platform.front = "anotherEditor"; f.platform.frontPID = 5678
            f.voice.frontmostAppChanged(to: "anotherEditor", pid: 5678)
            try await Task.sleep(for: .milliseconds(450))
            precondition(f.platform.restored.count == 1)
            f.platform.applyRestoreImmediately = true
            f.platform.source = "otherIME" // The first accepted request finally arrives.
            f.voice.inputSourceChanged()
            precondition(f.platform.source == Platform.ownSource,
                         "late restore changed the new foreground app after cancellation")
            precondition(f.platform.restored == ["otherIME", Platform.ownSource])
            passed += 1
        }
        do { // A manual third source remains authoritative even after a late restore.
            let f = Fixture(wait: 0.7)
            f.platform.source = "otherIME"; f.platform.applyRestoreImmediately = false
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.voice.release()
            try await settleUntil { f.platform.restored.count == 1 }
            f.platform.source = "userChosenIME"; f.voice.inputSourceChanged()
            f.platform.applyRestoreImmediately = true
            f.platform.source = "otherIME"; f.voice.inputSourceChanged()
            precondition(f.platform.source == "userChosenIME")
            precondition(f.platform.restored == ["otherIME", "userChosenIME"])
            passed += 1
        }
        do { // An attached controller from a different app is not a valid receiver.
            let f = Fixture(wait: 0.15)
            f.host.clientBundleID = "oldEditor"
            f.voice.press()
            try await settleUntil { !f.voice.isWaking }
            precondition(f.host.normalCaptures == 0 && f.host.target.commits.isEmpty && f.host.notices.count == 1)
            passed += 1
        }
        do { // Only the focused trial page may capture speech into the settings field.
            let f = Fixture()
            f.platform.front = "saylane"; f.host.isVoiceTrialActive = true; f.host.hasIMKClient = false
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.voice.release()
            try await settleUntil { !f.voice.isListening }
            precondition(f.host.trialCaptures == 1 && f.host.normalCaptures == 0 && f.platform.selections == 0)
            precondition(f.host.trialTarget.commits == ["voice result"])
            passed += 1
        }
        do { // Opening Saylane settings cancels an ordinary editor session.
            let f = Fixture()
            f.voice.press(); f.audio.emit()
            try await settleUntil { f.voice.state == .listening }
            f.platform.front = "saylane"; f.platform.frontPID = 9999
            f.voice.frontmostAppChanged(to: "saylane", pid: 9999)
            try await settleUntil { !f.voice.isListening }
            precondition(f.host.target.commits.isEmpty)
            passed += 1
        }
        do { // Router + voice, with state updates exactly as the composition root wires them.
            let f = Fixture()
            let router = InputEventRouter()
            router.updateContext { $0.trigger = .f20; $0.tapToTalk = true }
            f.host.onState = { router.updateContext {
                $0.isListening = f.voice.isListening || f.voice.isWaking
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
            precondition(f.host.target.commits.count == 1 && !router.context.isListening)
            f.host.hasIMKClient = false
            _ = router.feed(key(UInt16(kVK_F20), .keyDown, 3))
            precondition(f.voice.isWaking && router.context.isListening)
            _ = router.feed(key(UInt16(kVK_Escape), .keyDown, 3.1))
            precondition(!f.voice.isWaking && !f.audio.running && !router.context.isListening)
            passed += 1
        }
        print("PASS: \(passed) full voice-controller scenarios, IMK recovery, quick release, focus, trial routing and toggle/Esc")
    }
}
