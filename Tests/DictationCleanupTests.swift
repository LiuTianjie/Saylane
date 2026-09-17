import Foundation

@main struct DictationCleanupTests {
    static var failures = 0

    static func expect(_ input: String, _ expected: String, options: DictationCleanup.Options = .all, line: Int = #line) {
        let actual = DictationCleanup.clean(input, options: options)
        if actual != expected {
            failures += 1
            print("FAIL line \(line): \(input)\n  expected: \(expected)\n  actual:   \(actual)")
        }
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        // Punctuation normalization
        expect("你好 世界 ,今天 天气不错 .", "你好世界，今天天气不错。")
        expect("我用 iPhone 拍照，效果不错", "我用 iPhone 拍照，效果不错")
        expect("好的，，那就这样。。", "好的，那就这样。")
        expect("，我先走了，", "我先走了")
        expect("send it to john@gmail.com please", "Send it to john@gmail.com please")
        expect("hello ,world", "Hello, world")
        expect("版本是 3.5 不是 3.6", "版本是 3.5 不是 3.6")

        // Fillers
        expect("嗯，我想明天再说", "我想明天再说")
        expect("呃嗯，那个，我们下午开会", "我们下午开会")
        expect("额度不够了", "额度不够了")
        expect("这个方案不错", "这个方案不错")
        expect("那个东西放哪了", "那个东西放哪了")
        expect("好啊", "好啊")
        expect("啊，对了，记得带伞", "对了，记得带伞")
        expect("就是说，我们需要更多时间", "我们需要更多时间")
        expect("Um, so I think we should, uh, wait.", "So I think we should wait.")
        expect("It is 5 mm wide, er, 6 mm.", "It is 5 mm wide 6 mm.")
        expect("erase the board", "Erase the board")

        // Stutters
        expect("我我我想说的是这个", "我想说的是这个")
        expect("我，我想去", "我想去")
        expect("我们我们明天见", "我们明天见")
        expect("然后，然后我们就走了", "然后我们就走了")
        expect("看看这个，谢谢", "看看这个，谢谢")
        expect("他他们来了", "他们来了")
        expect("好，好的", "好的")
        expect("研究研究再说", "研究研究再说")
        expect("他在在线会议里", "他在在线会议里")
        expect("就就业问题聊聊", "就就业问题聊聊")
        expect("哈哈哈太好笑了", "哈哈哈太好笑了")
        expect("一个一个来，什么什么的", "一个一个来，什么什么的")
        expect("对对对，就是这样", "对，就是这样")
        expect("他说的不对，我是说他说的不全对", "他说的不全对")
        expect("我是说真的", "我是说真的")
        expect("the the meeting is at noon", "The meeting is at noon")
        expect("I, I think that that is fine", "I think that that is fine")
        expect("no no no, not that one", "No, not that one")
        expect("he had had enough", "He had had enough")

        // Self-correction: retraction + restated clause
        expect("我明天去北京，不对，去上海", "我明天去上海")
        expect("我明天去北京，不对，我是说上海", "我明天去上海")
        expect("我明天去北京，不对不对，是上海，然后开会", "我明天去上海，然后开会")
        expect("发给张三，说错了，发给李四", "发给李四")
        expect("三点开会，不对，四点", "四点开会")
        expect("今天天气很好，不对，不好", "今天天气不好")
        expect("我要一杯咖啡，不对，两杯", "我要两杯咖啡")
        expect("我买了三本书，不对，五本", "我买了五本书")
        expect("明天下午三点，不对，四点半开会", "明天下午四点半开会")
        expect("预算是 500，不对，800 万", "预算是 800 万")
        expect("我今天下午三点要去开会，不对，四点半", "我今天下午四点半要去开会")
        expect("我买了三本，不对，五个", "我买了五个")
        expect("把温度调到二十六度，不是二十六，是二十四度", "把温度调到二十四度")
        expect("北京，不对，我是说上海", "上海")
        expect("我明天去北京，不对，我后天去上海", "我后天去上海")
        expect("我明天去北京，不对我是说上海", "我明天去上海")
        expect("第一步先备份，第二步再升级，不对，第二步先测试，第三步再升级", "第一步先备份，第二步先测试，第三步再升级")
        expect("这个图形是不对称的", "这个图形是不对称的")
        expect("这个答案不对，我们再看看", "这个答案不对，我们再看看")
        expect("我觉得不对劲", "我觉得不对劲")
        // A dangling retraction (live hypothesis mid-sentence) waits for the restatement.
        expect("我明天去北京，不对，", "我明天去北京，不对")
        expect("不对，你听我说", "不对，你听我说")
        expect("我是说明天再来", "我是说明天再来")
        expect("周三开会，不是周三，是周四", "周四开会")
        expect("周三开会，不是周三，是周四，记得提醒我", "周四开会，记得提醒我")
        expect("不是我，是他", "不是我，是他")
        expect("这是我的书，不是我的，而是他的", "这是他的书")

        // Self-correction in English
        expect("Let's meet on Monday, no, I mean Tuesday.", "Let's meet on Tuesday.")
        expect("Send it to John, sorry, I mean to Jane, before noon.", "Send it to Jane, before noon.")
        expect("The call is at 3 pm, scratch that, 4 pm.", "The call is at 4 pm.")
        expect("Hi John. Let's meet on Monday, I mean Tuesday.", "Hi John. Let's meet on Tuesday.")
        expect("You know what I mean, right?", "You know what I mean, right?")
        expect("I mean it.", "I mean it.")

        // Options off keeps text (apart from trimming)
        expect("嗯，我我想去北京，不对，上海", "嗯，我我想去北京，不对，上海",
               options: .init(fillers: false, stutters: false, selfCorrection: false, punctuation: false))

        // Merge helper edge cases
        precondition(DictationCleanup.merge(previous: "", correction: "上海", cjk: true) == "上海")
        precondition(DictationCleanup.merge(previous: "去北京", correction: "去北京", cjk: true) == "去北京")
        precondition(DictationCleanup.merge(previous: "send it to John", correction: "to Jane", cjk: false) == "send it to Jane")

        // Language detection
        precondition(DictationCleanup.isCJKDominant("我用 iPhone 和 MacBook"))
        precondition(!DictationCleanup.isCJKDominant("Open the 设置 panel please"))
        precondition(!DictationCleanup.isCJKDominant("hello"))

        precondition(failures == 0, "\(failures) dictation cleanup cases failed")
        print("PASS: dictation cleanup punctuation, fillers, stutters, self-correction (zh/en)")
    }
}
