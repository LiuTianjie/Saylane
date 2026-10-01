import AppKit
import Foundation
import Observation

/// Screen-translation feature: wires the controller to preferences, permissions,
/// the input router and the shortcut recorder. The app model only forwards.
@MainActor @Observable
final class ScreenFeature {
    let controller = ScreenTranslateController()
    private(set) var isRecordingShortcut = false
    private(set) var recordingVerdict: ShortcutValidator.Verdict?

    var prefs: () -> Preferences = { Preferences() }
    var pairForDirection: () -> (AppLanguage, AppLanguage) = { (.zhHans, .en) }
    var onNotice: ((UserNotice) -> Void)?
    var onShortcutRecorded: ((ScreenCaptureShortcut) -> Void)?
    var onDirectionChanged: ((TranslationDirection) -> Void)?
    var onActivityChanged: (() -> Void)?
    var requestScreenCapture: () -> Bool = { false }
    var keysHandledGlobally: () -> Bool = { false }
    /// Cancel a voice session that has barely started; returns whether the screen may proceed.
    var yieldVoiceSession: () -> Bool = { true }

    var isActive: Bool { controller.isActive }
    var isSelecting: Bool { controller.isSelecting }
    var isPinVisible: Bool { controller.isPinVisible }

    func wire(router: InputEventRouter) {
        controller.onError = { [weak self] message in self?.onNotice?(.transient(message)) }
        controller.onPinVisibilityChanged = { [weak self, weak router] visible in
            router?.setPinVisible(visible)
            self?.onActivityChanged?()
        }
        controller.onScreenActiveChanged = { [weak self] _ in self?.onActivityChanged?() }
        controller.onDirectionChanged = { [weak self] direction in self?.onDirectionChanged?(direction) }
        controller.keysHandledGlobally = { [weak self] in self?.keysHandledGlobally() ?? false }
    }

    func apply(_ p: Preferences) {
        controller.freezesScreen = p.screenPinFreezesScreen
        controller.fontWeightDetection = p.screenFontWeightExperiment
    }

    func handleCaptureHotkey(preserveKeyboardFocus: Bool = false) {
        if isRecordingShortcut { return }
        if controller.isSelecting {
            controller.cancel()
            return
        }
        guard yieldVoiceSession() else { return }
        let p = prefs()
        if !requestScreenCapture() {
            onNotice?(.actionable(String(localized: "截屏翻译需要屏幕录制权限。允许后再按 \(p.screenCaptureShortcut.displayName) 划区。"), .screen))
            return
        }
        var last: TranslationDirection?
        if let source = p.screenTranslateSource, let target = p.screenTranslateTarget {
            last = TranslationDirection(source: source, target: target)
        }
        controller.polish = p.screenPolishEnabled ? Self.makePolish(endpoint: p.finalPolishEndpoint, model: p.finalPolishModel) : nil
        let (a, b) = pairForDirection()
        controller.beginSelection(a: a, b: b, last: last, preserveKeyboardFocus: preserveKeyboardFocus || keysHandledGlobally())
    }

    func handlePinKey(_ key: ScreenPinKey) {
        let (a, b) = pairForDirection()
        controller.handlePinKey(key, a: a, b: b)
    }

    func cycleDirection() {
        let (a, b) = pairForDirection()
        controller.cycleDirection(a: a, b: b)
    }

    // MARK: - Shortcut recording

    func beginRecordingShortcut() {
        isRecordingShortcut = true
        recordingVerdict = nil
        onActivityChanged?()
    }

    func cancelRecordingShortcut() { finishRecordingShortcut(nil) }

    func finishRecordingShortcut(_ shortcut: ScreenCaptureShortcut?) {
        isRecordingShortcut = false
        onActivityChanged?()
        guard let shortcut else { return }
        var conflicts: [(ScreenCaptureShortcut, String)] = []
        let voice = prefs().pushToTalk
        if !voice.isModifier {
            conflicts.append((ScreenCaptureShortcut(keyCode: UInt16(voice.keyCode), modifierFlags: 0),
                              String(localized: "语音输入快捷键")))
        }
        let verdict = ShortcutValidator.validate(shortcut, conflicts: conflicts)
        recordingVerdict = verdict
        if case .rejected = verdict { return }
        onShortcutRecorded?(shortcut)
    }

    private static func makePolish(endpoint: String, model: String) -> (@Sendable (String, String, String, String, String) async throws -> String) {
        { original, draft, source, target, context in
            let config = try FinalPolishConfiguration(endpoint: endpoint, model: model)
            let key = try PolishKeychain.read(endpoint: config.endpoint)
            return try await FinalPolishService.polish(configuration: config, apiKey: key, original: original, draft: draft,
                                                       sourceLanguage: source, targetLanguage: target, screenContext: context)
        }
    }
}
