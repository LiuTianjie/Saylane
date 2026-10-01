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
final class SaylaneInputController: IMKInputController, InputClientController {
    /// Identifies one activation of this controller's client. Pinyin sessions
    /// and text writes are scoped to it. IMK creates one controller per client,
    /// so the lease follows activation and never the identity of a proxy
    /// object: a key always reaches the session of the activation it belongs to.
    private(set) var sessionID: UUID?
    /// The receiver IMK named in the most recent callback of this activation.
    /// All marked text and commits use this one.
    private(set) var textInputClient: (any IMKTextInput)?
    /// The Latin layout is bound once per client, not on every key event.
    private var keyboardBound = false

    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        textInputClient = client as? IMKTextInput
        super.init(server: server, delegate: delegate, client: client)
    }

    /// Adopt the receiver of this callback and make sure a lease exists. Keys
    /// may arrive without a preceding activation (Chromium), so `handle` binds too.
    @MainActor @discardableResult
    private func bind(_ sender: Any?, newActivation: Bool = false) -> Bool {
        guard let next = (sender as? IMKTextInput) ?? textInputClient ?? client() else { return false }
        if newActivation, let previous = sessionID { retire(previous) }
        if (textInputClient as AnyObject?) !== (next as AnyObject) { keyboardBound = false }
        textInputClient = next
        if sessionID == nil { sessionID = UUID() }
        guard !keyboardBound else { return true }
        next.overrideKeyboard(withKeyboardNamed: latinKeyboardLayout)
        keyboardBound = true
        return true
    }

    /// End a lease: resolve its composition and drop everything scoped to it.
    @MainActor
    private func retire(_ leaseID: UUID) {
        if IMEManager.shared.isCurrent(self, leaseID: leaseID) {
            // IMK expects the composition to be resolved when the client goes away.
            IMEHost.shared.commitPinyin()
            IMEManager.shared.detach(self, leaseID: leaseID)
        }
        IMEHost.shared.forgetClient(leaseID)
        guard sessionID == leaseID else { return }
        sessionID = nil
        keyboardBound = false
    }

    override func menu() -> NSMenu! {
        nonisolated(unsafe) var built: NSMenu?
        nonisolated(unsafe) let me = self
        onMain { built = me.buildMenu() }
        return built
    }

    /// Wording and state come from the main program; this process only shows them.
    @MainActor private func buildMenu() -> NSMenu {
        let host = IMEHost.shared
        let state = host.menu
        let menu = NSMenu(title: "Saylane")
        menu.autoenablesItems = false
        if let notice = state.notice {
            add(menu, "⚠︎ " + notice, #selector(showNotice(_:)))
            menu.addItem(.separator())
        }
        if !state.directionTitle.isEmpty {
            menu.addItem(withTitle: state.directionTitle, action: nil, keyEquivalent: "").isEnabled = false
        }
        add(menu, host.englishMode ? String(localized: "切换到拼音中文") : String(localized: "切换到英文键盘"),
            #selector(togglePinyinMode(_:))).isEnabled = !host.isDictating
        if host.mainProgramConnected {
            if state.canSwitchDirection {
                add(menu, String(localized: "切换翻译方向"), #selector(switchOutputLanguage(_:))).isEnabled = !host.isDictating
            }
            add(menu, String(localized: "截屏翻译"), #selector(captureScreen(_:)))
            if state.hasLastDictation {
                add(menu, String(localized: "复制上一次听写"), #selector(copyLastDictation(_:)))
            }
        }
        menu.addItem(.separator())
        add(menu, String(localized: "打开 Rime 用户词库目录"), #selector(openRimeUserDirectory(_:)))
        add(menu, String(localized: "Saylane 设置…"), #selector(showPreferences(_:)))
        return menu
    }

    @MainActor @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    override func showPreferences(_ sender: Any!) {
        onMain { IMEHost.shared.perform(.openSettings) }
    }

    @objc private func showNotice(_ sender: Any!) {
        onMain { IMEHost.shared.perform(.showNotice) }
    }

    @objc private func switchOutputLanguage(_ sender: Any!) {
        onMain { IMEHost.shared.perform(.switchDirection) }
    }

    @objc private func togglePinyinMode(_ sender: Any!) {
        onMain { IMEHost.shared.toggleEnglishMode() }
    }

    @objc private func captureScreen(_ sender: Any!) {
        onMain { IMEHost.shared.perform(.screenCapture) }
    }

    @objc private func copyLastDictation(_ sender: Any!) {
        onMain { IMEHost.shared.perform(.copyLastDictation) }
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
            guard me.bind(callbackSender, newActivation: true) else {
                InputDiagnostics.record("ime-activated", "client=false")
                return
            }
            IMEManager.shared.attach(me)
        }
    }
    override func deactivateServer(_ sender: Any!) {
        nonisolated(unsafe) let me = self
        onMain {
            guard let leaseID = me.sessionID else { return }
            me.retire(leaseID)
        }
        super.deactivateServer(sender)
    }
    override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let me = self
        onMain {
            guard let leaseID = me.sessionID, IMEManager.shared.isCurrent(me, leaseID: leaseID) else { return }
            // Our own `insertText` makes some clients call back synchronously.
            if IMEManager.shared.isPerformingOwnedInsert(me, leaseID: leaseID) { return }
            // A client-side click must not submit a partially translated phrase:
            // while dictating, the preview is withdrawn and the dictation carries on.
            if !IMEHost.shared.isDictating { IMEHost.shared.commitPinyin() }
            // `commitComposition` is also how many hosts announce a focus move
            // within the same client. Pinyin writes again after the next key.
            IMEManager.shared.targetChanged(me, leaseID: leaseID)
        }
    }
    override func inputControllerWillClose() {
        nonisolated(unsafe) let me = self
        onMain {
            if let leaseID = me.sessionID { me.retire(leaseID) }
            me.textInputClient = nil
        }
        super.inputControllerWillClose()
    }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        // Key accessors raise on any other kind of event.
        guard let event, event.type == .keyDown || event.type == .flagsChanged else { return false }
        nonisolated(unsafe) let me = self
        nonisolated(unsafe) let keyEvent = event
        nonisolated(unsafe) let callbackSender = sender
        return onMain {
            // Without a receiver nothing can be written: let the application have the key.
            guard me.bind(callbackSender) else { return false }
            IMEManager.shared.attach(me)
            return IMEHost.shared.handle(keyEvent)
        }
    }
}
