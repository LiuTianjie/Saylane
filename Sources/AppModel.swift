import AppKit
import Carbon
import Foundation
import Observation
import Speech
import SwiftUI
import Translation

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    private var updatingLanguagePair = false
    var sourceLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "sourceLanguage"); if !updatingLanguagePair { settingsChanged() } }
    }
    var targetLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(targetLanguage.rawValue, forKey: "targetLanguage"); if !updatingLanguagePair { settingsChanged() } }
    }
    /// The two languages chosen in settings. Shortcut cycles A→A / A→B / B→A / B→B.
    var pairSource: AppLanguage {
        didSet {
            UserDefaults.standard.set(pairSource.rawValue, forKey: "pairSourceLanguage")
            if !updatingLanguagePair { applyPairAsTranslateMode() }
        }
    }
    var pairTarget: AppLanguage {
        didSet {
            UserDefaults.standard.set(pairTarget.rawValue, forKey: "pairTargetLanguage")
            if !updatingLanguagePair { applyPairAsTranslateMode() }
        }
    }
    var currentDirection: TranslationDirection {
        TranslationDirection(source: sourceLanguage, target: targetLanguage)
    }
    var overlayEnabled: Bool {
        didSet { UserDefaults.standard.set(overlayEnabled, forKey: "overlayEnabled") }
    }
    var pushToTalk: PushToTalkHotkey {
        didSet {
            coordinator.cancel(); resetShortcuts()
            UserDefaults.standard.set(pushToTalk.rawValue, forKey: "pushToTalkHotkey")
            overlay.setHotkeyLabel(pushToTalk.shortLabel)
        }
    }
    var languageSwitchEnabled: Bool {
        didSet { UserDefaults.standard.set(languageSwitchEnabled, forKey: "languageSwitchEnabled"); resetShortcuts() }
    }
    var tapToTalk: Bool {
        didSet { UserDefaults.standard.set(tapToTalk, forKey: "tapToTalk"); resetShortcuts(); refreshInputSourceStatus() }
    }
    var lastLanguageSwitch: String?
    var finalPolishEnabled: Bool {
        didSet { UserDefaults.standard.set(finalPolishEnabled, forKey: "finalPolishEnabled") }
    }
    var finalPolishEndpoint: String {
        didSet { UserDefaults.standard.set(finalPolishEndpoint, forKey: "finalPolishEndpoint") }
    }
    var finalPolishModel: String {
        didSet { UserDefaults.standard.set(finalPolishModel, forKey: "finalPolishModel") }
    }
    var lastError: String?
    var translationConfiguration: TranslationSession.Configuration?
    private(set) var speechModel = SpeechModel(rawValue: UserDefaults.standard.string(forKey: "speechModel") ?? "") ?? .apple
    let asrModels = ASRModelStore()
    var speechModelReady = false
    var translationModelReady = false
    var speechModelDetail = "正在检查…"
    var translationModelDetail = "正在检查…"
    var isPreparingModels = false
    var installationPathValid = false
    var inputSourceInstalled = false
    var inputSourceEnabled = false
    var inputSourceSelected = false
    var completedSessions = 0
    private var checkingSettings = false
    private var speechStatusChecks = 0
    var isChecking: Bool { checkingSettings || speechStatusChecks > 0 }
    var testText = ""
    let permissions = PermissionService()
    let translationEngine = TranslationEngine()
    let coordinator = SessionCoordinator()
    var sessionState: SessionState { coordinator.state }
    var isListening: Bool { sessionState != .idle }
    var readiness: SetupReadiness {
        SetupReadiness(microphoneGranted: permissions.allCriticalGranted,
            microphoneNeverRequested: permissions.microphone == .notDetermined,
            inputMethodEnabled: inputSourceEnabled, inputMethodSelected: inputSourceSelected,
            checkingModels: isChecking || isPreparingModels || asrModels.isDownloading,
            speechReady: speechModelReady, translationReady: translationModelReady,
            globalInvokeAvailable: globalHotkey.isListeningToEvents)
    }
    var ready: Bool { readiness.blocker == nil }
    var setupCompleted = UserDefaults.standard.bool(forKey: "setupVerifiedV3")
    var settingsTab = 0
    var isSetupRunning = false
    private var lastBlockedPromptTime: TimeInterval = 0
    private let overlay = OverlayController()
    private let settingsWindow = SettingsController()
    private var keys = InputShortcutHandler()
    private let globalHotkey = GlobalHotkeyMonitor.shared
    var globalHotkeyActive: Bool { globalHotkey.isListeningToEvents }
    let pinyin = PinyinEngine()
    var pinyinEnglishMode = UserDefaults.standard.bool(forKey: "pinyinEnglishMode")
    var pinyinAssociationEnabled = UserDefaults.standard.bool(forKey: "pinyinAssociationEnabled")
    var pinyinBarPreeditEnabled = UserDefaults.standard.bool(forKey: "pinyinBarPreeditEnabled")
    var pinyinFuzzyEnabled = UserDefaults.standard.object(forKey: "pinyinFuzzyEnabled") as? Bool ?? true
    private var holdTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var globalStartTask: Task<Void, Never>?
    private var settingsRevision = 0
    private var workspaceObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var suppressWorkspaceCancel = false
    private var shortcutDirectActive = false
    private var lastTapAttempt: TimeInterval = 0

    private init() {
        // Carry only product preferences across the input-method bundle-ID migration.
        let legacy = UserDefaults.standard.persistentDomain(forName: "com.rtranslate.app") ?? [:]
        for key in ["sourceLanguage", "targetLanguage", "pushToTalkHotkey", "overlayEnabled"] {
            if UserDefaults.standard.object(forKey: key) == nil, let value = legacy[key] {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        finalPolishEnabled = UserDefaults.standard.bool(forKey: "finalPolishEnabled")
        finalPolishEndpoint = UserDefaults.standard.string(forKey: "finalPolishEndpoint") ?? ""
        finalPolishModel = UserDefaults.standard.string(forKey: "finalPolishModel") ?? ""
        languageSwitchEnabled = UserDefaults.standard.object(forKey: "languageSwitchEnabled") as? Bool ?? true
        tapToTalk = UserDefaults.standard.bool(forKey: "tapToTalk")
        let initialSource = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "sourceLanguage") ?? "") ?? .zhHans
        let initialTarget = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "targetLanguage") ?? "") ?? .en
        let initialPairSource = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "pairSourceLanguage") ?? "") ?? initialSource
        let initialPairTarget = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "pairTargetLanguage") ?? "")
            ?? (initialTarget != initialSource ? initialTarget : (initialSource == .en ? .zhHans : .en))
        updatingLanguagePair = true
        sourceLanguage = initialSource
        targetLanguage = initialTarget
        pairSource = initialPairSource
        pairTarget = initialPairTarget
        updatingLanguagePair = false
        pushToTalk = PushToTalkHotkey(rawValue: UserDefaults.standard.string(forKey: "pushToTalkHotkey") ?? "") ?? .rightOption
        overlayEnabled = (UserDefaults.standard.object(forKey: "overlayEnabled") as? Bool) ?? true
    }

    func bootstrap() {
        InputDiagnostics.record("app-start", "version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") trigger=\(pushToTalk.rawValue)")
        NSApp.setActivationPolicy(.accessory)
        overlay.prepare()
        overlay.setHotkeyLabel(pushToTalk.shortLabel)
        PinyinLexicon.shared.loadDefault()
        coordinator.onState = { [weak self] state in
            guard let self else { return }
            InputDiagnostics.record("session-state", String(describing: state))
            switch state {
            case .idle:
                break
            case .preparing:
                self.overlay.hide()
                if self.overlayEnabled {
                    self.overlay.show(source: self.sourceLanguage.shortName, target: self.targetLanguage.shortName,
                                      liveInject: true, hotkeyLabel: self.pushToTalk.shortLabel)
                }
            case .listening: self.overlay.setPhase(.listening)
            case .finalizing: self.overlay.setPhase(.finalizing)
            case .polishing: self.overlay.setPhase(.polishing)
            case .cancelling: self.overlay.hide()
            }
        }
        coordinator.onCompletion = { [weak self] feedback in
            guard let self else { return }
            InputDiagnostics.record("completion", String(describing: feedback))
            guard self.overlayEnabled else {
                self.overlay.hide()
                return
            }
            if feedback.isWarning {
                self.overlay.showCompletion(feedback)
            } else {
                self.overlay.playFinishSweepThenHide()
            }
        }
        coordinator.onLevel = { [weak self] in self?.overlay.setLevel($0) }
        coordinator.onError = { [weak self] message in
            guard let self else { return }
            self.report(message)
            // Live-preview errors can still recover on release. Only terminal errors
            // show a failure notice; AI fallback already has its more specific notice.
            if self.overlayEnabled, self.coordinator.state == .idle {
                self.overlay.showConversionFailure()
            }
        }
        coordinator.onPreview = { InputDiagnostics.record("marked-preview", "characters=\($0)") }
        coordinator.onCommit = { [weak self] in self?.completedSessions += 1; self?.lastError = nil
            self?.setupCompleted = true
            UserDefaults.standard.set(true, forKey: "setupVerifiedV3")
            InputDiagnostics.record("text-committed") }
        IMEManager.shared.onWillSwitchClient = { [weak self] in self?.pinyin.commit() }
        IMEManager.shared.onTargetLost = { [weak self] in
            guard let self, !self.suppressWorkspaceCancel else { return }
            self.coordinator.cancel(); self.resetShortcuts()
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.suppressWorkspaceCancel {
                    self.refreshInputSourceStatus()
                    return
                }
                self.coordinator.cancel(); self.resetShortcuts(); self.refreshInputSourceStatus()
            }
        }
        inputSourceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshInputSourceStatus()
                // Doubao: `[ASRShortcut][Fn] inputSource changed, reselect inputSource until=`
                if (self.isListening || self.shortcutDirectActive),
                   InputSourceInstall.isEnabled, !InputSourceInstall.isSelected {
                    let ok = InputSourceInstall.selectEnabledMode()
                    InputDiagnostics.record("global-reselect", ok ? "ok" : (InputSourceInstall.lastFailure ?? "failed"))
                    self.refreshInputSourceStatus()
                }
                if !self.globalHotkey.isListeningToEvents {
                    self.startGlobalHotkeyMonitor()
                }
            }
        }
        startGlobalHotkeyMonitor()
        refreshInputSourceStatus()
        settingsChanged()
        if !setupCompleted || !permissions.allCriticalGranted {
            beginSetup()
        }
    }

    func beginSetup() {
        guard !isSetupRunning else { return }
        isSetupRunning = true
        settingsTab = 0
        openSettings()
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSetupRunning = false }
            // Present the explanation window before asking the OS for first-time consent.
            await Task.yield()
            self.permissions.refresh()
            if self.permissions.microphone == .notDetermined {
                await self.requestMicrophonePermission()
            }
            self.refreshInputSourceStatus()
            guard self.permissions.microphone == .granted else {
                self.report(SetupReadiness.Blocker.microphoneDenied.message)
                return
            }
            if !self.inputSourceSelected {
                self.enableInputSource()
                // Keep setup on the current step while the user responds to macOS.
                while self.isActivatingInputSource {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                self.refreshInputSourceStatus()
                guard self.inputSourceEnabled && self.inputSourceSelected else { return }
            }
            // Initial model inspection is asynchronous. Wait rather than silently
            // dropping the download request because inspection is still in progress.
            for _ in 0..<100 {
                if !self.isChecking { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !self.isChecking else {
                self.report("模型检查仍未完成，请稍后点击继续设置。")
                return
            }
            if !self.speechModelReady || !self.translationModelReady {
                await self.downloadModels()
            }
        }
    }

    func requestMicrophonePermission() async {
        await permissions.requestMicrophone()
        refreshInputSourceStatus()
        if permissions.microphone == .granted { lastError = nil }
        else { report(SetupReadiness.Blocker.microphoneDenied.message) }
    }

    func requestInputMonitoring() {
        permissions.requestInputMonitoring()
        startGlobalHotkeyMonitor()
        refreshInputSourceStatus()
        if globalHotkey.isListeningToEvents {
            lastError = nil
        } else if !permissions.inputMonitoringGranted {
            report("还没有允许输入监控。允许后，在其它输入法下按住快捷键就会切到 Saylane 并开始语音。")
        } else {
            report("输入监控已允许，但全局按键监听没有成功。请再试一次，或先手动切到 Saylane。")
        }
    }

    private func startGlobalHotkeyMonitor() {
        globalHotkey.onAction = { [weak self] action in
            Task { @MainActor in self?.performShortcut(action, fromGlobal: true) }
        }
        globalHotkey.updateContext(selected: InputSourceInstall.isSelected, trigger: pushToTalk,
                                   switchEnabled: languageSwitchEnabled, listening: isListening,
                                   tapToTalk: tapToTalk)
        let ok = globalHotkey.start()
        lastTapAttempt = ProcessInfo.processInfo.systemUptime
        InputDiagnostics.record("global-tap", ok ? (globalHotkey.isFiltering ? "filter" : "listen") : "failed")
    }

    private func showBlockedStart(_ blocker: SetupReadiness.Blocker) {
        report(blocker.message)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastBlockedPromptTime > 1.5 else { return }
        lastBlockedPromptTime = now
        settingsTab = blocker == .modelsMissing ? 2 : 0
        openSettings()
        // This press is cancelled. Consent must never silently resume an old recording.
        if blocker == .microphoneNotRequested {
            Task { [weak self] in await self?.requestMicrophonePermission() }
        }
    }

    func openSettings() {
        pinyin.commit()
        coordinator.cancel()
        settingsWindow.show(model: self)
        refreshInputSourceStatus()
    }

    func commitPinyin() { pinyin.commit() }

    func togglePinyinEnglishMode() {
        pinyin.setEnglishMode(!pinyinEnglishMode)
        pinyinEnglishMode = pinyin.englishMode
    }

    func setPinyinAssociationEnabled(_ enabled: Bool) {
        pinyin.setAssociationEnabled(enabled)
        pinyinAssociationEnabled = pinyin.associationEnabled
    }

    func setPinyinBarPreeditEnabled(_ enabled: Bool) {
        pinyin.setBarPreeditEnabled(enabled)
        pinyinBarPreeditEnabled = pinyin.barPreeditEnabled
    }

    func setPinyinFuzzyEnabled(_ enabled: Bool) {
        pinyin.setFuzzyEnabled(enabled)
        pinyinFuzzyEnabled = pinyin.fuzzyEnabled
    }

    private func resetShortcuts() {
        holdTask?.cancel(); holdTask = nil
        globalStartTask?.cancel(); globalStartTask = nil
        keys.reset()
        globalHotkey.resetGesture()
    }

    func setVoiceMode(_ direction: TranslationDirection) {
        guard !isListening, !isPreparingModels else { return }
        guard currentDirection != direction else { return }
        updatingLanguagePair = true
        sourceLanguage = direction.source
        targetLanguage = direction.target
        updatingLanguagePair = false
        settingsChanged()
        overlay.showLanguageSwitch(from: sourceLanguage.displayName, to: targetLanguage.displayName, title: direction.title)
        lastLanguageSwitch = "\(direction.title)：我说 \(sourceLanguage.displayName) → 写成 \(targetLanguage.displayName)"
    }

    func swapTranslationDirection() {
        guard !isListening, !isPreparingModels else { return }
        let next = TranslationDirection.cycled(
            current: currentDirection, a: pairSource, b: pairTarget)
        updatingLanguagePair = true
        sourceLanguage = next.source
        targetLanguage = next.target
        updatingLanguagePair = false
        settingsChanged()
        overlay.showLanguageSwitch(from: sourceLanguage.displayName, to: targetLanguage.displayName, title: next.title)
        lastLanguageSwitch = "\(next.title)：我说 \(sourceLanguage.displayName) → 写成 \(targetLanguage.displayName)"
        InputDiagnostics.record("translation-direction-cycled", "\(sourceLanguage.rawValue)->\(targetLanguage.rawValue)")
    }

    private func applyPairAsTranslateMode() {
        updatingLanguagePair = true
        sourceLanguage = pairSource
        targetLanguage = pairTarget
        updatingLanguagePair = false
        settingsChanged()
    }

    func consumeIMEEvent(_ event: NSEvent) -> Bool {
        // Doubao Combined handler: when the monitor tap is alive it owns the
        // voice shortcut. IMK only composes pinyin so we cannot miss a wake
        // after the user has switched to another input source.
        if globalHotkey.isListeningToEvents {
            if isListening { return false }
            let handled = pinyin.handle(event, pushToTalk: pushToTalk)
            pinyinEnglishMode = pinyin.englishMode
            return handled
        }
        return handleShortcutEvent(event, fromGlobal: false)
    }

    @discardableResult
    private func handleShortcutEvent(_ event: NSEvent, fromGlobal: Bool) -> Bool {
        let (action, consumed) = keys.handle(type: event.type, keyCode: event.keyCode,
            flags: UInt64(event.modifierFlags.rawValue), repeatKey: event.type == .keyDown && event.isARepeat,
            trigger: pushToTalk, switchEnabled: languageSwitchEnabled,
            active: isListening, now: ProcessInfo.processInfo.systemUptime, tapToTalk: tapToTalk)
        if action == .press { pinyin.commit() }
        if fromGlobal && action != .none {
            let captured = action
            DispatchQueue.main.async { self.performShortcut(captured, fromGlobal: true) }
        } else {
            performShortcut(action, fromGlobal: false)
        }
        if consumed { return true }
        if isListening { return false }
        if fromGlobal { return consumed }
        let handled = pinyin.handle(event, pushToTalk: pushToTalk)
        pinyinEnglishMode = pinyin.englishMode
        return handled
    }

    private func performShortcut(_ action: InputShortcutHandler.Action, fromGlobal: Bool = false) {
        if action != .none { InputDiagnostics.record("shortcut-action", "\(String(describing: action)) global=\(fromGlobal)") }
        switch action {
        case .armHold, .armTap:
            let delay = action == .armTap ? InputShortcutHandler.doubleTapGap : InputShortcutHandler.holdDelay
            holdTask?.cancel()
            holdTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                let next = fromGlobal
                    ? self.globalHotkey.holdDeadline(now: ProcessInfo.processInfo.systemUptime)
                    : self.keys.holdDeadline(now: ProcessInfo.processInfo.systemUptime)
                self.performShortcut(next, fromGlobal: fromGlobal)
            }
        case .press: startSession(fromGlobal: fromGlobal)
        case .release:
            holdTask?.cancel(); globalStartTask?.cancel()
            coordinator.release()
            endShortcutDirect()
        case .cancel:
            holdTask?.cancel(); globalStartTask?.cancel()
            coordinator.cancel()
            endShortcutDirect()
        case .switchTarget: holdTask?.cancel(); swapTranslationDirection()
        case .none: break
        }
    }

    func endSession() { coordinator.release(); endShortcutDirect() }

    private func startSession(fromGlobal: Bool = false) {
        guard !isListening else { return }
        if fromGlobal {
            beginShortcutDirect()
            InputDiagnostics.record("global-press", "current=\(InputSourceInstall.currentID ?? "none")")
            if InputSourceInstall.isEnabled && !InputSourceInstall.isSelected {
                let ok = InputSourceInstall.selectEnabledMode()
                InputDiagnostics.record("global-select", ok ? "ok" : (InputSourceInstall.lastFailure ?? "failed"))
                refreshInputSourceStatus()
            }
            globalStartTask?.cancel()
            globalStartTask = Task { [weak self] in
                await self?.waitForClientAndStart()
            }
            return
        }
        startSessionNow(openSettingsIfNeeded: true)
    }

    /// Doubao `prepare_input_source` / `shortcut_direct`: select ourselves, wait
    /// for IMK attach, and keep an ignore window so deactivateServer cannot cancel ASR.
    private func waitForClientAndStart() async {
        beginShortcutDirect()
        for _ in 0..<80 {
            if Task.isCancelled { return }
            if !InputSourceInstall.isSelected && InputSourceInstall.isEnabled {
                _ = InputSourceInstall.selectEnabledMode()
            }
            refreshInputSourceStatus()
            if IMEManager.shared.hasClient && InputSourceInstall.isSelected { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if Task.isCancelled {
            endShortcutDirect()
            return
        }
        startSessionNow(openSettingsIfNeeded: false)
        if !isListening { endShortcutDirect() }
    }

    private func beginShortcutDirect() {
        shortcutDirectActive = true
        suppressWorkspaceCancel = true
    }

    private func endShortcutDirect() {
        shortcutDirectActive = false
        if !isListening { suppressWorkspaceCancel = false }
    }

    private func startSessionNow(openSettingsIfNeeded: Bool) {
        guard !isListening else { return }
        refreshInputSourceStatus()
        InputDiagnostics.record("start-check", "selected=\(inputSourceSelected) client=\(IMEManager.shared.hasClient) mic=\(permissions.allCriticalGranted) speech=\(speechModelReady) translation=\(translationModelReady) checking=\(isChecking)")
        if let blocker = readiness.blocker {
            showBlockedStart(blocker)
            return
        }
        guard let target = IMEManager.shared.captureTarget() else {
            report("没有可输入的目标。请先点击普通文本框，再按住快捷键。")
            if openSettingsIfNeeded {
                settingsTab = 0
                openSettings()
            }
            return
        }
        lastError = nil
        // Freeze the request destination and languages for this utterance. No network
        // or Keychain reads occur for ordinary recognition or interim translations.
        let endpoint = finalPolishEndpoint, model = finalPolishModel
        let sourceCode = sourceLanguage.rawValue, targetCode = targetLanguage.rawValue
        let polish: ((String, String) async throws -> String)? = finalPolishEnabled ? { original, draft in
            let config = try FinalPolishConfiguration(endpoint: endpoint, model: model)
            let key = try PolishKeychain.read(endpoint: config.endpoint)
            return try await FinalPolishService.polish(configuration: config, apiKey: key,
                original: original, draft: draft, sourceLanguage: sourceCode, targetLanguage: targetCode)
        } : nil
        coordinator.start(locale: sourceLanguage.speechLocale, speech: makeSpeechEngine(), capture: AudioCaptureService(),
                          target: target, passthrough: sourceLanguage == targetLanguage, polish: polish) { [translationEngine] text in
            try await translationEngine.translate(text)
        }
    }

    func refreshInputSourceStatus() {
        permissions.refresh()
        installationPathValid = InputSourceInstall.isInstalledLocation
        inputSourceInstalled = IMEManager.shared.isInstalled
        inputSourceEnabled = InputSourceInstall.isEnabled
        inputSourceSelected = InputSourceInstall.isSelected
        globalHotkey.updateContext(selected: inputSourceSelected, trigger: pushToTalk,
                                   switchEnabled: languageSwitchEnabled, listening: isListening,
                                   tapToTalk: tapToTalk)
    }

    private var activationTask: Task<Void, Never>?
    var isActivatingInputSource = false

    func enableInputSource() {
        guard !isActivatingInputSource else { return }
        lastError = nil
        isActivatingInputSource = true
        activationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isActivatingInputSource = false; self.refreshInputSourceStatus() }
            guard InputSourceInstall.requestEnable() else {
                self.report(InputSourceInstall.lastFailure ?? "系统尚未发现输入法。")
                return
            }
            // Keep the GUI run loop alive for the native approval flow. Fresh handles
            // are queried on every poll; no preference writes or unrelated IME toggles.
            var requestedMode = InputSourceInstall.parentEnabled
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                self.refreshInputSourceStatus()
                if InputSourceInstall.parentEnabled && !requestedMode {
                    requestedMode = true
                    guard InputSourceInstall.requestModeEnable() else {
                        self.report(InputSourceInstall.lastFailure ?? "启用输入模式失败。")
                        return
                    }
                }
                if InputSourceInstall.isEnabled {
                    if !InputSourceInstall.selectEnabledMode() {
                        self.report(InputSourceInstall.lastFailure ?? "切换未完成。")
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self.report("文件已安装，但系统尚未启用 Saylane。请完成系统的允许或添加操作；若添加列表仍不可见，请保存工作后注销并重新登录。当前不能开始输入。")
        }
    }

    private func settingsChanged() {
        coordinator.cancel(); resetShortcuts()
        settingsRevision += 1
        let revision = settingsRevision
        modelTask?.cancel()
        speechModelReady = false; translationModelReady = false
        translationConfiguration = nil
        translationEngine.reset()
        checkingSettings = true
        modelTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == self.settingsRevision { self.checkingSettings = false } }
            if self.speechModel == .apple { await QwenRuntime.shared.unload() }
            guard revision == self.settingsRevision, !Task.isCancelled else { return }
            do {
                if self.sourceLanguage == self.targetLanguage { self.translationEngine.enablePassthrough() }
                else { try await self.translationEngine.prepareInstalled(source: self.sourceLanguage.translationLanguage, target: self.targetLanguage.translationLanguage) }
                guard revision == self.settingsRevision, !Task.isCancelled else { return }
            } catch {
                if revision == self.settingsRevision, !Task.isCancelled { self.report(error.localizedDescription) }
            }
            guard revision == self.settingsRevision, !Task.isCancelled else { return }
            await self.refreshModelStatus()
        }
    }

    private func makeSpeechEngine() -> any SpeechRecognizing {
        speechModel == .apple ? SpeechEngine() : QwenSpeechEngine(variant: speechModel)
    }

    func selectSpeechModel(_ selected: SpeechModel) {
        guard !isListening, !isChecking, !isPreparingModels, !asrModels.isDownloading,
              selected == .apple || asrModels.installed.contains(selected) else { return }
        speechModel = selected
        UserDefaults.standard.set(selected.rawValue, forKey: "speechModel")
        lastError = nil
        settingsChanged()
    }

    func downloadSpeechModel(_ selected: SpeechModel) async {
        guard !isListening, !isChecking, !isPreparingModels, !asrModels.isDownloading else { return }
        lastError = nil
        isPreparingModels = true
        defer { isPreparingModels = false }
        do {
            try await asrModels.download(selected)
            if speechModel == selected {
                await QwenRuntime.shared.unload()
                await refreshModelStatus()
            }
        } catch is CancellationError {
            // Explicit cancellation is not an application failure.
        } catch let error as URLError where error.code == .cancelled {
        } catch { report(error.localizedDescription) }
    }

    func removeSpeechModel(_ selected: SpeechModel) async {
        guard !isListening, !isChecking, !isPreparingModels, !asrModels.isDownloading else { return }
        if speechModel == selected {
            speechModel = .apple
            UserDefaults.standard.set(speechModel.rawValue, forKey: "speechModel")
            // Freeze all model actions while releasing the loaded weights.
            isPreparingModels = true
            await QwenRuntime.shared.unload()
            isPreparingModels = false
        }
        do { try asrModels.remove(selected) } catch { report(error.localizedDescription) }
        settingsChanged()
    }

    func refreshModelStatus() async {
        speechStatusChecks += 1
        defer { speechStatusChecks -= 1 }
        let revision = settingsRevision
        let source = sourceLanguage
        let selected = speechModel
        asrModels.refresh()
        if selected == .apple {
            await QwenRuntime.shared.unload()
            let installed = await SpeechEngine.isInstalled(for: source.speechLocale)
            guard revision == settingsRevision, !Task.isCancelled else { return }
            speechModelReady = installed
            speechModelDetail = !SpeechTranscriber.isAvailable ? "当前设备不支持 Apple 语音模型" : installed
                ? "\(source.displayName) 语音模型已安装" : "请下载 \(source.displayName) 的语音模型"
        } else {
            speechModelReady = false
            if asrModels.installed.contains(selected) {
                speechModelDetail = "正在校验并加载 \(selected.title)…"
                do {
                    _ = try QwenLanguage.name(for: source.speechLocale)
                    try await QwenRuntime.shared.prepare(selected)
                    guard revision == settingsRevision, !Task.isCancelled else { return }
                    speechModelReady = true
                    speechModelDetail = "\(selected.title) 已就绪 · 松开后出字"
                } catch {
                    guard revision == settingsRevision, !Task.isCancelled else { return }
                    speechModelDetail = "模型未就绪，请重试或重新下载修复"
                    report(error.localizedDescription)
                }
            } else {
                await QwenRuntime.shared.unload()
                speechModelDetail = "请下载 \(selected.title)"
            }
        }
        guard revision == settingsRevision, !Task.isCancelled else { return }
        translationModelReady = sourceLanguage == targetLanguage || translationEngine.isReady
        translationModelDetail = sourceLanguage == targetLanguage ? "同语言听写，不调用翻译" : translationModelReady
            ? "翻译模型已就绪" : "翻译模型未准备好，请点击下载"
        refreshInputSourceStatus()
    }

    func downloadModels() async {
        guard !isPreparingModels, !isListening, !isChecking, !asrModels.isDownloading else { return }
        isPreparingModels = true
        defer { isPreparingModels = false }
        lastError = nil
        do {
            if speechModel == .apple {
                guard let locale = await SpeechEngine.resolvedLocale(for: sourceLanguage.speechLocale) else { throw SpeechEngineError.unsupportedLocale }
                try await SpeechEngine.prepareModel(for: locale)
            } else if !asrModels.installed.contains(speechModel) {
                try await asrModels.download(speechModel)
            }
            if sourceLanguage != targetLanguage && !translationEngine.isReady {
                // Attached to the visible Settings view so Apple's download approval is visible.
                translationConfiguration = TranslationSession.Configuration(source: sourceLanguage.translationLanguage, target: targetLanguage.translationLanguage)
            }
            await refreshModelStatus()
        } catch { report(error.localizedDescription) }
    }

    func handleTranslationSession(_ session: TranslationSession) async {
        let revision = settingsRevision
        do {
            try await translationEngine.attach(session)
            guard revision == settingsRevision else { return }
            await refreshModelStatus()
        } catch { if revision == settingsRevision { report(error.localizedDescription) } }
    }

    private func report(_ message: String) {
        lastError = message
        InputDiagnostics.record("error", message)
        NSLog("Saylane: %@", message)
        // Error persists in menu/settings; do not steal focus from the target app.
    }
}
