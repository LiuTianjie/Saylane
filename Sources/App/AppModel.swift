import AppKit
import Carbon
import Foundation
import Observation
import SwiftUI

/// Composition root of the main program and the single object views observe.
/// It owns no feature logic itself: preferences live in `PreferencesStore`,
/// readiness in `Readiness` (reduced from events), input in `InputEventRouter`,
/// voice in `VoiceSessionController`, models in `ModelCoordinator`, screen
/// translation in `ScreenTranslateController`. Typing lives in another
/// process, the input method, reached through `IMEBridgeClient`.
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
    let ime = IMEBridgeClient()
    /// Names and terms learned from what the user changes after a dictation.
    let corrections = CorrectionLearner()
    let pinyinDictionaryUpdates = RimeDictionaryUpdateModel()
    let pinyinLanguageModel = PinyinLanguageModel()
    let router = InputEventRouter()
    private let settingsWindow = SettingsController()

    // MARK: Settings UI state

    var settingsTab = 1
    var isShowingSetup = false
    /// Settings-panel trial field: an ordinary text view, written like any other.
    var testText = ""
    private(set) var dictationTrialVisible = false
    var isRecordingScreenShortcut: Bool { screen.isRecordingShortcut }
    var shortcutRecordingVerdict: ShortcutValidator.Verdict? { screen.recordingVerdict }
    var lastLanguageSwitch: String?
    var isActivatingInputSource: Bool { permissionsController.isActivatingInputSource }
    private var lastPermissionRefreshAt: TimeInterval = -.infinity
    private var lastTapAttemptAt: TimeInterval = -.infinity
    private var lastTapOutcome: String?
    private var noticeExpiry: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var releaseWatchdog: Task<Void, Never>?

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
        // The one-process builds kept a single trace file; nothing writes it any more.
        try? FileManager.default.removeItem(at: AppDirectories.diagnostics.appendingPathComponent("input-session.json"))
        // The input method's domain, so an upgrade from the one-process
        // builds keeps every setting.
        preferences = PreferencesStore(backing: UserDefaults(suiteName: Bridge.defaultsSuite) ?? .standard)
        models = ModelCoordinator(preferences: preferences.current, translation: translation)
        voice = TestScript.isActive
            ? VoiceSessionController(environment: TestScript.environment,
                                     makeCapture: { PrerollCapture(underlying: ScriptedCapture(), limit: $0) })
            : VoiceSessionController()
        voice.host = self
    }

    // MARK: - Bootstrap

    func bootstrap() {
        InputDiagnostics.channel = "app"
        InputDiagnostics.record("app-start", "version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") pid=\(getpid()) trigger=\(prefs.pushToTalk.rawValue)")
        NSApp.setActivationPolicy(.accessory)
        // Running again: the input method may start us whenever it needs us.
        preferences.setQuitByUser(false)
        voice.overlay.prepare()
        voice.overlay.setHotkeyLabel(prefs.pushToTalk.shortLabel)
        if TestScript.isActive {
            // No translation models and nothing on the user's screen.
            preferences.update { $0.targetLanguage = $0.sourceLanguage; $0.overlayEnabled = false; $0.voiceCuesEnabled = false }
        }
        AudioCaptureService.preferredInputUID = prefs.microphoneUID
        pinyinLanguageModel.onChanged = { [weak self] in
            guard let self else { return }
            self.ime.push(pinyin: self.pinyinPreferences)
        }
        ime.onEvent = { [weak self] event in self?.handle(event) }
        ime.push(pinyin: pinyinPreferences)
        ime.start()
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

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = application?.bundleIdentifier
            let pid = application?.processIdentifier
            Task { @MainActor in
                guard let self else { return }
                // A scripted dictation has its own idea of what is in front.
                if !TestScript.isActive { self.voice.frontmostAppChanged(to: bundleID, pid: pid) }
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
                // The input method is started by the system when its source is selected.
                if !self.ime.isConnected { self.ime.refreshStatus() }
            }
        }
        startGlobalHotkeyMonitor()
        refreshInputSourceStatus()
        syncLoginItem()
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
        let outcome = ok ? (router.isGlobalTapFiltering ? "filter" : "listen") : "unavailable"
        if outcome != lastTapOutcome {
            lastTapOutcome = outcome
            InputDiagnostics.record("global-keys", outcome)
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
            let before = readinessState.permissions
            permissionsController.refresh()
            let currentPermissions = permissionsController.permissions
            reduce(.permissions(currentPermissions))
            // A grant becomes visible without a restart. A listener created
            // before it does not upgrade itself, so rebuild it on the transition.
            if (currentPermissions.accessibility && !before.accessibility)
                || (currentPermissions.inputMonitoring && !before.inputMonitoring) {
                startGlobalHotkeyMonitor()
            }
            if currentPermissions.accessibility != before.accessibility { syncLoginItem() }
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
            $0.voiceEnabled = voiceReadiness.inputSource.enabled
            $0.isOursSelected = readinessState.inputSource.selected
            $0.globalEventsCanBeConsumed = globalEventsCanBeConsumed
            $0.screenShortcut = p.screenCaptureShortcut
            $0.screenActive = screenTranslate.isActive
            $0.pinVisible = screenTranslate.isPinVisible
            $0.recordingShortcut = isRecordingScreenShortcut
        }
        syncBridgeContext(appOwnsKeys: globalEventsCanBeConsumed)
    }

    /// Everything the input method must know, recomputed whole. It decides
    /// about keys on its own from this; it never waits for an answer from here.
    private func syncBridgeContext(appOwnsKeys: Bool) {
        let p = prefs
        let phase: VoicePhase
        switch voice.state {
        case .idle, .cancelling: phase = .idle
        case .preparing, .listening: phase = .listening
        case .finalizing: phase = .finalizing
        case .polishing: phase = .polishing
        }
        let modes = TranslationDirection.voiceModes(a: p.pairSource, b: p.pairTarget)
        let actionable = notice.flatMap { $0.level == .actionable ? $0.message : nil }
        ime.update {
            $0.phase = phase
            $0.session = phase == .idle ? nil : voice.sessionID
            $0.sessionBundleID = phase == .idle ? nil : voice.targetBundleID
            $0.appOwnsKeys = appOwnsKeys
            $0.trigger = p.pushToTalk.rawValue
            $0.screenSelecting = screenTranslate.isActive && !screenTranslate.isPinVisible
            $0.screenShortcutKeyCode = p.screenCaptureShortcut.keyCode
            $0.screenShortcutFlags = p.screenCaptureShortcut.normalizedFlags
            $0.keysEndDictation = p.tapToTalk
            $0.userInputFence = voice.policy.userInputFence
            // A translation is not what was heard: its edits say nothing about recognition.
            $0.learnsCorrections = p.learnFromCorrections && p.translationIsPassthrough
            $0.menu = BridgeMenuState(modes: modes.map(\.compactTitle),
                                      currentMode: modes.firstIndex(of: currentDirection),
                                      canChooseMode: !isPreparingModels && phase == .idle,
                                      hasLastDictation: voice.lastDictation != nil,
                                      notice: actionable)
        }
    }

    private var pinyinPreferences: BridgePinyinPreferences {
        BridgePinyinPreferences(englishMode: prefs.pinyinEnglishMode, fuzzy: prefs.pinyinFuzzyEnabled,
                                barPreedit: prefs.pinyinBarPreeditEnabled, keys: prefs.pinyinKeys,
                                languageModel: pinyinLanguageModel.isInstalled)
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
        syncRouterContext()
    }

    func dismissNotice() { notice = nil; syncRouterContext() }

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
            || new.speechModel != old.speechModel {
            voice.cancel(); router.reset()
            models.apply(new)
        }
        if new.pushToTalk != old.pushToTalk || new.tapToTalk != old.tapToTalk || new.languageSwitchEnabled != old.languageSwitchEnabled {
            voice.cancel(); router.reset()
            voice.overlay.setHotkeyLabel(new.pushToTalk.shortLabel)
        }
        if new.launchAtLogin != old.launchAtLogin { syncLoginItem() }
        if new.microphoneUID != old.microphoneUID { AudioCaptureService.preferredInputUID = new.microphoneUID }
        if new.dictationGlossaryEnabled && !old.dictationGlossaryEnabled {
            Task { await DictationGlossaryStore.shared.refreshIfStale() }
        }
        if !new.learnFromCorrections && old.learnFromCorrections { corrections.stopWatching() }
        if new.pinyinEnglishMode != old.pinyinEnglishMode || new.pinyinBarPreeditEnabled != old.pinyinBarPreeditEnabled
            || new.pinyinFuzzyEnabled != old.pinyinFuzzyEnabled || new.pinyinKeys != old.pinyinKeys {
            ime.push(pinyin: pinyinPreferences)
        }
        if new.screenPinFreezesScreen != old.screenPinFreezesScreen {
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
        let hadIt = models.asrModels.installed.contains(selected)
        await models.downloadSpeechModel(selected)
        // Someone who downloads a recognizer wants to use it. (Repairing one that was there changes nothing.)
        if !hadIt, models.asrModels.installed.contains(selected) { selectSpeechModel(selected) }
    }

    func downloadModels() async {
        guard !isListening else { return }
        notice = nil
        await models.downloadModels()
    }

    func refreshModelStatus() async { await models.refreshStatus() }

    // MARK: - Input

    /// The input method reported something.
    private func handle(_ event: BridgeEvent) {
        switch event {
        case .hello, .attachment:
            // The client keeps the state; the menu and the routes follow it.
            syncRouterContext()
        case .key(let meta):
            let type: NSEvent.EventType = meta.kind == .keyDown ? .keyDown : .flagsChanged
            router.feed(InputEvent(source: .imk, type: type, keyCode: meta.keyCode, flags: meta.flags,
                                   isRepeat: meta.isRepeat, timestamp: meta.timestamp))
        case .userTyped(let session):
            // Optional polish never blocks typing: the ordinary result is
            // complete and can be written before the key that is waiting.
            if voice.sessionID == session, voice.state == .polishing {
                _ = voice.commitCompletedOutputForUserInput()
            }
        case .typingResumed, .talkKey:
            break
        case .readBack(let report):
            // The one event with text in it. It goes to the learner and
            // nowhere else; the trace gets counts.
            guard prefs.learnFromCorrections else { ime.forget(session: report.session); return }
            let outcome = corrections.received(report)
            if outcome.learned > 0 {
                InputDiagnostics.record("correction-learning", "pairs=\(outcome.learned) new=\(outcome.new) replacing=\(outcome.replacing)")
            }
            if outcome.finished, !report.closed { ime.forget(session: report.session) }
        case .menu(let action):
            perform(action)
        case .menuMode(let index):
            let modes = TranslationDirection.voiceModes(a: prefs.pairSource, b: prefs.pairTarget)
            if modes.indices.contains(index) { setVoiceMode(modes[index]) }
        case .pinyinMode(let english):
            preferences.update { $0.pinyinEnglishMode = english }
        }
    }

    private func perform(_ action: BridgeMenuAction) {
        switch action {
        case .openSettings: openSettings()
        case .showNotice: openSettings(for: notice?.destination ?? .none)
        case .screenCapture: handleScreenCaptureHotkey()
        case .copyLastDictation: copyLastDictation()
        }
    }

    /// Key events while the settings window is key. They reach the gestures
    /// under any input source and without any permission.
    func handleSettingsShortcut(_ event: NSEvent) -> NSEvent? {
        guard settingsWindow.isVisible else { return event }
        return router.feed(event, source: .settingsWindow) ? nil : event
    }

    private func perform(_ action: InputAction) {
        InputDiagnostics.record("input-action", String(describing: action))
        switch action {
        case .voice(let gesture):
            switch gesture {
            case .prewarm:
                guard !screenTranslate.isActive else { return }
                // An application handles its ⌘-shortcuts before the input
                // method sees the key, so a chord is also read from the system.
                if chordDuringHold(since: VoiceGesture.prewarmDelay) { abandonHold(); return }
                voice.arm()
            case .discard:
                voice.disarm()
            case .start:
                guard !screenTranslate.isActive else { voice.disarm(); return }
                if !prefs.pushToTalk.isModifier && !router.isGlobalTapFiltering {
                    voice.disarm()
                    post(.actionable(String(localized: "功能键语音快捷键需要辅助功能权限，才能拦截按键并可靠收到松开事件。"), .permissions))
                    return
                }
                if !prefs.tapToTalk, chordDuringHold(since: VoiceGesture.holdDelay) { abandonHold(); return }
                voice.press()
                if voice.isListening, !prefs.tapToTalk { startReleaseWatchdog() }
            case .stop:
                voice.release()
            case .cancel:
                voice.cancel()
            case .interrupt:
                voice.interrupt()
            case .switchDirection:
                voice.disarm()
                cycleDirection()
            }
        case .switchDirection:
            cycleDirection()
        case .screenCapture:
            screen.handleCaptureHotkey()
        case .screenPin(let key):
            screen.handlePinKey(key)
        case .recordedShortcut(let shortcut):
            screen.finishRecordingShortcut(shortcut)
        }
    }

    /// A key went down while a modifier talk key was being held, as the window
    /// server saw it. Needs no permission and works under any input source.
    private func chordDuringHold(since interval: TimeInterval) -> Bool {
        // A test home is driven by posted events; the hardware belongs to the user.
        guard prefs.pushToTalk.isModifier, !TestHome.isActive else { return false }
        // The hardware state: not changed by our own listener swallowing the
        // talk key. Our own ⌘V from the previous dictation is not a chord.
        let since = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        guard since < interval else { return false }
        let keyAt = ProcessInfo.processInfo.systemUptime - since
        return abs(keyAt - AccessibilityInserter.lastPasteAt) > 0.08
    }

    private func abandonHold() {
        InputDiagnostics.record("hold-abandoned", "key pressed during hold")
        router.abandonVoiceGesture()
        voice.disarm()
    }

    /// The release of the talk key can be lost: InputMethodKit stops reporting
    /// keys when the client changes mid-hold. While a hold-to-talk dictation
    /// records, the modifier is also read from the window server; when it has
    /// been up for a while the key is treated as released.
    private func startReleaseWatchdog() {
        releaseWatchdog?.cancel()
        let trigger = prefs.pushToTalk
        guard trigger.isModifier, let flag = trigger.modifierFlag else { return }
        // If the system does not show the key as held now, it cannot tell us when it is up.
        guard CGEventSource.flagsState(.hidSystemState).contains(flag) else {
            InputDiagnostics.record("release-watchdog", "modifier state unavailable")
            return
        }
        releaseWatchdog = Task { [weak self] in
            var up = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, self.voice.isCapturing else { return }
                up = CGEventSource.flagsState(.hidSystemState).contains(flag) ? 0 : up + 1
                if up >= 3 {
                    InputDiagnostics.record("release-watchdog", "talk key is up; its release was not delivered")
                    self.router.voiceTriggerLost()
                    return
                }
            }
        }
    }

    private func cycleDirection() {
        if screen.isActive { screen.cycleDirection() } else { swapTranslationDirection() }
    }

    func endSession() { voice.release() }

    // MARK: VoiceSessionHost

    /// What a dictation may rely on. A test home with a script has everything.
    var voiceReadiness: Readiness { TestScript.isActive ? TestScript.readiness : readinessState }

    func makeSpeechEngine() -> any SpeechRecognizing {
        if let scripted = TestScript.speech { return ScriptedSpeech(scripted) }
        // Apple biases recognition with contextual strings, Qwen with its prompt; the FunASR
        // CLIs accept no hotwords, so those engines rely on post-recognition vocabulary repair.
        let model = prefs.speechModel
        if model == .apple { return SpeechEngine(contextualStrings: vocabularyTerms) }
        let prompt = model.isQwen ? SpeechHotwords.context(terms: vocabularyTerms) : nil
        let engine = Self.twoPass(model, prompt: prompt, contextualStrings: vocabularyTerms)
        // Which recognizer wrote the text is the first thing to know when a result looks wrong.
        engine.onOutcome = { InputDiagnostics.record("final-text", $0) }
        return engine
    }

    /// The system's recognizer for the words on screen, the downloaded model for the text that is written.
    static func twoPass(_ model: SpeechModel, prompt: String?, contextualStrings: [String]) -> TwoPassSpeechEngine {
        TwoPassSpeechEngine(
            live: SpeechEngine(contextualStrings: contextualStrings),
            prepare: { locale in
                guard model.supports(locale: locale) else { throw ASRModelError.unsupportedLanguage }
                _ = try QwenLanguage.name(for: locale)
                try await QwenRuntime.shared.prepare(model)
            },
            transcribe: { samples, locale, hints in
                let context = ([prompt] + hints.map(Optional.some)).compactMap { $0 }.joined(separator: "、")
                let text = try await QwenRuntime.shared.transcribe(samples, language: QwenLanguage.name(for: locale),
                                                                   variant: model, context: model.isQwen && !context.isEmpty ? context : prompt)
                return QwenLanguage.normalize(text, locale: locale)
            },
            makeSolo: { QwenSpeechEngine(variant: model, context: prompt, runtime: QwenRuntime.shared) })
    }

    private var vocabularyTerms: [String] { vocabularyTerms(learned: true) }

    /// What biases recognition. `learned`: with the spellings learned from the
    /// user's corrections — for the recognizers on this Mac, and for nothing that is sent anywhere.
    private func vocabularyTerms(learned: Bool) -> [String] {
        DictationGlossary.biasTerms(userRaw: prefs.speechHotwords, includeUser: prefs.speechHotwordsEnabled,
                                    includeGlossary: prefs.dictationGlossaryEnabled,
                                    remote: DictationGlossaryStore.shared.terms,
                                    learned: learned && prefs.learnFromCorrections ? corrections.corrections.biasTerms : [])
    }

    /// Deterministic, on-device repair applied only to the final recognized text.
    func makeRefine() -> ((String) -> String)? {
        let p = prefs
        let glossary = p.dictationGlossaryEnabled
            ? DictationVocabulary(entries: DictationGlossary.combined(remote: DictationGlossaryStore.shared.terms)) : nil
        let vocabulary = p.speechHotwordsEnabled ? DictationVocabulary(raw: p.speechHotwords) : nil
        // Frozen for this utterance, like the rest.
        let learned = p.learnFromCorrections && !corrections.corrections.replacements.isEmpty ? corrections.corrections : nil
        guard p.dictationCleanupEnabled || glossary?.isEmpty == false || vocabulary?.isEmpty == false
                || learned != nil else { return nil }
        return { text in
            var result = p.dictationCleanupEnabled ? DictationCleanup.clean(text) : text
            if let glossary { result = glossary.apply(to: result) }
            // What the user corrected the same way twice. Their own vocabulary comes after it and has the last word.
            if let learned { result = learned.apply(to: result, lexicon: .system) }
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
        // The endpoint may be another machine: what was learned from corrections stays here.
        let terms = vocabularyTerms(learned: false)
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

    func keyboardOwner(front bundleID: String?) -> String? { ime.keyboardOwner(front: bundleID) }

    func textSink(inFront bundleID: String?, session: UUID) -> VoiceTextSink {
        let ime = ime
        let own = bundleID == Bundle.main.bundleIdentifier
        // How the finished text is written: applied to whatever route takes it.
        let options = DictationFormat.Options(dropFinalStop: prefs.dictationDropFinalStop,
                                              spaceBetweenScripts: prefs.dictationSpaceBetweenScripts)
        let format: (String) -> String = { options.isIdentity ? $0 : DictationFormat.apply($0, options) }
        // The input method reads back only what was written through it, and only when the context says so.
        let learner = prefs.learnFromCorrections && prefs.translationIsPassthrough ? corrections : nil
        InputDiagnostics.record("voice-target", "owner=\(bundleID ?? "none") input-method=\(ime.canWrite(inFront: bundleID)) attached=\(ime.attachedBundleID ?? "none") paste=\(AccessibilityInserter.isTrusted)")
        return VoiceTextSink(
            attached: { ime.canWrite(inFront: bundleID) },
            setMarked: { ime.setMarked($0, session: session, inFront: bundleID) },
            clearMarked: { ime.clearMarked(session: session) },
            insert: { raw in
                let text = format(raw)
                if ime.insert(text, session: session, inFront: bundleID) {
                    learner?.wrote(text, session: session)
                    return true
                }
                // Our own text fields can always be written without anybody's help.
                return own && LocalTextInserter.insert(text)
            },
            // A test home never posts keys and never touches the user's pasteboard.
            paste: { TestHome.isActive ? false : AccessibilityInserter.paste(format($0)) },
            copy: { if TestHome.isActive { TestScript.pasteboard.append(format($0)) } else { AccessibilityInserter.copy(format($0)) } },
            end: { ime.end(session: session) })
    }

    /// Put the most recent dictation on the pasteboard (input-method menu).
    func copyLastDictation() {
        guard let text = voice.lastDictation, !TestHome.isActive else { return }
        AccessibilityInserter.copy(text)
        post(.transient(String(localized: "上一次听写已复制到剪贴板。")))
    }

    func voiceSessionStateDidChange() {
        if !voice.isCapturing { releaseWatchdog?.cancel(); releaseWatchdog = nil }
        syncRouterContext()
    }

    func setDictationTrialVisible(_ visible: Bool) { dictationTrialVisible = visible }

    func voiceSessionDidEnd(committed: Bool) {
        if committed {
            notice = nil
            if !prefs.onboardingCompleted { preferences.update { $0.onboardingVersion = Preferences.currentOnboardingVersion } }
            if prefs.learnFromCorrections, let text = voice.lastDictation { corrections.noteWritten(text) }
        }
        releaseWatchdog?.cancel(); releaseWatchdog = nil
        router.reset()
        syncRouterContext()
    }

    // MARK: - Pinyin

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

    /// The input-method row of the guide: add Saylane, or switch to it.
    func openInputMethodPermission() {
        notice = nil
        if readinessState.inputSource.enabled {
            permissionsController.selectInputSource()
        } else {
            permissionsController.addInputSource(select: true)
        }
    }

    /// Whether a dictation needs Saylane to be the current input method:
    /// without the listener that works under every input method, the talk key
    /// only arrives through the input method itself.
    var needsInputSourceSelected: Bool {
        readinessState.inputSource.enabled && !readinessState.inputSource.selected && !readinessState.globalInvokeAvailable
    }

    /// The talk key cannot arrive right now: another input method is the
    /// current one and the listener that works under every input method is off.
    var talkKeyUnreachable: Bool { needsInputSourceSelected }

    /// After an installation, and wherever the guide is about to ask the user
    /// to talk: put Saylane in the input-source list and, unless the talk key
    /// works under every input method, make it the current one. Nobody is sent
    /// to System Settings for this.
    func ensureInputSource() {
        refreshInputSourceStatus()
        let source = readinessState.inputSource
        guard source.installedLocation else { return }
        if !source.enabled {
            InputDiagnostics.record("input-source", "adding")
            permissionsController.addInputSource(select: !readinessState.globalInvokeAvailable)
        } else if needsInputSourceSelected {
            InputDiagnostics.record("input-source", "selecting")
            permissionsController.selectInputSource()
        }
    }


    func requestMicrophonePermission() async {
        let granted = await permissionsController.requestMicrophone()
        if !granted, !settingsWindow.isVisible {
            post(.actionable(SetupReadiness.Blocker.microphoneDenied.message, .permissions))
        }
    }

    /// The talk key was held before the microphone was ever asked for: the
    /// system's question appears now, in whatever application the user is in.
    func requestMicrophoneForDictation() {
        guard !permissions.isRequestingMicrophone else { return }
        Task {
            if await permissionsController.requestMicrophone() {
                post(.transient(String(localized: "麦克风已允许。再按住快捷键说话。")))
            } else {
                post(.actionable(SetupReadiness.Blocker.microphoneDenied.message, .permissions))
            }
        }
    }

    /// The global talk key needs the main program to be running after a login
    /// even when another input method is selected. Without Accessibility there
    /// is no global talk key, and the input method starts us when it is used.
    private func syncLoginItem() {
        guard !TestHome.isActive, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let wanted = prefs.launchAtLogin && readinessState.permissions.accessibility
        if let failure = LoginItem.set(wanted) {
            InputDiagnostics.record("login-item", "failed: \(failure)")
        } else {
            InputDiagnostics.record("login-item", wanted ? "on" : "off")
        }
    }

    /// Accessibility is granted but the listener is not running: try again now.
    func reconnectGlobalKeys() {
        startGlobalHotkeyMonitor()
        refreshInputSourceStatus()
    }

    func requestAccessibility() {
        permissionsController.requestAccessibility()
        // The grant shows up without a restart; pick it up as soon as it does.
        lastTapAttemptAt = -.infinity
    }

    func requestScreenCapturePermission() {
        if !permissionsController.requestScreenCapture() {
            post(.actionable(String(localized: "还没有允许屏幕录制。允许后可以用 \(prefs.screenCaptureShortcut.displayName) 划区翻译。"), .screen))
        }
    }

    private func refreshGlossaryIfNeeded() {
        _ = DictationGlossaryStore.shared.terms
        // A test home stays off the network.
        guard prefs.dictationGlossaryEnabled, !TestHome.isActive else { return }
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

    func clearTestText() { testText = "" }

    /// The user chose Quit: the input method must not start us again by itself.
    func quitByUser() {
        voice.cancel()
        preferences.setQuitByUser(true)
        NSApp.terminate(nil)
    }
}
