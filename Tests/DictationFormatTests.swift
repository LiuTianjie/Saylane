import Foundation

@main struct DictationFormatTests {
    static func main() {
        typealias F = DictationFormat
        // The full stop at the very end goes; a question, an exclamation, an ellipsis and inner stops stay.
        precondition(F.withoutFinalStop("我们明天见。") == "我们明天见")
        precondition(F.withoutFinalStop("See you tomorrow.") == "See you tomorrow")
        precondition(F.withoutFinalStop("好。我们明天见。 ") == "好。我们明天见")
        precondition(F.withoutFinalStop("真的吗？") == "真的吗？" && F.withoutFinalStop("太好了！") == "太好了！")
        precondition(F.withoutFinalStop("等等...") == "等等..." && F.withoutFinalStop("") == "")
        // A space where Chinese meets Latin letters or digits, and nowhere else.
        precondition(F.spaced("用GitHub提交3个文件") == "用 GitHub 提交 3 个文件")
        precondition(F.spaced("已经有 空格 了") == "已经有 空格 了" && F.spaced("hello world 123") == "hello world 123")
        precondition(F.spaced("中文，English。") == "中文，English。", "punctuation separates already")
        // Together, and off by default.
        let both = F.Options(dropFinalStop: true, spaceBetweenScripts: true)
        precondition(F.apply("发到main分支。", both) == "发到 main 分支")
        precondition(F.apply("发到main分支。", F.Options()) == "发到main分支。")
        // Off means none, whatever the recognizer wrote: the same sentence is not spaced one time and tight the next.
        precondition(F.apply("我用 ChatGPT 和 OpenAI 的接口，写了 3 个文件。", F.Options()) == "我用ChatGPT和OpenAI的接口，写了3个文件。")
        precondition(F.apply("我用 iPhone和 MacBook都连不上", F.Options()) == "我用iPhone和MacBook都连不上")
        precondition(F.apply("Notion 里有文档， Slack 里说一声", F.Options()) == "Notion里有文档，Slack里说一声")
        // Spaces between Latin words are part of how they are written.
        precondition(F.apply("我的iPhone 15 Pro和VS Code，run make verify 就行", F.Options()) == "我的iPhone 15 Pro和VS Code，run make verify就行")
        precondition(F.apply("Hello world, this is a test.", F.Options()) == "Hello world, this is a test.")
        // On means one everywhere, also where the recognizer wrote none or only half.
        precondition(F.apply("我用 iPhone和MacBook， Slack里说", F.Options(spaceBetweenScripts: true)) == "我用 iPhone 和 MacBook，Slack 里说")
        print("PASS: dictation format: final stop, spacing between scripts, defaults")
    }
}
