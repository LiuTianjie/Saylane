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
    var bundle = "test.editor"
    func insertText(_ string: Any!, replacementRange: NSRange) { inserted.append(string as? String ?? "") }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        marked.append((string as? NSAttributedString)?.string ?? (string as? String ?? ""))
    }
    var asked = 0
    var onAsk: (() -> Void)?
    func selectedRange() -> NSRange { asked += 1; onAsk?(); return NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { asked += 1; onAsk?(); return NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
    func length() -> Int { 0 }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { bundle }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "test-client" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { "" }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
}

/// Letters compose; everything else is left to the client.
@MainActor final class FakePinyin: PinyinHandling {
    var isComposing = false
    var handled: [String] = []
    var commits = 0
    var ensured: [UUID?] = []
    func ensureClient(_ key: UUID?) { ensured.append(key) }
    func handle(_ event: NSEvent, pushToTalk: PushToTalkHotkey) -> Bool {
        guard event.type == .keyDown, let text = event.characters, text.count == 1,
              text.first!.isLetter, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        handled.append(text)
        return true
    }
    func commit() { commits += 1; isComposing = false }
}

@MainActor final class Fence {
    var continuation: CheckedContinuation<Void, Error>?
    func sleep(_ interval: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func expire() async {
        continuation?.resume()
        continuation = nil
        for _ in 0..<5 { await Task.yield() }
    }
}

@main struct InputMethodCoreTests {
    @MainActor static func key(_ characters: String, _ code: Int, flags: NSEvent.ModifierFlags = [], at time: TimeInterval = 1) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(code))!
    }
    @MainActor static func modifier(_ code: Int, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
    }

    @MainActor static func main() async {
        var passed = 0
        func make() -> (InputMethodCore, IMEManager, Client, FakePinyin, Fence, () -> [String], (TimeInterval) -> Void) {
            let manager = IMEManager(inputSourceSelected: { true })
            let client = Client()
            let pinyin = FakePinyin()
            let fence = Fence()
            final class Box { var events: [String] = []; var clock: TimeInterval = 100 }
            let box = Box()
            let core = InputMethodCore(manager: manager, pinyin: pinyin, send: { event in
                switch event {
                case .key(let meta): box.events.append("key:\(meta.kind.rawValue):\(meta.keyCode)")
                case .talkKey(let bundleID, let at): box.events.append("talkKey:\(bundleID ?? "none")@\(Int(at))")
                case .userTyped: box.events.append("userTyped")
                case .typingResumed: box.events.append("typingResumed")
                default: box.events.append("other")
                }
            }, now: { box.clock }, fence: InputDeferralDeadline(sleep: { try await fence.sleep($0) }))
            manager.attach(SaylaneInputController(client))
            return (core, manager, client, pinyin, fence, { box.events }, { box.clock = $0 })
        }
        func context(_ revision: UInt64, _ phase: VoicePhase, session: UUID? = nil, ownsKeys: Bool = false) -> BridgeContext {
            var c = BridgeContext()
            c.revision = revision; c.appPID = 42; c.phase = phase; c.session = session
            c.sessionBundleID = "test.editor"; c.appOwnsKeys = ownsKeys; c.trigger = "leftCommand"
            c.screenShortcutKeyCode = UInt16(kVK_ANSI_T); c.screenShortcutFlags = UInt64(NSEvent.ModifierFlags.option.rawValue)
            return c
        }
        let a = kVK_ANSI_A, b = kVK_ANSI_B

        do { // Idle: typing belongs to pinyin and stays in this process.
            let (core, _, _, pinyin, _, events, _) = make()
            core.apply(context(1, .idle))
            precondition(core.handle(key("a", a)))
            precondition(pinyin.handled == ["a"] && events().isEmpty, "plain typing must not be forwarded")
            precondition(!core.handle(modifier(kVK_Command, flags: .command)))
            precondition(!core.handle(key("w", kVK_ANSI_W, flags: .command)))
            precondition(events() == ["talkKey:test.editor@1", "key:flagsChanged:55", "key:keyDown:13"], "\(events())")
            // Electron delivers every modifier change twice: the copy is not reported again.
            precondition(!core.handle(modifier(kVK_Command, flags: .command)))
            precondition(events().count == 3, "\(events())")
            // The screen shortcut is swallowed here and acted on by the main program.
            precondition(core.handle(key("†", kVK_ANSI_T, flags: .option)))
            precondition(events().last == "key:keyDown:17")
            // Esc is ordinary while nothing is going on.
            precondition(!core.handle(key("\u{1b}", kVK_Escape)))
            passed += 1
        }
        do { // The main program listens to keys itself: nothing is forwarded, nothing is swallowed for it.
            let (core, _, _, _, _, events, _) = make()
            core.apply(context(1, .idle, ownsKeys: true))
            precondition(!core.handle(modifier(kVK_Command, flags: .command)), "the talk key is never swallowed")
            precondition(!core.handle(key("†", kVK_ANSI_T, flags: .option)))
            // Only where the talk key went down is reported: it tells the main
            // program which client has the keyboard. Its release, other
            // modifiers and every other key stay here.
            precondition(!core.handle(modifier(kVK_Command, flags: [])))
            precondition(!core.handle(modifier(kVK_Option, flags: .option)))
            precondition(events() == ["talkKey:test.editor@1"], "\(events())")
            passed += 1
        }
        do { // Listening: a composition is committed first, keys pass through, Esc is swallowed.
            let (core, _, client, pinyin, _, events, _) = make()
            core.apply(context(1, .idle))
            pinyin.isComposing = true
            let session = UUID()
            core.apply(context(2, .listening, session: session))
            precondition(pinyin.commits == 1)
            precondition(!core.handle(key("a", a)) && pinyin.handled.isEmpty)
            precondition(events() == ["key:keyDown:0"], "a key during listening is reported: \(events())")
            precondition(core.handle(key("\u{1b}", kVK_Escape)))
            // Preview: only for this session, in order, and only in a client of that application.
            precondition(core.voiceMarked(session: session, seq: 1, text: "你好"))
            precondition(core.voiceMarked(session: session, seq: 3, text: "你好世界"))
            precondition(!core.voiceMarked(session: session, seq: 2, text: "stale"))
            precondition(!core.voiceMarked(session: UUID(), seq: 9, text: "other session"))
            precondition(client.marked == ["你好", "你好世界"], "\(client.marked)")
            passed += 1
        }
        do { // A preview never appears in another application's client.
            let (core, _, client, _, _, _, _) = make()
            let session = UUID()
            var c = context(1, .listening, session: session)
            c.sessionBundleID = "another.app"
            core.apply(c)
            precondition(!core.voiceMarked(session: session, seq: 1, text: "x") && client.marked.isEmpty)
            precondition(!core.voiceInsert(session: session, text: "x", deadline: 1_000) && client.inserted.isEmpty)
            passed += 1
        }
        do { // Keys typed while the final text is pending wait behind it, in order.
            let (core, _, client, pinyin, _, events, _) = make()
            let session = UUID()
            core.apply(context(1, .listening, session: session))
            _ = core.voiceMarked(session: session, seq: 1, text: "preview")
            core.apply(context(2, .finalizing, session: session))
            precondition(core.handle(key("a", a)) && core.handle(key("9", kVK_ANSI_9)))
            precondition(pinyin.handled.isEmpty && client.inserted.isEmpty)
            precondition(events().filter { $0 == "userTyped" }.count == 1)
            precondition(core.voiceInsert(session: session, text: "final text", deadline: 1_000))
            precondition(client.inserted == ["final text", "9"] && pinyin.handled == ["a"],
                         "\(client.inserted) \(pinyin.handled)")
            // The session is closed: a late preview is ignored.
            precondition(!core.voiceMarked(session: session, seq: 2, text: "late"))
            core.apply(context(3, .idle))
            precondition(core.handle(key("b", b)) && pinyin.handled == ["a", "b"])
            passed += 1
        }
        do { // A command cannot wait: typing goes ahead, the preview goes, the dictation still lands.
            let (core, _, client, pinyin, _, events, _) = make()
            let session = UUID()
            core.apply(context(1, .listening, session: session))
            _ = core.voiceMarked(session: session, seq: 1, text: "preview")
            core.apply(context(2, .finalizing, session: session))
            precondition(core.handle(key("a", a)))
            precondition(!core.handle(key("\r", kVK_Return)))
            precondition(pinyin.handled == ["a"], "the queued key is written before the command")
            precondition(client.marked.last == "" && events().contains("typingResumed"))
            // From now on keys are not held back.
            precondition(core.handle(key("b", b)) && pinyin.handled == ["a", "b"])
            precondition(!core.voiceMarked(session: session, seq: 2, text: "no preview after typing resumed"))
            precondition(core.voiceInsert(session: session, text: "final", deadline: 1_000))
            precondition(client.inserted == ["final"])
            passed += 1
        }
        do { // The wait is bounded: when nothing arrives, typing goes ahead.
            let (core, _, client, pinyin, fence, events, _) = make()
            let session = UUID()
            core.apply(context(1, .finalizing, session: session))
            precondition(core.handle(key("a", a)))
            for _ in 0..<5 { await Task.yield() }
            await fence.expire()
            precondition(pinyin.handled == ["a"] && events().contains("typingResumed"), "\(pinyin.handled) \(events())")
            precondition(core.voiceInsert(session: session, text: "late final", deadline: 1_000))
            precondition(client.inserted == ["late final"])
            passed += 1
        }
        do { // A request that waited too long in a queue must not write.
            let (core, _, client, _, _, _, setClock) = make()
            let session = UUID()
            core.apply(context(1, .finalizing, session: session))
            setClock(200)
            precondition(!core.voiceInsert(session: session, text: "too late", deadline: 150))
            precondition(client.inserted.isEmpty)
            precondition(core.voiceInsert(session: session, text: "in time", deadline: 250))
            precondition(!core.voiceInsert(session: session, text: "twice", deadline: 250), "one dictation is written once")
            precondition(client.inserted == ["in time"])
            passed += 1
        }
        do { // Learning asks the client where the text will stand. A client that is slow to say must not get the text twice.
            let (core, _, client, _, _, _, setClock) = make()
            let session = UUID()
            var finalizing = context(1, .finalizing, session: session); finalizing.learnsCorrections = true
            core.apply(finalizing)
            client.onAsk = { setClock(300) }
            precondition(!core.voiceInsert(session: session, text: "slow", deadline: 250) && client.inserted.isEmpty,
                         "the main program stopped waiting and wrote the text itself")
            precondition(client.asked > 0)
            passed += 1
        }
        do { // The main program's own window: it waits for the answer, so it is asked nothing before the text is written.
            let (core, manager, client, _, _, _, _) = make()
            let session = UUID()
            client.bundle = Bridge.appBundleID
            manager.attach(SaylaneInputController(client))
            var finalizing = context(1, .finalizing, session: session); finalizing.learnsCorrections = true
            finalizing.sessionBundleID = Bridge.appBundleID
            core.apply(finalizing)
            precondition(core.voiceInsert(session: session, text: "own", deadline: 1_000) && client.inserted == ["own"])
            precondition(client.asked == 0, "asked \(client.asked) times")
            passed += 1
        }
        do { // Hands-free: the key that ends the utterance is what the user types next, so it lands after the text.
            let (core, _, client, pinyin, _, events, _) = make()
            let session = UUID()
            var listening = context(1, .listening, session: session); listening.keysEndDictation = true
            core.apply(listening)
            precondition(core.handle(key("a", a)) && pinyin.handled.isEmpty, "the key waits")
            precondition(events().contains("key:keyDown:0"), "and is still reported, so the utterance ends")
            precondition(!core.handle(key("\r", kVK_Return)), "a command cannot wait and passes through")
            var finalizing = context(2, .finalizing, session: session); finalizing.keysEndDictation = true
            core.apply(finalizing)
            precondition(core.voiceInsert(session: session, text: "said", deadline: 1_000))
            precondition(client.inserted == ["said"] && pinyin.handled == ["a"], "\(client.inserted) \(pinyin.handled)")
            passed += 1
        }
        do { // The main program dies mid-dictation: typing is released at once.
            let (core, _, client, pinyin, _, _, _) = make()
            let session = UUID()
            core.apply(context(1, .listening, session: session))
            _ = core.voiceMarked(session: session, seq: 1, text: "preview")
            core.apply(context(2, .finalizing, session: session))
            precondition(core.handle(key("a", a)))
            core.appExited()
            precondition(pinyin.handled == ["a"] && client.marked.last == "")
            precondition(core.context.phase == .idle && core.trigger == .leftCommand)
            precondition(core.handle(key("b", b)))
            // The next main program starts its revisions from one again.
            var fresh = context(1, .idle); fresh.appPID = 77
            core.apply(fresh)
            precondition(core.context.appPID == 77)
            passed += 1
        }
        do { // A main program that hangs cannot hold the keyboard for ever.
            let (core, _, _, pinyin, _, _, setClock) = make()
            core.apply(context(1, .listening, session: UUID()))
            precondition(!core.handle(key("a", a)))
            setClock(100 + InputMethodCore.listeningLimit + 1)
            precondition(core.handle(key("a", a)) && pinyin.handled == ["a"])
            precondition(core.context.phase == .idle)
            passed += 1
        }
        do { // An older push never replaces a newer one.
            let (core, _, _, _, _, _, _) = make()
            core.apply(context(5, .listening, session: UUID()))
            core.apply(context(4, .idle))
            precondition(core.context.phase == .listening)
            core.apply(context(6, .idle))
            precondition(core.context.phase == .idle)
            passed += 1
        }
        do { // Esc cancels a screen selection too; with a modifier it is somebody's shortcut.
            let (core, _, _, _, _, _, _) = make()
            var c = context(1, .idle); c.screenSelecting = true
            core.apply(c)
            precondition(core.handle(key("\u{1b}", kVK_Escape)))
            precondition(!core.handle(key("\u{1b}", kVK_Escape, flags: .command)))
            passed += 1
        }
        print("PASS: \(passed) input-method core scenarios: forwarding, local decisions, previews, queued keys, deadlines, a dying or hanging main program")
    }
}
