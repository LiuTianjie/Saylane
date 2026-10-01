import AppKit
import Carbon.HIToolbox
import InputMethodKit

/// Chromium clients (WeChat 4 chat, Chrome, Electron) skip IMK if we claim mouse/keyUp,
/// and they need an explicit Latin layout or they never attach the controller.
private let latinKeyboardLayout = "com.apple.keylayout.ABC"

private func onMain<T: Sendable>(_ work: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(work)
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated(work)
    }
}

@objc(SaylaneInputController)
final class SaylaneInputController: IMKInputController {
    /// Changes whenever this controller starts serving a different IMK client or
    /// a new activation. Pinyin sessions and text writes are scoped to this lease.
    private(set) var sessionID: UUID?
    private var lease = IMEClientLeaseState()
    private var ownedSessionIDs: Set<UUID> = []
    /// The receiver supplied by IMK for this activation. Keep it with the
    /// controller until deactivation; all marked text and commits use this one.
    private(set) var textInputClient: (any IMKTextInput)?
    /// The Latin layout is bound once per client, not on every key event.
    private var keyboardBound = false

    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        textInputClient = client as? IMKTextInput
        super.init(server: server, delegate: delegate, client: client)
        if let textInputClient {
            let binding = lease.bind(textInputClient, renew: true)
            sessionID = binding.id
            ownedSessionIDs.insert(binding.id)
        }
    }

    @MainActor @discardableResult
    private func bindLatinKeyboard(_ sender: Any?, renewLease: Bool = false) -> Bool {
        let next = (sender as? IMKTextInput) ?? textInputClient ?? client()
        guard let next else { return false }
        let binding = lease.bind(next, renew: renewLease)
        if binding.changed { keyboardBound = false }
        sessionID = binding.id
        ownedSessionIDs.insert(binding.id)
        textInputClient = next
        guard !keyboardBound else { return true }
        next.overrideKeyboard(withKeyboardNamed: latinKeyboardLayout)
        keyboardBound = true
        return true
    }

    @MainActor
    private func callbackLease(_ sender: Any?) -> UUID? {
        if let callback = sender as? IMKTextInput {
            return lease.lease(matching: callback)
        }
        // IMK normally supplies the text client as sender. Retain a narrow
        // fallback for hosts that only expose it through `client()`.
        return lease.lease(matching: client())
    }

    @MainActor
    private func invalidateLease(_ expected: UUID? = nil) {
        if let expected {
            let wasCurrent = sessionID == expected
            guard lease.invalidate(expected) else { return }
            guard wasCurrent else { return }
        } else {
            lease.invalidate()
        }
        sessionID = nil
        textInputClient = nil
        keyboardBound = false
    }

    @MainActor
    private func resolveCurrentLeaseBeforeLosingClient() {
        if let leaseID = sessionID, IMEManager.shared.isCurrent(self, leaseID: leaseID) {
            AppModel.shared.commitPinyin()
            IMEManager.shared.detach(self, leaseID: leaseID)
            AppModel.shared.pinyin.forgetClient(leaseID)
            ownedSessionIDs.remove(leaseID)
        }
        invalidateLease()
    }

    override func menu() -> NSMenu! {
        nonisolated(unsafe) var built: NSMenu?
        nonisolated(unsafe) let me = self
        onMain { built = me.buildMenu() }
        return built
    }

    @MainActor private func buildMenu() -> NSMenu {
        do {
            let model = AppModel.shared
            let menu = NSMenu(title: "Saylane")
            menu.autoenablesItems = false
            if let notice = model.notice, notice.level == .actionable {
                let item = menu.addItem(withTitle: "⚠︎ " + notice.message, action: #selector(showNoticeDestination(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(.separator())
            }
            let languages = menu.addItem(withTitle: model.currentDirection.title, action: nil, keyEquivalent: "")
            languages.isEnabled = false
            let keyboard = menu.addItem(withTitle: model.pinyinEnglishMode ? String(localized: "切换到拼音中文") : String(localized: "切换到英文键盘"),
                                        action: #selector(togglePinyinMode(_:)), keyEquivalent: "")
            keyboard.target = self
            keyboard.isEnabled = !model.isListening
            if model.prefs.languageSwitchEnabled {
                let change = menu.addItem(withTitle: String(localized: "切换翻译方向"), action: #selector(switchOutputLanguage(_:)), keyEquivalent: "")
                change.target = self
                change.isEnabled = !model.isListening && !model.isPreparingModels
            }
            let screen = menu.addItem(withTitle: String(localized: "截屏翻译"), action: #selector(captureScreen(_:)), keyEquivalent: "")
            screen.target = self
            menu.addItem(.separator())
            let redeploy = menu.addItem(withTitle: String(localized: "打开 Rime 用户词库目录"), action: #selector(openRimeUserDirectory(_:)), keyEquivalent: "")
            redeploy.target = self
            let settings = menu.addItem(withTitle: String(localized: "Saylane 设置…"), action: #selector(showPreferences(_:)), keyEquivalent: "")
            settings.target = self
            return menu
        }
    }

    override func showPreferences(_ sender: Any!) {
        onMain { AppModel.shared.openSettings() }
    }

    @objc private func showNoticeDestination(_ sender: Any!) {
        onMain {
            let model = AppModel.shared
            model.openSettings(for: model.notice?.destination ?? .none)
        }
    }

    @objc private func switchOutputLanguage(_ sender: Any!) {
        onMain { AppModel.shared.swapTranslationDirection() }
    }

    @objc private func togglePinyinMode(_ sender: Any!) {
        onMain { AppModel.shared.togglePinyinEnglishMode() }
    }

    @objc private func captureScreen(_ sender: Any!) {
        onMain { AppModel.shared.handleScreenCaptureHotkey() }
    }

    @objc private func openRimeUserDirectory(_ sender: Any!) {
        NSWorkspace.shared.open(AppDirectories.rime)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }
    // IMK calls these on the main thread; `onMain` asserts that. The controller and
    // its client are not Sendable, so the captures are marked unsafe deliberately.
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        nonisolated(unsafe) let me = self
        nonisolated(unsafe) let callbackSender = sender
        onMain {
            guard me.bindLatinKeyboard(callbackSender, renewLease: true) else {
                me.resolveCurrentLeaseBeforeLosingClient()
                InputDiagnostics.record("ime-activated", "client=false")
                return
            }
            let id = me.textInputClient?.bundleIdentifier() ?? ""
            InputDiagnostics.record("ime-activated", "bundle=\(id) client=\(me.textInputClient != nil)")
            IMEManager.shared.attach(me)
        }
    }
    override func deactivateServer(_ sender: Any!) {
        nonisolated(unsafe) let me = self
        nonisolated(unsafe) let callbackSender = sender
        onMain {
            guard let leaseID = me.callbackLease(callbackSender) else {
                InputDiagnostics.record("ime-deactivated", "stale-client")
                return
            }
            let current = IMEManager.shared.isCurrent(me, leaseID: leaseID)
            InputDiagnostics.record("ime-deactivated", "current=\(current) bundle=\(me.textInputClient?.bundleIdentifier() ?? "unknown")")
            guard current else {
                AppModel.shared.pinyin.forgetClient(leaseID)
                me.ownedSessionIDs.remove(leaseID)
                me.invalidateLease(leaseID)
                return
            }
            // IMK expects the composition to be resolved when the client goes away.
            AppModel.shared.commitPinyin()
            IMEManager.shared.detach(me, leaseID: leaseID)
            AppModel.shared.pinyin.forgetClient(leaseID)
            me.ownedSessionIDs.remove(leaseID)
            me.invalidateLease(leaseID)
        }
        super.deactivateServer(sender)
    }
    override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let me = self
        nonisolated(unsafe) let callbackSender = sender
        onMain {
            guard let leaseID = me.callbackLease(callbackSender),
                  IMEManager.shared.isCurrent(me, leaseID: leaseID) else { return }
            if IMEManager.shared.isPerformingOwnedInsert(me, leaseID: leaseID) {
                return
            }
            if AppModel.shared.isListening {
                // A client-side click must not submit a partially translated phrase.
                IMEManager.shared.targetChanged(me, leaseID: leaseID)
            } else {
                AppModel.shared.commitPinyin()
                // `commitComposition` is also how many hosts announce a focus
                // move within the same app/proxy. Require a subsequent handle
                // or activation before voice may capture this receiver again.
                IMEManager.shared.targetChanged(me, leaseID: leaseID)
            }
        }
    }
    override func inputControllerWillClose() {
        nonisolated(unsafe) let me = self
        onMain {
            if let leaseID = me.sessionID, IMEManager.shared.isCurrent(me, leaseID: leaseID) {
                AppModel.shared.commitPinyin()
                IMEManager.shared.detach(me, leaseID: leaseID)
            }
            for leaseID in me.ownedSessionIDs {
                AppModel.shared.pinyin.forgetClient(leaseID)
            }
            me.ownedSessionIDs.removeAll()
            me.invalidateLease()
        }
        super.inputControllerWillClose()
    }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        nonisolated(unsafe) let me = self
        nonisolated(unsafe) let keyEvent = event
        nonisolated(unsafe) let callbackSender = sender
        return onMain {
            guard me.bindLatinKeyboard(callbackSender) else {
                me.resolveCurrentLeaseBeforeLosingClient()
                return false
            }
            IMEManager.shared.attach(me)
            if keyEvent.type == .flagsChanged {
                InputDiagnostics.record("modifier-received", "key=\(keyEvent.keyCode) flags=\(keyEvent.modifierFlags.rawValue)")
            }
            return AppModel.shared.consumeIMEEvent(keyEvent)
        }
    }
}
