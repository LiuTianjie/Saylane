import Carbon.HIToolbox
import Foundation

@main struct ScreenTranslateTests {
    static func main() {
        var cache = ScreenTranslationCache()
        precondition(cache.missing(["Post", "Post", "Home"], direction: "en-zh") == ["Post", "Home"])
        cache.store("Post", translation: "发布", direction: "en-zh")
        precondition(cache.missing(["Post"], direction: "en-zh").isEmpty)
        precondition(cache.value("Post", direction: "zh-en") == nil)
        for i in 0..<600 { cache.store("item-\(i)", translation: "结果", direction: "en-zh") }
        precondition(cache.value("Post", direction: "en-zh") == nil, "Session cache is bounded")

        let optionT = ScreenCaptureShortcut.optionT
        precondition(optionT.displayName == "⌥T")
        precondition(optionT.matches(keyCode: UInt16(kVK_ANSI_T), flags: ScreenModifier.option))
        precondition(optionT.matches(keyCode: UInt16(kVK_ANSI_T), flags: ScreenModifier.option | (1 << 8)))
        precondition(optionT.matches(keyCode: UInt16(kVK_ANSI_T), flags: ScreenModifier.command) == false)
        precondition(optionT.matches(keyCode: UInt16(kVK_ANSI_S), flags: ScreenModifier.option) == false)
        let commandT = ScreenCaptureShortcut(keyCode: UInt16(kVK_ANSI_T), modifierFlags: ScreenModifier.command)
        precondition(commandT.displayName == "⌘T")
        precondition(commandT.isUsable)
        let bareT = ScreenCaptureShortcut(keyCode: UInt16(kVK_ANSI_T), modifierFlags: 0)
        precondition(bareT.isUsable == false)
        let f8 = ScreenCaptureShortcut(keyCode: UInt16(kVK_F8), modifierFlags: 0)
        precondition(f8.isUsable)
        precondition(f8.displayName == "F8")

        let a = AppLanguage.zhHans
        let b = AppLanguage.en
        let voice = TranslationDirection(source: a, target: a)
        let screen = ScreenTranslate.screenMode(current: voice, a: a, b: b)
        precondition(screen == TranslationDirection(source: b, target: a))
        precondition(ScreenTranslate.screenModes(a: a, b: b) == [
            TranslationDirection(source: b, target: a),
            TranslationDirection(source: a, target: b)
        ])
        var current = screen
        current = ScreenTranslate.cycled(current: current, a: a, b: b)
        precondition(current == TranslationDirection(source: a, target: b))
        current = ScreenTranslate.cycled(current: current, a: a, b: b)
        precondition(current == TranslationDirection(source: b, target: a))
        precondition(ScreenTranslate.screenMode(current: current, a: a, b: b) == current)

        precondition(ScreenTranslate.ocrLanguageHints(source: .en, target: .zhHans) == [
            "en-US", "en", "zh-CN", "zh-Hans"
        ], "Source language must stay first and deterministic")
        precondition(ScreenTranslate.ocrLanguageHints(source: .zhHans, target: .en) == [
            "zh-CN", "zh-Hans", "en-US", "en"
        ], "Reversing direction must also reverse OCR language priority")

        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 50)
        let captured = ScreenTranslate.captureSourceRect(appKitRect: rect, screenFrame: screenFrame)
        precondition(captured.origin.x == 100)
        precondition(captured.origin.y == 650)
        precondition(captured.width == 200)
        precondition(captured.height == 50)

        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let other = CGRect(x: 1540, y: 10, width: 100, height: 100)
        let flipped = ScreenTranslate.captureSourceRect(appKitRect: other, screenFrame: secondary)
        precondition(flipped.origin.x == 100)
        precondition(flipped.origin.y == 970)

        let cg = CGRect(x: 100, y: 100, width: 200, height: 50)
        let appKit = ScreenTranslate.appKitRect(fromCGWindowBounds: cg, mainDisplayHeight: 800)
        precondition(appKit.origin.x == 100)
        precondition(appKit.origin.y == 650)
        let front = ScreenTranslate.HoverCandidate(bounds: CGRect(x: 10, y: 10, width: 40, height: 40), owner: "front")
        let back = ScreenTranslate.HoverCandidate(bounds: CGRect(x: 0, y: 0, width: 400, height: 400), owner: "back")
        let hit = ScreenTranslate.topmostBounds(at: CGPoint(x: 20, y: 20), candidates: [front, back])
        precondition(hit == front.bounds)
        let miss = ScreenTranslate.topmostBounds(at: CGPoint(x: 300, y: 300), candidates: [front, back])
        precondition(miss == back.bounds)

        // What is text to translate, and what is left as it is.
        precondition(ScreenTranslate.isMachineText("const foo = 1"))
        precondition(ScreenTranslate.isMachineText("function App() {"))
        precondition(ScreenTranslate.isMachineText("13"))
        precondition(ScreenTranslate.shouldReplace("设置"))
        precondition(ScreenTranslate.shouldReplace("OK"))
        precondition(ScreenTranslate.shouldReplace("AI"))
        precondition(ScreenTranslate.isMachineText("FFN(x) = max(0, xW_1 + b_1)W_2 + b_2"))
        precondition(ScreenTranslate.shouldReplace("I feel like JS performance has been dragged down by React."))
        precondition(ScreenTranslate.shouldReplace("In this work we employ h = 8 parallel attention layers, or heads."))
        precondition(ScreenTranslate.shouldReplace("The Transformer uses multi-head attention in three different ways:"))
        precondition(ScreenTranslate.isEquationLike("where head_i = Attention(QW"))
        precondition(ScreenTranslate.isEquationLike("MultiHead(Q, K, V) = Concat(head1, ..., headh)W"))
        precondition(ScreenTranslate.isEquationLike("In this work we employ h = 8 parallel attention layers, or heads.") == false)
        precondition(ScreenTranslate.isEquationLike("ak = dr = Amodel/h= 64. Due to the reduced dimension of each head."))
        precondition(ScreenTranslate.shouldReplace("mation and softmax function to convert the decoder output to predicted next-token probabilities. In"))

        precondition(ScreenTranslate.joinParagraphLines(["transfor-", "mation of tokens"]) == "transformation of tokens")
        precondition(ScreenTranslate.joinParagraphLines(["Hello", "world"]) == "Hello world")
        precondition(ScreenTranslate.joinParagraphLines(["你好", "世界"]) == "你好世界")

        let origin = CGRect(x: 100, y: 200, width: 400, height: 300)
        let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
        let fitted = ScreenTranslate.visiblePinRect(
            content: CGSize(width: 400, height: 2000),
            originRect: origin,
            visible: visible
        )
        precondition(fitted.height < 600)
        precondition(fitted.maxY <= visible.maxY)
        precondition(fitted.minY >= visible.minY)
        let short = ScreenTranslate.visiblePinRect(
            content: CGSize(width: 400, height: 120),
            originRect: origin,
            visible: visible
        )
        precondition(abs(short.height - 120) < 1)
        precondition(abs(short.maxY - origin.maxY) < 1, "Short content keeps the original top edge")

        print("PASS: screen shortcut, directions, capture geometry, what counts as text, pin placement")
    }
}
