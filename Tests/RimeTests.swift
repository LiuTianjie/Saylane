import AppKit
import Carbon.HIToolbox

@main struct RimeTests {
    static func main() throws {
        if CommandLine.arguments.count == 4 {
            try persistence(phase: CommandLine.arguments[2], user: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("saylane-rime-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: user) }
        let runtime = try RimeRuntime(sharedData: URL(fileURLWithPath: CommandLine.arguments[1]), userData: user)
        defer { SLRimeFinalize() }
        print("Native engine: librime \(runtime.version)")
        let session = try RimePinyinSession(runtime: runtime)
        func type(_ text: String) {
            for ch in text { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        }
        func firstWord(_ enabled: Bool, _ input: String) -> String {
            precondition(session.setFuzzyEnabled(enabled))
            session.cancel()
            type(input)
            let word = session.candidates.first?.word ?? ""
            session.cancel()
            return word
        }
        // One rule: fuzzy never steals the exact-spelling winner.
        // Same penalty for every pair; these inputs only sample the rule.
        for input in ["si", "shi", "ci", "chi", "zi", "zhi", "su", "shu", "se", "she",
                      "zan", "zhan", "cen", "ceng", "bin", "bing", "side", "shide"] {
            let exact = firstWord(false, input)
            let fuzzy = firstWord(true, input)
            precondition(!exact.isEmpty && exact == fuzzy, "fuzzy changed exact winner for \(input): \(exact) -> \(fuzzy)")
        }
        precondition(session.setFuzzyEnabled(true))
        type("zongguo")
        precondition(session.candidates.prefix(9).contains(where: { $0.word == "中国" }))
        session.cancel()
        type("zhongguo")
        precondition(session.candidates.first?.word == "中国")
        session.cancel()
        precondition(session.setFuzzyEnabled(true))
        for input in ["hello", "github", "python", "world"] {
            session.cancel()
            type(input)
            let words = session.candidates.prefix(9).map(\.word)
            precondition(words.contains(where: { $0.lowercased() == input }), "missing English candidate for \(input): \(words)")
            precondition(session.candidates.first?.word.lowercased() == input, "English should be first for \(input), got \(words)")
        }
        for input in ["app", "ok", "ios"] {
            session.cancel()
            type(input)
            let words = session.candidates.prefix(9).map(\.word)
            precondition(words.contains(where: { $0.lowercased() == input }), "missing English candidate for \(input): \(words)")
            if let first = session.candidates.first, first.word.contains(where: { !$0.isASCII }) {
                continue
            }
            precondition(session.candidates.first?.word.lowercased() == input, "English-only input should keep \(input) first, got \(words)")
        }
        for input in ["be", "nih", "nh"] {
            session.cancel()
            type(input)
            let first = session.candidates.first?.word ?? ""
            precondition(first.contains(where: { !$0.isASCII }), "pinyin \(input) must stay Chinese-first, got \(first)")
        }
        session.cancel()
        type("youshih")
        let youshih = session.candidates.prefix(9).map(\.word)
        precondition(youshih.contains("有时候"), "youshih should recall 有时候: \(youshih)")
        precondition(session.candidates.first?.word != "youshih", "raw latin must not beat 有时候: \(youshih)")
        precondition(session.candidates.first?.word.contains(where: { !$0.isASCII }) == true, "you'shi'h must stay Chinese-first, got \(youshih)")
        session.cancel()
        type("woxiangqxbeijing")
        let mistype = session.candidates.prefix(9).map(\.word)
        precondition(session.candidates.first?.word != "woxiangqxbeijing", "mid-string typo must not echo raw latin first: \(mistype)")
        if mistype.contains(where: { $0.contains(where: { !$0.isASCII }) }) {
            precondition(session.candidates.first?.word.contains(where: { !$0.isASCII }) == true,
                         "Chinese correction should lead a mistyped pinyin string: \(mistype)")
        }
        session.cancel()
        type("lue")
        let lue = session.candidates.prefix(9).map(\.word)
        precondition(lue.contains("略"), "lue should recall 略, not split into lu'e: \(lue)")
        precondition(session.candidates.first?.word == "略", "lue must keep 略 first, got \(lue)")
        session.cancel()
        type("nue")
        let nue = session.candidates.prefix(9).map(\.word)
        precondition(nue.contains("虐"), "nue should recall 虐: \(nue)")
        session.cancel()
        type("xign")
        let xign = session.candidates.prefix(9).map(\.word)
        precondition(xign.contains(where: { ["行", "星", "兴", "型", "形"].contains($0) }), "ign→ing should recall 行/星 for xign: \(xign)")
        session.cancel()
        type("haha")
        let haha = session.candidates.prefix(9)
        precondition(haha.contains(where: { $0.word.contains("哈") }), "haha should still yield 哈: \(haha.map(\.word))")
        precondition(haha.contains(where: { !$0.comment.isEmpty || $0.word.unicodeScalars.contains { $0.value >= 0x1F300 } }),
                     "emoji OpenCC should annotate 哈: \(haha.map { "\($0.word)/\($0.comment)" })")
        session.cancel()
        // Pictures never take the first places: the engine offers 可以 🙆‍♂️ 🙆‍♀️ 🉑 刻意 可疑.
        type("keyi")
        let keyi = Array(session.candidates.prefix(9))
        precondition(keyi.first?.word == "可以" && !keyi.prefix(4).contains(where: \.isEmoji),
                     "words first: \(keyi.map(\.word))")
        precondition(keyi.filter(\.isEmoji).count == 1 && keyi.last?.isEmoji == true,
                     "one picture per word, behind the words on the first page: \(keyi.map(\.word))")
        precondition(keyi.contains { $0.word == "刻意" } && keyi.contains { $0.word == "可疑" })
        for (text, expected) in [("你好", false), ("GitHub", false), ("👋", true), ("🙆‍♂️", true), ("🇨🇳", true), ("🔟", true),
                                 ("1️⃣", true), ("12", false), ("©", false), ("→", false)] {
            precondition(PinyinCandidate(word: text, pinyin: "", inputLength: 0, frequency: 0).isEmoji == expected, text)
        }
        session.cancel()
        type("nihao")
        precondition(session.candidates.prefix(2).map(\.word) == ["你好", "拟好"], "\(session.candidates.prefix(4).map(\.word))")
        session.cancel()
        type("nihao")
        precondition(session.candidates.first?.word == "你好")
        session.cancel()
        type("chi")
        precondition(session.candidates.first?.word == "吃")
        session.cancel()
        type("beijing")
        precondition(session.candidates.first?.word == "北京")
        session.cancel()
        type("hello")
        session.selectCandidate(at: 0)
        precondition(session.takeCommit() == "hello")
        session.cancel()
        precondition(session.setFuzzyEnabled(false))
        for (input, expected) in [("nihao", "你好"), ("beijing", "北京"), ("shurufa", "输入法"),
                                  ("woxiangqubeijing", "我想去北京"), ("jintiantianqihenhao", "今天天气很好")] {
            session.cancel()
            type(input)
            print(input, session.candidates.prefix(5).map(\.word))
            precondition(session.candidates.first?.word == expected, "Wrong first candidate: \(input)")
            session.selectCandidate(at: 0)
            precondition(session.takeCommit() == expected)
            precondition(!session.isComposing)
        }
        for (input, expected) in [("nh", "你好"), ("woxiangqubj", "我想去北京")] {
            type(input)
            precondition(session.candidates.prefix(9).contains(where: { $0.word == expected }))
            session.cancel()
        }
        type("nihao")
        _ = session.handle(modifier(kVK_Shift, .shift), shiftToggleEnabled: true)
        precondition(session.handle(modifier(kVK_Shift, []), shiftToggleEnabled: true))
        precondition(session.takeCommit() == "nihao")
        precondition(session.englishMode && !session.isComposing && !session.showsCandidates)
        precondition(!session.handle(letter("a"), shiftToggleEnabled: true))
        session.setEnglishMode(false)
        type("nihao")
        precondition(session.candidates.first?.word == "你好")
        _ = session.handle(modifier(kVK_CapsLock, .capsLock), shiftToggleEnabled: true)
        precondition(session.takeCommit() == "nihao" && !session.isComposing)
        type("nihao")
        _ = session.handle(modifier(kVK_CapsLock, []), shiftToggleEnabled: true)
        precondition(session.takeCommit() == "nihao" && !session.isComposing, "Caps Lock must commit letters, not 你好")
        let upper = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_A), characters: "A", letter: "a", flags: .capsLock, isRepeat: false)
        precondition(!session.handle(upper, shiftToggleEnabled: true))
        _ = session.handle(modifier(kVK_CapsLock, []), shiftToggleEnabled: true)
        type("nihao")
        _ = session.handle(key(kVK_Return), shiftToggleEnabled: true)
        precondition(session.takeCommit() == "nihao")
        type("nihao")
        let ni = session.candidates.firstIndex(where: { $0.word == "你" })!
        session.selectCandidate(at: ni)
        precondition(session.isComposing && session.markedText.hasPrefix("你"))
        precondition(session.takeCommit().isEmpty) // Rime keeps confirmed prefix marked.
        session.setEnglishMode(true)
        precondition(session.takeCommit() == "你hao")
        session.setEnglishMode(false)
        type("shi")
        precondition(session.candidates.count > 9)
        let expected = session.candidates[9].word
        session.pageCandidates(1)
        precondition(session.highlighted == 9)
        _ = session.handle(key(kVK_ANSI_1, "1"), shiftToggleEnabled: true)
        precondition(session.takeCommit() == expected)
        type("nihao")
        _ = session.handle(key(kVK_Delete), shiftToggleEnabled: true)
        precondition(session.preedit == "niha")
        session.cancel()
        precondition(session.takeCommit().isEmpty && session.markedText.isEmpty)
        precondition(session.setFuzzyEnabled(true))
        type("zongguo")
        fputs("fuzzy: \(session.candidates.prefix(5).map(\.word))\n", stderr)
        precondition(session.candidates.prefix(9).contains(where: { $0.word == "中国" }))
        session.cancel()
        precondition(session.setFuzzyEnabled(false))
        type("n")
        let repeatN = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_N), characters: "n", letter: "n",
                                     flags: [], isRepeat: true)
        precondition(session.handle(repeatN, shiftToggleEnabled: true))
        precondition(session.preedit == "n")
        session.cancel()
        type("nihao")
        _ = session.handle(modifier(kVK_Shift, .shift), shiftToggleEnabled: false)
        precondition(!session.handle(modifier(kVK_Shift, []), shiftToggleEnabled: false))
        precondition(session.isComposing && !session.englishMode)
        session.cancel()
        type("nihao")
        let command = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_A), characters: "a",
                                     letter: "a", flags: .command, isRepeat: false)
        precondition(!session.handle(command, shiftToggleEnabled: true))
        precondition(session.preedit == "nihao")
        _ = session.handle(modifier(kVK_RightShift, .shift), shiftToggleEnabled: true)
        _ = session.handle(command, shiftToggleEnabled: true)
        precondition(!session.handle(modifier(kVK_RightShift, []), shiftToggleEnabled: true))
        precondition(!session.englishMode && session.takeCommit().isEmpty)
        session.cancel()
        let digit = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_3), characters: "3", letter: nil, flags: [], isRepeat: false)
        precondition(!session.handle(digit, shiftToggleEnabled: true))
        _ = session.handle(key(0, "."), shiftToggleEnabled: true)
        precondition(session.takeCommit() == ".")
        _ = session.handle(key(0, "."), shiftToggleEnabled: true)
        precondition(session.takeCommit() == "。")
        type("ni")
        let bracket = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_LeftBracket), characters: "[",
                                     letter: nil, flags: [], isRepeat: false)
        precondition(session.handle(bracket, shiftToggleEnabled: true))
        let committed = session.takeCommit()
        precondition(committed.hasSuffix("【"), "left bracket should insert 【, not page candidates: \(committed)")
        session.cancel()
        type("beijing")
        precondition(session.candidates.first?.word == "北京")
        let background = session.candidates.firstIndex(where: { $0.word == "背景" })!
        session.selectCandidate(at: background)
        precondition(session.takeCommit() == "背景")
        type("beijing")
        precondition(session.candidates.first?.word == "背景", "Native learning should prefer 背景 for beijing, got \(session.candidates.prefix(5).map(\.word))")
        session.cancel()
        // Editing is owned by Rime, independently from the candidate highlight.
        type("nihao")
        let endCaret = session.markedCaret
        _ = session.handle(key(kVK_LeftArrow), shiftToggleEnabled: true)
        precondition(session.markedCaret < endCaret && session.highlighted == 0)
        _ = session.handle(key(kVK_ForwardDelete), shiftToggleEnabled: true)
        precondition(session.preedit == "niha", "forward delete must remove o after the caret")
        type("o")
        precondition(session.preedit == "nihao")
        _ = session.handle(key(kVK_ForwardDelete), shiftToggleEnabled: true)
        precondition(session.preedit == "nihao", "forward delete at end must not backspace")
        _ = session.handle(key(kVK_Home), shiftToggleEnabled: true)
        precondition(session.markedCaret == 0, "Home must retain a genuine zero caret")
        _ = session.handle(key(kVK_LeftArrow), shiftToggleEnabled: true)
        precondition(session.markedCaret == 0, "left at start must not wrap")
        _ = session.handle(key(kVK_RightArrow), shiftToggleEnabled: true)
        precondition(session.markedCaret == 1)
        _ = session.handle(key(kVK_End), shiftToggleEnabled: true)
        precondition(session.markedCaret == (session.markedText as NSString).length)
        _ = session.handle(key(kVK_RightArrow), shiftToggleEnabled: true)
        precondition(session.markedCaret == (session.markedText as NSString).length)
        session.cancel()

        // UTF-8 native ranges must become UTF-16 client ranges after selecting 你.
        type("nihao")
        session.selectCandidate(at: session.candidates.firstIndex(where: { $0.word == "你" })!)
        precondition(session.markedText == "你hao")
        precondition(session.markedHighlight == NSRange(location: 1, length: 3),
                     "active range must underline hao, got \(session.markedHighlight)")
        precondition(session.markedCaret == 4)
        type("qx")
        precondition(session.markedText.hasPrefix("你"))
        precondition(session.candidates.allSatisfy { $0.engineIndex != nil },
                     "raw candidate must not clear a previously confirmed Chinese prefix")
        session.commitRaw()
        precondition(session.takeCommit() == "你haoqx")

        type("nihaonihao")
        session.selectCandidate(at: session.candidates.firstIndex(where: { $0.word == "👋" })!)
        precondition(session.markedText.hasPrefix("👋"))
        precondition(session.markedHighlight.location == 2, "emoji prefix occupies two UTF-16 units")
        precondition(session.markedCaret == (session.markedText as NSString).length)
        session.cancel()

        // Corrected syllables and abbreviation sentences must not lose to raw text.
        for input in ["xign", "shagn", "zhogn", "shagnhai", "zhognwen", "woxiangqubj", "woxiangqxbeijing"] {
            type(input)
            precondition(session.candidates.first?.engineIndex != nil,
                         "native correction should lead \(input): \(session.candidates.prefix(9))")
            session.cancel()
        }

        // Preserve the displayed order when lazily enumerating beyond 90 results.
        precondition(session.setFuzzyEnabled(true))
        type("hello")
        let firstPage = Array(session.candidates.prefix(9))
        let loaded = session.candidates.count
        for _ in 0..<9 { session.pageCandidates(1) }
        precondition(session.candidates.count > loaded, "fixture must trigger lazy loading")
        precondition(Array(session.candidates.prefix(9)) == firstPage,
                     "loading another page must not undo English promotion")
        for _ in 0..<9 { session.pageCandidates(-1) }
        precondition(session.highlighted == 0)
        session.pageCandidates(-1)
        precondition(session.highlighted == 0, "previous on first page must not jump to the tail")
        _ = session.handle(key(kVK_Space), shiftToggleEnabled: true)
        precondition(session.takeCommit() == "hello", "displayed English selection must map to native index")
        precondition(session.setFuzzyEnabled(false))

        for (code, symbol) in [(kVK_ANSI_Minus, "_"), (kVK_ANSI_Slash, "/"),
                               (kVK_ANSI_2, "@"), (kVK_ANSI_0, "0")] {
            type("nihao")
            precondition(session.handle(key(code, symbol), shiftToggleEnabled: true))
            precondition(session.takeCommit() == "你好" + symbol,
                         "symbol must follow committed composition: \(symbol)")
            precondition(!session.isComposing)
        }
        precondition(!FileManager.default.fileExists(atPath: user.appendingPathComponent("first_is_best.json").path),
                     "native learning must not require a second frontend learning database")
        print("PASS: caret editing, forward delete, UTF-16 ranges, partial-prefix safety, correction priority, stable paging, symbols")
        var latencies: [Double] = []
        for _ in 0..<5 {
            for ch in "woxiangqubeijing" {
                let start = ProcessInfo.processInfo.systemUptime
                _ = session.handle(letter(ch), shiftToggleEnabled: true)
                latencies.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            session.cancel()
        }
        latencies.sort()
        print(String(format: "Candidate latency (75 warm keystrokes): p50 %.1f ms, p95 %.1f ms, max %.1f ms",
                     latencies[latencies.count / 2], latencies[Int(Double(latencies.count - 1) * 0.95)], latencies.last!))
        print("PASS: real librime candidates, sentences, paging, selection, raw Latin switching, deletion, exact-first fuzzy, key repeat")
    }
    static func persistence(phase: String, user: URL) throws {
        let runtime = try RimeRuntime(sharedData: URL(fileURLWithPath: CommandLine.arguments[1]), userData: user)
        defer { SLRimeFinalize() }
        let session = try RimePinyinSession(runtime: runtime)
        for ch in "beijing" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        if phase == "--learn" {
            precondition(session.candidates.first?.word == "北京")
            let index = session.candidates.firstIndex(where: { $0.word == "背景" })!
            session.selectCandidate(at: index)
            precondition(session.takeCommit() == "背景")
        } else {
            precondition(phase == "--verify-learning")
            precondition(session.candidates.first?.word == "背景", "User dictionary did not persist across processes")
        }
        precondition(!FileManager.default.fileExists(atPath: user.appendingPathComponent("first_is_best.json").path))
        print("PASS: native user dictionary (without frontend pinning)", phase)
    }

    static func letter(_ ch: Character) -> PinyinKeyEvent {
        PinyinKeyEvent(type: .keyDown, keyCode: 0, characters: String(ch), letter: ch, flags: [], isRepeat: false)
    }
    static func key(_ code: Int, _ text: String = "") -> PinyinKeyEvent {
        PinyinKeyEvent(type: .keyDown, keyCode: UInt16(code), characters: text, letter: nil, flags: [], isRepeat: false)
    }
    static func modifier(_ code: Int, _ flags: NSEvent.ModifierFlags) -> PinyinKeyEvent {
        PinyinKeyEvent(type: .flagsChanged, keyCode: UInt16(code), characters: "", letter: nil, flags: flags, isRepeat: false)
    }
}
