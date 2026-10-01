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
    private var clientFresh = false
    /// Client callbacks caused synchronously by our own `insertText` are not a
    /// focus change. Without this guard the final voice commit invalidates the
    /// exact lease before queued user text can be replayed.
    private var ownedInsertLeaseID: UUID?
    private var ownedInsertDepth = 0
    /// Monotonic focus/client epoch used by voice and captured composition targets.
    private(set) var clientGeneration = 0
    private var lastCaretRects: [UUID: NSRect] = [:]
    var onTargetLost: (() -> Void)?
    var hasClient: Bool { clientFresh && controller?.textInputClient != nil }
    var isInstalled: Bool { !InputSourceInstall.ours(includeDisabled: true).isEmpty }
    var isOursSelected: Bool { selected() }
    var clientBundleID: String? { hasClient ? controller?.textInputClient?.bundleIdentifier() : nil }
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
        let sameLease = controller === next && attachedClient === nextClient && attachedLeaseID == nextLeaseID
        guard !sameLease || !clientFresh else { return }
        clientGeneration += 1
        controller = next
        attachedClient = nextClient
        attachedLeaseID = nextLeaseID
        clientFresh = true
        if !sameLease {
            onTargetLost?()
            onWillSwitchClient?(next)
        }
    }
    @discardableResult
    func detach(_ old: SaylaneInputController, leaseID: UUID) -> Bool {
        guard isCurrent(old, leaseID: leaseID) else { return false }
        clientGeneration += 1
        lastCaretRects.removeValue(forKey: leaseID)
        controller = nil
        attachedClient = nil
        attachedLeaseID = nil
        clientFresh = false
        onTargetLost?()
        onWillSwitchClient?(nil)
        return true
    }
    func targetChanged(_ old: SaylaneInputController, leaseID: UUID) {
        guard isCurrent(old, leaseID: leaseID) else { return }
        clientGeneration += 1
        clientFresh = false
        onTargetLost?()
    }

    private func suspendCurrentClient() {
        guard controller != nil || attachedClient != nil || attachedLeaseID != nil else { return }
        clientGeneration += 1
        if let attachedLeaseID { lastCaretRects.removeValue(forKey: attachedLeaseID) }
        controller = nil
        attachedClient = nil
        attachedLeaseID = nil
        clientFresh = false
        onTargetLost?()
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
        let previous = ownedInsertLeaseID
        ownedInsertLeaseID = leaseID
        ownedInsertDepth += 1
        defer {
            ownedInsertDepth -= 1
            if ownedInsertDepth == 0 { ownedInsertLeaseID = previous }
        }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    func insertDeferredText(_ text: String, leaseID: UUID, generation: Int) -> Bool {
        performOwnedInsert(text, leaseID: leaseID, generation: generation)
    }

    func captureTarget() -> (any CompositionTarget)? {
        guard clientFresh, isOursSelected, let controller, let client = controller.textInputClient,
              let leaseID = attachedLeaseID, controller.sessionID == leaseID else { return nil }
        let token = clientGeneration
        return CapturedComposition(
            valid: { [weak self, weak controller] in
                guard let self, let controller else { return false }
                return self.clientGeneration == token && self.controller === controller
                    && self.attachedLeaseID == leaseID && self.attachedClient === client
                    && self.isOursSelected
            },
            marked: { text in
                IMEManager.applyMarkedText(text, caret: (text as NSString).length, highlight: NSRange(location: 0, length: 0), to: client)
            },
            insert: { [weak self] text in
                guard let self,
                      self.performOwnedInsert(text, leaseID: leaseID, generation: token) else {
                    throw SessionFailure.targetLost
                }
            }
        )
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

@MainActor
private final class CapturedComposition: CompositionTarget {
    let valid: () -> Bool
    let marked: (String) -> Void
    let insert: (String) throws -> Void
    private var ownsMarkedText = false
    init(valid: @escaping () -> Bool, marked: @escaping (String) -> Void, insert: @escaping (String) throws -> Void) {
        self.valid = valid; self.marked = marked; self.insert = insert
    }
    var isValid: Bool { valid() }
    func setMarked(_ text: String) {
        guard isValid else { return }
        ownsMarkedText = true
        marked(text)
    }
    func commit(_ text: String) throws {
        guard isValid else { throw SessionFailure.targetLost }
        ownsMarkedText = false
        try insert(text)
    }
    func cancelMarked() {
        guard ownsMarkedText else { return }
        ownsMarkedText = false
        guard isValid else { return }
        marked("")
    }
}
