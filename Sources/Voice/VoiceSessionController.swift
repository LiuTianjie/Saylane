import AppKit
import Foundation
import Observation

/// What the voice feature needs from the rest of the app.
@MainActor
protocol VoiceSessionHost: AnyObject {
    var prefs: Preferences { get }
    var readinessState: Readiness { get }
    var isVoiceTrialActive: Bool { get }
    func makeSpeechEngine() -> any SpeechRecognizing
    func makeRefine() -> ((String) -> String)?
    func makePolish() -> ((String, String) async throws -> String)?
    func translate(_ text: String) async throws -> String
    /// The IMK client currently attached, if any.
    func captureTarget() -> (any CompositionTarget)?
    var hasIMKClient: Bool { get }
    var clientBundleID: String? { get }
    /// Changes whenever the usable IMK receiver/focus lease changes.
    var clientGeneration: Int { get }
    var keyboardInputRevision: UInt64 { get }
    /// The settings-window trial field.
    func settingsCaptureTarget() -> (any CompositionTarget)?
    func post(_ notice: UserNotice)
    func voiceSessionDidEnd(committed: Bool)
    func voiceSessionStateDidChange()
    func commitPinyinBeforeVoice()
    func refreshInputSourceStatus()
}

/// The voice feature: press → capture at once → prepare → recognize → commit,
/// plus everything around it (global wake, input-source restore, HUD, fallback).
@MainActor @Observable
final class VoiceSessionController {
    let coordinator: SessionCoordinator
    let overlay: OverlayController
    var policy: VoicePolicy
    weak var host: VoiceSessionHost?
    private let environment: VoiceInputEnvironment
    private let makeCapture: (TimeInterval) -> PrerollCapture

    private var preroll: PrerollCapture?
    private var wakeTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    /// Input source to go back to after a global wake, and the exact process it
    /// belonged to when the gesture began.
    private var wakeOrigin: (inputSourceID: String, bundleID: String?, pid: pid_t?)?
    private var targetBundleID: String?
    private var targetPID: pid_t?
    private(set) var isWaking = false
    /// The key was released while the wake was still attaching: finalize as soon as the session starts.
    private var pendingRelease = false
    /// The current session began with a global wake; IMK attach/detach flapping must not cancel it.
    private var sessionFromGlobalWake = false
    private var listeningStartedAt: TimeInterval?
    private var sessionActive = false
    private var lastOutcomeCommitted = false
    private enum SourceTransitionKind { case wakeToOwn, bridgeOut, bridgeBack, restore }
    private struct SourceTransition {
        let token: Int
        let kind: SourceTransitionKind
        let fromID: String?
        let expectedID: String
    }
    private struct PendingRestore {
        let token: Int
        let originID: String
        let bundleID: String?
        let pid: pid_t?
    }
    /// TIS returning success accepts a request; cancelling our Task cannot
    /// cancel the system request. Keep a short receipt after timeout/cancel so
    /// its delayed notification can be unwound instead of being mistaken for
    /// a new user selection.
    private struct RetiredSourceRequest {
        let transition: SourceTransition
        let expiresAt: TimeInterval
        var compensationID: String?
    }
    private enum TransitionStatus: Equatable { case pending, arrived, interrupted, timedOut }
    private var sourceTransition: SourceTransition?
    private var pendingRestore: PendingRestore?
    private var retiredSourceRequests: [RetiredSourceRequest] = []
    private var sourceToken = 0
    private(set) var completedSessions = 0
    private(set) var usesAccessibilityTarget = false

    var state: SessionState { coordinator.state }
    var isListening: Bool { coordinator.state != .idle }
    var isCapturing: Bool { isWaking || coordinator.isAcceptingAudio }
    var listeningDuration: TimeInterval? { listeningStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } }

    init(coordinator: SessionCoordinator? = nil, overlay: OverlayController? = nil, policy: VoicePolicy = .standard,
         environment: VoiceInputEnvironment? = nil, makeCapture: ((TimeInterval) -> PrerollCapture)? = nil) {
        self.coordinator = coordinator ?? SessionCoordinator()
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
        guard host.readinessState.permissions.microphone == .granted else { return }
        let capture = makeCapture(policy.prerollLimit)
        capture.onLevel = { [weak self] in self?.overlay.setLevel($0) }
        do {
            try capture.arm()
            preroll = capture
            record("preroll-armed")
            // A gesture that never becomes a press (chord, focus change) must not leave the microphone open.
            Task { [weak self, weak capture] in
                try? await Task.sleep(for: .seconds(self?.policy.prerollLimit ?? 3))
                guard let self, let capture, self.preroll === capture, !self.isListening, !self.isWaking else { return }
                self.disarm()
                record("preroll-expired")
            }
        } catch {
            record("preroll-failed", error.localizedDescription)
        }
    }

    /// The gesture turned out not to be a press (double tap, chord, short tap).
    func disarm() {
        preroll?.discard()
        preroll = nil
    }

    /// The gesture is a press. In the settings window the trial field is the
    /// target; anywhere else we select ourselves if needed and wait for the client.
    func press() {
        guard !isListening, !isWaking, let host else { return }
        arm()
        host.commitPinyinBeforeVoice()
        if host.isVoiceTrialActive {
            startNow(fromGlobal: false)
            return
        }
        beginGlobalWake()
    }

    func release() {
        if isWaking {
            // A short utterance: let the wake finish, then commit what the preroll heard.
            pendingRelease = true
            preroll?.stop()
            return
        }
        if !isListening { disarm() }
        coordinator.release()
    }

    func cancel() {
        cancel(restoreOrigin: true)
    }

    /// Optional polishing may be preempted without losing the completed local
    /// result. Final recognition cannot: its tail remains authoritative.
    @discardableResult
    func commitCompletedOutputForUserInput() -> Bool {
        coordinator.commitOrdinaryOutputForUserInput()
    }

    /// Once the user continues typing through our IMK client, an automatic
    /// source restore must not interrupt the new Pinyin composition.
    func userResumedTyping() {
        wakeOrigin = nil
        supersedeRetiredRequests(with: environment.currentInputSource())
        cancelPendingRestore()
    }

    private func cancel(restoreOrigin: Bool) {
        retireSourceTransition(compensateTo: restoreOrigin
            ? (wakeOrigin?.inputSourceID ?? environment.ownInputSourceID)
            : environment.currentInputSource())
        if !restoreOrigin {
            wakeOrigin = nil
            cancelPendingRestore()
        }
        pendingRelease = false
        wakeTask?.cancel(); wakeTask = nil
        if isWaking { finishWake(started: false) }
        disarm()
        coordinator.cancel()
    }

    // MARK: - Global wake

    /// Select ourselves, wait briefly for the target to attach an IMK client, then start.
    private func beginGlobalWake() {
        cancelPendingRestore()
        retireSourceTransition(compensateTo: environment.currentInputSource())
        isWaking = true
        pendingRelease = false
        sessionFromGlobalWake = true
        let current = environment.currentInputSource()
        targetBundleID = environment.frontmostBundleID()
        targetPID = environment.frontmostPID()
        if let current, !environment.inputSourceSelected() {
            wakeOrigin = (current, targetBundleID, targetPID)
        }
        record("global-press", "current=\(current ?? "none") front=\(targetBundleID ?? "none") pid=\(targetPID.map(String.init) ?? "none")")
        host?.voiceSessionStateDidChange()
        if let prefs = host?.prefs, prefs.overlayEnabled {
            overlay.show(source: prefs.sourceLanguage.shortName, target: prefs.targetLanguage.shortName,
                         liveInject: true, hotkeyLabel: prefs.pushToTalk.shortLabel,
                         showsText: prefs.overlayShowsText)
            overlay.setPhase(.preparing, status: String(localized: "正在连接输入框…"))
        }
        if environment.inputSourceEnabled() && !environment.inputSourceSelected() {
            let token = beginSourceTransition(kind: .wakeToOwn, from: current,
                                              expected: environment.ownInputSourceID,
                                              action: environment.selectOwnInputSource)
            record("global-select", token == nil ? "failed" : "accepted")
            host?.refreshInputSourceStatus()
            if token == nil {
                fail(.actionable(String(localized: "无法切换到 Saylane 输入法，请先手动选中后重试。"), .permissions), fromGlobal: true)
                return
            }
        }
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in await self?.waitForClientAndStart() }
    }

    private func waitForClientAndStart() async {
        guard let host else { return }
        let started = environment.monotonicTime()
        let deadline = started + policy.clientWait
        var recoveryAttempts = 0
        let recoveryThresholds: [TimeInterval] = [0.25, 1.0]
        while environment.monotonicTime() < deadline {
            if Task.isCancelled { return }
            if !frontmostMatchesTarget() {
                cancel(restoreOrigin: false)
                return
            }
            if let transition = sourceTransition {
                switch transitionStatus(transition.token) {
                case .pending: break
                case .arrived: host.refreshInputSourceStatus()
                case .interrupted:
                    record("wake-cancelled", "unexpected source=\(environment.currentInputSource() ?? "none")")
                    cancel(restoreOrigin: false)
                    return
                case .timedOut:
                    break // `transitionStatus` itself never returns this case.
                }
            } else if environment.currentInputSource() != environment.ownInputSourceID {
                record("wake-cancelled", "user selected \(environment.currentInputSource() ?? "unknown")")
                cancel(restoreOrigin: false)
                return
            }
            host.refreshInputSourceStatus()
            if clientMatchesTarget(host) && environment.inputSourceSelected() { break }
            // Re-selecting an already selected source is a no-op. Rebuild a
            // stale connection with a verified out/back transition. Each
            // request is issued once and must reach its exact expected source.
            let elapsed = environment.monotonicTime() - started
            if recoveryAttempts < recoveryThresholds.count, environment.inputSourceSelected(),
               elapsed >= min(recoveryThresholds[recoveryAttempts], policy.clientWait * (recoveryAttempts == 0 ? 0.35 : 0.75)) {
                recoveryAttempts += 1
                await reconnectClient(attempt: recoveryAttempts, host: host, deadline: deadline)
                if !isWaking || Task.isCancelled { return }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if Task.isCancelled { return }
        guard environment.inputSourceSelected(), sourceTransition == nil else {
            retireSourceTransition(compensateTo: wakeOrigin?.inputSourceID ?? environment.ownInputSourceID)
            fail(.actionable(String(localized: "Saylane 没有在限定时间内接入当前输入框，请点进输入框后重试。"), .voice),
                 fromGlobal: true)
            return
        }
        startNow(fromGlobal: true)
    }

    private func finishWake(started: Bool) {
        let wasActive = isWaking || sessionFromGlobalWake
        isWaking = false
        pendingRelease = false
        retireSourceTransition(compensateTo: wakeOrigin?.inputSourceID ?? environment.ownInputSourceID)
        if !started {
            sessionFromGlobalWake = false
            overlay.hide()
            restoreInputSourceIfNeeded()
            if wasActive { host?.voiceSessionDidEnd(committed: false) }
        }
        host?.voiceSessionStateDidChange()
    }

    private func restoreInputSourceIfNeeded() {
        guard let origin = wakeOrigin else { return }
        wakeOrigin = nil
        guard host?.prefs.restoreInputSourceAfterSession == true else { return }
        let frontmost = environment.frontmostBundleID()
        let frontPID = environment.frontmostPID()
        guard (origin.bundleID == nil || frontmost == origin.bundleID),
              (origin.pid == nil || frontPID == origin.pid) else {
            record("restore-skipped", "front=\(frontmost ?? "none")")
            return
        }
        let current = environment.currentInputSource()
        if current == origin.inputSourceID {
            record("restore-input-source", "already-restored")
            host?.refreshInputSourceStatus()
            return
        }
        guard current == environment.ownInputSourceID else {
            record("restore-skipped", "source=\(current ?? "none")")
            return
        }
        restoreTask?.cancel()
        sourceToken += 1
        let pending = PendingRestore(token: sourceToken, originID: origin.inputSourceID,
                                     bundleID: origin.bundleID, pid: origin.pid)
        pendingRestore = pending
        restoreTask = Task { [weak self] in
            guard let self else { return }
            await Task.yield()
            for attempt in 1...3 {
                guard !Task.isCancelled, self.pendingRestore?.token == pending.token,
                      !self.isWaking, !self.isListening else { return }
                let front = self.environment.frontmostBundleID()
                let pid = self.environment.frontmostPID()
                guard (pending.bundleID == nil || front == pending.bundleID),
                      (pending.pid == nil || pid == pending.pid) else {
                    self.record("restore-skipped", "front=\(front ?? "none")")
                    self.cancelPendingRestore()
                    return
                }
                let current = self.environment.currentInputSource()
                if current == pending.originID {
                    self.record("restore-input-source", "verified attempt=\(attempt)")
                    self.finishPendingRestore(token: pending.token)
                    self.host?.refreshInputSourceStatus()
                    return
                }
                guard current == self.environment.ownInputSourceID else {
                    self.record("restore-skipped", "user-source=\(current ?? "none")")
                    self.cancelPendingRestore()
                    return
                }
                let token = self.beginSourceTransition(kind: .restore, from: current,
                                                       expected: pending.originID) {
                    self.environment.selectInputSource(pending.originID)
                }
                self.record("restore-input-source", "attempt=\(attempt) accepted=\(token != nil)")
                guard let token else { continue }
                let status = await self.waitForSourceTransition(token, timeout: 0.12 * Double(attempt))
                if status == .arrived {
                    self.finishPendingRestore(token: pending.token)
                    self.host?.refreshInputSourceStatus()
                    return
                }
                if status == .interrupted { self.cancelPendingRestore(); return }
            }
            self.record("restore-input-source", "failed actual=\(self.environment.currentInputSource() ?? "none")")
            self.finishPendingRestore(token: pending.token)
            self.host?.refreshInputSourceStatus()
        }
    }

    @discardableResult
    private func beginSourceTransition(kind: SourceTransitionKind, from: String?, expected: String,
                                       action: () -> Bool) -> Int? {
        retireSourceTransition(compensateTo: expected)
        sourceToken += 1
        let transition = SourceTransition(token: sourceToken, kind: kind, fromID: from, expectedID: expected)
        sourceTransition = transition
        guard action() else {
            if sourceTransition?.token == transition.token { sourceTransition = nil }
            return nil
        }
        return transition.token
    }

    private func transitionStatus(_ token: Int) -> TransitionStatus {
        guard let transition = sourceTransition, transition.token == token else {
            return .interrupted
        }
        let current = environment.currentInputSource()
        if current == transition.expectedID {
            sourceTransition = nil
            return .arrived
        }
        if current == nil || current == transition.fromID { return .pending }
        retireSourceTransition(compensateTo: current)
        return .interrupted
    }

    private func waitForSourceTransition(_ token: Int, timeout: TimeInterval) async -> TransitionStatus {
        let deadline = environment.monotonicTime() + timeout
        while environment.monotonicTime() < deadline {
            if Task.isCancelled { return .interrupted }
            let status = transitionStatus(token)
            if status != .pending { return status }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return .interrupted }
        }
        let status = transitionStatus(token)
        if status == .pending, sourceTransition?.token == token {
            // A late restore/back arrival is still useful until the user changes
            // app/source. A late temporary ABC/wake arrival needs compensation.
            let temporary = sourceTransition?.kind == .bridgeOut || sourceTransition?.kind == .wakeToOwn
            retireSourceTransition(compensateTo: temporary
                ? (wakeOrigin?.inputSourceID ?? environment.ownInputSourceID) : nil)
        }
        return status == .pending ? .timedOut : status
    }

    private func retireSourceTransition(compensateTo destination: String?) {
        guard let transition = sourceTransition else { return }
        sourceTransition = nil
        guard environment.currentInputSource() != transition.expectedID else { return }
        retiredSourceRequests.removeAll { $0.expiresAt <= environment.monotonicTime() }
        retiredSourceRequests.append(RetiredSourceRequest(transition: transition,
            expiresAt: environment.monotonicTime() + 2, compensationID: destination))
        if retiredSourceRequests.count > 8 { retiredSourceRequests.removeFirst() }
    }

    /// A manual source/app change supersedes even requests whose Tasks already
    /// timed out. Preserve that choice if an accepted old request lands later.
    private func supersedeRetiredRequests(with sourceID: String?) {
        guard let sourceID else { return }
        for index in retiredSourceRequests.indices {
            if retiredSourceRequests[index].transition.expectedID != sourceID {
                retiredSourceRequests[index].compensationID = sourceID
            }
        }
    }

    @discardableResult
    private func compensateRetiredSourceArrival(_ current: String?) -> Bool {
        retiredSourceRequests.removeAll { $0.expiresAt <= environment.monotonicTime() }
        guard let current,
              let receipt = retiredSourceRequests.last(where: { $0.transition.expectedID == current }) else { return false }
        retiredSourceRequests.removeAll { $0.transition.expectedID == current }
        // A newer live request for this same source owns the arrival now.
        if sourceTransition?.expectedID == current { return false }
        guard let destination = receipt.compensationID, destination != current else { return false }
        record("late-source-arrival", "kind=\(receipt.transition.kind) actual=\(current) restore=\(destination)")
        // One bounded compensation request. Its own late arrival is observed as
        // a bridge-back receipt and never causes an unbounded selection loop.
        guard let token = beginSourceTransition(kind: .bridgeBack, from: current, expected: destination, action: {
            environment.selectInputSource(destination)
        }) else { return false }
        if transitionStatus(token) == .pending {
            Task { [weak self] in
                guard let self else { return }
                _ = await self.waitForSourceTransition(token, timeout: 0.35)
                self.host?.refreshInputSourceStatus()
            }
        }
        host?.refreshInputSourceStatus()
        return true
    }

    private func reconnectClient(attempt: Int, host: VoiceSessionHost, deadline: TimeInterval) async {
        guard let bridgeID = environment.asciiInputSourceID(),
              bridgeID != environment.ownInputSourceID,
              environment.currentInputSource() == environment.ownInputSourceID else { return }
        let priorLease = host.clientGeneration
        guard let outToken = beginSourceTransition(kind: .bridgeOut,
                                                   from: environment.ownInputSourceID,
                                                   expected: bridgeID,
                                                   action: environment.selectASCIILayout) else {
            record("client-reconnect", "attempt=\(attempt) bridge-request-failed")
            return
        }
        record("client-reconnect", "attempt=\(attempt) bridge=\(bridgeID)")
        let remaining = max(0.05, min(0.45, deadline - environment.monotonicTime()))
        let outStatus = await waitForSourceTransition(outToken, timeout: remaining)
        guard isWaking, !Task.isCancelled else { return }
        guard outStatus == .arrived, environment.currentInputSource() == bridgeID else {
            if outStatus == .interrupted, environment.currentInputSource() != environment.ownInputSourceID {
                cancel(restoreOrigin: false)
            }
            return
        }

        // Source change and IMK deactivation are separate notifications. Give
        // the old receiver a bounded chance to invalidate before selecting back.
        let detachDeadline = min(deadline, environment.monotonicTime() + 0.25)
        while host.clientGeneration == priorLease, host.hasIMKClient,
              environment.monotonicTime() < detachDeadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
        guard isWaking, !Task.isCancelled, environment.currentInputSource() == bridgeID else { return }
        guard let backToken = beginSourceTransition(kind: .bridgeBack, from: bridgeID,
                                                    expected: environment.ownInputSourceID,
                                                    action: environment.selectOwnInputSource) else {
            await unwindOwnedBridge(bridgeID)
            cancel(restoreOrigin: false)
            return
        }
        let backStatus = await waitForSourceTransition(backToken,
            timeout: max(0.05, min(0.45, deadline - environment.monotonicTime())))
        if backStatus != .arrived, environment.currentInputSource() == bridgeID {
            await unwindOwnedBridge(bridgeID)
        }
        if backStatus != .arrived, environment.currentInputSource() != environment.ownInputSourceID {
            cancel(restoreOrigin: false)
        }
        host.refreshInputSourceStatus()
    }

    /// A failed bridge-back request must not strand the user on our temporary
    /// ASCII source. Restore only while that exact bridge still owns selection;
    /// a third source is a user choice and is never overwritten.
    private func unwindOwnedBridge(_ bridgeID: String) async {
        guard environment.currentInputSource() == bridgeID else { return }
        let destination = wakeOrigin?.inputSourceID ?? environment.ownInputSourceID
        guard let token = beginSourceTransition(kind: .bridgeBack, from: bridgeID,
                                                expected: destination, action: {
            environment.selectInputSource(destination)
        }) else { return }
        _ = await waitForSourceTransition(token, timeout: 0.35)
    }

    private func frontmostMatchesTarget() -> Bool {
        let bundle = environment.frontmostBundleID()
        let pid = environment.frontmostPID()
        guard targetBundleID == nil || bundle == targetBundleID else { return false }
        guard targetPID == nil || pid == targetPID else { return false }
        return true
    }

    private func finishPendingRestore(token: Int) {
        guard pendingRestore?.token == token else { return }
        pendingRestore = nil
        if sourceTransition?.kind == .restore { retireSourceTransition(compensateTo: nil) }
        restoreTask = nil
    }

    private func cancelPendingRestore() {
        restoreTask?.cancel()
        restoreTask = nil
        pendingRestore = nil
        if sourceTransition?.kind == .restore { retireSourceTransition(compensateTo: environment.currentInputSource()) }
    }

    // MARK: - Start

    private func startNow(fromGlobal: Bool) {
        guard let host, !isListening else { return }
        host.refreshInputSourceStatus()
        let p = host.prefs
        let readiness = host.readinessState
        let inSettings = host.isVoiceTrialActive
        record("start-check", "settings=\(inSettings) selected=\(readiness.inputSource.selected) client=\(host.hasIMKClient) host=\(host.clientBundleID ?? "none") front=\(environment.frontmostBundleID() ?? "none") mic=\(readiness.permissions.microphone == .granted) speech=\(readiness.models.speechReady) translation=\(readiness.models.translationReady) checking=\(readiness.models.busy)")

        let target: any CompositionTarget
        usesAccessibilityTarget = false
        if inSettings {
            guard let captured = host.settingsCaptureTarget() else { fail(nil, fromGlobal: fromGlobal); return }
            target = captured
        } else {
            guard environment.inputSourceSelected() else {
                fail(.actionable(String(localized: "Saylane 尚未成为当前输入法，请手动选中后重试。"), .permissions),
                     fromGlobal: fromGlobal)
                return
            }
            if let blocker = readiness.blocker {
                fail(.actionable(blocker.message, ReadinessReducer.destination(for: blocker)), fromGlobal: fromGlobal)
                return
            }
            if clientMatchesTarget(host), let captured = host.captureTarget() {
                target = captured
            } else if p.accessibilityFallbackEnabled, AccessibilityInserter.isTrusted,
                      let captured = AccessibilityTarget(bundleID: targetBundleID ?? environment.frontmostBundleID(),
                          inputRevision: { [weak host] in host?.keyboardInputRevision ?? UInt64.max }) {
                target = captured
                usesAccessibilityTarget = true
                host.post(.transient(String(localized: "这个应用不支持组字，说完后会以粘贴方式写入。")))
                record("accessibility-fallback")
            } else {
                fail(.actionable(String(localized: "当前应用没有可输入的文本框，或它不支持输入法组字。请点进文本框后重试。"), .voice), fromGlobal: fromGlobal)
                return
            }
        }
        if fromGlobal { isWaking = false }
        if !fromGlobal {
            targetBundleID = environment.frontmostBundleID()
            targetPID = environment.frontmostPID()
        }

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
        if !isListening { fail(nil, fromGlobal: fromGlobal); return }
        if pendingRelease {
            pendingRelease = false
            coordinator.release()
        }
    }

    private func fail(_ notice: UserNotice?, fromGlobal: Bool) {
        disarm()
        if fromGlobal { finishWake(started: false) }
        if let notice { host?.post(notice) }
    }

    private func clientMatchesTarget(_ host: VoiceSessionHost) -> Bool {
        host.hasIMKClient && (targetBundleID == nil || host.clientBundleID == targetBundleID)
    }

    func inputSourceChanged() {
        // Only the exact from→expected edge owned by a transaction is allowed.
        // A third source at any point is user intent and cancels pending work.
        guard host?.isVoiceTrialActive != true else { return }
        let current = environment.currentInputSource()
        if compensateRetiredSourceArrival(current) { return }
        if let transition = sourceTransition {
            if current == transition.expectedID || current == transition.fromID || current == nil { return }
            record("source-transition-interrupted", "kind=\(transition.kind) actual=\(current ?? "none")")
            supersedeRetiredRequests(with: current)
            retireSourceTransition(compensateTo: current)
            if pendingRestore != nil { cancelPendingRestore() }
            if isWaking || isListening { cancel(restoreOrigin: false) }
            return
        }
        if let pending = pendingRestore {
            if current == pending.originID { return }
            if current != environment.ownInputSourceID {
                record("restore-cancelled", "user selected \(current ?? "none")")
                supersedeRetiredRequests(with: current)
                cancelPendingRestore()
            }
            return
        }
        supersedeRetiredRequests(with: current)
        if isWaking {
            if current != environment.ownInputSourceID { cancel(restoreOrigin: false) }
            return
        }
        guard isListening else { return }
        // Distributed TIS notifications may arrive after polling already saw
        // the expected source and the IMK client started recording. A duplicate
        // notification that still reports Saylane is confirmation, not a user
        // switch away.
        if current == environment.ownInputSourceID { return }
        // The user explicitly chose another source. Respect it instead of
        // cancelling and immediately switching them back to the wake origin.
        cancel(restoreOrigin: false)
    }

    // MARK: - External changes

    /// Attachment may fluctuate during wake-up. Once a target is captured,
    /// losing it must cancel, even when the session started from a global hotkey.
    func targetLost() {
        if isWaking || host?.isVoiceTrialActive == true { return }
        guard isListening else { return }
        coordinator.cancel()
    }

    /// Another application came to the front.
    func frontmostAppChanged(to bundleID: String?, pid: pid_t? = nil) {
        supersedeRetiredRequests(with: environment.currentInputSource())
        if let pending = pendingRestore {
            let sameBundle = pending.bundleID == nil || bundleID == pending.bundleID
            let sameProcess = pending.pid == nil || pid == pending.pid
            if !sameBundle || !sameProcess {
                record("restore-cancelled", "app switched to \(bundleID ?? "none") pid=\(pid.map(String.init) ?? "none")")
                cancelPendingRestore()
            }
        }
        guard isListening || isWaking else { return }
        if host?.isVoiceTrialActive == true, bundleID == environment.ownBundleID { return }
        let sameBundle = targetBundleID == nil || bundleID == targetBundleID
        let sameProcess = targetPID == nil || pid == targetPID
        guard sameBundle && sameProcess else {
            record("session-cancelled", "app switched to \(bundleID ?? "none") pid=\(pid.map(String.init) ?? "none")")
            cancel(restoreOrigin: false)
            return
        }
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
                if p?.overlayEnabled == true, let p {
                    if self.overlay.model.phase == .hidden {
                        self.overlay.show(source: p.sourceLanguage.shortName, target: p.targetLanguage.shortName,
                                          liveInject: true, hotkeyLabel: p.pushToTalk.shortLabel,
                                          showsText: p.overlayShowsText)
                    } else {
                        self.overlay.setPhase(.preparing)
                    }
                }
            case .listening:
                self.listeningStartedAt = ProcessInfo.processInfo.systemUptime
                self.overlay.setPhase(.listening)
            case .finalizing: self.overlay.setPhase(.finalizing)
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
            guard self.host?.prefs.overlayEnabled == true else { self.overlay.hide(); return }
            if feedback.isWarning { self.overlay.showCompletion(feedback) } else { self.overlay.playFinishSweepThenHide() }
        }
        coordinator.onLevel = { [weak self] in self?.overlay.setLevel($0) }
        coordinator.onSourceText = { [weak self] text in
            guard let self, self.host?.prefs.overlayShowsText == true else { return }
            self.overlay.setSource(text)
        }
        coordinator.onDisplayedText = { [weak self] text in
            guard let self, self.host?.prefs.overlayShowsText == true else { return }
            self.overlay.setTranslation(text)
        }
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
        usesAccessibilityTarget = false
        restoreInputSourceIfNeeded()
        isWaking = false
        pendingRelease = false
        sessionFromGlobalWake = false
        preroll = nil
        targetBundleID = nil
        targetPID = nil
        retireSourceTransition(compensateTo: environment.currentInputSource())
        host?.voiceSessionDidEnd(committed: committed)
    }

}
