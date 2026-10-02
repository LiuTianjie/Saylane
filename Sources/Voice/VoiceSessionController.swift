import AppKit
import Foundation
import Observation

/// What the voice feature needs from the rest of the app.
@MainActor
protocol VoiceSessionHost: AnyObject {
    var prefs: Preferences { get }
    /// Permissions, input source and models, as far as a dictation depends on them.
    var voiceReadiness: Readiness { get }
    func makeSpeechEngine() -> any SpeechRecognizing
    func makeRefine() -> ((String) -> String)?
    func makePolish() -> ((String, String) async throws -> String)?
    func translate(_ text: String) async throws -> String
    /// The application that has the keyboard while `bundleID` is the one in
    /// front: a panel such as Spotlight takes keys without coming to the front.
    func keyboardOwner(front bundleID: String?) -> String?
    /// The microphone has never been asked for: ask now, and say what to do next.
    func requestMicrophoneForDictation()
    /// The ways to write into the application whose bundle is `bundleID`.
    func textSink(inFront bundleID: String?, session: UUID) -> VoiceTextSink
    func post(_ notice: UserNotice)
    func voiceSessionDidEnd(committed: Bool)
    func voiceSessionStateDidChange()
    func refreshInputSourceStatus()
}

/// The voice feature: hold → capture → recognize → write at the caret of the
/// application in front. Whichever input source is selected stays selected;
/// the text goes through the input method when it is attached there and is
/// pasted otherwise.
@MainActor @Observable
final class VoiceSessionController {
    let coordinator: SessionCoordinator
    let overlay: OverlayController
    var policy: VoicePolicy
    weak var host: VoiceSessionHost?
    private let environment: VoiceInputEnvironment
    private let makeCapture: (TimeInterval) -> PrerollCapture
    /// The sounds at the start and the end of listening; replaceable in tests.
    var playCue: (VoiceCue) -> Void = { $0.play() }

    private var preroll: PrerollCapture?
    /// One dictation, from the start until its text is written or dropped.
    private(set) var sessionID: UUID?
    /// The application the dictation belongs to: the one that had the keyboard.
    private(set) var targetBundleID: String?
    /// The application in front at the press, and its process.
    private var frontBundleID: String?
    private var targetPID: pid_t?
    private var target: FocusedTextTarget?
    private var sink: VoiceTextSink?
    private var listeningStartedAt: TimeInterval?
    private var sessionActive = false
    private var lastOutcomeCommitted = false
    /// Shown once the session has ended, so the finish animation cannot hide it.
    private var deliveryNotice: UserNotice?
    private(set) var completedSessions = 0
    /// The most recent final text, kept in memory only, so a dictation that
    /// landed nowhere can still be copied from the input-method menu.
    private(set) var lastDictation: String?

    var state: SessionState { coordinator.state }
    var isListening: Bool { coordinator.state != .idle }
    var isCapturing: Bool { coordinator.isAcceptingAudio }
    var listeningDuration: TimeInterval? { listeningStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } }

    init(coordinator: SessionCoordinator? = nil, overlay: OverlayController? = nil, policy: VoicePolicy = .standard,
         environment: VoiceInputEnvironment? = nil, makeCapture: ((TimeInterval) -> PrerollCapture)? = nil) {
        self.coordinator = coordinator ?? SessionCoordinator(typingInterval: VoicePolicy.typingInterval, releaseTail: ReleaseTail())
        self.overlay = overlay ?? OverlayController()
        self.policy = policy
        self.environment = environment ?? .system
        self.makeCapture = makeCapture ?? { PrerollCapture(limit: $0) }
        wire()
    }

    private func record(_ stage: String, _ detail: String = "") { environment.trace(stage, detail) }

    // MARK: - Gestures

    /// The key went down but the gesture is not final yet: open the microphone now.
    func arm() {
        guard !isListening, preroll == nil, let host else { return }
        guard host.voiceReadiness.permissions.microphone == .granted else { return }
        let capture = makeCapture(policy.prerollLimit)
        capture.onLevel = { [weak self] in self?.overlay.setLevel($0) }
        do {
            try capture.arm()
            preroll = capture
            record("preroll-armed")
            // A gesture that never becomes a press (chord, focus change) must not leave the microphone open.
            Task { [weak self, weak capture] in
                try? await Task.sleep(for: .seconds(self?.policy.prerollLimit ?? 3))
                guard let self, let capture, self.preroll === capture, !self.isListening else { return }
                self.disarm()
                record("preroll-expired")
            }
        } catch {
            record("preroll-failed", error.localizedDescription)
        }
    }

    /// The gesture turned out not to be a hold (a chord, a tap).
    func disarm() {
        preroll?.discard()
        preroll = nil
    }

    /// The hold is confirmed: start. There is nothing to wait for — where the
    /// text goes is decided when it is ready.
    func press() {
        guard !isListening, host != nil else { return }
        arm()
        start()
    }

    /// A key or a click while the talk key was held. Right after the start it
    /// means the press was a shortcut; later it is a slip, and what was said
    /// is kept on the pasteboard instead of landing wherever the caret now is.
    func interrupt() {
        guard isCapturing else { disarm(); return }
        guard let duration = listeningDuration, duration >= policy.interruptGrace else {
            record("interrupted", "dropped")
            cancel()
            return
        }
        record("interrupted", "kept after \(Int(duration * 1000)) ms")
        target?.interrupted = true
        coordinator.release()
    }

    func release() {
        if !isListening { disarm() }
        coordinator.release()
    }

    func cancel() {
        disarm()
        coordinator.cancel()
    }

    /// Optional polishing may be preempted without losing the completed local
    /// result. Final recognition cannot: its tail remains authoritative.
    @discardableResult
    func commitCompletedOutputForUserInput() -> Bool {
        coordinator.commitOrdinaryOutputForUserInput()
    }

    // MARK: - Start

    private func start() {
        guard let host, !isListening else { return }
        let p = host.prefs
        var readiness = host.voiceReadiness
        if readiness.blocker != nil {
            // What is remembered says no, but the user may just have allowed
            // it: look again before refusing. A start that may go ahead never
            // waits for the system's answers — asking takes tens of
            // milliseconds, and seconds right after an installation.
            host.refreshInputSourceStatus()
            readiness = host.voiceReadiness
        }
        let front = environment.frontmostBundleID()
        let owner = host.keyboardOwner(front: front)
        record("start-check", "selected=\(readiness.inputSource.selected) front=\(front ?? "none")\(owner == front ? "" : " keyboard=" + (owner ?? "none")) mic=\(readiness.permissions.microphone == .granted) speech=\(readiness.models.speechReady) translation=\(readiness.models.translationReady) checking=\(readiness.models.busy)")

        if let blocker = readiness.blocker {
            if blocker == .microphoneNotRequested {
                // The first dictation: the system asks here, where it is
                // needed. Nothing is recorded; the user holds the key again.
                fail(nil)
                host.requestMicrophoneForDictation()
            } else {
                fail(.actionable(blocker.message, ReadinessReducer.destination(for: blocker)))
            }
            return
        }
        let pid = environment.frontmostPID()
        let environment = self.environment
        let session = UUID()
        let sink = host.textSink(inFront: owner, session: session)
        // A panel has no other sign of life than the input method's attachment:
        // once that is gone the keyboard is back in the application behind it.
        let panel = owner != front
        let target = FocusedTextTarget(sink: sink) {
            (pid == nil || environment.frontmostPID() == pid) && (!panel || sink.attached())
        }
        target.onDelivery = { [weak self] delivery, text in self?.delivered(delivery, text: text) }
        sessionID = session
        self.sink = sink
        self.target = target
        targetBundleID = owner
        frontBundleID = front
        targetPID = pid

        let capture: any AudioCapturing = preroll ?? makeCapture(policy.prerollLimit)
        preroll = nil
        coordinator.start(locale: p.sourceLanguage.speechLocale, speech: host.makeSpeechEngine(), capture: capture,
                          target: target,
                          passthrough: p.translationIsPassthrough,
                          refine: host.makeRefine(), polish: host.makePolish(), policy: policy,
                          model: p.speechModel.rawValue) { [weak host] text in
            guard let host else { throw CancellationError() }
            return try await host.translate(text)
        }
        if !isListening { fail(nil) }
    }

    /// The press could not become a session. Nothing was recorded for the user to lose.
    private func fail(_ notice: UserNotice?) {
        disarm()
        clearSession()
        host?.voiceSessionDidEnd(committed: false)
        if let notice { host?.post(notice) }
    }

    private func delivered(_ delivery: VoiceDelivery, text: String) {
        lastDictation = text
        record("delivery", String(describing: delivery))
        switch delivery {
        case .inputMethod, .pasted:
            break
        case .copied:
            // Report whichever route was missing; the text itself is safe on the pasteboard.
            deliveryNotice = host?.voiceReadiness.permissions.accessibility == true
                ? .transient(String(localized: "没能直接写入，文字已复制到剪贴板，按 ⌘V 粘贴。"))
                : .actionable(String(localized: "这里无法通过输入法写入，文字已复制到剪贴板，按 ⌘V 粘贴。允许“辅助功能”后会自动写入。"), .permissions)
        case .copiedAfterAppSwitch:
            deliveryNotice = .transient(String(localized: "已切换到其它应用，这次听写没有写入，文字已复制到剪贴板。"))
        case .copiedAfterInterrupt:
            deliveryNotice = .transient(String(localized: "听写被按键打断，没有写入，文字已复制到剪贴板。"))
        }
    }

    // MARK: - External changes

    /// Another application came to the front. A dictation belongs to the
    /// application it started in and is never written into a different one:
    /// recording stops, and unless the user comes back before the result is
    /// ready it is left on the pasteboard.
    func frontmostAppChanged(to bundleID: String?, pid: pid_t? = nil) {
        guard isListening else { return }
        let sameBundle = frontBundleID == nil || bundleID == frontBundleID
        let sameProcess = targetPID == nil || pid == targetPID
        guard !(sameBundle && sameProcess) else { return }
        record("app-switched", "to \(bundleID ?? "none") pid=\(pid.map(String.init) ?? "none") capturing=\(isCapturing)")
        if isCapturing { coordinator.release() }
    }

    // MARK: - HUD and notices

    func showNotice(_ notice: UserNotice) {
        guard notice.level != .diagnostic, host?.prefs.overlayEnabled == true else { return }
        overlay.showNotice(notice.message, warning: notice.level == .actionable, duration: notice.hudDuration)
    }

    private func wire() {
        coordinator.onState = { [weak self] state in
            guard let self else { return }
            record("session-state", String(describing: state))
            let p = self.host?.prefs
            switch state {
            case .idle:
                self.listeningStartedAt = nil
                if self.sessionActive {
                    // Every way a session can end (commit, cancel, failure) passes through here once.
                    self.sessionActive = false
                    let committed = self.lastOutcomeCommitted
                    self.lastOutcomeCommitted = false
                    self.sessionEnded(committed: committed)
                }
            case .preparing:
                self.sessionActive = true
                self.lastOutcomeCommitted = false
                self.deliveryNotice = nil
                if p?.overlayEnabled == true, let p {
                    if self.overlay.model.phase == .hidden {
                        self.overlay.show(source: p.sourceLanguage.shortName, target: p.targetLanguage.shortName,
                                          liveInject: true, hotkeyLabel: p.pushToTalk.shortLabel)
                    } else {
                        self.overlay.setPhase(.preparing)
                    }
                }
            case .listening:
                self.listeningStartedAt = ProcessInfo.processInfo.systemUptime
                self.overlay.setPhase(.listening)
                if p?.voiceCuesEnabled == true {
                    self.playCue(.started)
                    self.coordinator.noteCue(lasting: VoiceCue.started.audible)
                }
            case .finalizing:
                self.overlay.setPhase(.finalizing)
                if p?.voiceCuesEnabled == true { self.playCue(.stopped) }
            case .polishing: self.overlay.setPhase(.polishing)
            case .cancelling:
                self.listeningStartedAt = nil
                self.overlay.hide()
            }
            self.host?.voiceSessionStateDidChange()
        }
        coordinator.onCompletion = { [weak self] feedback in
            guard let self else { return }
            record("completion", String(describing: feedback))
            if let notice = self.deliveryNotice {
                // Where the text went matters more than the finish animation.
                self.deliveryNotice = nil
                self.overlay.hide()
                self.host?.post(notice)
                return
            }
            guard self.host?.prefs.overlayEnabled == true else { self.overlay.hide(); return }
            if feedback.isWarning { self.overlay.showCompletion(feedback) } else { self.overlay.playFinishSweepThenHide() }
        }
        coordinator.onLevel = { [weak self] in self?.overlay.setLevel($0) }
        coordinator.onError = { [weak self] message in
            guard let self else { return }
            // Live-preview errors can still recover on release; only terminal errors reach the user.
            if self.coordinator.state == .idle {
                self.host?.post(.transient(message))
            } else {
                self.host?.post(.diagnostic(message))
            }
        }
        coordinator.onMetrics = { [weak self] in self?.record("speech-metrics", $0.logValue) }
        coordinator.onLengthLimit = { [weak self] in
            self?.host?.post(.transient(String(localized: "已达到单次语音时长上限，已提交听到的部分。")))
        }
        coordinator.onCommit = { [weak self] in
            guard let self else { return }
            self.completedSessions += 1
            self.lastOutcomeCommitted = true
            record("text-committed")
        }
    }

    private func sessionEnded(committed: Bool) {
        preroll = nil
        clearSession()
        host?.voiceSessionDidEnd(committed: committed)
    }

    private func clearSession() {
        sink?.end()
        sink = nil
        target = nil
        sessionID = nil
        targetBundleID = nil
        frontBundleID = nil
        targetPID = nil
    }
}
