import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Last resort for applications that never attach an IMK client (terminals, some
/// Electron fields): write the final text through Accessibility, or paste it.
/// Requires the Accessibility permission; never used for live marked text.
enum AccessibilityInserter {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Insert `text` at the focused element of the frontmost application.
    /// Returns false when neither the AX attribute nor a paste could be attempted.
    @MainActor
    static func insert(_ text: String, into target: AXUIElement) -> Bool {
        guard !text.isEmpty, isTrusted else { return false }
        if insertThroughAccessibility(text, into: target) { return true }
        return paste(text)
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    static func isEditable(_ target: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return false }
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(target, kAXSubroleAttribute as CFString, &subrole)
        return subrole as? String != kAXSecureTextFieldSubrole
    }

    struct FieldSnapshot: Equatable {
        var selection: NSRange?
        var value: String?
    }

    /// Focus can remain on the same AX object after a caret move or an edit.
    /// Validate its text/selection too, including when keyboard monitoring is
    /// unavailable. These values remain local and are never logged.
    static func snapshot(of target: AXUIElement) -> FieldSnapshot {
        var snapshot = FieldSnapshot()
        var rawRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, &rawRange) == .success,
           let rawRange, CFGetTypeID(rawRange) == AXValueGetTypeID() {
            let value = rawRange as! AXValue
            var range = CFRange()
            if AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) {
                snapshot.selection = NSRange(location: range.location, length: range.length)
            }
        }
        var rawValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &rawValue) == .success {
            snapshot.value = rawValue as? String
        }
        return snapshot
    }

    private static func insertThroughAccessibility(_ text: String, into target: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(target, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    /// Preserve all pasteboard representations, and restore only while the
    /// pasteboard is still ours. clearContents and setString each change its count.
    @MainActor
    private static func paste(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                item.data(forType: type).map { (type, $0) }
            }
        } ?? []
        func restore() {
            pasteboard.clearContents()
            let items = previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { restore(); return false }
        let ownedCount = pasteboard.changeCount
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            // Only restore if nobody else has written to the pasteboard meanwhile.
            guard pasteboard.changeCount == ownedCount else { return }
            restore()
        }
        return true
    }
}

/// `CompositionTarget` that shows nothing live and commits once through Accessibility.
@MainActor
final class AccessibilityTarget: CompositionTarget {
    private let bundleID: String?
    private let element: AXUIElement
    private var committed = false
    private let inputRevision: () -> UInt64
    private let capturedInputRevision: UInt64
    private let fieldSnapshot: AccessibilityInserter.FieldSnapshot
    init?(bundleID: String?, inputRevision: @escaping () -> UInt64) {
        guard AccessibilityInserter.isTrusted,
              let element = AccessibilityInserter.focusedElement(), AccessibilityInserter.isEditable(element) else { return nil }
        self.bundleID = bundleID
        self.element = element
        self.inputRevision = inputRevision
        capturedInputRevision = inputRevision()
        fieldSnapshot = AccessibilityInserter.snapshot(of: element)
    }
    var isValid: Bool {
        guard !committed, inputRevision() == capturedInputRevision, AccessibilityInserter.isTrusted,
              let focused = AccessibilityInserter.focusedElement(), CFEqual(focused, element),
              AccessibilityInserter.snapshot(of: element) == fieldSnapshot else { return false }
        guard let bundleID else { return true }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }
    func setMarked(_ text: String) {}
    func commit(_ text: String) throws {
        guard isValid else { throw SessionFailure.targetLost }
        guard AccessibilityInserter.insert(text, into: element) else { throw SessionFailure.insertionFailed }
        committed = true
    }
    func cancelMarked() {}
}
