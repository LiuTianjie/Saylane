import AppKit
import InputMethodKit
import Carbon.HIToolbox

final class SaylaneInputController: InputClientController {
    var sessionID: UUID? = UUID()
    var textInputClient: (any IMKTextInput)?
    init(_ client: any IMKTextInput) { textInputClient = client }
}

/// A text client that holds a document, as a text field does: writes land at
/// the selection, reads come from the text. How it answers a read can be
/// changed, because real clients differ.
final class Document: NSObject, IMKTextInput {
    enum Answers { case faithfully, nothing, onlyInside, tooMuch, otherText, wrongType }
    let text = NSMutableString()
    var selection = NSRange(location: 0, length: 0)
    var marked = NSRange(location: NSNotFound, length: 0)
    var answers = Answers.faithfully
    /// Questions asked of the client: reads of text, and of ranges.
    var reads = 0
    var rangeQuestions = 0

    func type(_ string: String) { insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    /// The user's own edit: one stretch replaced by another, the caret after it.
    func edit(_ old: String, _ new: String) {
        let range = text.range(of: old)
        precondition(range.location != NSNotFound, "\(old) is not in \(text)")
        text.replaceCharacters(in: range, with: new)
        selection = NSRange(location: range.location + (new as NSString).length, length: 0)
    }
    func clear() { text.setString(""); selection = NSRange(location: 0, length: 0) }

    func insertText(_ string: Any!, replacementRange: NSRange) {
        let string = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let target = marked.location != NSNotFound ? marked : selection
        text.replaceCharacters(in: target, with: string)
        selection = NSRange(location: target.location + (string as NSString).length, length: 0)
        marked = NSRange(location: NSNotFound, length: 0)
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        let string = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let target = marked.location != NSNotFound ? marked : selection
        text.replaceCharacters(in: target, with: string)
        let length = (string as NSString).length
        marked = length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: target.location, length: length)
        selection = NSRange(location: target.location + length, length: 0)
    }
    func selectedRange() -> NSRange { rangeQuestions += 1; return selection }
    func markedRange() -> NSRange { rangeQuestions += 1; return marked }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        reads += 1
        let inside = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        switch answers {
        case .nothing: return nil
        case .otherText: return NSAttributedString(string: String(repeating: "x", count: range.length))
        case .tooMuch: return NSAttributedString(string: text as String + String(repeating: "x", count: range.length + 1))
        case .wrongType: return unsafeBitCast(text.substring(with: inside) as NSString, to: NSAttributedString.self)
        case .onlyInside: if inside.length != range.length { return nil }
        case .faithfully: break
        }
        guard range.location <= text.length else { return nil }
        return NSAttributedString(string: text.substring(with: inside))
    }
    func length() -> Int { text.length }
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

/// Composes nothing unless told to; every key is left to the client.
@MainActor final class FakePinyin: PinyinHandling {
    var isComposing = false
    func ensureClient(_ key: UUID?) {}
    func handle(_ event: NSEvent, pushToTalk: PushToTalkHotkey) -> Bool { false }
    func commit() { isComposing = false }
}

@MainActor final class Rig {
    let manager = IMEManager(inputSourceSelected: { true })
    let document = Document()
    let pinyin = FakePinyin()
    let controller: SaylaneInputController
    private(set) var core: InputMethodCore!
    var reports: [BridgeReadBack] = []
    var traces: [String] = []
    var clock: TimeInterval = 100
    private var revision: UInt64 = 0

    init(learns: Bool = true) {
        controller = SaylaneInputController(document)
        core = InputMethodCore(manager: manager, pinyin: pinyin, send: { [unowned self] event in
            if case .readBack(let report) = event { self.reports.append(report) }
        }, now: { [unowned self] in self.clock },
        // The timers are fired by hand: `settled()` and `typingPaused()` are what they call.
        readBackSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        core.trace = { [unowned self] stage, detail in if stage == "read-back" { self.traces.append(detail) } }
        manager.attach(controller)
        push(.idle, learns: learns)
    }

    func push(_ phase: VoicePhase, session: UUID? = nil, learns: Bool = true) {
        revision += 1
        var context = BridgeContext()
        context.revision = revision; context.appPID = 42; context.phase = phase; context.session = session
        context.sessionBundleID = phase == .idle ? nil : "test.editor"
        context.learnsCorrections = learns
        core.apply(context)
    }

    /// A whole dictation as the main program drives it: listening, a preview, the final text, idle.
    @discardableResult
    func dictate(_ text: String, preview: Bool = true, learns: Bool = true) -> UUID {
        let session = UUID()
        push(.listening, session: session, learns: learns)
        if preview { _ = core.voiceMarked(session: session, seq: 1, text: String(text.prefix(2))) }
        push(.finalizing, session: session, learns: learns)
        precondition(core.voiceInsert(session: session, text: text, deadline: clock + 10), "the dictation was not written")
        core.voiceEnd(session: session)
        push(.idle, learns: learns)
        return session
    }

    func key(_ characters: String, _ code: Int) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: clock, windowNumber: 0,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: UInt16(code))!
        precondition(!core.handle(event), "the key must reach the application")
    }
    func pressReturn() { key("\r", kVK_Return) }
}

@main struct DictationReadBackTests {
    @MainActor static func main() {
        var passed = 0
        do { // The user has not allowed learning: the client is asked nothing, ever.
            let rig = Rig(learns: false)
            rig.dictate("我明天和黄根诚开会。", learns: false)
            rig.core.readBack.settled()
            rig.document.edit("黄根诚", "黄根成")
            rig.pressReturn()
            rig.core.readBack.typingPaused()
            precondition(rig.document.text == "我明天和黄根成开会。")
            precondition(rig.document.reads == 0 && rig.document.rangeQuestions == 0 && rig.reports.isEmpty)
            precondition(!rig.core.readBack.isWatching)
            passed += 1
        }
        do { // A dictation, an edit, Return: one report, with the stretch as it reads now.
            let rig = Rig()
            rig.document.type("前文，")
            let session = rig.dictate("我明天和黄根诚开会。")
            precondition(rig.document.text == "前文，我明天和黄根诚开会。")
            precondition(rig.document.rangeQuestions == 1 && rig.document.reads == 0, "one question before the write, none after")
            rig.core.readBack.settled()
            precondition(rig.document.reads == 1 && rig.traces == ["watching"])
            // Untouched text is read and nothing is said about it.
            rig.pressReturn()
            precondition(rig.document.reads == 2 && rig.reports.isEmpty)
            rig.document.edit("黄根诚", "黄根成")
            rig.pressReturn()
            precondition(rig.reports == [BridgeReadBack(session: session, text: "我明天和黄根成开会。", startsDocument: false,
                                                        endsDocument: true, closed: false)], "\(rig.reports)")
            // The same text again is not reported twice.
            rig.pressReturn()
            precondition(rig.reports.count == 1)
            // Typing after it does not change the stretch, only what follows it.
            rig.document.selection = NSRange(location: rig.document.text.length, length: 0)
            rig.document.type("然后去吃饭")
            rig.pressReturn()
            precondition(rig.reports.count == 2 && rig.reports[1].text == "我明天和黄根成开会。然后去吃饭")
            passed += 1
        }
        do { // Only so much is read: the stretch and a little after it, never what is before.
            let rig = Rig()
            rig.document.type(String(repeating: "前", count: 50))
            rig.dictate("黄根诚来了")
            rig.document.type(String(repeating: "后", count: 80))
            rig.core.readBack.settled()
            rig.document.edit("黄根诚", "黄根成")
            rig.pressReturn()
            let text = rig.reports.last?.text ?? ""
            precondition(text == "黄根成来了" + String(repeating: "后", count: DictationReadBack.slack), "\(text)")
            precondition(rig.reports.last?.endsDocument == false && rig.reports.last?.startsDocument == false)
            passed += 1
        }
        do { // A pause in typing is a moment to look; a composition in progress is not.
            let rig = Rig()
            let session = rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            rig.document.edit("章三", "张三")
            rig.key("x", kVK_ANSI_X)
            precondition(rig.reports.isEmpty, "an ordinary key reads nothing")
            rig.pinyin.isComposing = true
            rig.core.readBack.typingPaused()
            rig.pressReturn()
            precondition(rig.reports.isEmpty && rig.document.reads == 1, "nothing is read while pinyin is composing")
            rig.pinyin.isComposing = false
            rig.core.readBack.typingPaused()
            precondition(rig.reports == [BridgeReadBack(session: session, text: "帮我找一下张三", startsDocument: true,
                                                        endsDocument: true, closed: false)], "\(rig.reports)")
            passed += 1
        }
        do { // The next dictation in the same field: the earlier one is looked at first and stays watched.
            let rig = Rig()
            let first = rig.dictate("我明天和黄根诚开会。")
            rig.core.readBack.settled()
            rig.document.edit("黄根诚", "黄根成")
            rig.document.selection = NSRange(location: rig.document.text.length, length: 0)
            let second = rig.dictate("章三也来。")
            precondition(rig.reports.map(\.session) == [first] && rig.reports[0].text == "我明天和黄根成开会。")
            rig.core.readBack.settled()
            // The user goes back and fixes both.
            rig.document.edit("黄根成", "黄根城")
            rig.document.edit("章三", "张三")
            rig.pressReturn()
            precondition(rig.reports.count == 3 && rig.reports[1].session == first && rig.reports[2].session == second)
            precondition(rig.reports[1].text == "我明天和黄根城开会。张三也来。" && rig.reports[2].text == "张三也来。", "\(rig.reports)")
            passed += 1
        }
        do { // A dictation written into or before a watched stretch ends the watching of that one.
            let rig = Rig()
            let first = rig.dictate("我明天和黄根诚开会。")
            rig.core.readBack.settled()
            rig.document.edit("黄根诚", "黄根成")
            rig.pressReturn()
            // The message was sent with the mouse; the next dictation starts at the same place.
            rig.document.clear()
            let second = rig.dictate("好的。")
            // What stands there now is not passed on; the main program only hears that the watching is over.
            precondition(rig.reports.map(\.session) == [first, first] && rig.reports[1] ==
                         BridgeReadBack(session: first, text: nil, closed: true), "\(rig.reports)")
            rig.core.readBack.settled()
            rig.document.edit("好的", "好滴")
            rig.pressReturn()
            precondition(rig.reports.count == 3 && rig.reports[2].session == second && rig.reports[2].text == "好滴。")
            passed += 1
        }
        do { // Another text at the same place (another field of the same client, a new message): not the dictation's, not reported.
            let rig = Rig()
            rig.dictate("我明天和黄根诚开会。")
            rig.core.readBack.settled()
            rig.document.clear()
            rig.document.type("今晚一起吃饭吗？我请客。")
            rig.pressReturn()
            precondition(rig.reports.isEmpty && !rig.core.readBack.isWatching && rig.traces.last == "the text is gone", "\(rig.traces)")
            passed += 1
        }
        do { // The client loses focus in an orderly way: a last look, and the report says it is the last.
            let rig = Rig()
            let session = rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            rig.document.edit("章三", "张三")
            precondition(rig.manager.detach(rig.controller, leaseID: rig.controller.sessionID!))
            precondition(rig.reports == [BridgeReadBack(session: session, text: "帮我找一下张三", startsDocument: true,
                                                        endsDocument: true, closed: true)], "\(rig.reports)")
            precondition(!rig.core.readBack.isWatching)
            // An untouched dictation leaves without a word.
            let quiet = Rig()
            quiet.dictate("你好")
            quiet.core.readBack.settled()
            precondition(quiet.manager.detach(quiet.controller, leaseID: quiet.controller.sessionID!))
            precondition(quiet.reports.isEmpty && !quiet.core.readBack.isWatching)
            passed += 1
        }
        do { // The client is replaced without a goodbye: nothing is asked of it any more.
            let rig = Rig()
            let session = rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            rig.document.edit("章三", "张三")
            rig.pressReturn()
            let reads = rig.document.reads
            rig.document.edit("张三", "张珊")
            rig.manager.attach(SaylaneInputController(Document()))
            precondition(rig.document.reads == reads && !rig.core.readBack.isWatching)
            precondition(rig.reports.last == BridgeReadBack(session: session, text: nil, closed: true))
            passed += 1
        }
        // Clients that cannot report their text, or report it wrongly: nothing is learned, nothing is disturbed.
        for answers in [Document.Answers.nothing, .otherText, .tooMuch] {
            let rig = Rig()
            rig.document.answers = answers
            rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            precondition(!rig.core.readBack.isWatching && rig.traces.count == 1 && rig.traces[0].hasPrefix("the client"), "\(answers)")
            rig.document.edit("章三", "张三")
            rig.pressReturn()
            rig.core.readBack.typingPaused()
            precondition(rig.reports.isEmpty && rig.document.reads == 1, "\(answers)")
            precondition(rig.document.text == "帮我找一下张三")
            passed += 1
        }
        do { // A client that hands back a plain string where an attributed one was promised is still read, not trusted blindly.
            let rig = Rig()
            rig.document.answers = .wrongType
            let session = rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            rig.document.edit("章三", "张三")
            rig.pressReturn()
            precondition(rig.reports.map(\.session) == [session] && rig.reports[0].text == "帮我找一下张三")
            passed += 1
        }
        do { // A client that answers only for a range wholly inside its text: read without the margin.
            let rig = Rig()
            rig.document.answers = .onlyInside
            let session = rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            rig.document.edit("章三", "张三")
            rig.pressReturn()
            precondition(rig.reports == [BridgeReadBack(session: session, text: "帮我找一下张三", startsDocument: true,
                                                        endsDocument: false, closed: false)], "\(rig.reports)")
            // The text got shorter than the dictation was: this client says nothing, and the watching ends.
            rig.document.edit("帮我找一下", "找")
            rig.pressReturn()
            precondition(rig.reports.last == BridgeReadBack(session: session, text: nil, closed: true))
            precondition(!rig.core.readBack.isWatching)
            passed += 1
        }
        do { // A dictation is not watched for ever, and not more than three at once.
            let rig = Rig()
            rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            rig.clock += DictationReadBack.lifetime + 1
            rig.document.edit("章三", "张三")
            rig.pressReturn()
            precondition(rig.reports.isEmpty && !rig.core.readBack.isWatching && rig.document.reads == 1)

            let many = Rig()
            var sessions: [UUID] = []
            for index in 0..<5 {
                many.document.selection = NSRange(location: many.document.text.length, length: 0)
                sessions.append(many.dictate("第\(index)句话章三。"))
                many.core.readBack.settled()
            }
            many.document.text.replaceOccurrences(of: "章三", with: "张三", range: NSRange(location: 0, length: many.document.text.length))
            many.pressReturn()
            precondition(many.reports.map(\.session) == Array(sessions.suffix(DictationReadBack.limit)), "\(many.reports.count)")
            passed += 1
        }
        do { // A very long dictation is not read back.
            let rig = Rig()
            rig.dictate(String(repeating: "很长的一段话", count: 101))
            rig.core.readBack.settled()
            precondition(!rig.core.readBack.isWatching && rig.document.reads == 0)
            passed += 1
        }
        do { // The main program says it is done with a dictation, switches learning off, or dies.
            let rig = Rig()
            let session = rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            rig.core.voiceForget(session: session)
            precondition(!rig.core.readBack.isWatching)
            rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            rig.push(.idle, learns: false)
            precondition(!rig.core.readBack.isWatching)
            rig.push(.idle, learns: true)
            rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            precondition(rig.core.readBack.isWatching)
            rig.core.appExited()
            precondition(!rig.core.readBack.isWatching)
            let reads = rig.document.reads
            rig.document.text.replaceOccurrences(of: "章三", with: "张三", range: NSRange(location: 0, length: rig.document.text.length))
            rig.pressReturn()
            precondition(rig.reports.isEmpty && rig.document.reads == reads)
            passed += 1
        }
        do { // While a dictation is running, keys read nothing: a preview stands in the text.
            let rig = Rig()
            rig.dictate("帮我找一下章三")
            rig.core.readBack.settled()
            rig.document.edit("章三", "张三")
            let reads = rig.document.reads
            let next = UUID()
            rig.push(.listening, session: next)
            precondition(rig.document.reads == reads + 1 && rig.reports.count == 1, "one look when the next dictation starts")
            _ = rig.core.voiceMarked(session: next, seq: 1, text: "预览")
            rig.pressReturn()
            rig.core.readBack.typingPaused()
            precondition(rig.document.reads == reads + 1)
            passed += 1
        }
        do { // Without a preview the text is written at the selection, which it replaces.
            let rig = Rig()
            rig.document.type("开头旧的结尾")
            rig.document.selection = NSRange(location: 2, length: 2)
            let session = rig.dictate("章三", preview: false)
            precondition(rig.document.text == "开头章三结尾")
            rig.core.readBack.settled()
            rig.document.edit("章三", "张三")
            rig.pressReturn()
            precondition(rig.reports == [BridgeReadBack(session: session, text: "张三结尾", startsDocument: false,
                                                        endsDocument: true, closed: false)], "\(rig.reports)")
            passed += 1
        }
        print("PASS: \(passed) read-back scenarios: off by default, report on change only, bounded window, pauses and compositions, several dictations, sent messages, focus loss, clients that cannot or will not report, limits, the main program's say")
    }
}
