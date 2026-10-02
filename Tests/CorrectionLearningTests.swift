import Foundation

/// A fixed lexicon, so that what is tested is the rules and not this Mac's
/// language models: these names, these words, every other character on its own.
private let knownNames = ["黄根成", "黄根诚", "张三", "李小明", "扎格罗斯", "杜娟", "王维"]
private let knownWords = ["权利", "权力", "他们", "她们", "明天", "后天", "下午", "开会", "今天", "输入法", "豆包", "再见",
                          "杜鹃", "客户", "文档", "山脉", "代码", "提交", "知道", "飞书", "我们", "同事", "一下", "电脑",
                          "芯片", "会议", "世界", "你好", "天气", "出去", "增长", "文章"]

private func occurrences(of terms: [String], in text: String) -> [Range<Int>] {
    let ns = text as NSString
    var found: [Range<Int>] = []
    for term in terms {
        var from = 0
        while from < ns.length {
            let hit = ns.range(of: term, range: NSRange(location: from, length: ns.length - from))
            guard hit.location != NSNotFound else { break }
            found.append(hit.location..<hit.location + hit.length)
            from = hit.location + hit.length
        }
    }
    return found
}

private let fixed = CorrectionLexicon(
    names: { occurrences(of: knownNames, in: $0) },
    words: { text in
        // Longest known word first, as a segmenter would.
        let ns = text as NSString
        var words: [Range<Int>] = []
        var at = 0
        while at < ns.length {
            let length = [2, 3, 4].reversed().first { at + $0 <= ns.length && knownWords.contains(ns.substring(with: NSRange(location: at, length: $0))) } ?? 1
            words.append(at..<at + length)
            at += length
        }
        return words
    })

@main struct CorrectionLearningTests {
    /// What the rules learn, as "heard→corrected", with "(hint)" for a pair that may never replace.
    static func learned(_ written: String, _ now: String, starts: Bool = true, ends: Bool = true,
                        lexicon: CorrectionLexicon = fixed) -> [String]? {
        switch CorrectionRules.read(written: written, now: now, startsDocument: starts, endsDocument: ends, lexicon: lexicon) {
        case .gone: return nil
        case .pairs(let pairs): return pairs.map { "\($0.heard)→\($0.corrected)" + ($0.replaceable ? "" : " (hint)") }
        }
    }

    static func expect(_ written: String, _ now: String, _ expected: [String]?, starts: Bool = true, ends: Bool = true,
                       lexicon: CorrectionLexicon = fixed, line: UInt = #line) {
        let got = learned(written, now, starts: starts, ends: ends, lexicon: lexicon)
        precondition(got == expected, "line \(line): \"\(written)\" → \"\(now)\" taught \(got.map { "\($0)" } ?? "gone"), expected \(expected.map { "\($0)" } ?? "gone")")
    }

    @MainActor static func main() {
        rules()
        sound()
        store()
        learner()
        system()
        print("PASS: learning from corrections: names, mixed terms, numbers, what is not learned, anchors, gone texts, sound, the store, the learner, the system lexicon")
    }

    static func rules() {
        // Chinese names. One wrong character is the usual case; the pair is the whole name.
        expect("我明天和黄根诚开会。", "我明天和黄根成开会。", ["黄根诚→黄根成"])
        expect("帮我找一下章三", "帮我找一下张三", ["章三→张三"])
        expect("李晓明说他不来了。", "李小明说他不来了。", ["李晓明→李小明"])
        // Two changes inside one name are one correction.
        expect("我和皇根诚开会", "我和黄根成开会", ["皇根诚→黄根成"])
        expect("札格罗斯山脉很高。", "扎格罗斯山脉很高。", ["札格罗斯→扎格罗斯"])
        expect("章三", "张三", ["章三→张三"])
        // Not a name to the tagger, but a word the mishearing was no word for.
        expect("我在看斗包的文档。", "我在看豆包的文档。", ["斗包→豆包"])
        // A name that was heard as an ordinary word may bias, never replace: 杜鹃 is also a bird.
        expect("他是杜鹃的同事。", "他是杜娟的同事。", ["杜鹃→杜娟 (hint)"])
        // Two people in one sentence.
        expect("黄根诚和章三都来。", "黄根成和张三都来。", ["黄根诚→黄根成", "章三→张三"])

        // Mixed Chinese and English: product names and terms.
        expect("我在用塞蓝输入法。", "我在用Saylane输入法。", ["塞蓝→Saylane"])
        expect("我在用塞蓝输入法。", "我在用 Saylane 输入法。", ["塞蓝→Saylane"])
        expect("我找克劳德", "我找Claude", ["克劳德→Claude"])
        // A term dictated on its own and retyped whole: only when it is all the field holds.
        expect("塞蓝", "Saylane", ["塞蓝→Saylane"])
        expect("塞蓝", "Saylane", nil, ends: false)
        expect("塞蓝", "Saylane", nil, starts: false)
        expect("我用克劳德扣的写代码。", "我用Claude Code写代码。", ["克劳德扣的→Claude Code"])
        expect("我用Say lane写。", "我用Saylane写。", ["Say lane→Saylane"])
        // English in lower case may be ordinary speech: it biases, it is never replaced.
        expect("我用cloud code写代码。", "我用Claude Code写代码。", ["cloud code→Claude Code (hint)"])
        expect("把代码提交到get hub上。", "把代码提交到GitHub上。", ["get hub→GitHub (hint)"])
        expect("we deploy with cube control now.", "we deploy with kubectl now.", [])
        expect("We deploy with Cube Control now.", "We deploy with kubectl now.", ["Cube Control→kubectl"])

        // Numbers. Inside a name they are learned with the name…
        expect("我用的是GPT四。", "我用的是GPT-4。", ["GPT四→GPT-4"])
        expect("这台电脑是M一芯片。", "这台电脑是M1芯片。", ["M一→M1"])
        expect("我买了iPhone十五。", "我买了iPhone 15。", ["iPhone十五→iPhone 15"])
        expect("我用千问三写的。", "我用Qwen3写的。", ["千问三→Qwen3"])
        // …on their own they are not terms: the next number will be another one.
        expect("会议在三点五十分。", "会议在3点50分。", [])
        expect("一共二零二六个。", "一共2026个。", [])
        expect("一共15个。", "一共50个。", [])
        expect("增长了百分之二十。", "增长了20%。", [])

        // Not learned: a change of mind is not a mishearing.
        expect("明天下午开会。", "后天下午开会。", [])
        expect("我们用飞书开会。", "我们用Lark开会。", [])
        expect("好的，我知道了。", "OK，我知道了。", [])
        // Two real words that sound the same: which one is right depends on the sentence.
        expect("这是他的权利。", "这是他的权力。", [])
        expect("他们今天不来。", "她们今天不来。", [])
        expect("it is bigger then that.", "it is bigger than that.", [])
        // A single character, however common the confusion.
        expect("他说今天不来。", "她说今天不来。", [])
        expect("我跑的很快。", "我跑得很快。", [])
        expect("我在家", "我再家", [])
        // Punctuation, spacing, deletions, additions.
        expect("你好，世界。", "你好, 世界!", [])
        expect("你好 世界", "你好世界", [])
        expect("嗯我明天去开会", "我明天去开会", [])
        expect("我明天去开会", "我明天去北京开会", [])
        expect("我明天去开会", "我明天去开会，然后去吃饭", [])
        // Capitalising an ordinary word.
        expect("the code is good.", "The code is good.", [])
        expect("i use cursor every day.", "i use Cursor every day.", [])
        // But capitals inside a word are a spelling.
        expect("i use iphone every day.", "i use iPhone every day.", ["iphone→iPhone (hint)"])
        // Another script, or sentence punctuation inside the span.
        expect("我在用塞蓝输入法。", "我在用セイレーン输入法。", [])
        expect("我在用塞蓝输入法。", "我在用Say，lane输入法。", [])
        // A sentence that was rewritten teaches nothing, even with a name in it.
        expect("我明天和黄根诚去开会。", "后天下午我跟黄根成一起吃个饭。", [])
        expect("黄根诚和章三还有李晓明和札格罗斯都来。", "黄根成和张三还有李小明和扎格罗斯都来。", [])

        // Anchors. At the end of a dictation with other text after it, nobody
        // can tell where the correction stops…
        expect("我明天和黄根诚", "我明天和黄根成，然后去吃饭", [], ends: false)
        // …unless the document ends there, or dictated text follows.
        expect("我明天和黄根诚", "我明天和黄根成", ["黄根诚→黄根成"])
        expect("我明天和黄根诚开会", "我明天和黄根成开会，然后去吃饭", ["黄根诚→黄根成"], ends: false)
        // The same at the start.
        expect("章三明天来", "张三明天来", [], starts: false)
        expect("章三明天来", "张三明天来", ["章三→张三"])
        // Text typed in front of the dictation shifts what is read; nothing wrong comes of it.
        expect("我明天和黄根诚开会。", "你好我明天和黄根诚开", [], starts: false, ends: false)
        expect("我明天和黄根诚开会。", "你好我明天和黄根成开", ["黄根诚→黄根成"], starts: false, ends: false)

        // The dictation is gone: sent, cleared, or something else stands there.
        expect("今天天气很好我们出去玩吧。", "", nil)
        expect("今天天气很好我们出去玩吧。", "明天下雨，不去了。", nil)
        expect("好的", "", nil)
        expect("好的", "收到", nil)
        // Half of a short sentence changed: still there.
        expect("我找克劳德", "我找Claude，", ["克劳德→Claude"])
    }

    static func sound() {
        let alike = [("塞蓝", "Saylane"), ("克劳德", "Claude"), ("库伯奈提斯", "Kubernetes"), ("千问三", "Qwen3"),
                     ("GPT四", "GPT-4"), ("cloud", "Claude"), ("curser", "Cursor"), ("say lane", "Saylane"),
                     ("黄根诚", "黄根成"), ("章三", "张三"), ("李晓明", "李小敏"), ("拉客", "Lark"), ("吉特哈布", "GitHub")]
        for (heard, corrected) in alike {
            precondition(CorrectionRules.soundsAlike(heard, corrected), "\(heard) / \(corrected) should sound alike")
        }
        let different = [("飞书", "Lark"), ("大模型", "LLM"), ("好的", "OK"), ("苹果", "Apple"), ("react", "Vue"),
                         ("明天", "后天"), ("谢谢", "Thanks"), ("黄根诚", "黄根"), ("章三", "李四")]
        for (heard, corrected) in different {
            precondition(!CorrectionRules.soundsAlike(heard, corrected), "\(heard) / \(corrected) should not sound alike")
        }
    }

    static func store() {
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let name = CorrectionRules.Pair(heard: "黄根诚", corrected: "黄根成", replaceable: true)
        let term = CorrectionRules.Pair(heard: "cloud code", corrected: "Claude Code", replaceable: false)
        let joined = CorrectionRules.Pair(heard: "Say lane", corrected: "Saylane", replaceable: true)

        // Once: a hint for the recognizer at once, no replacement yet.
        var learned = LearnedCorrections()
        var result = learned.learn([name, term], now: start)
        precondition(result.new == 2 && result.replacing == 0)
        precondition(learned.biasTerms == ["黄根成", "Claude Code"] || learned.biasTerms == ["Claude Code", "黄根成"])
        precondition(learned.apply(to: "我和黄根诚开会", lexicon: fixed) == "我和黄根诚开会")
        precondition(learned.standing(of: learned.items[0]) == .replacesAfterNext && learned.standing(of: learned.items[1]) == .hint)
        // Twice: the heard spelling is replaced, literally.
        result = learned.learn([name], now: start + day)
        precondition(result.new == 0 && result.replacing == 1 && learned.items[0].seen == 2)
        precondition(learned.apply(to: "我和黄根诚开会，黄根诚说好。", lexicon: fixed) == "我和黄根成开会，黄根成说好。")
        precondition(learned.apply(to: "黄跟诚", lexicon: fixed) == "黄跟诚", "a learned pair is not stretched to what sounds like it")
        precondition(learned.biasTerms.first == "黄根成", "the most recently used spelling comes first")
        // An ordinary heard spelling is never replaced, however often it was corrected.
        for step in 2...5 { learned.learn([term], now: start + day * Double(step)) }
        precondition(learned.apply(to: "I like cloud code.", lexicon: fixed) == "I like cloud code.")
        precondition(learned.replacements.map(\.heard) == ["黄根诚"])
        // Latin spellings are whole words, in any case.
        learned.learn([joined], now: start)
        learned.learn([joined], now: start)
        precondition(learned.apply(to: "I use say lane and Say Lane, not essay lanes.", lexicon: fixed) == "I use Saylane and Saylane, not essay lanes.")
        precondition(learned.apply(to: "用say lane写，不是say lanes", lexicon: fixed) == "用Saylane写，不是say lanes")

        // The correction made the other way round takes the pair back.
        var undone = LearnedCorrections()
        undone.learn([name], now: start)
        undone.learn([name], now: start)
        undone.learn([CorrectionRules.Pair(heard: "黄根成", corrected: "黄根诚", replaceable: true)], now: start)
        precondition(undone.isEmpty)

        // Two corrected spellings for one heard spelling: it depends on the sentence, so neither replaces.
        var contested = LearnedCorrections()
        let zhang = CorrectionRules.Pair(heard: "章三", corrected: "张三", replaceable: true)
        contested.learn([zhang], now: start)
        contested.learn([zhang], now: start)
        precondition(contested.apply(to: "章三来了", lexicon: fixed) == "张三来了")
        // Only where it stands as a word of its own: inside "文章" + "三篇" it is not the name.
        precondition(contested.apply(to: "这篇文章三天写完，章三看过", lexicon: fixed) == "这篇文章三天写完，张三看过")
        contested.learn([CorrectionRules.Pair(heard: "章三", corrected: "张珊", replaceable: true)], now: start + day)
        precondition(contested.apply(to: "章三来了", lexicon: fixed) == "章三来了" && contested.replacements.isEmpty)
        precondition(contested.biasTerms == ["张珊", "张三"])

        // A pair that is not used expires; one whose spelling keeps being written does not.
        var aging = LearnedCorrections()
        aging.learn([name, zhang], now: start)
        precondition(aging.noteWritten("今天黄根成来了", now: start + day * 60))
        precondition(!aging.noteWritten("今天黄根成来了", now: start + day * 60 + 60), "use is noted once a day at most")
        precondition(aging.noteWritten("今天没有他", now: start + day * 100), "what nobody used for 90 days goes")
        precondition(aging.items.map(\.corrected) == ["黄根成"])
        aging.expire(now: start + day * 151)
        precondition(aging.isEmpty)

        // The list is capped; the least recently used go first.
        var many = LearnedCorrections()
        for index in 0..<(LearnedCorrections.capacity + 20) {
            many.learn([CorrectionRules.Pair(heard: "塞蓝\(index)", corrected: "Saylane\(index)", replaceable: true)],
                       now: start + Double(index))
        }
        precondition(many.items.count == LearnedCorrections.capacity)
        precondition(!many.items.contains { $0.heard == "塞蓝0" } && many.items.contains { $0.heard == "塞蓝219" })
        precondition(many.biasTerms.count == LearnedCorrections.biasLimit)

        // What a file may hold: anything else in it is dropped.
        let odd = LearnedCorrections([
            LearnedCorrection(heard: "诚", corrected: "成", seen: 9, replaceable: true, lastUsed: start),
            LearnedCorrection(heard: "Claude", corrected: "Claude Code", seen: 9, replaceable: true, lastUsed: start),
            LearnedCorrection(heard: "章三", corrected: "张三", seen: 0, replaceable: true, lastUsed: start),
            LearnedCorrection(heard: "章三", corrected: "张三", seen: 2, replaceable: true, lastUsed: start),
            LearnedCorrection(heard: "章三", corrected: "张三", seen: 5, replaceable: true, lastUsed: start),
        ])
        precondition(odd.items.count == 1 && odd.items[0].seen == 2)
    }

    @MainActor static func learner() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saylane-learning-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("Learned/corrections.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let learner = CorrectionLearner(fileURL: file, lexicon: fixed, now: { clock.now })
        func report(_ session: UUID, _ text: String?, closed: Bool = false) -> CorrectionLearner.Outcome {
            learner.received(BridgeReadBack(session: session, text: text, startsDocument: true, endsDocument: true, closed: closed))
        }

        // While the dictation is still there the user may be half-way through an edit: nothing is learned yet.
        let first = UUID()
        learner.wrote("我明天和黄根诚开会。", session: first)
        precondition(report(first, "我明天和黄根开会。") == CorrectionLearner.Outcome())
        precondition(report(first, "我明天和黄根城开会。") == CorrectionLearner.Outcome())
        precondition(report(first, "我明天和黄根成开会。") == CorrectionLearner.Outcome())
        precondition(learner.corrections.isEmpty && !FileManager.default.fileExists(atPath: file.path))
        // The client lost focus: what the text read last is what counts.
        let closed = report(first, nil, closed: true)
        precondition(closed == CorrectionLearner.Outcome(finished: true, learned: 1, new: 1, replacing: 0), "\(closed)")
        precondition(learner.corrections.items.map(\.id) == ["黄根诚\u{1F}黄根成"])
        precondition(report(first, "我明天和黄根成开会。").finished, "a dictation that is over is not watched again")

        // The file holds pairs and nothing of the sentence.
        let stored = try! String(contentsOf: file, encoding: .utf8)
        precondition(stored.contains("黄根诚") && stored.contains("黄根成"))
        precondition(!stored.contains("明天") && !stored.contains("开会"), "no sentence may be stored: \(stored)")

        // The same correction in another dictation, which is then sent: the text is gone, the pair has earned its place.
        let second = UUID()
        learner.wrote("黄根诚说他不来了", session: second)
        precondition(report(second, "黄根成说他不来了") == CorrectionLearner.Outcome())
        let sent = report(second, "")
        precondition(sent == CorrectionLearner.Outcome(finished: true, learned: 1, new: 0, replacing: 1), "\(sent)")
        precondition(learner.corrections.apply(to: "黄根诚来了", lexicon: fixed) == "黄根成来了")

        // A new process reads the same pairs.
        let reloaded = CorrectionLearner(fileURL: file, lexicon: fixed, now: { clock.now })
        precondition(reloaded.corrections == learner.corrections)

        // A correction that was taken back before the text was left teaches nothing.
        let third = UUID()
        learner.wrote("帮我找一下章三", session: third)
        _ = report(third, "帮我找一下张三")
        _ = report(third, "帮我找一下章三")
        precondition(report(third, nil, closed: true) == CorrectionLearner.Outcome(finished: true))
        // A dictation nobody was told about, and one whose learning was switched off.
        precondition(report(UUID(), "anything", closed: true) == CorrectionLearner.Outcome(finished: true))
        let fourth = UUID()
        learner.wrote("帮我找一下章三", session: fourth)
        learner.stopWatching()
        precondition(report(fourth, "帮我找一下张三", closed: true) == CorrectionLearner.Outcome(finished: true))
        precondition(learner.corrections.items.count == 1)

        // Only a few dictations are held, and not for long; the oldest is judged by what was last seen of it.
        let early = UUID()
        learner.wrote("帮我找一下章三", session: early)
        _ = report(early, "帮我找一下张三")
        for _ in 0..<CorrectionLearner.watchLimit {
            clock.now += 1
            learner.wrote("你好", session: UUID())
        }
        precondition(learner.corrections.items.contains { $0.corrected == "张三" })
        precondition(report(early, nil, closed: true) == CorrectionLearner.Outcome(finished: true))

        // The user's control: forget one, forget all.
        learner.forget("章三\u{1F}张三")
        precondition(learner.corrections.items.map(\.corrected) == ["黄根成"])
        learner.forgetAll()
        precondition(learner.corrections.isEmpty && !FileManager.default.fileExists(atPath: file.path))
    }

    /// The lexicon the main program uses: this Mac's own segmenter and name
    /// tagger. A few plain cases, to notice when a system update changes them.
    static func system() {
        expect("我明天和黄根诚开会。", "我明天和黄根成开会。", ["黄根诚→黄根成"], lexicon: .system)
        expect("帮我找一下章三", "帮我找一下张三", ["章三→张三"], lexicon: .system)
        expect("这是他的权利。", "这是他的权力。", [], lexicon: .system)
        expect("他说今天不来。", "她说今天不来。", [], lexicon: .system)
        expect("我在用塞蓝输入法。", "我在用Saylane输入法。", ["塞蓝→Saylane"], lexicon: .system)
        var learned = LearnedCorrections()
        for _ in 1...2 {
            learned.learn([CorrectionRules.Pair(heard: "黄根诚", corrected: "黄根成", replaceable: true),
                           CorrectionRules.Pair(heard: "章三", corrected: "张三", replaceable: true)], now: Date())
        }
        let replaced = learned.apply(to: "明天和黄根诚开会，这篇文章三天写完。", lexicon: .system)
        precondition(replaced == "明天和黄根成开会，这篇文章三天写完。", replaced)
    }
}
