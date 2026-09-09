import AppKit
import Carbon.HIToolbox
import InputMethodKit

@objc(SaylaneInputController)
final class SaylaneInputController: IMKInputController {
    override func menu() -> NSMenu! {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            let menu = NSMenu(title: "Saylane")
            menu.autoenablesItems = false
            let languages = menu.addItem(withTitle: model.currentDirection.title, action: nil, keyEquivalent: "")
            languages.isEnabled = false
            let keyboard = menu.addItem(withTitle: model.pinyinEnglishMode ? "切换到拼音中文" : "切换到英文键盘",
                                        action: #selector(togglePinyinMode(_:)), keyEquivalent: "")
            keyboard.target = self
            keyboard.isEnabled = !model.isListening
            let settings = menu.addItem(withTitle: "Saylane 设置…", action: #selector(showPreferences(_:)), keyEquivalent: "")
            settings.target = self
            if model.languageSwitchEnabled {
                let change = menu.addItem(withTitle: "切换翻译方向", action: #selector(switchOutputLanguage(_:)), keyEquivalent: "")
                change.target = self
                change.isEnabled = !model.isListening && !model.isPreparingModels
            }
            return menu
        }
    }

    override func showPreferences(_ sender: Any!) {
        MainActor.assumeIsolated { AppModel.shared.openSettings() }
    }

    @objc private func switchOutputLanguage(_ sender: Any!) {
        MainActor.assumeIsolated { AppModel.shared.swapTranslationDirection() }
    }

    @objc private func togglePinyinMode(_ sender: Any!) {
        MainActor.assumeIsolated { AppModel.shared.togglePinyinEnglishMode() }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]).rawValue)
    }
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MainActor.assumeIsolated { InputDiagnostics.record("ime-activated"); IMEManager.shared.attach(self) }
    }
    override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            InputDiagnostics.record("ime-deactivated")
            AppModel.shared.commitPinyin()
            IMEManager.shared.detach(self)
        }
        super.deactivateServer(sender)
    }
    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            if AppModel.shared.isListening {
                // A client-side click must not submit a partially translated phrase.
                IMEManager.shared.targetChanged(self)
            } else {
                AppModel.shared.commitPinyin()
            }
        }
    }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        return MainActor.assumeIsolated {
            IMEManager.shared.attach(self)
            if event.type == .flagsChanged {
                InputDiagnostics.record("modifier-received", "key=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")
            }
            return AppModel.shared.consumeIMEEvent(event)
        }
    }
}

@MainActor
final class IMEManager {
    static let shared = IMEManager()
    private weak var controller: SaylaneInputController?
    private var generation = 0
    var onTargetLost: (() -> Void)?
    var hasClient: Bool { controller?.client() != nil }
    var isInstalled: Bool { !InputSourceInstall.ours(includeDisabled: true).isEmpty }
    var isOursSelected: Bool { InputSourceInstall.isSelected }

    var onWillSwitchClient: (() -> Void)?

    func attach(_ next: SaylaneInputController) {
        guard controller !== next else { return }
        onWillSwitchClient?()
        onTargetLost?()
        generation += 1
        controller = next
    }
    func detach(_ old: SaylaneInputController) {
        guard controller === old else { return }
        onWillSwitchClient?()
        onTargetLost?()
        generation += 1
        controller = nil
    }
    func targetChanged(_ old: SaylaneInputController) {
        guard controller === old else { return }
        onTargetLost?()
        generation += 1
    }

    func captureTarget() -> (any CompositionTarget)? {
        guard isOursSelected, let controller, let client = controller.client() else { return nil }
        let token = generation
        return CapturedComposition(
            valid: { [weak self, weak controller] in
                guard let self, let controller else { return false }
                return self.generation == token && self.controller === controller && self.isOursSelected
            },
            marked: { text in
                IMEManager.applyMarkedText(text, caret: (text as NSString).length, highlight: NSRange(location: 0, length: 0), to: client)
            },
            insert: { text in client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        )
    }

    func setPinyinMarked(_ text: String, caret: Int? = nil, highlight: NSRange = NSRange(location: 0, length: 0)) {
        guard let client = controller?.client() else { return }
        Self.applyMarkedText(text, caret: caret ?? (text as NSString).length, highlight: highlight, to: client)
    }

    /// Caret sits at the end of the composition, not as a full-range selection.
    /// The active syllable uses a thicker underline, matching Doubao/Rime frontends.
    fileprivate static func applyMarkedText(_ text: String, caret: Int, highlight: NSRange, to client: IMKTextInput) {
        if text.isEmpty {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        let ns = text as NSString
        let length = ns.length
        let marked = NSMutableAttributedString(string: text)
        marked.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                            range: NSRange(location: 0, length: length))
        let start = min(max(0, highlight.location), length)
        let end = min(max(start, highlight.location + highlight.length), length)
        if end > start {
            marked.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue,
                                range: NSRange(location: start, length: end - start))
        }
        client.setMarkedText(marked, selectionRange: NSRange(location: min(max(0, caret), length), length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func insertPinyin(_ text: String) {
        guard !text.isEmpty, let client = controller?.client() else { return }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func caretScreenRect() -> NSRect? {
        guard let client = controller?.client() else { return nil }
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

}

@MainActor
private final class CapturedComposition: CompositionTarget {
    let valid: () -> Bool
    let marked: (String) -> Void
    let insert: (String) -> Void
    private var ownsMarkedText = false
    init(valid: @escaping () -> Bool, marked: @escaping (String) -> Void, insert: @escaping (String) -> Void) {
        self.valid = valid; self.marked = marked; self.insert = insert
    }
    var isValid: Bool { valid() }
    func setMarked(_ text: String) {
        guard isValid else { return }
        ownsMarkedText = true
        marked(text)
    }
    func commit(_ text: String) {
        guard isValid else { return }
        ownsMarkedText = false
        insert(text)
    }
    func cancelMarked() {
        guard ownsMarkedText else { return }
        ownsMarkedText = false
        // Never resolve a new client: this closure still references the original client.
        marked("")
    }
}
