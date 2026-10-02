import AppKit
import InputMethodKit
import Carbon.HIToolbox

final class SaylaneInputController: InputClientController {
    var sessionID: UUID? = UUID()
    var textInputClient: (any IMKTextInput)?
    init(_ client: any IMKTextInput) { textInputClient = client }
}

final class Client: NSObject, IMKTextInput {
    var log: [String] = []
    /// What the client holds: every insert, in order. Enough to be read back.
    var text = ""
    func insertText(_ string: Any!, replacementRange: NSRange) {
        log.append("insert:\(string as? String ?? "")")
        text += string as? String ?? ""
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        log.append("marked:\((string as? NSAttributedString)?.string ?? (string as? String ?? ""))")
    }
    func selectedRange() -> NSRange { NSRange(location: (text as NSString).length, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        let all = text as NSString
        guard range.location <= all.length else { return nil }
        return NSAttributedString(string: all.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: all.length))))
    }
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

@MainActor final class FakePinyin: PinyinHandling {
    var isComposing = false
    func ensureClient(_ key: UUID?) {}
    func handle(_ event: NSEvent, pushToTalk: PushToTalkHotkey) -> Bool { false }
    func commit() { isComposing = false }
}

/// The two halves of the bridge in two real processes: the main program's
/// client on one side, the input method's core behind its responder on the
/// other. Everything except InputMethodKit itself.
@main struct BridgeEndToEndTests {
    /// The input method's side: a core with one attached client of "test.editor".
    @MainActor static func serveInputMethod() -> Never {
        let manager = IMEManager(inputSourceSelected: { true })
        let client = Client()
        let app = BridgeSender(name: Bridge.appPortName)
        let core = InputMethodCore(manager: manager, pinyin: FakePinyin(), send: { app.post(Bridge.encode($0)) })
        manager.attach(SaylaneInputController(client))
        let status = { BridgeIMEStatus(version: "test", pid: getpid(), attachedBundleID: manager.clientBundleID,
                                       attachedFresh: manager.hasClient, pinyinError: nil) }
        var seen: Int32 = 0
        let responder = BridgeResponder(core: core, status: status, applyPinyin: { _ in },
                                        mainProgramSeen: { pid in
                                            if seen == 0 { app.post(Bridge.encode(BridgeEvent.pinyinMode(english: true))) }
                                            seen = pid
                                        })
        let listener = BridgeListener(name: Bridge.imePortName) { data in
            // Plain text requests let the test read what the client saw,
            // press the talk key in it, now or ten seconds ago, and be the
            // user who changes a word of the dictation and presses Return.
            let command = String(decoding: data, as: UTF8.self)
            if command == "dump" { return Data(client.log.joined(separator: "|").utf8) }
            if command.hasPrefix("edit:") {
                let parts = command.dropFirst(5).split(separator: ">").map(String.init)
                client.text = client.text.replacingOccurrences(of: parts[0], with: parts[1])
                return Data("edited".utf8)
            }
            if command == "return" {
                let press = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                             isARepeat: false, keyCode: UInt16(kVK_Return))!
                return MainActor.assumeIsolated { Data((core.handle(press) ? "taken" : "passed").utf8) }
            }
            if command == "talk" || command == "talk-old" {
                let time = ProcessInfo.processInfo.systemUptime - (command == "talk" ? 0 : 10)
                let press = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command, timestamp: time,
                                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                             isARepeat: false, keyCode: UInt16(kVK_Command))!
                return MainActor.assumeIsolated { Data((core.handle(press) ? "taken" : "passed").utf8) }
            }
            return MainActor.assumeIsolated { responder.answer(data) }
        }
        guard listener != nil else { exit(3) }
        app.post(Bridge.encode(BridgeEvent.hello(status())))
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
        withExtendedLifetime(listener) { RunLoop.main.run() }
        exit(0)
    }

    @MainActor static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    @MainActor static func waitUntil(_ what: String, _ condition: () -> Bool) {
        for _ in 0..<100 where !condition() { spin(0.03) }
        precondition(condition(), what)
    }

    @MainActor static func main() {
        precondition(TestHome.isActive, "run with SAYLANE_TEST_HOME so the test ports are used")
        if CommandLine.arguments.dropFirst().first == "ime" { serveInputMethod() }

        // The main program starts first; the input method is not there yet.
        let ime = IMEBridgeClient()
        var events: [String] = []
        var readBacks: [BridgeReadBack] = []
        ime.onEvent = { event in
            switch event {
            case .readBack(let report): readBacks.append(report)
            case .hello: events.append("hello")
            case .pinyinMode(let english): events.append("pinyinMode:\(english)")
            case .attachment(let bundle): events.append("attachment:\(bundle ?? "nil")")
            case .talkKey(let bundle, _): events.append("talkKey:\(bundle ?? "nil")")
            default: events.append("other")
            }
        }
        ime.start()
        precondition(!ime.isConnected && !ime.canWrite(inFront: "test.editor"))
        let session = UUID()
        ime.update { $0.trigger = "leftCommand" }
        precondition(!ime.insert("nobody home", session: session, inFront: "test.editor"))

        // The input method starts and says hello; everything it must know is pushed to it.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["ime"]
        try! child.run()
        waitUntil("the input method said hello") { ime.isConnected }
        precondition(ime.status?.pid == child.processIdentifier && ime.attachedBundleID == "test.editor")
        waitUntil("an event from the input method arrived") { events.contains("pinyinMode:true") }
        precondition(events.first == "hello", "\(events)")

        // Which application has the keyboard. Being attached proves nothing by
        // itself, and neither does a press from ten seconds ago; the talk key
        // arriving through the client just now does, whatever is "in front".
        func press(_ command: String) {
            let before = events.count
            let answer = BridgeSender(name: Bridge.imePortName).request(Data(command.utf8), timeout: 1)
            precondition(answer.map { String(decoding: $0, as: UTF8.self) } == "passed", "the talk key is never swallowed")
            waitUntil("the talk key was reported") { events.dropFirst(before).contains("talkKey:test.editor") }
        }
        precondition(ime.keyboardOwner(front: "another.app") == "another.app")
        press("talk-old")
        precondition(ime.keyboardOwner(front: "another.app") == "another.app", "an old press proves nothing")
        press("talk")
        precondition(ime.keyboardOwner(front: "another.app") == "test.editor", "the client that delivered the talk key has the keyboard")
        precondition(ime.keyboardOwner(front: "test.editor") == "test.editor" && ime.keyboardOwner(front: nil) == nil)

        // A dictation into the application the input method is attached to.
        precondition(ime.canWrite(inFront: "test.editor") && !ime.canWrite(inFront: "another.app"))
        ime.update { $0.phase = .listening; $0.session = session; $0.sessionBundleID = "test.editor"; $0.learnsCorrections = true }
        precondition(ime.setMarked("你好", session: session, inFront: "test.editor"))
        precondition(ime.setMarked("你好世界", session: session, inFront: "test.editor"))
        ime.update { $0.phase = .finalizing }
        precondition(ime.insert("你好，世界。", session: session, inFront: "test.editor"), "the final text was not written")
        precondition(!ime.insert("twice", session: session, inFront: "test.editor"), "one dictation is written once")
        ime.end(session: session)
        ime.update { $0.phase = .idle; $0.session = nil; $0.sessionBundleID = nil }

        // The user changes a word of the dictation and presses Return: the
        // stretch as it reads now comes back, once, and no more after the main
        // program says it is done with that dictation.
        func user(_ command: String, _ expected: String) {
            let answer = BridgeSender(name: Bridge.imePortName).request(Data(command.utf8), timeout: 1)
            precondition(answer.map { String(decoding: $0, as: UTF8.self) } == expected, command)
        }
        // The input method first makes sure the client reads back what was written.
        spin(DictationReadBack.settleDelay + 0.3)
        user("return", "passed")
        spin(0.2)
        precondition(readBacks.isEmpty, "untouched text is not reported")
        user("edit:世界>视界", "edited")
        user("return", "passed")
        waitUntil("the edit was reported") { !readBacks.isEmpty }
        precondition(readBacks == [BridgeReadBack(session: session, text: "你好，视界。", startsDocument: true,
                                                  endsDocument: true, closed: false)], "\(readBacks)")
        ime.forget(session: session)
        spin(0.2)
        user("edit:视界>世界", "edited")
        user("return", "passed")
        spin(0.3)
        precondition(readBacks.count == 1, "a forgotten dictation is not read again")

        // A dictation that belongs to another application is refused, without a trace in the client.
        let other = UUID()
        ime.update { $0.phase = .finalizing; $0.session = other; $0.sessionBundleID = "another.app" }
        precondition(!ime.insert("wrong place", session: other, inFront: "another.app"))
        ime.update { $0.phase = .idle; $0.session = nil; $0.sessionBundleID = nil }

        let dump = BridgeSender(name: Bridge.imePortName).request(Data("dump".utf8), timeout: 1)
            .map { String(decoding: $0, as: UTF8.self) }
        precondition(dump == "marked:你好|marked:你好世界|insert:你好，世界。", "the client saw: \(dump ?? "nil")")

        // The input method goes away: the main program notices and stops using it.
        child.terminate(); child.waitUntilExit()
        waitUntil("the input method's exit was noticed") { !ime.isConnected }
        precondition(!ime.canWrite(inFront: "test.editor") && ime.attachedBundleID == nil)
        precondition(ime.keyboardOwner(front: "another.app") == "another.app")
        precondition(!ime.insert("gone", session: UUID(), inFront: "test.editor"))
        print("PASS: bridge end to end: late start, pushed context, who has the keyboard, preview and final text, an edit read back and forgotten, wrong application, a second write, the peer exiting")
    }
}
