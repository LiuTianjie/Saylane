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

        let glossary = DictationVocabulary(entries: DictationGlossary.entries)
        precondition(DictationGlossary.entries.count >= 200)
        precondition(Set(DictationGlossary.entries.map(\.canonical)).count == DictationGlossary.entries.count)
        precondition(!DictationGlossary.entries.contains(where: { ["微信", "翻译", "复制", "细胞"].contains($0.canonical) }))
        expect(glossary, "用派森写一个脚本", "用Python写一个脚本")
        expect(glossary, "傅立叶变换", "傅里叶变换")
        expect(glossary, "哈西表查一下", "哈希表查一下")
        expect(glossary, "柠檬酸循环是什么", "三羧酸循环是什么")
        expect(glossary, "这个人很有威信", "这个人很有威信")
        expect(glossary, "请帮我翻译这段", "请帮我翻译这段")
        expect(glossary, "今天有点内卷", "今天有点内卷")
        expect(glossary, "we use kubernetis", "we use Kubernetes")
        let bias = DictationGlossary.biasTerms(userRaw: "张三\n微信", includeUser: true, includeGlossary: true, limit: 50)
        precondition(bias.first == "张三" && bias.contains("微信") && bias.count == 50)
        expect(DictationVocabulary(raw: "微信"), "发个威信给我", "发个微信给我")

        precondition(DictationGlossary.remoteTerm(fromTitle: "闭包 (数学)") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "時間複雜度") == "时间复杂度")
        precondition(DictationGlossary.remoteTerm(fromTitle: "二次函数") == "二次函数")
        precondition(DictationGlossary.remoteTerm(fromTitle: "电子榨菜") == "电子榨菜")
        precondition(DictationGlossary.remoteTerm(fromTitle: "yyds") == "yyds")
        precondition(DictationGlossary.remoteTerm(fromTitle: "PUA") == "PUA")
        precondition(DictationGlossary.remoteTerm(fromTitle: "NP困难") == "NP困难")
        precondition(DictationGlossary.remoteTerm(fromTitle: "i人") == "i人")
        precondition(DictationGlossary.remoteTerm(fromTitle: "内卷") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "苹果") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "计算") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "翻译") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "几乎") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "幾乎") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "数据结构与算法术语列表") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "拓扑学术语") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "危") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "233") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "hi") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "dog") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "加速") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "M/M/1") == nil)
        precondition(DictationGlossary.remoteTerm(fromTitle: "Up to") == nil)
        let merged = DictationGlossary.combined(remote: ["翻译", "拓扑斯", "微积分", "時間複雜度"])
        precondition(merged.filter { $0.canonical == "微积分" }.count == 1)
        precondition(merged.contains { $0.canonical == "拓扑斯" })
        precondition(merged.contains { $0.canonical == "时间复杂度" })
        precondition(!merged.contains { $0.canonical == "翻译" })

        precondition(failures == 0, "\(failures) vocabulary cases failed")
        print("PASS: vocabulary entries/aliases, pinyin (toned canonical, toneless alias), Latin fuzzy spelling, built-in glossary")
    }
}
