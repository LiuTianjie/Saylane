import AppKit
import InputMethodKit

@MainActor
final class IMEManager {
    static let shared = IMEManager()
    private let selected: () -> Bool
    init(inputSourceSelected: @escaping () -> Bool = { InputSourceInstall.isSelected }) {
        selected = inputSourceSelected
    }
    // Explicitly own the active controller. Deactivation clears it; the active
    // input receiver must not disappear between an IMK callback and a hotkey.
    private(set) var controller: SaylaneInputController?
    private var attachedClient: (any IMKTextInput)?
    private var attachedLeaseID: UUID?
    /// Read once per attachment; asking the proxy is a round trip to the client.
    private var attachedBundleID: String?
    private var clientFresh = false
    /// The lease whose client currently shows a dictation preview.
    private var voiceMarkedLeaseID: UUID?
    /// Client callbacks caused synchronously by our own `insertText` are not a
    /// focus change. Without this guard the final voice commit invalidates the
    /// exact lease before queued user text can be replayed.
    private var ownedInsertLeaseID: UUID?
    private var ownedInsertDepth = 0
    /// Monotonic focus/client epoch used by voice and captured composition targets.
    private(set) var clientGeneration = 0
    private var lastCaretRects: [UUID: NSRect] = [:]
    var hasClient: Bool { clientFresh && controller?.textInputClient != nil }
    var isInstalled: Bool { !InputSourceInstall.ours(includeDisabled: true).isEmpty }
    var isOursSelected: Bool { selected() }
    /// Application of the attached client, fresh or not.
    var clientBundleID: String? { attachedBundleID }
    var currentLeaseID: UUID? { attachedLeaseID }
    var deferredInputSnapshot: (leaseID: UUID, generation: Int)? {
        guard clientFresh, let leaseID = attachedLeaseID,
              controller?.sessionID == leaseID, attachedClient != nil else { return nil }
        return (leaseID, clientGeneration)
    }
    func isCurrent(_ candidate: SaylaneInputController, leaseID: UUID) -> Bool {
        controller === candidate && attachedLeaseID == leaseID
    }
    func isCurrentLease(_ leaseID: UUID) -> Bool {
        clientFresh && attachedLeaseID == leaseID && controller?.sessionID == leaseID && attachedClient != nil
    }

    /// The active client changed; the pinyin engine switches to that client's session.
    var onWillSwitchClient: ((SaylaneInputController?) -> Void)?

    func attach(_ next: SaylaneInputController) {
        guard let nextClient = next.textInputClient, let nextLeaseID = next.sessionID else {
            suspendCurrentClient()
            return
        }
        let sameLease = controller === next && attachedLeaseID == nextLeaseID
        guard !sameLease || !clientFresh else {
            // The receiver object may differ between callbacks of one activation.
            attachedClient = nextClient
            return
        }
        if !sameLease { clearVoiceMarked() }
        clientGeneration += 1
        controller = next
        attachedClient = nextClient
        attachedLeaseID = nextLeaseID
        clientFresh = true
        if !sameLease {
            attachedBundleID = nextClient.bundleIdentifier()
            onWillSwitchClient?(next)
        }
    }
    @discardableResult
    func detach(_ old: SaylaneInputController, leaseID: UUID) -> Bool {
        guard isCurrent(old, leaseID: leaseID) else { return false }
        clearVoiceMarked()
        clientGeneration += 1
        lastCaretRects.removeValue(forKey: leaseID)
        controller = nil
        attachedClient = nil
        attachedLeaseID = nil
        attachedBundleID = nil
        clientFresh = false
        onWillSwitchClient?(nil)
        return true
    }
    /// The client resolved its composition (a click, a focus move inside the
    /// same proxy). Pinyin needs a new key callback before it writes again; a
    /// dictation preview is withdrawn and continues in the HUD.
    func targetChanged(_ old: SaylaneInputController, leaseID: UUID) {
        guard isCurrent(old, leaseID: leaseID) else { return }
        clearVoiceMarked()
        clientGeneration += 1
        clientFresh = false
    }

    private func suspendCurrentClient() {
        guard controller != nil || attachedClient != nil || attachedLeaseID != nil else { return }
        clearVoiceMarked()
        clientGeneration += 1
        if let attachedLeaseID { lastCaretRects.removeValue(forKey: attachedLeaseID) }
        controller = nil
        attachedClient = nil
        attachedLeaseID = nil
        attachedBundleID = nil
        clientFresh = false
        onWillSwitchClient?(nil)
    }

    func matchesDeferredInput(leaseID: UUID, generation: Int) -> Bool {
        isCurrentLease(leaseID) && clientGeneration == generation
    }

    func isPerformingOwnedInsert(_ candidate: SaylaneInputController, leaseID: UUID) -> Bool {
        ownedInsertDepth > 0 && ownedInsertLeaseID == leaseID && isCurrent(candidate, leaseID: leaseID)
    }

    @discardableResult
    private func performOwnedInsert(_ text: String, leaseID: UUID, generation: Int? = nil) -> Bool {
        guard !text.isEmpty, isCurrentLease(leaseID),
              generation == nil || clientGeneration == generation,
              let client = attachedClient else { return false }
        ownedInsert(text, into: client, leaseID: leaseID)
        return true
    }

    private func ownedInsert(_ text: String, into client: any IMKTextInput, leaseID: UUID) {
        let previous = ownedInsertLeaseID
        ownedInsertLeaseID = leaseID
        ownedInsertDepth += 1
        defer {
            ownedInsertDepth -= 1
            if ownedInsertDepth == 0 { ownedInsertLeaseID = previous }
        }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func insertDeferredText(_ text: String, leaseID: UUID, generation: Int) -> Bool {
        performOwnedInsert(text, leaseID: leaseID, generation: generation)
    }

    // MARK: - Voice

    /// Dictation writes need our source selected and a client of the application
    /// in front that is still attached. Unlike pinyin they do not need a fresh
    /// key callback: after a click inside the same client the text belongs at
    /// the new caret. Anything else is written without IMK by the caller.
    private func voiceClient(inFront bundleID: String?) -> (client: any IMKTextInput, leaseID: UUID)? {
        guard isOursSelected, let controller, let client = attachedClient,
              let leaseID = attachedLeaseID, controller.sessionID == leaseID else { return nil }
        if let bundleID, attachedBundleID != bundleID { return nil }
        return (client, leaseID)
    }

    func canWriteVoice(inFront bundleID: String?) -> Bool { voiceClient(inFront: bundleID) != nil }

    /// Show a dictation preview as marked text. False when no client accepts it.
    @discardableResult
    func setVoiceMarked(_ text: String, inFront bundleID: String?) -> Bool {
        // A preview withdrawn by the client stays in the HUD until a key or a
        // new activation proves where the caret is.
        guard clientFresh, let target = voiceClient(inFront: bundleID) else { return false }
        Self.applyMarkedText(text, caret: (text as NSString).length, highlight: NSRange(location: 0, length: 0), to: target.client)
        voiceMarkedLeaseID = text.isEmpty ? nil : target.leaseID
        return !text.isEmpty
    }

    /// Insert the final dictation. False when no client accepts it.
    @discardableResult
    func insertVoiceText(_ text: String, inFront bundleID: String?) -> Bool {
        guard !text.isEmpty, let target = voiceClient(inFront: bundleID) else { return false }
        voiceMarkedLeaseID = nil
        ownedInsert(text, into: target.client, leaseID: target.leaseID)
        return true
    }

    /// Withdraw the preview from the client that shows it, if it is still attached.
    func clearVoiceMarked() {
        guard let leaseID = voiceMarkedLeaseID else { return }
        voiceMarkedLeaseID = nil
        guard leaseID == attachedLeaseID, let client = attachedClient else { return }
        Self.applyMarkedText("", caret: 0, highlight: NSRange(location: 0, length: 0), to: client)
    }

    @discardableResult
    func setPinyinMarked(_ text: String, caret: Int? = nil,
                         highlight: NSRange = NSRange(location: 0, length: 0), leaseID: UUID) -> Bool {
        guard isCurrentLease(leaseID), let client = attachedClient else { return false }
        Self.applyMarkedText(text, caret: caret ?? (text as NSString).length, highlight: highlight, to: client)
        return true
    }

    /// Preserve the engine's editing caret as a zero-length selection.
    /// The active segment uses a thicker underline.
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

    @discardableResult
    func insertPinyin(_ text: String, leaseID: UUID) -> Bool {
        performOwnedInsert(text, leaseID: leaseID)
    }

    /// Screen rectangle of the insertion point. Asks at the caret's own index
    /// (index 0 is wrong for anything but an empty field), remembers the last
    /// good answer per client, and returns nil when the client reports nothing.
    func caretScreenRect(leaseID: UUID) -> NSRect? {
        guard isCurrentLease(leaseID), let client = attachedClient else { return nil }
        var rect = NSRect.zero
        let selected = client.selectedRange()
        let index = selected.location == NSNotFound ? 0 : selected.location
        _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
        if rect.width + rect.height <= 0, index > 0 {
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        }
        if rect.width + rect.height > 0 {
            lastCaretRects[leaseID] = rect
            return rect
        }
        return lastCaretRects[leaseID]
    }
}
