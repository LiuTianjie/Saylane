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
    /// Holds its text as a text field does: writes land at the caret, a
    /// composition stands in the text, and what is there can be read back.
    private final class Client: NSObject, IMKTextInput {
        var marked = ""
        var inserted: [String] = []
        var calls = 0
        let text = NSMutableString()
        private var caret = 0
        private var markedStart: Int?
        /// Some clients cannot report their text: nothing is learned there, and nothing else changes.
        var reportsText = true

        private func write(_ string: String) -> Int {
            let target = markedStart.map { NSRange(location: $0, length: (marked as NSString).length) } ?? NSRange(location: caret, length: 0)
            text.replaceCharacters(in: target, with: string)
            caret = target.location + (string as NSString).length
            return target.location
        }
        /// The user's own edit: one stretch replaced by another, the caret left at the end.
        func edit(_ old: String, _ new: String) {
            let range = text.range(of: old, options: .backwards)
            guard range.location != NSNotFound else { return }
            text.replaceCharacters(in: range, with: new)
            caret = text.length
        }
        func insertText(_ string: Any!, replacementRange: NSRange) {
            calls += 1
            let string = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
            inserted.append(string)
            _ = write(string)
            marked = ""
            markedStart = nil
        }
        func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
            calls += 1
            let string = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
            let start = write(string)
            marked = string
            markedStart = string.isEmpty ? nil : start
        }
        func selectedRange() -> NSRange { NSRange(location: caret, length: 0) }
        func markedRange() -> NSRange {
            markedStart.map { NSRange(location: $0, length: (marked as NSString).length) } ?? NSRange(location: NSNotFound, length: 0)
        }
        func attributedSubstring(from range: NSRange) -> NSAttributedString! {
            guard reportsText, range.location <= text.length else { return nil }
            return NSAttributedString(string: text.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: text.length))))
        }
        func length() -> Int { text.length }
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

        // The optional language model, when a test home has it in its Rime
        // directory: the plugin shipped in this bundle reads it, and a sentence
        // the plain engine gets wrong (…提交岛主分支了) comes out right.
        if case .success(let runtime) = RimeRuntime.shared, runtime.languageModelInstalled {
            for letter in "daimayijingtijiaodaozhufenzhile" {
                _ = controller.handle(key(String(letter), 0))
            }
            check(controller.handle(key(" ", kVK_Space)) && client.inserted.last == "代码已经提交到主分支了",
                  "with the language model installed, a whole sentence comes out right (\(client.inserted.last ?? ""))")
        }

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

        await readBackChecks(client: client, controller: controller, context: &context)

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

    /// The user changes a dictation after it was written. With the main
    /// program's say-so the input method reads the stretch back and reports
    /// it; without it, or in a client that cannot report its text, it reads
    /// and reports nothing, and typing goes on as before.
    private static func readBackChecks(client: Client, controller: StandIn, context: inout BridgeContext) async {
        var reports: [BridgeReadBack] = []
        // This process plays the main program's port as well: what the input method posts arrives here.
        let listener = BridgeListener(name: Bridge.appPortName) { data in
            if case .readBack(let report)? = Bridge.decode(BridgeEvent.self, from: data) { reports.append(report) }
            return nil
        }
        check(listener != nil, "the self-test listens where the main program would")
        defer { listener?.invalidate() }

        func dictate(_ text: String, learns: Bool) async -> UUID {
            let session = UUID()
            context.learnsCorrections = learns
            context.revision += 1; context.phase = .listening; context.session = session
            context.sessionBundleID = "local.saylane.selftest"
            _ = await ask(.context(context))
            _ = await ask(.voiceMarked(session: session, seq: 1, text: String(text.prefix(2))))
            context.revision += 1; context.phase = .finalizing
            _ = await ask(.context(context))
            let written = done(await ask(.voiceInsert(session: session, text: text, deadline: ProcessInfo.processInfo.systemUptime + 2)))
            _ = await ask(.voiceEnd(session: session))
            context.revision += 1; context.phase = .idle; context.session = nil; context.sessionBundleID = nil
            _ = await ask(.context(context))
            check(written && client.text.hasSuffix(text), "a dictation is written at the caret (\(client.inserted.suffix(1)))")
            // The input method looks half a second after the write whether the client reads back.
            try? await Task.sleep(for: .seconds(DictationReadBack.settleDelay + 0.2))
            return session
        }
        func pressReturn() -> Bool { controller.handle(key("\r", kVK_Return)) }

        // Not allowed: nothing comes back, whatever the user does to the text.
        _ = await dictate("明天和黄根诚开会。", learns: false)
        client.edit("黄根诚", "黄根成")
        check(!pressReturn(), "Return is left to the application")
        _ = await wait(0.3) { !reports.isEmpty }
        check(reports.isEmpty, "without the main program's say-so nothing is read back")

        // Allowed: untouched text says nothing; an edit comes back once, as the stretch reads now.
        let session = await dictate("帮我找一下章三。", learns: true)
        _ = pressReturn()
        _ = await wait(0.3) { !reports.isEmpty }
        check(reports.isEmpty, "an untouched dictation is not reported")
        client.edit("章三", "张三")
        check(!pressReturn(), "Return still reaches the application after an edit")
        check(await wait(2) { !reports.isEmpty }, "an edit after a dictation is reported")
        check(reports.first == BridgeReadBack(session: session, text: "帮我找一下张三。", startsDocument: false, endsDocument: true, closed: false),
              "the report is the dictated stretch as it reads now, nothing before it (\(reports.first?.text?.count ?? -1) characters)")
        _ = pressReturn()
        _ = await wait(0.3) { reports.count > 1 }
        check(reports.count == 1, "the same text is not reported twice")
        // The main program is done with it.
        check(done(await ask(.voiceForget(session: session))), "the bridge accepts a forget")
        client.edit("张三", "张珊")
        _ = pressReturn()
        _ = await wait(0.3) { reports.count > 1 }
        check(reports.count == 1, "a forgotten dictation is not read again")

        // A client that cannot report its text: nothing is learned, and typing is what it was.
        client.reportsText = false
        _ = await dictate("帮我找一下章三。", learns: true)
        client.edit("章三", "张三")
        _ = pressReturn()
        _ = await wait(0.3) { reports.count > 1 }
        check(reports.count == 1, "a client that cannot report its text is left alone")
        client.reportsText = true
        if IMEHost.shared.englishMode { IMEHost.shared.toggleEnglishMode() }
        for (letter, code) in [("n", kVK_ANSI_N), ("i", kVK_ANSI_I)] { _ = controller.handle(key(letter, code)) }
        check(controller.handle(key(" ", kVK_Space)) && client.inserted.last == "你", "pinyin composes as before (\(client.inserted.suffix(1)))")
        context.learnsCorrections = false
        context.revision += 1
        _ = await ask(.context(context))
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

        // The menu: the four ways to speak and write, chosen here, changed in the main program.
        check(await wait(5) { host.menu.modes.count == 4 && host.menu.currentMode == 0 && host.menu.canChooseMode },
              "the menu lists the four ways to speak and write (\(host.menu.modes))")
        host.chooseMode(3)
        check(await wait(5) { host.menu.currentMode == 3 }, "choosing one in the menu changes it in the main program")
        _ = await wait(3) { host.menu.canChooseMode }
        host.chooseMode(0)
        check(await wait(5) { host.menu.currentMode == 0 }, "and choosing the first one changes it back")

        // Learning from a correction, end to end (`SAYLANE_TEST_CORRECTION=heard>corrected`,
        // with a scripted sentence that contains the heard spelling): the user
        // fixes the name and leaves the field, twice; the third time the main
        // program writes the corrected name by itself.
        if let correction = ProcessInfo.processInfo.environment["SAYLANE_TEST_CORRECTION"]?.split(separator: ">").map(String.init),
           correction.count == 2 {
            let heard = correction[0], corrected = correction[1]
            let fixed = expected.replacingOccurrences(of: heard, with: corrected)
            func dictate() async -> String? {
                let before = client.inserted.count
                _ = controller.handle(modifier(trigger, down: true))
                guard await wait(5, until: { host.isDictating }) else { return nil }
                _ = await wait(3) { !client.marked.isEmpty }
                _ = controller.handle(modifier(trigger, down: false))
                guard await wait(5, until: { client.inserted.count > before && !host.isDictating }) else { return nil }
                return client.inserted.last
            }
            /// How often the main program has seen the correction, from the file it keeps.
            func seen() -> Int {
                guard let data = try? Data(contentsOf: AppDirectories.learnedCorrectionsFile),
                      let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pairs = file["pairs"] as? [[String: Any]] else { return 0 }
                return pairs.first { $0["heard"] as? String == heard && $0["corrected"] as? String == corrected }?["seen"] as? Int ?? 0
            }
            for round in 1...2 {
                check(await dictate() == expected, "round \(round): the dictation is written as it was heard")
                try? await Task.sleep(for: .seconds(DictationReadBack.settleDelay + 0.2))
                client.edit(heard, corrected)
                _ = controller.handle(key("\r", kVK_Return))
                // The field loses focus, as the controller does it; then it is activated again.
                if let lease = controller.sessionID {
                    host.commitPinyin()
                    IMEManager.shared.detach(controller, leaseID: lease)
                    host.forgetClient(lease)
                }
                check(await wait(5) { seen() == round }, "round \(round): the main program learned the correction (seen \(seen()))")
                controller.sessionID = UUID()
                IMEManager.shared.attach(controller)
            }
            check(await dictate() == fixed, "the third time the corrected name is written without anyone's help (\(client.inserted.suffix(1)))")
            let stored = (try? String(contentsOf: AppDirectories.learnedCorrectionsFile, encoding: .utf8)) ?? ""
            check(stored.contains(heard) && !stored.contains(expected) && !stored.contains(fixed), "the file holds the pair and no sentence")
        }

        print(failures == 0 ? "PASS: two-process self-test" : "FAILED: \(failures) check(s)")
        return failures == 0 ? 0 : 1
    }
}
