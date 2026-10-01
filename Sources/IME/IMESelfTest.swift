import AppKit
import Carbon.HIToolbox
import InputMethodKit

/// `--self-test`: run the input method's own code — the real controller, the
/// real client bookkeeping, real Rime, the real candidate window and the real
/// bridge — against a text client that lives in this process. The only part
/// not exercised is InputMethodKit's transport to other applications; no
/// IMKServer is created, so the installed input method is not disturbed.
/// Runs only in a test home (`SAYLANE_TEST_HOME`).
@MainActor
enum IMESelfTest {
    private final class Client: NSObject, IMKTextInput {
        var marked = ""
        var inserted: [String] = []
        var calls = 0
        func insertText(_ string: Any!, replacementRange: NSRange) {
            calls += 1
            inserted.append((string as? NSAttributedString)?.string ?? (string as? String ?? ""))
            marked = ""
        }
        func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
            calls += 1
            marked = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        }
        func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
        func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length) }
        func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
        func length() -> Int { 0 }
        func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
        func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
            lineHeightRectangle?.pointee = NSRect(x: 400, y: 400, width: 2, height: 18)
            return [:]
        }
        func validAttributesForMarkedText() -> [Any]! { [] }
        func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
        func selectMode(_ modeIdentifier: String!) {}
        func supportsUnicode() -> Bool { true }
        func bundleIdentifier() -> String! { "local.saylane.selftest" }
        func windowLevel() -> CGWindowLevel { 0 }
        func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
        func uniqueClientIdentifierString() -> String! { "self-test" }
        func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { "" }
        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { NSRect(x: 400, y: 400, width: 2, height: 18) }
    }

    private final class StandIn: InputClientController {
        var sessionID: UUID? = UUID()
        var textInputClient: (any IMKTextInput)?
        init(client: any IMKTextInput) { textInputClient = client }
        /// What the input controller's `handle` does once it has bound its client.
        @MainActor func handle(_ event: NSEvent) -> Bool {
            IMEManager.shared.attach(self)
            return IMEHost.shared.handle(event)
        }
    }

    private static var failures = 0

    private static func check(_ condition: Bool, _ message: String) {
        print((condition ? "ok   " : "FAIL ") + message)
        if !condition { failures += 1 }
    }

    private static func key(_ characters: String, _ code: Int, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(code))!
    }

    /// Ask our own bridge port from another thread, as the main program would.
    private static func ask(_ request: BridgeRequest) async -> BridgeReply? {
        let data = Bridge.encode(request)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let reply = BridgeSender(name: Bridge.imePortName).request(data, timeout: 2)
                continuation.resume(returning: Bridge.decode(BridgeReply.self, from: reply))
            }
        }
    }

    private static func done(_ reply: BridgeReply?) -> Bool {
        if case .done(let value)? = reply { return value }
        return false
    }

    static func run() async -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        guard TestHome.isActive else {
            print("self-test needs SAYLANE_TEST_HOME")
            return 2
        }
        let host = IMEHost.shared
        host.start()
        check(host.pinyin.initializationError == nil, "Rime starts from the bundle's own data (\(host.pinyin.initializationError ?? "ok"))")

        // InputMethodKit's controller cannot exist without its server, and a
        // server would register this process as the input method. A stand-in
        // gives the manager the same two facts the real controller does.
        let client = Client()
        let controller = StandIn(client: client)
        IMEManager.shared.attach(controller)
        check(IMEManager.shared.clientBundleID == "local.saylane.selftest" && IMEManager.shared.hasClient,
              "activation attaches the client")
        check(client.calls == 0, "activation writes nothing into the client (\(client.calls) calls)")

        // Typing: nihao → a composition, a candidate window, 你好 on space.
        if host.englishMode { host.toggleEnglishMode() }
        var consumed = true
        for (letter, code) in [("n", kVK_ANSI_N), ("i", kVK_ANSI_I), ("h", kVK_ANSI_H), ("a", kVK_ANSI_A), ("o", kVK_ANSI_O)] {
            consumed = controller.handle(key(letter, code)) && consumed
        }
        check(consumed, "letters are taken by the input method")
        check(!client.marked.isEmpty && client.inserted.isEmpty, "a composition is shown in the client (\"\(client.marked)\")")
        let panel = NSApp.windows.first { $0.isVisible && $0 is NSPanel }
        check(panel != nil, "the candidate window is on screen")
        check(controller.handle(key(" ", kVK_Space)), "space is taken by the input method")
        check(client.inserted == ["你好"] && client.marked.isEmpty, "space writes the first candidate (\(client.inserted))")
        check(NSApp.windows.allSatisfy { !($0.isVisible && $0 is NSPanel) }, "the candidate window is gone after the commit")

        // A shortcut passes through untouched.
        check(!controller.handle(key("w", kVK_ANSI_W, flags: .command)), "⌘W is left to the application")

        // Shift toggles Chinese and English; in English mode letters go straight through.
        host.toggleEnglishMode()
        check(!controller.handle(key("a", kVK_ANSI_A)) || client.inserted.last == "a",
              "in English mode a letter is not composed")
        host.toggleEnglishMode()

        // A dictation written through the bridge, exactly as the main program asks for it.
        let session = UUID()
        var context = BridgeContext()
        context.revision = 1; context.appPID = 1; context.trigger = "rightOption"
        context.phase = .listening; context.session = session; context.sessionBundleID = "local.saylane.selftest"
        check(done(await ask(.context(context))), "the bridge accepts a context")
        check(host.isDictating, "the input method knows a dictation is running")
        check(!controller.handle(key("x", kVK_ANSI_X)), "while listening a key is left to the application")
        check(controller.handle(key("\u{1b}", kVK_Escape)), "while listening Esc is swallowed")
        check(done(await ask(.voiceMarked(session: session, seq: 1, text: "你好世界"))) && client.marked == "你好世界",
              "a preview appears in the client (\"\(client.marked)\")")
        context.revision = 2; context.phase = .finalizing
        _ = await ask(.context(context))
        check(controller.handle(key("b", kVK_ANSI_B)), "a key typed while the text is pending waits")
        let before = client.inserted.count
        check(done(await ask(.voiceInsert(session: session, text: "你好，世界。", deadline: ProcessInfo.processInfo.systemUptime + 2))),
              "the final text is written")
        check(client.inserted.count > before && client.inserted[before] == "你好，世界。", "it replaces the preview (\(client.inserted))")
        check(!client.marked.isEmpty || client.inserted.last == "b", "the waiting key is typed after it (marked \"\(client.marked)\")")
        _ = await ask(.voiceEnd(session: session))
        context.revision = 3; context.phase = .idle; context.session = nil; context.sessionBundleID = nil
        _ = await ask(.context(context))
        check(!host.isDictating, "the dictation is over")
        if case .status(let status)? = await ask(.status) {
            check(status.attachedBundleID == "local.saylane.selftest" && status.protocolVersion == Bridge.protocolVersion,
                  "status reports the attached client")
        } else {
            check(false, "status is answered")
        }

        // Deactivation, as the controller does it: resolve the composition, detach, forget the session.
        _ = controller.handle(key("n", kVK_ANSI_N))
        check(!client.marked.isEmpty, "a new composition is showing")
        if let lease = controller.sessionID {
            host.commitPinyin()
            IMEManager.shared.detach(controller, leaseID: lease)
            host.forgetClient(lease)
        }
        check(IMEManager.shared.clientBundleID == nil, "deactivation detaches the client")
        check(client.marked.isEmpty, "nothing is left marked in the client (inserted \(client.inserted.suffix(2)))")

        print(failures == 0 ? "PASS: input method self-test" : "FAILED: \(failures) check(s)")
        return failures == 0 ? 0 : 1
    }

    private static func wait(_ seconds: TimeInterval, until condition: () -> Bool) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func modifier(_ trigger: PushToTalkHotkey, down: Bool) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? trigger.nsModifierFlag : [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(trigger.keyCode))!
    }

    /// `--self-test-duo`: this process plays the input method for a main program
    /// started in the same test home with a scripted recognizer. Keys go in here
    /// exactly as InputMethodKit would deliver them; the dictation they start
    /// in the other process must come back as text in this process's client.
    /// `SAYLANE_TEST_FRONT` is the application the main program believes is in
    /// front: this client's own, or another one — then the client is a panel
    /// over it (Spotlight, a launcher) and must be written all the same.
    static func runDuo() async -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        guard TestHome.isActive, let expected = ProcessInfo.processInfo.environment["SAYLANE_TEST_SPEECH"], !expected.isEmpty else {
            print("duo self-test needs SAYLANE_TEST_HOME and SAYLANE_TEST_SPEECH")
            return 2
        }
        let host = IMEHost.shared
        host.start()
        let client = Client()
        let controller = StandIn(client: client)
        IMEManager.shared.attach(controller)
        let front = ProcessInfo.processInfo.environment["SAYLANE_TEST_FRONT"] ?? "unknown"
        print(front == client.bundleIdentifier() ? "the client's application is in front"
                                                 : "the client is a panel over \(front)")
        check(await wait(15) { host.mainProgramConnected }, "the main program found the input method and introduced itself")
        guard host.mainProgramConnected else { return 1 }
        let trigger = host.trigger

        // A chord with the talk key: nothing may happen in either process.
        _ = controller.handle(modifier(trigger, down: true))
        _ = controller.handle(key("c", kVK_ANSI_C, flags: trigger.nsModifierFlag))
        _ = await wait(0.7) { host.isDictating }
        _ = controller.handle(modifier(trigger, down: false))
        check(!host.isDictating && client.calls == 0, "a chord with the talk key starts nothing")

        // A tap: nothing either.
        _ = controller.handle(modifier(trigger, down: true))
        try? await Task.sleep(for: .milliseconds(60))
        _ = controller.handle(modifier(trigger, down: false))
        _ = await wait(0.6) { host.isDictating }
        check(!host.isDictating && client.calls == 0, "a tap of the talk key starts nothing")

        // Held on its own: the dictation starts over there, its preview shows up here.
        // The main program may still be starting (a first launch takes seconds):
        // the key stays held until it answers, as a person would hold it.
        _ = controller.handle(modifier(trigger, down: true))
        check(await wait(12) { host.isDictating }, "holding the talk key starts a dictation in the main program")
        check(await wait(3) { !client.marked.isEmpty }, "its preview appears at the caret (\"\(client.marked)\")")
        _ = controller.handle(modifier(trigger, down: false))
        check(await wait(5) { client.inserted.last == expected }, "releasing writes the final text (\(client.inserted))")
        check(await wait(3) { !host.isDictating }, "and the dictation ends")
        check(client.marked.isEmpty, "no preview is left behind")

        // Typing still works afterwards.
        if host.englishMode { host.toggleEnglishMode() }
        for (letter, code) in [("n", kVK_ANSI_N), ("i", kVK_ANSI_I)] { _ = controller.handle(key(letter, code)) }
        _ = controller.handle(key(" ", kVK_Space))
        check(client.inserted.last == "你", "pinyin still composes after a dictation (\(client.inserted))")

        // A second dictation, to be sure nothing of the first one lingers.
        _ = controller.handle(modifier(trigger, down: true))
        _ = await wait(3) { host.isDictating }
        _ = await wait(3) { !client.marked.isEmpty }
        _ = controller.handle(modifier(trigger, down: false))
        check(await wait(5) { client.inserted.filter { $0 == expected }.count == 2 }, "a second dictation is written as well")

        print(failures == 0 ? "PASS: two-process self-test" : "FAILED: \(failures) check(s)")
        return failures == 0 ? 0 : 1
    }
}
