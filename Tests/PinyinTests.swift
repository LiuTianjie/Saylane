import AppKit
import Carbon.HIToolbox

@main struct PinyinTests {
    static func main() {
        normalize()
        sessionSelection()
        latinModeSwitch()
        dictionary()
        pagingFuzzy()
        userChoice()
        composeWord()
        doubaoAlignment()
        characterCoverage()
        print("PASS: pinyin ranking, sentences, abbreviations, composition, user choice, coverage")
    }

    static func letter(_ ch: Character, shift: Bool = false) -> PinyinKeyEvent {
        PinyinKeyEvent(type: .keyDown, keyCode: 0, characters: String(ch), letter: ch,
                       flags: shift ? .shift : [], isRepeat: false)
    }

    static func key(_ code: Int, characters: String = "") -> PinyinKeyEvent {
        PinyinKeyEvent(type: .keyDown, keyCode: UInt16(code), characters: characters, letter: nil,
                       flags: [], isRepeat: false)
    }

    static func normalize() {
        precondition(PinyinSyllable.normalize("nǐ hǎo") == "nihao")
        precondition(PinyinSyllable.normalize("xi'an") == "xian")
        precondition(PinyinSyllable.normalize("nüe") == "nve")
        precondition(PinyinSyllable.normalize("lue") == "lve")
        precondition(PinyinSyllable.coversQuanpin("nihao"))
        precondition(PinyinSyllable.coversQuanpin("woaini"))
        precondition(PinyinSyllable.coversQuanpin("wo"))
        precondition(!PinyinSyllable.coversQuanpin("nh"))
        precondition(!PinyinSyllable.coversQuanpin("zg"))
        precondition(!PinyinSyllable.coversQuanpin("wmn"))
        precondition(PinyinSyllable.coversQuanpin("nih"))
        precondition(PinyinSyllable.display("nihao") == "ni'hao")
        precondition(PinyinSyllable.display("nih") == "ni'h")
        precondition(PinyinSyllable.display("xian") == "xian")
        precondition(PinyinSyllable.display("xi'an") == "xi'an")
        precondition(PinyinSyllable.display("woaini") == "wo'ai'ni")
    }

    static func sessionSelection() {
        let lexicon = PinyinLexicon()
        lexicon.replace(with: [
            PinyinEntry(word: "你好", pinyin: "nihao", frequency: 100),
            PinyinEntry(word: "你", pinyin: "ni", frequency: 90),
            PinyinEntry(word: "尼", pinyin: "ni", frequency: 20),
            PinyinEntry(word: "好", pinyin: "hao", frequency: 80),
            PinyinEntry(word: "我", pinyin: "wo", frequency: 100)
        ])
        let session = PinyinSession(lexicon: lexicon)
        for ch in "nihao" { precondition(session.handle(letter(ch), shiftToggleEnabled: true)) }
        precondition(session.candidates.first?.word == "你好")
        precondition(session.markedText == "ni'hao")
        precondition(session.handle(key(kVK_Space), shiftToggleEnabled: true))
        precondition(session.takeCommit() == "你好")
        precondition(!session.isComposing)
        precondition(session.markedText.isEmpty)
        precondition(!session.isAssociating)
        precondition(session.candidates.isEmpty)

        for ch in "nihao" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        let ni = session.candidates.firstIndex(where: { $0.word == "你" })!
        session.selectCandidate(at: ni)
        precondition(session.takeCommit() == "你")
        precondition(session.preedit == "hao")
        precondition(session.markedText == "hao")
        _ = session.handle(key(kVK_Return), shiftToggleEnabled: true)
        precondition(session.takeCommit() == "hao")

        _ = session.handle(letter("w"), shiftToggleEnabled: true)
        _ = session.handle(key(kVK_Escape), shiftToggleEnabled: true)
        precondition(!session.isComposing)
        precondition(session.takeCommit().isEmpty)

        precondition(session.handle(letter("a", shift: true), shiftToggleEnabled: true) == false)
        let comma = PinyinKeyEvent(type: .keyDown, keyCode: 0, characters: ",", letter: nil, flags: [], isRepeat: false)
        precondition(session.handle(comma, shiftToggleEnabled: true))
        precondition(session.takeCommit() == "，")

        let three = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_3), characters: "3", letter: nil,
                                   flags: [], isRepeat: false)
        precondition(session.handle(three, shiftToggleEnabled: true) == false)
        let period = PinyinKeyEvent(type: .keyDown, keyCode: 0, characters: ".", letter: nil, flags: [], isRepeat: false)
        precondition(session.handle(period, shiftToggleEnabled: true))
        precondition(session.takeCommit() == ".")
        precondition(session.handle(period, shiftToggleEnabled: true))
        precondition(session.takeCommit() == "。")
        precondition(session.handle(three, shiftToggleEnabled: true) == false)
        precondition(session.handle(comma, shiftToggleEnabled: true))
        precondition(session.takeCommit() == ",")

        let commandA = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_A), characters: "a", letter: "a",
                                      flags: .command, isRepeat: false)
        precondition(session.handle(commandA, shiftToggleEnabled: true) == false)

        let down = PinyinKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_Shift), characters: "", letter: nil,
                                  flags: .shift, isRepeat: false)
        let up = PinyinKeyEvent(type: .flagsChanged, keyCode: UInt16(kVK_Shift), characters: "", letter: nil,
                                flags: [], isRepeat: false)
        precondition(session.handle(down, shiftToggleEnabled: true) == false)
        precondition(session.handle(up, shiftToggleEnabled: true))
        precondition(session.englishMode)
        precondition(session.handle(letter("a"), shiftToggleEnabled: true) == false)
    }

    static func latinModeSwitch() {
        let persisted = PinyinLanguageModel.persistEnabled
        PinyinLanguageModel.persistEnabled = false
        defer { PinyinLanguageModel.persistEnabled = persisted }
        let lexicon = PinyinLexicon()
        lexicon.replace(with: [
            PinyinEntry(word: "你好", pinyin: "nihao", frequency: 100),
            PinyinEntry(word: "你", pinyin: "ni", frequency: 90),
            PinyinEntry(word: "好", pinyin: "hao", frequency: 80)
        ])
        func modifier(_ code: Int, _ flags: NSEvent.ModifierFlags) -> PinyinKeyEvent {
            PinyinKeyEvent(type: .flagsChanged, keyCode: UInt16(code), characters: "",
                           letter: nil, flags: flags, isRepeat: false)
        }
        func composing() -> PinyinSession {
            let session = PinyinSession(lexicon: lexicon)
            for ch in "nihao" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
            precondition(session.candidates.first?.word == "你好")
            return session
        }
        for code in [kVK_Shift, kVK_RightShift] {
            let session = composing()
            _ = session.handle(modifier(code, .shift), shiftToggleEnabled: true)
            precondition(session.handle(modifier(code, []), shiftToggleEnabled: true))
            precondition(session.takeCommit() == "nihao")
            precondition(session.englishMode && !session.isComposing && !session.showsCandidates)
            precondition(session.markedText.isEmpty)
            precondition(!session.handle(letter("a"), shiftToggleEnabled: true))
            _ = session.handle(modifier(code, .shift), shiftToggleEnabled: true)
            _ = session.handle(modifier(code, []), shiftToggleEnabled: true)
            precondition(!session.englishMode && session.takeCommit().isEmpty)
        }
        let caps = composing()
        precondition(caps.handle(modifier(kVK_CapsLock, .capsLock), shiftToggleEnabled: true))
        precondition(caps.takeCommit() == "nihao")
        precondition(!caps.isComposing && !caps.showsCandidates && !caps.englishMode)
        let uppercase = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_A),
                                      characters: "A", letter: "a", flags: .capsLock, isRepeat: false)
        precondition(!caps.handle(uppercase, shiftToggleEnabled: true))
        let punctuation = PinyinKeyEvent(type: .keyDown, keyCode: 0, characters: ",",
                                        letter: nil, flags: .capsLock, isRepeat: false)
        precondition(!caps.handle(punctuation, shiftToggleEnabled: true))
        precondition(!caps.handle(modifier(kVK_CapsLock, []), shiftToggleEnabled: true))
        precondition(caps.takeCommit().isEmpty)
        precondition(caps.handle(letter("n"), shiftToggleEnabled: true))

        let disabled = composing()
        _ = disabled.handle(modifier(kVK_Shift, .shift), shiftToggleEnabled: false)
        precondition(!disabled.handle(modifier(kVK_Shift, []), shiftToggleEnabled: false))
        precondition(disabled.preedit == "nihao" && !disabled.englishMode)
        precondition(disabled.takeCommit().isEmpty)

        let direct = composing()
        direct.setEnglishMode(true)
        precondition(direct.takeCommit() == "nihao" && !direct.isComposing)
        direct.setEnglishMode(true)
        precondition(direct.takeCommit().isEmpty)

        let partial = composing()
        partial.selectCandidate(at: partial.candidates.firstIndex(where: { $0.word == "你" })!)
        precondition(partial.takeCommit() == "你")
        partial.setEnglishMode(true)
        precondition(partial.takeCommit() == "hao")
        precondition(partial.markedText.isEmpty && !partial.showsCandidates)
    }

    static func bundledLexicon() -> PinyinLexicon {
        PinyinLanguageModel.shared.clearUserForTests()
        let lexicon = PinyinLexicon()
        lexicon.load(from: URL(fileURLWithPath: "Sources/Resources/pinyin.dict.tsv"))
        lexicon.overlay(from: URL(fileURLWithPath: "Sources/Resources/pinyin.chars.tsv"))
        lexicon.overlay(from: URL(fileURLWithPath: "Sources/Resources/pinyin.core.tsv"))
        lexicon.overlay(from: URL(fileURLWithPath: "Sources/Resources/pinyin.extra.tsv"))
        PinyinLanguageModel.shared.clearUserForTests()
        return lexicon
    }

    static func dictionary() {
        let lexicon = bundledLexicon()
        precondition(lexicon.isReady)
        func top(_ input: String) -> [String] {
            lexicon.candidates(for: input).prefix(9).map(\.word)
        }
        precondition(top("ni").first == "你")
        let kWords = top("k")
        precondition(!(kWords.first?.count ?? 0 > 1), "single letter k must not jump to 可以")
        precondition(kWords.first?.count == 1)
        precondition(!kWords.prefix(3).contains("可以"))
        precondition(top("ky").first == "可以" || top("ke").contains("可"))

        precondition(!top("ni").contains("伲"))
        precondition(top("nihao").first == "你好")
        precondition(top("nh").first == "你好")
        precondition(top("wo").first == "我")
        precondition(top("woaini").first == "我爱你")
        precondition(top("wm").first == "我们")
        precondition(top("woshi").first == "我是")
        precondition(top("keai").first == "可爱")
        precondition(top("de").first == "的")
        precondition(top("hao").first == "好")
        let xian = top("xian")
        precondition(xian.first == "先" || xian.first == "现")
        let zg = top("zg")
        precondition(zg.contains("中国") || zg.contains("这个"))
        precondition(top("sm").first == "什么")
        precondition(top("lv").contains("绿"))
        precondition(top("woxiangqubeijing").first == "我想去北京")
        precondition(top("jintiantianqihenhao").first == "今天天气很好")
        precondition(top("woxiangchi").first == "我想吃")
        precondition(top("zhongguorenmin").first == "中国人民")
        let beijingAlts = lexicon.candidates(for: "woxiangqubeijing")
        precondition(beijingAlts.contains { $0.word == "我想" || $0.preview.contains("北京") })
        precondition(top("beijing").first == "北京")
        precondition(top("shanghai").first == "上海")
        precondition(top("xuexi").first == "学习")
        precondition(top("pinyin").first == "拼音")
        precondition(top("shurufa").first == "输入法")
        precondition(top("youjian").first == "邮件")
        precondition(top("chifan").first == "吃饭")
        precondition(top("ceshi").first == "测试")
        precondition(top("bukeqi").first == "不客气")
        precondition(top("zhangsan").first == "张三")
        precondition(top("woshizhangsan").first == "我是张三")
        precondition(top("qingwenxianzaijidianle").first == "请问现在几点了")
        precondition(top("zheshiyigeceshi").first == "这是一个测试")
        precondition(!top("beijing").contains("被警察"))
        precondition(top("kyishishi").first == "可以试试")
        precondition(top("kyssk").first == "可以试试看")
        precondition(top("woxiangqubj").first == "我想去北京")
        precondition(top("keyishishi").first == "可以试试")
        let kWords2 = top("k")
        precondition(kWords2.first?.count == 1)
        precondition(!kWords2.prefix(3).contains("可以"))

        let huan = top("huan")
        precondition(huan.contains("换") && huan.contains("环") && huan.contains("欢") && huan.contains("缓"))
        precondition(huan.firstIndex(of: "缓")! < 9)
        precondition(huan.contains("幻"))
        precondition(!huan.prefix(5).contains("胡安"))
        precondition(!huan.prefix(5).contains("獾"))
        precondition(top("huancun").first == "缓存")
        precondition(top("huan'cun").first == "缓存")
        precondition(!huan.contains("黄"))
        precondition(top("weixin").first == "微信")
        precondition(top("zhifubao").first == "支付宝")
        precondition(top("fuzhi").contains("复制"))
        precondition(top("waimai").first == "外卖" || top("waimai").contains("外卖"))
        precondition(top("denglu").first == "登录" || top("denglu").contains("登录"))
        lexicon.fuzzyEnabled = false
        precondition(!lexicon.candidates(for: "zongguo").prefix(9).map(\.word).contains("中国"))
        lexicon.fuzzyEnabled = true
        precondition(top("zongguo").contains("中国"))
        precondition(top("huancum").contains("缓存"))
        precondition(top("zonggue").contains("中国"))
        precondition(top("k").first?.count == 1)
        precondition(!top("k").prefix(3).contains("可以"))
    }

    static func pagingFuzzy() {
        let lexicon = bundledLexicon()
        func top(_ input: String) -> [String] {
            lexicon.candidates(for: input).prefix(9).map(\.word)
        }
        // Doubao FuzzyType z2zh: zongguo should still recall 中国, exact zhongguo stays first.
        precondition(top("zhongguo").first == "中国")
        precondition(top("zongguo").contains("中国"))
        precondition(top("side").contains("是的") || top("shide").first == "是的")

        let session = PinyinSession(lexicon: lexicon)
        session.setAssociationEnabled(true)
        for ch in "wo" { precondition(session.handle(letter(ch), shiftToggleEnabled: true)) }
        precondition(session.handle(key(kVK_Space), shiftToggleEnabled: true))
        precondition(session.takeCommit() == "我")
        precondition(!session.isComposing)
        precondition(session.isAssociating)
        precondition(session.candidates.first?.word == "们")

        for ch in "ni" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        precondition(session.isComposing)
        precondition(!session.isAssociating)
        precondition(session.pageCount >= 1)
        if session.pageCount > 1 {
            session.pageCandidates(1)
            precondition(session.pageIndex == 1)
            session.pageCandidates(-1)
            precondition(session.pageIndex == 0)
        }
        _ = session.handle(key(kVK_Escape), shiftToggleEnabled: true)
        precondition(!session.isSelecting)
    }

    static func userChoice() {
        PinyinLanguageModel.persistEnabled = false
        let lexicon = PinyinLexicon()
        lexicon.replace(with: [
            PinyinEntry(word: "你好", pinyin: "nihao", frequency: 100),
            PinyinEntry(word: "尼耗", pinyin: "nihao", frequency: 20),
            PinyinEntry(word: "你", pinyin: "ni", frequency: 90)
        ])
        let session = PinyinSession(lexicon: lexicon)
        for ch in "nihao" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        let rare = session.candidates.firstIndex(where: { $0.word == "尼耗" })!
        session.selectCandidate(at: rare)
        _ = session.takeCommit()
        for ch in "nihao" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        precondition(session.candidates.first?.word == "尼耗")
        _ = session.handle(key(kVK_Escape), shiftToggleEnabled: true)

        PinyinLanguageModel.shared.clearUserForTests()
        PinyinLanguageModel.persistEnabled = true
        let live = bundledLexicon()
        let typed = PinyinSession(lexicon: live)
        for ch in "huan" { _ = typed.handle(letter(ch), shiftToggleEnabled: true) }
        let ring = typed.candidates.firstIndex(where: { $0.word == "环" })!
        typed.selectCandidate(at: ring)
        _ = typed.takeCommit()
        for ch in "huan" { _ = typed.handle(letter(ch), shiftToggleEnabled: true) }
        precondition(typed.candidates.first?.word == "环")
        _ = typed.handle(key(kVK_Escape), shiftToggleEnabled: true)
        PinyinLanguageModel.persistEnabled = false
    }

    static func composeWord() {
        PinyinLanguageModel.persistEnabled = false
        PinyinLanguageModel.shared.clearUserForTests()
        let lexicon = PinyinLexicon()
        lexicon.replace(with: [
            PinyinEntry(word: "你好", pinyin: "nihao", frequency: 100),
            PinyinEntry(word: "你", pinyin: "ni", frequency: 90),
            PinyinEntry(word: "尼", pinyin: "ni", frequency: 20),
            PinyinEntry(word: "好", pinyin: "hao", frequency: 80),
            PinyinEntry(word: "耗", pinyin: "hao", frequency: 10)
        ])
        let session = PinyinSession(lexicon: lexicon)
        for ch in "nihao" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        let ni = session.candidates.firstIndex(where: { $0.word == "尼" })!
        session.selectCandidate(at: ni)
        precondition(session.takeCommit() == "尼")
        precondition(session.preedit == "hao")
        let hao = session.candidates.firstIndex(where: { $0.word == "耗" })!
        session.selectCandidate(at: hao)
        precondition(session.takeCommit() == "耗")
        for ch in "nihao" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        precondition(session.candidates.first?.word == "尼耗")
        _ = session.handle(key(kVK_Escape), shiftToggleEnabled: true)
        PinyinLanguageModel.shared.clearUserForTests()
    }

    static func doubaoAlignment() {
        let lexicon = bundledLexicon()
        let off = PinyinSession(lexicon: lexicon)
        for ch in "wo" { _ = off.handle(letter(ch), shiftToggleEnabled: true) }
        _ = off.handle(key(kVK_Space), shiftToggleEnabled: true)
        precondition(off.takeCommit() == "我")
        precondition(!off.isAssociating)
        precondition(off.candidates.isEmpty)

        let session = PinyinSession(lexicon: lexicon)
        session.setAssociationEnabled(true)

        for ch in "ni" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        precondition(session.markedText == "ni")
        let comma = PinyinKeyEvent(type: .keyDown, keyCode: 0, characters: ",", letter: nil, flags: [], isRepeat: false)
        precondition(session.handle(comma, shiftToggleEnabled: true))
        precondition(session.takeCommit() == "你，")
        precondition(!session.isComposing)
        precondition(!session.isAssociating)

        for ch in "wo" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        _ = session.handle(key(kVK_Space), shiftToggleEnabled: true)
        precondition(session.takeCommit() == "我")
        precondition(session.isAssociating)
        precondition(session.candidates.first?.word == "们")
        _ = session.handle(key(kVK_Space), shiftToggleEnabled: true)
        precondition(session.takeCommit() == "们")
        precondition(session.isAssociating)

        _ = session.handle(key(kVK_Escape), shiftToggleEnabled: true)
        precondition(!session.isSelecting)

        for ch in "nihao" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        precondition(session.markedText == "ni'hao")
        let period = PinyinKeyEvent(type: .keyDown, keyCode: 0, characters: ".", letter: nil, flags: [], isRepeat: false)
        precondition(session.handle(period, shiftToggleEnabled: true))
        precondition(session.takeCommit() == "你好。")
        precondition(!session.isAssociating)

        for ch in "ni" { _ = session.handle(letter(ch), shiftToggleEnabled: true) }
        precondition(session.pageCount > 1)
        let minus = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_Minus), characters: "-", letter: nil,
                                   flags: [], isRepeat: false)
        precondition(session.handle(minus, shiftToggleEnabled: true))
        precondition(session.pageIndex == session.pageCount - 1)
        let equal = PinyinKeyEvent(type: .keyDown, keyCode: UInt16(kVK_ANSI_Equal), characters: "=", letter: nil,
                                   flags: [], isRepeat: false)
        precondition(session.handle(equal, shiftToggleEnabled: true))
        precondition(session.pageIndex == 0)
        _ = session.handle(key(kVK_Escape), shiftToggleEnabled: true)
    }

    static func characterCoverage() {
        let lexicon = bundledLexicon()
        func words(_ input: String) -> [String] {
            lexicon.candidates(for: input).map(\.word)
        }
        func top(_ input: String) -> [String] {
            Array(words(input).prefix(9))
        }
        precondition(top("zhan").contains("栈"))
        precondition(words("zhan").contains("盏"))
        precondition(words("zhan").contains("绽"))
        precondition(words("zhan").contains("崭"))
        precondition(top("duizhan").contains("堆栈"))
        precondition(top("hang").contains("行"))
        precondition(top("chang").contains("长"))
        precondition(top("yue").contains("乐"))
        precondition(top("fo").contains("佛"))
        precondition(top("liao").contains("了"))
        precondition(top("chong").contains("重"))
        let yiChars = words("yi").filter { $0.count == 1 }
        precondition(yiChars.count >= 100)
        precondition(words("yi").contains("一"))
    }
}
