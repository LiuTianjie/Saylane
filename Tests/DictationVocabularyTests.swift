import Foundation

@main struct DictationVocabularyTests {
    static var failures = 0

    static func expect(_ vocabulary: DictationVocabulary, _ input: String, _ expected: String, line: Int = #line) {
        let actual = vocabulary.apply(to: input)
        if actual != expected {
            failures += 1
            print("FAIL line \(line): \(input)\n  expected: \(expected)\n  actual:   \(actual)")
        }
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let entries = SpeechHotwords.entries(" Saylane|赛兰|塞蓝, 张三\n提分侠｜提分下|提分侠 ,Saylane|again")
        precondition(entries == [
            .init(canonical: "Saylane", aliases: ["赛兰", "塞蓝"]),
            .init(canonical: "张三", aliases: []),
            .init(canonical: "提分侠", aliases: ["提分下"]),
        ])
        precondition(SpeechHotwords.context(" Saylane|赛兰, 张三\n提分侠 ") == "Saylane、张三、提分侠")
        precondition(SpeechHotwords.terms("") .isEmpty && DictationVocabulary(raw: " , ").isEmpty)

        let vocabulary = DictationVocabulary(raw: "Saylane|赛兰|塞蓝\n张三\n微信\nKubernetes\nCursor\nQ版\n北京大学\n北京")
        // Chinese: canonical spelling matches the same toned syllables (fuzzy zh/z, n/l, ing/in).
        expect(vocabulary, "章三来了", "张三来了")
        expect(vocabulary, "臧三来了", "张三来了")
        expect(vocabulary, "张三来了", "张三来了")
        expect(vocabulary, "章伞来了", "章伞来了")
        expect(vocabulary, "以为新的方案更好", "以为新的方案更好")
        expect(vocabulary, "发个威信给我", "发个微信给我")
        expect(vocabulary, "北京大学在北京", "北京大学在北京")
        // Aliases ignore tone: this is what the recognizer produced for the term.
        expect(vocabulary, "我在用塞蓝输入法", "我在用Saylane输入法")
        expect(vocabulary, "我在用赛蓝输入法", "我在用Saylane输入法")
        expect(vocabulary, "我在用Saylane输入法", "我在用Saylane输入法")
        // Latin: casing, small misspellings and an accidental split.
        expect(vocabulary, "say lane is great", "Saylane is great")
        expect(vocabulary, "saylan is great", "Saylane is great")
        expect(vocabulary, "sailing is great", "sailing is great")
        expect(vocabulary, "we run kubernetes is production", "we run Kubernetes is production")
        expect(vocabulary, "we run Kubernetis", "we run Kubernetes")
        expect(vocabulary, "move the cursor, then the cursors", "move the Cursor, then the cursors")
        expect(vocabulary, "a curse", "a curse")
        // Mixed scripts fall back to a literal, case-insensitive match.
        expect(vocabulary, "画一个q版人物", "画一个Q版人物")
        expect(vocabulary, "", "")
        expect(DictationVocabulary(raw: ""), "章三来了", "章三来了")

        precondition(DictationVocabulary.editDistance("kitten", "sitting") == 3)
        precondition(DictationVocabulary.fuzzy("zhang") == "zan" && DictationVocabulary.fuzzy("ning") == "lin" && DictationVocabulary.fuzzy("ba") == "ba")
        precondition(DictationVocabulary.pinyin("张").tone == 1 && DictationVocabulary.pinyin("三").syllable == "san")

        precondition(failures == 0, "\(failures) vocabulary cases failed")
        print("PASS: vocabulary entries/aliases, pinyin (toned canonical, toneless alias), Latin fuzzy spelling")
    }
}
