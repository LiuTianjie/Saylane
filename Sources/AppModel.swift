import AppKit
import Carbon
import Foundation
import Observation
import SwiftUI

/// Composition root and the single object views observe. It owns no feature
/// logic itself: preferences live in `PreferencesStore`, readiness in
/// `Readiness` (reduced from events), input in `InputEventRouter`, voice in
/// `VoiceSessionController`, models in `ModelCoordinator`, screen translation in
/// `ScreenTranslateController` and pinyin in `PinyinEngine`.
@MainActor @Observable
final class AppModel: VoiceSessionHost {
    static let shared = AppModel()

    // MARK: State

    let preferences: PreferencesStore
    var prefs: Preferences { preferences.current }
    private(set) var readinessState = Readiness()
    /// The one user-facing message. `post(_:)` decides how it is shown.
    var notice: UserNotice?

    // MARK: Features

    let permissionsController = PermissionsController()
    var permissions: PermissionService { permissionsController.service }
    let translation = TranslationProvider()
    let models: ModelCoordinator
    let voice: VoiceSessionController
    let screen = ScreenFeature()
    var screenTranslate: ScreenTranslateController { screen.controller }
    let pinyin = PinyinEngine()
    let pinyinDictionaryUpdates = RimeDictionaryUpdateModel()
    let router = InputEventRouter()
    private let settingsWindow = SettingsController()

    // MARK: Settings UI state

    var settingsTab = 1
    var isShowingSetup = false
    /// Settings-panel trial field. Voice writes here; the host is not an IMK client.
    var testText = ""
    private(set) var dictationTrialVisible = false
    var isRecordingScreenShortcut: Bool { screen.isRecordingShortcut }
    var shortcutRecordingVerdict: ShortcutValidator.Verdict? { screen.recordingVerdict }
    var lastLanguageSwitch: String?
    var isActivatingInputSource: Bool { permissionsController.isActivatingInputSource }
    private var settingsCapture: SettingsCaptureTarget?
    private var lastPermissionRefreshAt: TimeInterval = -.infinity
    private var lastTapAttemptAt: TimeInterval = -.infinity
    private var lastTapOutcome: String?
    private var noticeExpiry: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private struct DeferredIMEInput {
        let event: NSEvent
        let leaseID: UUID
        let clientGeneration: Int
    }
    private var deferredIMEInput: [DeferredIMEInput] = []
    /// The user typed on while a result was still being finalized: keys are no
    /// longer held back for the rest of this dictation.
    private var typingResumedDuringFinalization = false
    private let deferredInputDeadline = InputDeferralDeadline()
    private struct DeferredSettingsInput {
        let event: NSEvent
        let responder: ObjectIdentifier?
    }
    private var deferredSettingsInput: [DeferredSettingsInput] = []
    private var replayingSettingsInput = false

    // MARK: Derived

    var currentDirection: TranslationDirection { prefs.currentDirection }
    var sessionState: SessionState { voice.state }
    var isListening: Bool { voice.isListening }
    var isChecking: Bool { models.isChecking }
    var isPreparingModels: Bool { models.isPreparing }
    var asrModels: ASRModelStore { models.asrModels }
    var readiness: SetupReadiness { readinessState.setup }
    var ready: Bool { readinessState.isReady }
    var completedSessions: Int { voice.completedSessions }
    var globalHotkeyActive: Bool { readinessState.globalInvokeAvailable }
    var isSettingsWindowVisible: Bool { settingsWindow.isVisible }
    var isVoiceTrialActive: Bool { dictationTrialVisible && settingsWindow.isFocused }
    var setupCompleted: Bool { prefs.onboardingCompleted }
    var pinyinEnglishMode: Bool { prefs.pinyinEnglishMode }

    private init() {
        AppDirectories.migrateLegacyLayout()
        preferences = PreferencesStore()
        models = ModelCoordinator(preferences: preferences.current, translation: translation)
        voice = VoiceSessionController()
        voice.host = self
    }

    // MARK: - Bootstrap

    func bootstrap() {
        InputDiagnostics.record("app-start", "version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") trigger=\(prefs.pushToTalk.rawValue)")
        NSApp.setActivationPolicy(.accessory)
        voice.overlay.prepare()
        voice.overlay.setHotkeyLabel(prefs.pushToTalk.shortLabel)
        pinyin.applyPreferences(prefs)
        if let error = pinyin.initializationError {
            InputDiagnostics.record("pinyin-init-failed", error)
        } else {
            InputDiagnostics.record("pinyin-ready", "librime")
        }
        pinyin.onEnglishModeChanged = { [weak self] enabled in
            self?.preferences.update { $0.pinyinEnglishMode = enabled }
        }
        models.onReadiness = { [weak self] event in self?.reduce(event) }
        models.onNotice = { [weak self] notice in self?.post(notice) }
        router.onAction = { [weak self] action in self?.perform(action) }
        router.onGlobalCapabilityChanged = { [weak self] listening, _ in
            guard let self else { return }
            self.reduce(.globalInvoke(available: listening))
            self.syncRouterContext()
        }
        permissionsController.onNotice = { [weak self] notice in self?.post(notice) }
        permissionsController.onChanged = { [weak self] in self?.refreshInputSourceStatus() }
        wireScreen()

        IMEManager.shared.onWillSwitchClient = { [weak self] controller in self?.pinyin.switchClient(to: controller?.sessionID) }
        // IMK may activate before applicationDidFinishLaunching wires these
        // observers. Synchronize an already attached client as well.
        pinyin.switchClient(to: IMEManager.shared.controller?.sessionID)

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = application?.bundleIdentifier
            let pid = application?.processIdentifier
            Task { @MainActor in
                guard let self else { return }
                self.voice.frontmostAppChanged(to: bundleID, pid: pid)
                self.refreshStatus(throttled: true)
            }
        }
        inputSourceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshStatus(throttled: true)
                self.retryGlobalHotkeyMonitor()
            }
        }
        startGlobalHotkeyMonitor()
        refreshInputSourceStatus()
        models.apply(prefs)
        refreshGlossaryIfNeeded()
    }

    private func startGlobalHotkeyMonitor() {
        lastTapAttemptAt = ProcessInfo.processInfo.systemUptime
        syncRouterContext()
        let ok = router.startGlobalTap()
        reduce(.globalInvoke(available: router.isGlobalTapListening))
        // Filtering can change while availability stays true (listen-only →
        // consumable). Read it after the monitor has negotiated its backend.
        syncRouterContext()
        let outcome = ok ? (router.isGlobalTapFiltering ? "filter" : "listen") : "failed"
        if outcome != lastTapOutcome {
            lastTapOutcome = outcome
            InputDiagnostics.record("global-tap", outcome)
        }
    }

    /// Focus and input-source changes arrive many times a second. Each attempt
    /// asks the privacy database several questions, so a missing permission is
    /// re-checked at most every few seconds.
    private func retryGlobalHotkeyMonitor() {
        guard !router.isGlobalTapListening,
              ProcessInfo.processInfo.systemUptime - lastTapAttemptAt > 5 else { return }
        startGlobalHotkeyMonitor()
    }

    // MARK: - Readiness

    private func reduce(_ event: ReadinessEvent) {
        let next = ReadinessReducer.reduce(readinessState, event)
        guard next != readinessState else { return }
        readinessState = next
        // A blocker the user was told about has been resolved: drop the banner.
        if let notice, notice.level == .actionable, next.isReady,
           notice.destination == .permissions || notice.destination == .models {
            self.notice = nil
        }
        syncRouterContext()
    }

    func refreshInputSourceStatus() { refreshStatus(throttled: false) }

    /// `throttled` is for focus and input-source notifications: the input
    /// source is re-read every time, permissions at most every few seconds
    /// unless the settings window is showing them.
    private func refreshStatus(throttled: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !throttled || settingsWindow.isVisible || now - lastPermissionRefreshAt > 3 {
            lastPermissionRefreshAt = now
            let monitoringWasGranted = readinessState.permissions.inputMonitoring
            permissionsController.refresh()
            let currentPermissions = permissionsController.permissions
            reduce(.permissions(currentPermissions))
            // Returning from System Settings is the normal point at which an input
            // monitoring grant becomes visible.  A listen-only fallback created
            // before the grant does not upgrade itself, so rebuild the tap once on
            // the permission transition.
            if currentPermissions.inputMonitoring && !monitoringWasGranted {
                startGlobalHotkeyMonitor()
            }
        }
        reduce(.inputSource(permissionsController.inputSource))
        reduce(.globalInvoke(available: router.isGlobalTapListening))
    }

    private func syncRouterContext() {
        let p = prefs
        // Never acquire the monitor's state lock from inside the router's shared
        // arbiter lock; the event-tap callback takes them in the opposite order.
        let globalEventsCanBeConsumed = router.isGlobalTapFiltering
        router.updateContext {
            $0.trigger = p.pushToTalk
            $0.switchEnabled = p.languageSwitchEnabled
            $0.tapToTalk = p.tapToTalk
            $0.isListening = isListening
            $0.voiceCapturing = voice.isCapturing
            $0.voiceEnabled = readinessState.inputSource.enabled || isVoiceTrialActive
            $0.isOursSelected = readinessState.inputSource.selected
            $0.globalEventsCanBeConsumed = globalEventsCanBeConsumed
            $0.screenShortcut = p.screenCaptureShortcut
            $0.screenHoldEnabled = p.screenHoldEnabled
            $0.screenActive = screenTranslate.isActive
            $0.pinVisible = screenTranslate.isPinVisible
            $0.recordingShortcut = isRecordingScreenShortcut
        }
    }

    // MARK: - Notices

    func post(_ notice: UserNotice) {
        InputDiagnostics.record("notice", "\(notice.level) \(notice.message)")
        NSLog("Saylane: %@", notice.message)
        noticeExpiry?.cancel(); noticeExpiry = nil
        switch notice.level {
        case .diagnostic:
            return
        case .transient:
            voice.showNotice(notice)
            if settingsWindow.isVisible {
                self.notice = notice
                noticeExpiry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(notice.hudDuration))
                    guard let self, self.notice?.id == notice.id else { return }
                    self.notice = nil
                }
            }
        case .actionable:
            self.notice = notice
            voice.showNotice(notice)
        }
    }

    func dismissNotice() { notice = nil }

    // MARK: - Preferences

    /// Two-way binding for settings views. Side effects run in `preferencesDidChange`.
    func binding<T: Equatable>(_ keyPath: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { self.prefs[keyPath: keyPath] }, set: { self.set(keyPath, $0) })
    }

    func set<T: Equatable>(_ keyPath: WritableKeyPath<Preferences, T>, _ value: T) {
        update { $0[keyPath: keyPath] = value }
    }

    func update(_ mutate: (inout Preferences) -> Void) {
        let old = prefs
        preferences.update(mutate)
        let new = prefs
        guard new != old else { return }
        preferencesDidChange(from: old, to: new)
    }

    private func preferencesDidChange(from old: Preferences, to new: Preferences) {
        if new.sourceLanguage != old.sourceLanguage || new.targetLanguage != old.targetLanguage
            || new.speechModel != old.speechModel || new.recognitionOnly != old.recognitionOnly {
            voice.cancel(); router.reset()
            models.apply(new)
        }
        if new.pushToTalk != old.pushToTalk || new.tapToTalk != old.tapToTalk || new.languageSwitchEnabled != old.languageSwitchEnabled {
            voice.cancel(); router.reset()
            voice.overlay.setHotkeyLabel(new.pushToTalk.shortLabel)
        }
        if new.dictationGlossaryEnabled && !old.dictationGlossaryEnabled {
            Task { await DictationGlossaryStore.shared.refreshIfStale() }
        }
        if new.pinyinEnglishMode != old.pinyinEnglishMode || new.pinyinBarPreeditEnabled != old.pinyinBarPreeditEnabled
            || new.pinyinFuzzyEnabled != old.pinyinFuzzyEnabled {
            pinyin.applyPreferences(new)
        }
        if new.screenPinFreezesScreen != old.screenPinFreezesScreen || new.screenFontWeightExperiment != old.screenFontWeightExperiment {
            screen.apply(new)
        }
        syncRouterContext()
    }

    /// One change, one model reload, whichever of the two languages moved.
    func setLanguagePair(a: AppLanguage, b: AppLanguage) {
        update {
            $0.pairSource = a
            $0.pairTarget = b
            $0.sourceLanguage = a
            $0.targetLanguage = b
        }
    }

    func setVoiceMode(_ direction: TranslationDirection) {
        guard !isListening, !isPreparingModels, currentDirection != direction else { return }
        update { $0.sourceLanguage = direction.source; $0.targetLanguage = direction.target }
        announceDirection(direction)
    }

    func swapTranslationDirection() {
        guard !isListening, !isPreparingModels else { return }
        let next = TranslationDirection.cycled(current: currentDirection, a: prefs.pairSource, b: prefs.pairTarget)
        update { $0.sourceLanguage = next.source; $0.targetLanguage = next.target }
        announceDirection(next)
        InputDiagnostics.record("translation-direction-cycled", next.id)
    }

    private func announceDirection(_ direction: TranslationDirection) {
        voice.overlay.showLanguageSwitch(from: direction.source.displayName, to: direction.target.displayName, title: direction.title)
        lastLanguageSwitch = String(localized: "\(direction.title)：我说 \(direction.source.displayName) → 写成 \(direction.target.displayName)")
    }

    func selectSpeechModel(_ selected: SpeechModel) {
        guard !isListening, models.canSelect(selected) else { return }
        notice = nil
        set(\.speechModel, selected)
    }

    func removeSpeechModel(_ selected: SpeechModel) async {
        guard !isListening else { return }
        if await models.removeSpeechModel(selected) { set(\.speechModel, .apple) } else { models.apply(prefs) }
    }

    func downloadSpeechModel(_ selected: SpeechModel) async {
        guard !isListening else { return }
        notice = nil
        await models.downloadSpeechModel(selected)
    }

    func downloadModels() async {
        guard !isListening else { return }
        notice = nil
        await models.downloadModels()
    }

    func refreshModelStatus() async { await models.refreshStatus() }

    // MARK: - Input

    /// IMK delivered a key while Saylane is the selected input source.
    func consumeIMEEvent(_ event: NSEvent) -> Bool {
        pinyin.ensureClient(IMEManager.shared.currentLeaseID)
        if router.feed(event, source: .imk) { return true }
        // Optional polish never blocks typing: the ordinary result is already
        // complete and can be committed before handling this same event.
        if voice.state == .polishing {
            _ = voice.commitCompletedOutputForUserInput()
        }
        if voice.state == .finalizing {
            // A bare modifier is not typing.
            guard event.type == .keyDown else { return pinyin.handle(event, pushToTalk: prefs.pushToTalk) }
            guard !typingResumedDuringFinalization, deferredIMEInput.count < 64,
                  PinyinKeyEvent(event).canDeferForVoiceFinalization,
                  let snapshot = IMEManager.shared.deferredInputSnapshot else {
                // Commands cannot be reconstructed through IMKTextInput, so they
                // stay on this callback. The dictation is not discarded: its
                // preview is withdrawn and the result is written when it is ready.
                resumeTypingDuringFinalization()
                return pinyin.handle(event, pushToTalk: prefs.pushToTalk)
            }
            deferredIMEInput.append(DeferredIMEInput(event: event, leaseID: snapshot.leaseID,
                                                      clientGeneration: snapshot.generation))
            armDeferredIMEFence()
            return true
        }
        // Cancellation has already removed the run and cleared its marked text;
        // speech cleanup may continue without blocking ordinary Pinyin input.
        if voice.state == .cancelling {
            return pinyin.handle(event, pushToTalk: prefs.pushToTalk)
        }
        if isListening { return false }
        return pinyin.handle(event, pushToTalk: prefs.pushToTalk)
    }

    /// Key events while the settings window is key.
    func handleSettingsShortcut(_ event: NSEvent) -> NSEvent? {
        guard settingsWindow.isVisible else { return event }
        if replayingSettingsInput { return event }
        if router.feed(event, source: .settingsWindow) { return nil }
        guard event.type == .keyDown else { return event }
        if voice.state == .polishing {
            _ = voice.commitCompletedOutputForUserInput()
        }
        if voice.state == .finalizing {
            guard PinyinKeyEvent(event).canDeferForVoiceFinalization,
                  deferredSettingsInput.count < 64 else {
                voice.cancel()
                replayDeferredSettingsInput()
                return event
            }
            deferredSettingsInput.append(DeferredSettingsInput(
                event: event, responder: settingsWindow.focusedResponderIdentity))
            armDeferredIMEFence()
            return nil
        }
        return event
    }

    private func perform(_ action: InputAction) {
        InputDiagnostics.record("input-action", String(describing: action))
        switch action {
        case .voice(let gesture):
            switch gesture {
            case .armHold, .armTap:
                guard !screenTranslate.isActive else { return }
                // Opening the microphone on every ⌘/⌃/⇧ press would flash the
                // recording indicator for ordinary shortcuts; those keys start
                // capturing when the hold is confirmed.
                if gesture == .armTap || !prefs.pushToTalk.isChordModifier { voice.arm() }
            case .disarm:
                voice.disarm()
            case .press:
                guard !screenTranslate.isActive else { return }
                if !prefs.pushToTalk.isModifier && !router.isGlobalTapFiltering {
                    voice.disarm()
                    post(.actionable(String(localized: "功能键语音快捷键需要辅助功能权限，才能拦截按键并可靠收到松开事件。"), .permissions))
                    return
                }
                if prefs.pushToTalk.isModifier, !prefs.tapToTalk, Self.keyWentDownDuringHold() {
                    // Applications handle ⌘-shortcuts before the input method
                    // sees the key, so the chord is read from the system instead.
                    InputDiagnostics.record("hold-abandoned", "key pressed during hold")
                    voice.disarm()
                    return
                }
                voice.press()
            case .release:
                voice.release()
            case .cancel:
                voice.cancel()
            case .switchTarget:
                voice.disarm()
                cycleDirection()
            case .none:
                break
            }
        case .switchDirection:
            cycleDirection()
        case .screenCapture:
            screen.handleCaptureHotkey()
        case .screenHold(let hold):
            screen.handleHold(hold)
        case .screenPin(let key):
            screen.handlePinKey(key)
        case .recordedShortcut(let shortcut):
            screen.finishRecordingShortcut(shortcut)
        }
    }

    /// A key was pressed while the talk key was being held, as seen by the
    /// window server. Needs no permission and works under any input source.
    private static func keyWentDownDuringHold() -> Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < InputShortcutHandler.holdDelay
    }

    private func cycleDirection() {
        if screen.isActive { screen.cycleDirection() } else { swapTranslationDirection() }
    }

    func endSession() { voice.release() }

    // MARK: VoiceSessionHost

    func makeSpeechEngine() -> any SpeechRecognizing {
        // Apple biases recognition with contextual strings, Qwen with its prompt; the FunASR
        // CLIs accept no hotwords, so those engines rely on post-recognition vocabulary repair.
        let model = prefs.speechModel
        if model == .apple { return SpeechEngine(contextualStrings: vocabularyTerms) }
        let prompt = model.isQwen ? SpeechHotwords.context(terms: vocabularyTerms) : nil
        return QwenSpeechEngine(variant: model, context: prompt, runtime: QwenRuntime.shared)
    }

    private var vocabularyTerms: [String] {
        DictationGlossary.biasTerms(userRaw: prefs.speechHotwords, includeUser: prefs.speechHotwordsEnabled,
                                    includeGlossary: prefs.dictationGlossaryEnabled,
                                    remote: DictationGlossaryStore.shared.terms)
    }

    /// Deterministic, on-device repair applied only to the final recognized text.
    func makeRefine() -> ((String) -> String)? {
        let p = prefs
        let glossary = p.dictationGlossaryEnabled
            ? DictationVocabulary(entries: DictationGlossary.combined(remote: DictationGlossaryStore.shared.terms)) : nil
        let vocabulary = p.speechHotwordsEnabled ? DictationVocabulary(raw: p.speechHotwords) : nil
        guard p.dictationCleanupEnabled || glossary?.isEmpty == false || vocabulary?.isEmpty == false else { return nil }
        return { text in
            var result = p.dictationCleanupEnabled ? DictationCleanup.clean(text) : text
            if let glossary { result = glossary.apply(to: result) }
            if let vocabulary { result = vocabulary.apply(to: result) }
            return result
        }
    }

    func makePolish() -> ((String, String) async throws -> String)? {
        let p = prefs
        guard p.finalPolishEnabled else { return nil }
        // Freeze the request destination and languages for this utterance.
        let endpoint = p.finalPolishEndpoint, model = p.finalPolishModel
        let sourceCode = p.sourceLanguage.rawValue, targetCode = p.targetLanguage.rawValue
        let terms = vocabularyTerms
        return { original, draft in
            let config = try FinalPolishConfiguration(endpoint: endpoint, model: model)
            let key = try PolishKeychain.read(endpoint: config.endpoint)
            let result = try await FinalPolishService.polish(configuration: config, apiKey: key,
                original: original, draft: draft, sourceLanguage: sourceCode, targetLanguage: targetCode, vocabulary: terms)
            // Same-language proofreading may only touch a little; anything more is a rewrite.
            if sourceCode == targetCode, !FinalPolishService.isPlausibleProofread(original: draft, polished: result) { throw PolishRejected() }
            return result
        }
    }

    func translate(_ text: String) async throws -> String { try await translation.translate(text) }

    func textSink(inFront bundleID: String?) -> VoiceTextSink {
        let ime = IMEManager.shared
        InputDiagnostics.record("voice-target", "imk=\(ime.canWriteVoice(inFront: bundleID)) client=\(ime.clientBundleID ?? "none") paste=\(AccessibilityInserter.isTrusted)")
        return VoiceTextSink(
            setMarked: { ime.setVoiceMarked($0, inFront: bundleID) },
            clearMarked: { ime.clearVoiceMarked() },
            insert: { [weak self] text in
                guard ime.canWriteVoice(inFront: bundleID) else { return false }
                // `insertText` would replace a pinyin composition typed meanwhile.
                if self?.pinyin.isComposing == true { self?.pinyin.commit() }
                return ime.insertVoiceText(text, inFront: bundleID)
            },
            paste: { AccessibilityInserter.paste($0) },
            copy: { AccessibilityInserter.copy($0) })
    }

    /// Put the most recent dictation on the pasteboard (input-method menu).
    func copyLastDictation() {
        guard let text = voice.lastDictation else { return }
        AccessibilityInserter.copy(text)
        post(.transient(String(localized: "上一次听写已复制到剪贴板。")))
    }

    func voiceSessionStateDidChange() { syncRouterContext() }

    func setDictationTrialVisible(_ visible: Bool) {
        dictationTrialVisible = visible
        syncRouterContext()
    }

    func settingsCaptureTarget() -> (any CompositionTarget)? {
        let r = readinessState
        if r.permissions.microphone != .granted {
            post(.actionable(r.permissions.microphone == .denied
                ? SetupReadiness.Blocker.microphoneDenied.message
                : SetupReadiness.Blocker.microphoneNotRequested.message, .permissions))
            return nil
        }
        if r.models.busy {
            post(.transient(String(localized: "正在准备语音模型，好了再按住说。")))
            return nil
        }
        if !r.models.speechReady {
            post(.transient(String(localized: "正在准备语音模型，好了再按住说。")))
            Task { await downloadModels() }
            return nil
        }
        if !r.models.translationReady {
            post(.transient(String(localized: "正在准备翻译模型，好了再试语音翻译。")))
            Task { await downloadModels() }
            return nil
        }
        // The user may have typed or edited the trial field since the previous
        // session. Snapshot that text for each capture instead of keeping a
        // second, stale long-lived copy.
        let target = SettingsCaptureTarget(model: self, initialText: testText)
        settingsCapture = target
        return target
    }

    func voiceSessionDidEnd(committed: Bool) {
        if committed {
            notice = nil
            if !prefs.onboardingCompleted { preferences.update { $0.onboardingVersion = Preferences.currentOnboardingVersion } }
        }
        router.reset()
        syncRouterContext()
        typingResumedDuringFinalization = false
        deferredInputDeadline.cancel()
        replayDeferredIMEInput()
        replayDeferredSettingsInput()
    }

    /// Typing wins over the wait for a recognizer tail, but never at the price
    /// of the dictation: queued keys are written now, the result when it is ready.
    private func resumeTypingDuringFinalization() {
        typingResumedDuringFinalization = true
        IMEManager.shared.clearVoiceMarked()
        replayDeferredIMEInput()
    }

    private func armDeferredIMEFence() {
        deferredInputDeadline.arm(after: voice.policy.userInputFence) { [weak self] in
            guard let self else { return }
            if self.voice.state == .polishing {
                _ = self.voice.commitCompletedOutputForUserInput()
            } else if self.voice.state == .finalizing {
                if self.deferredSettingsInput.isEmpty {
                    self.resumeTypingDuringFinalization()
                } else {
                    // The trial field has no way to order a late result after typed text.
                    self.voice.cancel()
                    self.post(.transient(String(localized: "已继续键盘输入，本次听写已取消。")))
                }
            }
            self.replayDeferredIMEInput()
            self.replayDeferredSettingsInput()
        }
    }

    private func replayDeferredIMEInput() {
        deferredInputDeadline.cancel()
        let pending = deferredIMEInput
        deferredIMEInput.removeAll(keepingCapacity: true)
        for item in pending {
            guard IMEManager.shared.matchesDeferredInput(leaseID: item.leaseID,
                                                         generation: item.clientGeneration) else { continue }
            if !pinyin.handle(item.event, pushToTalk: prefs.pushToTalk) {
                _ = IMEManager.shared.insertDeferredText(item.event.characters ?? "",
                                                         leaseID: item.leaseID,
                                                         generation: item.clientGeneration)
            }
        }
    }

    private func replayDeferredSettingsInput() {
        let pending = deferredSettingsInput
        deferredSettingsInput.removeAll(keepingCapacity: true)
        guard !pending.isEmpty, settingsWindow.isFocused else { return }
        replayingSettingsInput = true
        defer { replayingSettingsInput = false }
        for item in pending where item.responder == settingsWindow.focusedResponderIdentity {
            NSApp.sendEvent(item.event)
        }
    }

    func commitPinyinBeforeVoice() { pinyin.commit() }

    // MARK: - Pinyin

    func commitPinyin() {
        // Caps Lock often makes IMK call commitComposition before flagsChanged.
        // Commit the typed letters, not the highlighted Chinese candidate.
        if NSEvent.modifierFlags.contains(.capsLock) { pinyin.commitRaw() } else { pinyin.commit() }
    }

    func togglePinyinEnglishMode() { set(\.pinyinEnglishMode, !prefs.pinyinEnglishMode) }

    // MARK: - Permissions and setup

    func beginSetup() {
        isShowingSetup = true
        refreshInputSourceStatus()
        settingsTab = 0
        notice = nil
        openSettings()
    }

    func finishSetup(destination: Int = 1) {
        settingsTab = destination
        voice.cancel()
        isShowingSetup = false
        preferences.update { $0.onboardingVersion = Preferences.currentOnboardingVersion }
    }

    /// Leave the guide without claiming it was completed. Reopening Saylane
    /// returns to setup until the user finishes or successfully tries voice.
    func deferSetup(destination: Int = 1) {
        settingsTab = destination
        voice.cancel()
        isShowingSetup = false
    }

    func openSettings(tab: Int? = nil) {
        if let tab { settingsTab = tab }
        settingsWindow.show(model: self)
        refreshInputSourceStatus()
    }

    func openSettings(for destination: UserNotice.Destination) {
        switch destination {
        case .permissions: openSettings(tab: 0)
        case .models: openSettings(tab: 2)
        case .voice: openSettings(tab: 1)
        case .screen: openSettings(tab: 4)
        case .none: openSettings()
        }
    }

    func openInputMethodPermission() {
        notice = nil
        permissionsController.openInputMethodSettings()
    }

    func requestSpeechRecognitionPermission() async { await permissionsController.requestSpeechRecognition() }

    func requestMicrophonePermission() async {
        let granted = await permissionsController.requestMicrophone()
        if !granted, !settingsWindow.isVisible {
            post(.actionable(SetupReadiness.Blocker.microphoneDenied.message, .permissions))
        }
    }

    func requestInputMonitoring() {
        permissionsController.requestInputMonitoring()
        startGlobalHotkeyMonitor()
        refreshInputSourceStatus()
        if router.isGlobalTapListening {
            notice = nil
        } else if !permissions.inputMonitoringGranted {
            post(.actionable(String(localized: "还没有允许输入监控。允许后，在其它输入法下按住快捷键也能开始语音。"), .permissions))
        } else {
            post(.actionable(String(localized: "输入监控已允许，但全局按键监听没有成功。请再试一次，或先手动切到 Saylane。"), .permissions))
        }
    }

    func requestAccessibility() { permissionsController.requestAccessibility() }

    func requestScreenCapturePermission() {
        if !permissionsController.requestScreenCapture() {
            post(.actionable(String(localized: "还没有允许屏幕录制。允许后可以用 \(prefs.screenCaptureShortcut.displayName) 划区翻译。"), .screen))
        }
    }

    func enableInputSource() {
        notice = nil
        permissionsController.enableInputSource()
    }

    private func refreshGlossaryIfNeeded() {
        _ = DictationGlossaryStore.shared.terms
        guard prefs.dictationGlossaryEnabled else { return }
        if CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--waveform-snapshot") { return }
        Task { await DictationGlossaryStore.shared.refreshIfStale() }
    }

    // MARK: - Screen translate

    private func wireScreen() {
        screen.wire(router: router)
        screen.apply(prefs)
        screen.prefs = { [weak self] in self?.prefs ?? Preferences() }
        screen.pairForDirection = { [weak self] in (self?.prefs.pairSource ?? .zhHans, self?.prefs.pairTarget ?? .en) }
        screen.onNotice = { [weak self] notice in self?.post(notice) }
        screen.onActivityChanged = { [weak self] in self?.syncRouterContext() }
        screen.onShortcutRecorded = { [weak self] shortcut in self?.set(\.screenCaptureShortcut, shortcut) }
        screen.onDirectionChanged = { [weak self] direction in
            self?.preferences.update { $0.screenTranslateSource = direction.source; $0.screenTranslateTarget = direction.target }
        }
        screen.keysHandledGlobally = { [weak self] in self?.router.isGlobalTapFiltering ?? false }
        screen.requestScreenCapture = { [weak self] in
            guard let self else { return false }
            self.permissionsController.refresh()
            if self.permissions.screenCaptureGranted { return true }
            return self.permissionsController.requestScreenCapture()
        }
        screen.yieldVoiceSession = { [weak self] in
            guard let self, self.isListening else { return true }
            // A chord pressed right after the talk key most likely meant the screenshot.
            if (self.voice.listeningDuration ?? 1) > 0.35 { return false }
            self.voice.cancel()
            return true
        }
    }

    func handleScreenCaptureHotkey(preserveKeyboardFocus: Bool = false) {
        screen.handleCaptureHotkey(preserveKeyboardFocus: preserveKeyboardFocus)
    }

    func beginRecordScreenShortcut() { screen.beginRecordingShortcut() }
    func cancelRecordScreenShortcut() { screen.cancelRecordingShortcut() }

    // MARK: - Settings trial target

    /// Writes ASR into `testText`. The IME host is not a valid IMK client for itself.
    private final class SettingsCaptureTarget: CompositionTarget {
        unowned let model: AppModel
        private var committed = ""
        private var ownsMarked = false
        init(model: AppModel, initialText: String) {
            self.model = model
            committed = initialText
        }
        var isValid: Bool { model.isVoiceTrialActive }
        func setMarked(_ text: String) {
            ownsMarked = true
            model.testText = committed + text
        }
        func commit(_ text: String) throws {
            guard isValid else { throw SessionFailure.targetLost }
            ownsMarked = false
            committed += text
            model.testText = committed
        }
        func cancelMarked() {
            guard ownsMarked else { return }
            ownsMarked = false
            model.testText = committed
        }
        func reset() { committed = ""; model.testText = "" }
    }

    func clearTestText() {
        settingsCapture?.reset()
        testText = ""
    }
}
