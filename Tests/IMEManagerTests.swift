import AppKit
import InputMethodKit
import Carbon.HIToolbox

final class SaylaneInputController: InputClientController {
    var sessionID: UUID? = UUID()
    var textInputClient: (any IMKTextInput)?
    init(_ client: any IMKTextInput) { textInputClient = client }
}
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
    var bundle = "test.editor"
    func bundleIdentifier() -> String! { bundle }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "test-client" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { "" }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

@main struct IMEManagerTests {
    @MainActor static func main() throws {
        var selected = true
        let manager = IMEManager(inputSourceSelected: { selected })
        let a = Client(), b = Client()
        let controllerA = SaylaneInputController(a), controllerB = SaylaneInputController(b)
        manager.attach(controllerA)
        let snapshot = manager.deferredInputSnapshot!
        // Simulate an IMK client that calls commitComposition synchronously from
        // insertText. Owned insertion must not become a phantom focus change.
        a.onInsert = {
            MainActor.assumeIsolated {
                if !manager.isPerformingOwnedInsert(controllerA, leaseID: snapshot.leaseID) {
                    manager.targetChanged(controllerA, leaseID: snapshot.leaseID)
                }
            }
        }
        precondition(manager.setVoiceMarked("voice preview", inFront: "test.editor"))
        precondition(manager.insertVoiceText("authoritative final tail", inFront: "test.editor"))
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

        // A dictation preview is withdrawn from the client that showed it when
        // another client takes over, and never appears in the new one.
        precondition(manager.setVoiceMarked("owned preview", inFront: "test.editor"))
        manager.attach(controllerB)
        precondition(a.marked.last == "" && b.marked.isEmpty && b.inserted.isEmpty)
        manager.clearVoiceMarked()
        precondition(b.marked.isEmpty)
        precondition(!manager.detach(controllerA, leaseID: snapshot.leaseID))
        precondition(manager.controller === controllerB && manager.hasClient)

        // Voice writes follow attachment, not key freshness: after the client
        // resolved its composition (a click), the preview stays in the HUD but
        // the final text is still inserted at the new caret.
        let leaseB = manager.currentLeaseID!
        precondition(manager.setVoiceMarked("live", inFront: "test.editor") && b.marked.last == "live")
        manager.targetChanged(controllerB, leaseID: leaseB)
        precondition(b.marked.last == "", "the client's commitComposition must withdraw the preview")
        precondition(!manager.setVoiceMarked("more", inFront: "test.editor") && b.marked.last == "")
        precondition(manager.insertVoiceText("final", inFront: "test.editor") && b.inserted == ["final"])
        // Never through a client of another application, a detached client, or
        // while another input source is selected.
        precondition(!manager.canWriteVoice(inFront: "other.app")
                     && !manager.insertVoiceText("x", inFront: "other.app"))
        selected = false
        precondition(!manager.insertVoiceText("x", inFront: "test.editor"))
        selected = true
        manager.attach(controllerB)
        precondition(manager.setVoiceMarked("again", inFront: "test.editor"))
        precondition(manager.detach(controllerB, leaseID: leaseB) && b.marked.last == "")
        precondition(!manager.canWriteVoice(inFront: "test.editor")
                     && !manager.insertVoiceText("x", inFront: "test.editor") && b.inserted == ["final"])
        manager.attach(controllerB)

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
        // IMK may hand over another receiver object within one activation. It is
        // the same lease: no focus epoch change, and writes use the newest object.
        let c1 = Client(), c2 = Client()
        let controllerC = SaylaneInputController(c1)
        manager.attach(controllerC)
        let epoch = manager.clientGeneration
        controllerC.textInputClient = c2
        manager.attach(controllerC)
        precondition(manager.clientGeneration == epoch)
        precondition(manager.insertPinyin("x", leaseID: controllerC.sessionID!)
                     && c2.inserted == ["x"] && c1.inserted.isEmpty)
        print("PASS: exact IME epochs, owned final insertion, stale-focus rejection, voice writes by attachment, deferred text/command boundary")
    }
}
