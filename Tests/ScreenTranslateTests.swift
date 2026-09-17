import Carbon.HIToolbox
import Foundation

@main struct ScreenTranslateTests {
    static func main() {
        // Dense prose: preserve natural paragraph gaps despite OCR ink-height
        // jitter, and share a body font instead of amplifying per-line errors.
        let prose = (0..<24).map { index in
            ScreenOCRLine(text: "A sufficiently long body sentence about sequence models and their representations.",
                visionBox: CGRect(x: 0.17, y: 0.9 - CGFloat(index) * 0.018 - CGFloat(index / 6) * 0.010,
                    width: 0.65, height: index < 6 ? 0.016 : 0.013))
        }
        precondition(ScreenTranslate.isDocument(prose))
        precondition(!ScreenTranslate.isDocument(Array(prose.prefix(12))), "Chat-sized groups keep their existing path")
        var narrow = prose
        for i in narrow.indices { narrow[i].visionBox.size.width = 0.25 }
        precondition(!ScreenTranslate.isDocument(narrow), "Multi-column feeds keep their existing path")
        var documentParagraphs = ScreenTranslate.groupParagraphs(from: prose, canvasSize: CGSize(width: 800, height: 1000))
        precondition(documentParagraphs.count == 4, "Paragraph spacing separates four natural paragraphs")
        let bodyFonts = ScreenTranslate.paragraphFonts(documentParagraphs, canvasSize: CGSize(width: 800, height: 1000))
        precondition(bodyFonts.max()! - bodyFonts.min()! < 0.01, "Same document body style has one font size")
        for i in documentParagraphs.indices { documentParagraphs[i].translation = "这是论文正文段落。" }
        let documentPlates = ScreenTranslate.layoutPlates(documentParagraphs, canvasSize: CGSize(width: 800, height: 1000))
        precondition(documentPlates.allSatisfy(\.preservesColumnWidth), "Document blocks retain the source column width")
        let quantity = ScreenOCRLine(text: "6 months of ChatGPT Pro, which includes Codex",
            visionBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.02))
        precondition(!ScreenTranslate.groupParagraphs(from: [quantity])[0].isHeading,
            "A quantity at body size must not acquire heading weight")
        var bullet = quantity
        bullet.startsListItem = true
        var secondBullet = ScreenOCRLine(text: "Conditional access to Codex Security",
            visionBox: CGRect(x: 0.1, y: 0.765, width: 0.5, height: 0.02))
        secondBullet.startsListItem = true
        precondition(!ScreenTranslate.canJoinParagraph(previous: bullet, next: secondBullet),
            "Adjacent bullet items remain separate even with a small gap")
        let continuation = ScreenOCRLine(text: "for eligible maintainers", visionBox: CGRect(x: 0.1, y: 0.74, width: 0.4, height: 0.02))
        precondition(ScreenTranslate.canJoinParagraph(previous: secondBullet, next: continuation),
            "A wrapped continuation stays with its bullet item")
        var cache = ScreenTranslationCache()
        precondition(cache.missing(["Post", "Post", "Home"], direction: "en-zh") == ["Post", "Home"])
        cache.store("Post", translation: "发布", direction: "en-zh")
        precondition(cache.missing(["Post"], direction: "en-zh").isEmpty)
        precondition(cache.value("Post", direction: "zh-en") == nil)
        for i in 0..<600 { cache.store("item-\(i)", translation: "结果", direction: "en-zh") }
        precondition(cache.value("Post", direction: "en-zh") == nil, "Session cache is bounded")
        // Same physical lines on canvases with very different aspect ratios.
        func physicalLine(_ text: String, _ rect: CGRect, _ size: CGSize) -> ScreenOCRLine {
            ScreenOCRLine(text: text, visionBox: CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                width: rect.width / size.width, height: rect.height / size.height))
        }
        for size in [CGSize(width: 300, height: 1000), CGSize(width: 2000, height: 500)] {
            let first = physicalLine("A body sentence that wraps", CGRect(x: 10, y: 100, width: 230, height: 16), size)
            let next = physicalLine("onto the next line", CGRect(x: 10, y: 80, width: 180, height: 16), size)
            precondition(ScreenTranslate.canJoinParagraph(previous: first, next: next, canvasSize: size))
            let otherColumn = physicalLine("another column", CGRect(x: 280, y: 80, width: 200, height: 16), size)
            precondition(!ScreenTranslate.canJoinParagraph(previous: first, next: otherColumn, canvasSize: size))
        }
        let gutterUpper = CGRect(x: 20, y: 20, width: 200, height: 20)
        let gutterLower = CGRect(x: 20, y: 60, width: 200, height: 20)
        let aRegion = ScreenTranslate.boundedViewport(source: gutterUpper,
            proposed: CGRect(x: 20, y: 10, width: 240, height: 60), neighbors: [gutterUpper, gutterLower])
        let bRegion = ScreenTranslate.boundedViewport(source: gutterLower,
            proposed: CGRect(x: 20, y: 30, width: 240, height: 60), neighbors: [gutterUpper, gutterLower])
        precondition(aRegion.maxY <= bRegion.minY, "Two paragraphs cannot own the same empty gutter")
        var collisionBlocks: [ScreenLaidOutBlock] = []
        for i in 0..<60 {
            let rect = CGRect(x: CGFloat((i % 6) * 35), y: CGFloat((i / 6) * 22), width: 32, height: 18)
            collisionBlocks.append(ScreenLaidOutBlock(text: "完整译文保留", rect: rect.insetBy(dx: -15, dy: -12),
                sourceRect: rect, fontSize: 12, isHeading: false))
        }
        // Include malformed overlapping/duplicate OCR source rectangles.
        collisionBlocks.append(collisionBlocks[0])
        let collisionFree = ScreenTranslate.nonOverlapping(collisionBlocks)
        for i in collisionFree.indices {
            for j in collisionFree.indices where j > i {
                let hit = collisionFree[i].rect.intersection(collisionFree[j].rect)
                precondition(hit.isNull || hit.width <= 0 || hit.height <= 0, "Final overlays must NEVER overlap")
            }
            precondition(collisionFree[i].text == collisionBlocks[i].text, "Suppressed overlays retain their full text")
        }
        precondition(ScreenTranslate.nonOverlapping(collisionFree) == collisionFree, "Copy must preserve resolved layout")
        let contextParagraphs = (0..<20).map { i in
            ScreenParagraph(original: "source-\(i)", translation: "draft-\(i)",
                visionBox: CGRect(x: 0.1, y: CGFloat(i) * 0.04, width: 0.2, height: 0.02),
                lineHeight: 0.02, linePitch: 0.025, isHeading: false, lineCount: 1)
        }
        var navigation = Array(contextParagraphs.prefix(4))
        for (i, label) in ["Home", "Explore", "Profile", "Post"].enumerated() { navigation[i].original = label }
        precondition(ScreenTranslate.navigationTranslation(for: 3, paragraphs: navigation,
            canvasSize: CGSize(width: 1000, height: 800), source: .en, target: .zhHans) == "发布")
        precondition(ScreenTranslate.navigationTranslation(for: 0, paragraphs: [navigation[3]],
            canvasSize: CGSize(width: 1000, height: 800), source: .en, target: .zhHans) == nil,
            "A lone Post in prose must not receive a navigation override")
        navigation[3].visionBox.origin.x = 0.8
        precondition(ScreenTranslate.navigationTranslation(for: 3, paragraphs: navigation,
            canvasSize: CGSize(width: 1000, height: 800), source: .en, target: .zhHans) == nil,
            "Navigation labels in another column are not evidence for this text")
        let context = ScreenTranslate.translationContext(for: 0, paragraphs: contextParagraphs)
        precondition(context.hasPrefix("source-1\n\nsource-2"))
        precondition(!context.contains("source-0") && !context.contains("draft-"))
        precondition(context.components(separatedBy: "\n\n").count == 12)
        var largeContext = contextParagraphs
        for i in largeContext.indices { largeContext[i].original = String(repeating: "界", count: 2_000) }
        precondition(ScreenTranslate.translationContext(for: 0, paragraphs: largeContext).utf8.count <= 4_000)
        precondition(ScreenTranslate.translationContext(for: -1, paragraphs: contextParagraphs).isEmpty)
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
        let voiceAfter = TranslationDirection(source: a, target: a)
        precondition(voiceAfter != current)
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

        let lines = [
            ScreenOCRLine(text: "Hello", visionBox: CGRect(x: 0, y: 0.5, width: 1, height: 0.2)),
            ScreenOCRLine(text: "World", visionBox: CGRect(x: 0, y: 0.2, width: 1, height: 0.2))
        ]
        let mapped = ScreenTranslate.assignTranslations(to: lines, translated: "你好\n世界")
        precondition(mapped?[0].translation == "你好")
        precondition(mapped?[1].translation == "世界")
        precondition(ScreenTranslate.assignTranslations(to: lines, translated: "你好世界") == nil)

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

        let fragments = ScreenTranslate.mergeFragments([
            ScreenOCRLine(text: "Hello", visionBox: CGRect(x: 0.10, y: 0.50, width: 0.30, height: 0.04)),
            ScreenOCRLine(text: "there", visionBox: CGRect(x: 0.42, y: 0.50, width: 0.20, height: 0.04)),
            ScreenOCRLine(text: "Next", visionBox: CGRect(x: 0.10, y: 0.30, width: 0.50, height: 0.04))
        ])
        precondition(fragments.count == 2, "Same-row fragments merge; the next line stays separate")
        precondition(fragments[0].text.contains("Hello"))
        precondition(fragments[0].text.contains("there"))
        precondition(fragments[1].text == "Next")

        let columns = ScreenTranslate.mergeFragments([
            ScreenOCRLine(text: "Left", visionBox: CGRect(x: 0.05, y: 0.50, width: 0.30, height: 0.04)),
            ScreenOCRLine(text: "Right", visionBox: CGRect(x: 0.60, y: 0.50, width: 0.30, height: 0.04))
        ])
        precondition(columns.count == 2, "Two columns on one baseline must not merge")

        precondition(ScreenTranslate.isMachineText("const foo = 1"))
        precondition(ScreenTranslate.isMachineText("function App() {"))
        precondition(ScreenTranslate.isMachineText("13"))
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
        precondition(("類似於單頭注意力".applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? "") == "类似于单头注意力")

        let wrap = ScreenOCRLine(text: "In encoder-decoder attention layers the queries come", visionBox: CGRect(x: 0.12, y: 0.50, width: 0.70, height: 0.04), translation: "第一行")
        let wrapCont = ScreenOCRLine(text: "from the previous decoder layer", visionBox: CGRect(x: 0.16, y: 0.44, width: 0.66, height: 0.04), translation: "续行")
        let wrapped = ScreenTranslate.groupParagraphs(from: [wrap, wrapCont])
        precondition(wrapped.count == 1, "Indented wrap lines stay in the same paragraph")

        let canvas = CGSize(width: 1000, height: 800)
        var first = ScreenOCRLine(text: "Hello there", visionBox: CGRect(x: 0.1, y: 0.62, width: 0.7, height: 0.04))
        first.translation = "你好"
        var second = ScreenOCRLine(text: "friends", visionBox: CGRect(x: 0.1, y: 0.56, width: 0.7, height: 0.04))
        second.translation = "朋友们"
        let grouped = ScreenTranslate.groupParagraphs(from: [first, second])
        precondition(grouped.count == 1, "Adjacent body lines become one paragraph")
        precondition(grouped[0].original == "Hello there friends")
        precondition(grouped[0].translation == "你好朋友们")
        let plates = ScreenTranslate.layoutPlates([first, second], canvasSize: canvas)
        precondition(plates.count == 1, "A paragraph is pasted as one block")
        let unionBox = ScreenTranslate.topLeftRect(
            visionBox: first.visionBox.union(second.visionBox),
            canvasSize: canvas
        )
        precondition(abs(plates[0].rect.minX - unionBox.minX) < 1.5)

        var heading = ScreenOCRLine(text: "3.3 Title", visionBox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.08))
        heading.translation = "3.3 位置前馈网络"
        var body = ScreenOCRLine(text: "Body text that is longer than a title", visionBox: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.035))
        body.translation = "比标题更长的正文"
        let sized = ScreenTranslate.layoutPlates([heading, body], canvasSize: canvas)
        precondition(sized.count == 2)
        precondition(sized[0].fontSize > sized[1].fontSize, "A taller source line keeps a larger font")

        var jitterA = ScreenOCRLine(text: "Same body size", visionBox: CGRect(x: 0.1, y: 0.50, width: 0.7, height: 0.040))
        jitterA.translation = "甲"
        var jitterB = ScreenOCRLine(text: "Also body size", visionBox: CGRect(x: 0.1, y: 0.455, width: 0.7, height: 0.032))
        jitterB.translation = "乙"
        var jitterC = ScreenOCRLine(text: "Still body size", visionBox: CGRect(x: 0.1, y: 0.40, width: 0.7, height: 0.051))
        jitterC.translation = "丙"
        let jittered = ScreenTranslate.layoutPlates([jitterA, jitterB, jitterC], canvasSize: canvas)
        precondition(jittered.count == 1, "Consecutive body lines share one paragraph plate")

        var numbered = ScreenOCRLine(text: "2 Background", visionBox: CGRect(x: 0.1, y: 0.80, width: 0.4, height: 0.040))
        numbered.translation = "2 背景"
        var numberedBody = ScreenOCRLine(text: "Body next to a section title", visionBox: CGRect(x: 0.1, y: 0.70, width: 0.7, height: 0.039))
        numberedBody.translation = "紧挨着标题的正文"
        let numberedPlates = ScreenTranslate.layoutPlates([numbered, numberedBody], canvasSize: canvas)
        precondition(numberedPlates.count == 2, "A section title stays its own block")
        precondition(abs(numberedPlates[0].fontSize - numberedPlates[1].fontSize) < 0.35, "A same-size section title must not jump up")

        let before = ScreenOCRLine(text: "Before the formula", visionBox: CGRect(x: 0.1, y: 0.50, width: 0.7, height: 0.04), translation: "公式前")
        let formula = ScreenOCRLine(text: "FFN(x) = max(0, x)", visionBox: CGRect(x: 0.1, y: 0.44, width: 0.5, height: 0.04))
        let after = ScreenOCRLine(text: "After the formula", visionBox: CGRect(x: 0.1, y: 0.38, width: 0.7, height: 0.04), translation: "公式后")
        let split = ScreenTranslate.groupParagraphs(from: [before, formula, after])
        precondition(split.count == 2, "A formula splits the paragraph")
        precondition(split[0].original == "Before the formula")
        precondition(split[1].original == "After the formula")

        var equation = ScreenOCRLine(text: "where head_i = Attention(QW", visionBox: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.04))
        equation.translation = "公式"
        precondition(ScreenTranslate.layoutPlates([equation], canvasSize: canvas).isEmpty, "Displayed equations stay as original pixels")

        let navA = ScreenOCRLine(text: "Home", visionBox: CGRect(x: 0.04, y: 0.80, width: 0.12, height: 0.03), translation: "家")
        let navB = ScreenOCRLine(text: "Explore", visionBox: CGRect(x: 0.04, y: 0.74, width: 0.12, height: 0.03), translation: "探索")
        let nav = ScreenTranslate.groupParagraphs(from: [navA, navB])
        precondition(nav.count == 2, "Short sidebar labels stay separate")

        let wrappedRail = ScreenOCRLine(
            text: "Fans Share Stunning Close-Up Concert Footage",
            visionBox: CGRect(x: 0.72, y: 0.40, width: 0.22, height: 0.12),
            translation: "粉丝分享特写音乐会画面"
        )
        let railBody = ScreenOCRLine(
            text: "Trending now in entertainment with many posts",
            visionBox: CGRect(x: 0.72, y: 0.24, width: 0.22, height: 0.04),
            translation: "娱乐趋势"
        )
        let rail = ScreenTranslate.layoutPlates([wrappedRail, railBody], canvasSize: canvas)
        precondition(rail.count == 2)
        precondition(abs(rail[0].fontSize - rail[1].fontSize) < 1.2, "A wrapped narrow column is body text, not a title")

        let upper = CGRect(x: 10, y: 10, width: 80, height: 12)
        let lower = CGRect(x: 10, y: 22, width: 80, height: 12)
        let flush = ScreenTranslate.padLimits(box: upper, obstacles: [upper, lower])
        precondition(flush.y < 0.6, "Do not expand a plate into the next OCR line")
        let gapped = CGRect(x: 10, y: 40, width: 80, height: 12)
        let room = ScreenTranslate.padLimits(box: upper, obstacles: [upper, gapped])
        precondition(room.y >= 7, "Pad into empty space between distant lines")

        var code = ScreenOCRLine(text: "const foo = 1", visionBox: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.04))
        code.translation = "常量 foo = 1"
        precondition(ScreenTranslate.layoutPlates([code], canvasSize: canvas).isEmpty, "Code stays as original pixels")

        let weak = ScreenOCRLine(text: "Hello", visionBox: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.04), translation: "你好", confidence: 0.1)
        precondition(ScreenTranslate.layoutPlates([weak], canvasSize: canvas).isEmpty, "Low-confidence OCR is left alone")

        var longLine = ScreenOCRLine(
            text: "Hello there friends",
            visionBox: CGRect(x: 0.1, y: 0.72, width: 0.18, height: 0.04)
        )
        longLine.translation = "这是一段明显更长的译文，需要在原框里换行并往下撑开，不能盖住下一行。"
        var nextLine = ScreenOCRLine(
            text: "Next",
            visionBox: CGRect(x: 0.1, y: 0.62, width: 0.18, height: 0.04)
        )
        nextLine.translation = "下一行"
        let stacked = ScreenTranslate.layoutPlates([longLine, nextLine], canvasSize: canvas)
        precondition(stacked.count == 2)
        let nextBox = ScreenTranslate.topLeftRect(visionBox: nextLine.visionBox, canvasSize: canvas)
        precondition(stacked[0].rect.maxY <= stacked[1].rect.minY, "A long translation must not cover the next line")
        precondition(stacked[1].rect.minY == nextBox.minY, "Later lines keep their source anchors")

        precondition(abs(stacked[0].fontSize - stacked[1].fontSize) < 0.01,
            "Translation length must never change the font")
        let right = ScreenLaidOutBlock(text: "Right column", rect: CGRect(x: 600, y: 240, width: 200, height: 30), fontSize: 20, isHeading: false)
        let flowedColumns = ScreenTranslate.expandAndStack([stacked[0], right])
        precondition(flowedColumns[1].rect.minY == right.rect.minY, "Independent columns do not move together")
        precondition(stacked[0].textContentHeight > stacked[0].rect.height, "Overflow has a scrollable text document")
        let shortPara = ScreenOCRLine(text: "A short English line that becomes even shorter.", visionBox: CGRect(x: 0.1, y: 0.50, width: 0.7, height: 0.12), translation: "很短")
        let headingAfter = ScreenOCRLine(text: "3.3 Next Section Title Here", visionBox: CGRect(x: 0.1, y: 0.30, width: 0.5, height: 0.08), translation: "3.3 下一节")
        let packed = ScreenTranslate.layoutPlates([shortPara, headingAfter], canvasSize: canvas)
        let headingBox = ScreenTranslate.topLeftRect(visionBox: headingAfter.visionBox, canvasSize: canvas)
        precondition(packed.count == 2)
        precondition(abs((packed[1].rect.minY - packed[0].rect.maxY) - (headingBox.minY - packed[0].sourceRect.maxY)) < 1, "Reflow preserves the original gap between paragraphs")
        var bottomLong = ScreenOCRLine(
            text: "A translation near the bottom of the selection",
            visionBox: CGRect(x: 0.1, y: 0.02, width: 0.18, height: 0.04)
        )
        bottomLong.translation = "这是一段靠近选区底边的很长译文，可以在框内利用空隙，但不能把选区画布撑高。"
        let fixed = ScreenTranslate.layoutPlates([bottomLong], canvasSize: canvas)
        precondition(fixed.count == 1)
        precondition(fixed[0].rect.maxY <= canvas.height && fixed[0].textContentHeight > fixed[0].rect.height, "A bottom-edge translation scrolls without moving pixels")
        precondition(!fixed[0].isClipped, "Long translations remain complete")
        precondition(
            ScreenTranslate.contentHeight(items: fixed, canvasHeight: canvas.height) >= fixed[0].rect.maxY,
            "The document contains the complete translation"
        )

        let bodyParagraphs = [CGFloat(0.028), 0.037, 0.024].enumerated().map { index, height in
            ScreenParagraph(original: "Same body style with noisy OCR boxes", translation: index == 1 ? String(repeating: "很长的译文", count: 20) : "短译文",
                visionBox: CGRect(x: 0.1, y: 0.8 - CGFloat(index) * 0.2, width: 0.7, height: height),
                lineHeight: height, linePitch: height, isHeading: false, lineCount: 1)
        }
        let stableBody = ScreenTranslate.layoutPlates(bodyParagraphs, canvasSize: canvas)
        var shortenedBody = bodyParagraphs
        for index in shortenedBody.indices { shortenedBody[index].translation = "短" }
        let shortenedLayout = ScreenTranslate.layoutPlates(shortenedBody, canvasSize: canvas)
        precondition(stableBody.map(\.fontSize) == shortenedLayout.map(\.fontSize), "Translation length cannot affect source font estimates")

        let bubbleA = ScreenOCRLine(
            text: "First chat message on its own bubble",
            visionBox: CGRect(x: 0.40, y: 0.70, width: 0.48, height: 0.04),
            translation: "第一条"
        )
        let bubbleB = ScreenOCRLine(
            text: "Second chat message below it",
            visionBox: CGRect(x: 0.40, y: 0.58, width: 0.48, height: 0.04),
            translation: "第二条"
        )
        let bubbles = ScreenTranslate.groupParagraphs(from: [bubbleA, bubbleB])
        precondition(bubbles.count == 2, "A gap taller than a line is a new bubble, not a wrap")

        func placed(_ line: ScreenOCRLine, origin: CGPoint, scale: CGFloat) -> ScreenOCRLine {
            var next = line
            next.visionBox = CGRect(
                x: origin.x + line.visionBox.origin.x * scale,
                y: origin.y + line.visionBox.origin.y * scale,
                width: line.visionBox.width * scale,
                height: line.visionBox.height * scale
            )
            return next
        }
        let windowWrap = ScreenTranslate.groupParagraphs(from: [
            placed(wrap, origin: CGPoint(x: 0.38, y: 0.20), scale: 0.45),
            placed(wrapCont, origin: CGPoint(x: 0.38, y: 0.20), scale: 0.45)
        ])
        precondition(windowWrap.count == 1, "Wrap grouping must not depend on how much chrome is around the crop")

        let sidebar: [ScreenOCRLine] = (0..<12).map { index in
            ScreenOCRLine(
                text: "Sidebar row \(index) title",
                visionBox: CGRect(x: 0.02, y: 0.90 - CGFloat(index) * 0.06, width: 0.18, height: 0.018),
                translation: "侧栏\(index)"
            )
        }
        let chat = ScreenOCRLine(
            text: "A full chat bubble that is the actual body text",
            visionBox: CGRect(x: 0.40, y: 0.50, width: 0.50, height: 0.036),
            translation: "这是正文气泡"
        )
        let mixed = ScreenTranslate.layoutPlates(sidebar + [chat], canvasSize: canvas)
        let chatPlate = mixed.first { $0.text == "这是正文气泡" }
        precondition(chatPlate != nil)
        precondition(chatPlate!.fontSize > mixed[0].fontSize, "Small sidebar labels cannot set body size")

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

        print("PASS: screen shortcut, source font hierarchy, anchored overlays, and text overflow")
    }
}
