import Foundation

@main struct LatinWritingTests {
    static func main() {
        var passed = 0
        func same(_ model: String, _ expected: String, system: String = "", line: UInt = #line) {
            let got = LatinWriting.tidied(model, system: system)
            precondition(got == expected, "line \(line): \(got)")
            passed += 1
        }
        // What the downloaded model wrote for letters said one by one (heard on device and with synthesized speech).
        same("我说A P P，它会把这个A P P三个字母给我拆开。", "我说APP，它会把这个APP三个字母给我拆开。")
        same("比如说，我说“a p p”，它会把这个“a p p”三个字母给我拆开。", "比如说，我说“APP”，它会把这个“APP”三个字母给我拆开。")
        same("我说：“A P P”，它会把这个A P P三个字母给我拆开。", "我说：“APP”，它会把这个APP三个字母给我拆开。")
        same("现在A I很火，我们的U I也要改一下。", "现在AI很火，我们的UI也要改一下。")
        same("我们利用 SQL 查数据库，再调 A P I。", "我们利用 SQL 查数据库，再调 API。")
        same("A P P", "APP"); same("O K，没问题。", "OK，没问题。")
        // Letters that already stand together, and letters with something between them, stay.
        same("这个APP的UI设计的不错。", "这个APP的UI设计的不错。")
        same("从A到B，选A、B都行。", "从A到B，选A、B都行。")
        same("M 1芯片和A 17", "M 1芯片和A 17")
        // In an English sentence a letter is also a word.
        same("Plan A is fine. I have a B plan too.", "Plan A is fine. I have a B plan too.")
        same("I think the A P I is ready and the U I works.", "I think the API is ready and the U I works.")
        same("I think the A P I is ready and the U I works.", "I think the API is ready and the UI works.", system: "I think the API is ready and the UI works")
        same("Plan A I think.", "Plan A I think.", system: "Plan A, I think")
        same("I have a B c plan.", "I have a B c plan.")
        // Names with a way of writing of their own.
        same("我用 Chat GPT 和 OpenAI 的接口写了一个 JavaScript 的小工具。", "我用 ChatGPT 和 OpenAI 的接口写了一个 JavaScript 的小工具。")
        same("你用 Git Hub 还是 Git Lab？", "你用 GitHub 还是 GitLab？")
        same("Mac OS升级之后，就这样。", "macOS升级之后，就这样。")
        same("用 Power Point 做一个 PPT。", "用 PowerPoint 做一个 PPT。")
        same("我们的 app 在 app store 上架了。", "我们的 app 在 App Store 上架了。")
        same("因为我们毕竟不是Web Socket，我的iphone和I O S都是新的。", "因为我们毕竟不是WebSocket，我的iPhone和iOS都是新的。")
        // English keeps its words: only the case of a name written in one piece is put right.
        same("We chat every day on wechat.", "We chat every day on WeChat.")
        same("My SQL query needs a power point.", "My SQL query needs a power point.")
        // Part of a longer word is not the name.
        same("用gpts和 github2 试试 chatgpt", "用gpts和 github2 试试 ChatGPT")
        same("", ""); same("没有字母。", "没有字母。")
        print("LatinWritingTests: \(passed) checks passed")
    }
}
