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
        precondition(F.Options().isIdentity && F.apply("发到main分支。", F.Options()) == "发到main分支。")
        print("PASS: dictation format: final stop, spacing between scripts, defaults")
    }
}
