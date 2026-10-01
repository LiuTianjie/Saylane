import AppKit
import InputMethodKit
import Carbon.HIToolbox

@MainActor enum InputSourceInstall {
    static let isSelected = true
    static func ours(includeDisabled: Bool) -> [Int] { [] }
}
@MainActor final class SaylaneInputController {
    var sessionID: UUID? = UUID()
    var textInputClient: (any IMKTextInput)?
    init(_ client: any IMKTextInput) { textInputClient = client }
}
@MainActor protocol CompositionTarget: AnyObject {
    var isValid: Bool { get }
    func setMarked(_ text: String)
    func commit(_ text: String) throws
    func cancelMarked()
}
enum SessionFailure: Error { case targetLost }

final class Client: NSObject, IMKTextInput {
    var inserted: [String] = []
    var marked: [String] = []
    var onInsert: (() -> Void)?
    func insertText(_ string: Any!, replacementRange: NSRange) {
        inserted.append(string as? String ?? "")
        onInsert?()
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        marked.append((string as? NSAttributedString)?.string ?? (string as? String ?? ""))
    }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
    func length() -> Int { 0 }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "test.editor" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "test-client" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { "" }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

@main struct IMEManagerTests {
    @MainActor static func main() throws {
        let manager = IMEManager(inputSourceSelected: { true })
        let a = Client(), b = Client()
        let controllerA = SaylaneInputController(a), controllerB = SaylaneInputController(b)
        manager.attach(controllerA)
        let snapshot = manager.deferredInputSnapshot!
        let target = manager.captureTarget()!
        // Simulate an IMK client that calls commitComposition synchronously from
        // insertText. Owned insertion must not become a phantom focus change.
        a.onInsert = {
            MainActor.assumeIsolated {
                if !manager.isPerformingOwnedInsert(controllerA, leaseID: snapshot.leaseID) {
                    manager.targetChanged(controllerA, leaseID: snapshot.leaseID)
                }
            }
        }
        target.setMarked("voice preview")
        try target.commit("authoritative final tail")
        precondition(manager.matchesDeferredInput(leaseID: snapshot.leaseID, generation: snapshot.generation))
        precondition(manager.insertDeferredText("A9", leaseID: snapshot.leaseID, generation: snapshot.generation))
        precondition(a.inserted == ["authoritative final tail", "A9"])

        // A real focus change within the SAME proxy/activation invalidates queued
        // keys. Returning to that proxy cannot make the old epoch current again.
        manager.targetChanged(controllerA, leaseID: snapshot.leaseID)
        precondition(!manager.matchesDeferredInput(leaseID: snapshot.leaseID, generation: snapshot.generation))
        precondition(!manager.insertDeferredText("stale", leaseID: snapshot.leaseID, generation: snapshot.generation))
        manager.attach(controllerA)
        precondition(!manager.matchesDeferredInput(leaseID: snapshot.leaseID, generation: snapshot.generation))
        precondition(a.inserted.count == 2)

        let currentTarget = manager.captureTarget()!
        currentTarget.setMarked("owned preview")
        manager.attach(controllerB)
        precondition(!currentTarget.isValid)
        currentTarget.cancelMarked()
        precondition(b.marked.isEmpty && b.inserted.isEmpty)
        precondition(!manager.detach(controllerA, leaseID: snapshot.leaseID))
        precondition(manager.controller === controllerB && manager.hasClient)

        // The deferred path accepts only printable text that has a faithful
        // insertText fallback. Commands remain on the original IMK callback.
        func key(_ code: Int, _ text: String, _ flags: NSEvent.ModifierFlags = []) -> PinyinKeyEvent {
            .init(type: .keyDown, keyCode: UInt16(code), characters: text, letter: nil, flags: flags, isRepeat: false)
        }
        for item in [key(kVK_ANSI_A, "a"), key(kVK_ANSI_9, "9"), key(kVK_Space, " "),
                     key(kVK_ANSI_A, "A", .shift), key(kVK_ANSI_A, "A", .capsLock), key(kVK_ANSI_Period, ".")] {
            precondition(item.canDeferForVoiceFinalization)
        }
        for item in [key(kVK_ANSI_A, "a", .command), key(kVK_ANSI_A, "a", .control),
                     key(kVK_ANSI_A, "å", .option), key(kVK_Return, "\r"), key(kVK_Tab, "\t"),
                     key(kVK_Delete, "\u{7f}"), key(kVK_LeftArrow, "\u{F702}"), key(kVK_F1, "\u{F704}")] {
            precondition(!item.canDeferForVoiceFinalization)
        }
        print("PASS: exact IME epochs, owned final insertion, stale-focus rejection, deferred text/command boundary")
    }
}
