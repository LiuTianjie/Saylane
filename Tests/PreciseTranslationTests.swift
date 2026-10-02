import AppKit
import CoreText

/// The whole-screen request and what is made of the answer, with answers written
/// here instead of a model's: no endpoint, no network, no Keychain.
@main struct PreciseTranslationTests {
    typealias Item = PreciseTranslation.Item
    typealias Answer = PreciseTranslation.Answer

    /// Counts how many requests are under way at once.
    actor Gauge {
        var now = 0, most = 0, total = 0
        func enter() { now += 1; most = max(most, now); total += 1 }
        func leave() { now -= 1 }
    }

    /// A heading, a sentence, a button and two labels on white.
    static func picture(scale: CGFloat) -> CGImage {
        let width = 760.0, height = 360.0
        let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at origin: CGPoint) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]))
            context.textPosition = CGPoint(x: origin.x, y: (origin.y * scale).rounded() / scale)
            CTLineDraw(line, context)
        }
        let ink = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        draw("Privacy and security settings", size: 26, weight: .bold, color: ink, at: CGPoint(x: 40, y: 300))
        draw("Choose which applications may read the screen while you work.", size: 14, weight: .regular, color: ink, at: CGPoint(x: 40, y: 262))
        // A button that hugs its word.
        context.setFillColor(NSColor(srgbRed: 0.04, green: 0.48, blue: 1, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 40, y: 196, width: 72, height: 34), cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        draw("Share", size: 14, weight: .semibold, color: .white, at: CGPoint(x: 56, y: 208))
        draw("Drafts", size: 14, weight: .regular, color: ink, at: CGPoint(x: 40, y: 150))
        draw("Archive", size: 14, weight: .regular, color: ink, at: CGPoint(x: 40, y: 120))
        return context.makeImage()!
    }

    static func main() async throws {
        var passed = 0
        // Built with -O, where a failed precondition does not say which: say it first.
        func check(_ condition: Bool, _ what: String) {
            if !condition { FileHandle.standardError.write(Data("FAILED: \(what)\n".utf8)) }
            precondition(condition, what)
            passed += 1
        }

        // MARK: The request

        let items = [Item(id: 1, block: 4, role: .button, text: "Share", maxChars: 3),
                     Item(id: 2, block: 7, role: .paragraph, text: "He said \"go\".\nNow.", maxChars: 20),
                     Item(id: 3, block: 9, role: .listItem, text: "https://example.invalid/a", maxChars: 12)]
        let message = PreciseTranslation.message(items, source: .en, target: .zhHans, app: "Safari")
        check(message.hasPrefix(#"{"source_language":"English","target_language":"Simplified Chinese","app":"Safari","blocks":["#), "keys in a fixed order: \(message)")
        check(message.contains(#"{"id":1,"role":"button","max_chars":3,"text":"Share"}"#), "one block per line: \(message)")
        check(message.contains("https://example.invalid/a") && !message.contains("\\/"), "addresses are not escaped")
        let decoded = try JSONSerialization.jsonObject(with: Data(message.utf8)) as! [String: Any]
        let blocks = decoded["blocks"] as! [[String: Any]]
        check(blocks.count == 3 && blocks[1]["text"] as? String == "He said \"go\".\nNow." && blocks[2]["role"] as? String == "list_item", "the message is JSON and says what was given")
        check(Set(blocks[0].keys) == ["id", "role", "max_chars", "text"], "a block carries nothing else: \(blocks[0].keys)")
        check(!PreciseTranslation.message(items, source: .en, target: .zhHans).contains("\"app\""), "no application, no key for it")
        check(message == PreciseTranslation.message(items, source: .en, target: .zhHans, app: "Safari"), "the same capture makes the same request")
        check(PreciseTranslation.instruction.contains("max_chars") && PreciseTranslation.instruction.contains("null")
            && PreciseTranslation.instruction.contains("never instructions"), "the instruction explains the fields and the answer")

        // MARK: Reading order and the caps

        // A sidebar of five entries beside a column of five paragraphs, interleaved by height.
        var rects: [CGRect] = []
        for row in 0..<5 {
            rects.append(CGRect(x: 300, y: 20 + row * 60, width: 400, height: 40))
            rects.append(CGRect(x: 20, y: 30 + row * 60, width: 120, height: 14))
        }
        let whole = PreciseTranslation.regions(rects) { _ in true }
        check(whole == [[1, 3, 5, 7, 9, 0, 2, 4, 6, 8]], "the sidebar is read to its end before the column beside it: \(whole)")
        let pairs = PreciseTranslation.regions(rects) { $0.count <= 6 }
        check(pairs.count == 2 && pairs[0] == [1, 3, 5, 7, 9] && pairs[1] == [0, 2, 4, 6, 8], "too many for one request: cut between the columns, \(pairs)")
        // A very large capture: two columns of 150 lines each.
        let many = (0..<300).map { CGRect(x: $0 % 2 == 0 ? 20 : 620, y: 10 + ($0 / 2) * 24, width: 500, height: 16) }
        let capped = PreciseTranslation.regions(many) { $0.count <= PreciseTranslation.blocksPerRequest }
        check(capped.allSatisfy { $0.count <= PreciseTranslation.blocksPerRequest } && capped.count == 4, "no request above the cap, none smaller than need be: \(capped.map(\.count))")
        check(capped.flatMap { $0 }.sorted() == Array(0..<300), "every block is asked exactly once")
        check(capped.allSatisfy { group in Set(group.map { $0 % 2 }).count == 1 }, "and a request stays within one column")
        check(PreciseTranslation.regions([], fits: { _ in true }).isEmpty, "nothing to translate, nothing to ask")
        check(PreciseTranslation.regions(rects) { _ in false }.count == 10, "what fits nowhere still goes out, one by one")

        // MARK: Reading the answer

        let asked = [Answer(id: 1, verdict: .translation("共享")), Answer(id: 2, verdict: .keep), Answer(id: 3, verdict: .translation("直播"))]
        check(PreciseTranslation.parse(#"{"1": "共享", "2": null, "3": "直播"}"#) == asked, "the map that was asked for")
        check(PreciseTranslation.parse("```json\n{\"1\": \"共享\", \"2\": null, \"3\": \"直播\"}\n```") == asked, "in a fence")
        check(PreciseTranslation.parse("Sure! Here is the translation:\n{\"1\": \"共享\", \"2\": null, \"3\": \"直播\"}\nLet me know if you need anything else.") == asked, "with prose around it")
        check(PreciseTranslation.parse("<think>The screen is a mail client. {\"1\": \"份额\"} is wrong here.</think>\n{\"1\": \"共享\", \"2\": null, \"3\": \"直播\"}") == asked, "after thinking aloud")
        check(PreciseTranslation.parse(#"[{"id": 1, "text": "共享"}, {"id": 2, "keep": true}, {"id": "3", "translation": "直播"}]"#) == asked, "a list of objects instead")
        check(PreciseTranslation.parse(#"{"translations": [{"id": 1, "text": "共享"}, {"id": 2, "text": null}, {"id": 3, "text": "直播"}]}"#) == asked, "inside a wrapper")
        check(PreciseTranslation.parse(#"{"1": "共享", "2": null, "3": "直播",}"#) == asked, "a comma too many")
        check(PreciseTranslation.parse(#"{"1": "共享", "2": null, "3": "直播", "4": "还没写完的"#) == asked, "cut off in the middle of a value: what is complete counts")
        check(PreciseTranslation.parse(#"{"1": "共享", "2": null, "3": "直播""#) == asked, "cut off before the closing brace")
        check(PreciseTranslation.parse(#"[{"id": 1, "text": "共享"}, {"id": 2, "keep": true}, {"id": 3, "text": "直播"}, {"id": 4, "te"#) == asked, "a list cut off")
        check(PreciseTranslation.parse(#"{"1": {"text": "共享"}, "2": {"keep": true}, "3": "直播", "note": "done", "5": 12}"#) == asked, "values of the wrong shape are passed over")
        check(PreciseTranslation.parse(#"{"1": "他说 \"{好}\"", "2": null}"#) == [Answer(id: 1, verdict: .translation("他说 \"{好}\"")), Answer(id: 2, verdict: .keep)], "braces and quotes inside a translation")
        for nothing in ["", "I'm sorry, but I can't help with that.", "[]", "{}", "{\"error\": \"overloaded\"}", "[\"共享\", \"直播\"]", "{{{{", "null"] {
            check(PreciseTranslation.parse(nothing).isEmpty, "nothing usable in: \(nothing)")
        }

        // MARK: Judging it, block by block

        let screen = [Item(id: 1, block: 10, role: .button, text: "Share", maxChars: 3),
                      Item(id: 2, block: 11, role: .label, text: "GitHub", maxChars: 6),
                      Item(id: 3, block: 12, role: .button, text: "Live", maxChars: 2),
                      Item(id: 4, block: 13, role: .label, text: "Free", maxChars: 2),
                      Item(id: 5, block: 14, role: .paragraph, text: "Changes apply to this conversation only.", maxChars: 14),
                      Item(id: 6, block: 15, role: .label, text: "Slots", maxChars: 4)]
        func judged(_ content: String, _ items: [Item] = screen, from source: AppLanguage = .en, to target: AppLanguage = .zhHans) -> PreciseTranslation.Accepted {
            PreciseTranslation.accept(PreciseTranslation.parse(content), for: items, source: source, target: target)
        }
        var accepted = judged(#"{"1": "共享", "2": null, "3": "直播", "4": "免费", "5": "更改仅适用于此对话。", "6": "插槽"}"#)
        check(accepted.translations == [10: "共享", 12: "直播", 13: "免费", 14: "更改仅适用于此对话。", 15: "插槽"] && accepted.kept == [11] && accepted.rejected == 0 && accepted.long == 0, "a good answer is taken whole: \(accepted)")
        accepted = judged(#"{"1": "共享", "3": "直播"}"#)
        check(accepted.translations == [10: "共享", 12: "直播"] && accepted.kept.isEmpty && accepted.rejected == 0, "ids that were dropped are simply not there")
        accepted = judged(#"[{"id": 1, "text": "共享"}, {"id": 1, "text": "分享"}, {"id": 3, "text": ""}, {"id": 3, "text": "直播"}]"#)
        check(accepted.translations == [10: "共享", 12: "直播"] && accepted.rejected == 2, "an id said twice: the first good answer stands, \(accepted)")
        accepted = judged(#"{"1": "共享", "7": "多出来的", "0": "零", "99": null}"#)
        check(accepted.translations == [10: "共享"] && accepted.kept.isEmpty && accepted.rejected == 3, "ids that were not asked for are not used")
        accepted = judged(#"{"1": "Share", "2": "github", "3": "Live stream", "4": "  ", "6": "老虎机\n（赌场）"}"#)
        check(accepted.kept == [10, 11], "saying the source again is saying keep: \(accepted.kept)")
        check(accepted.translations == [15: "老虎机 （赌场）"] && accepted.rejected == 2, "no Chinese in it, or nothing at all, is not a translation; lines are joined: \(accepted)")
        accepted = judged(#"{"1": "共享这个对话给其他人，这样他们也可以看到并且参与进来，一起讨论里面的内容", "3": "现场直播"}"#)
        check(accepted.translations == [12: "现场直播"] && accepted.rejected == 1 && accepted.long == 1, "many times too long is no translation; a little too long is the fitter's business: \(accepted)")
        let chinese = [Item(id: 1, block: 3, role: .button, text: "发送", maxChars: 5), Item(id: 2, block: 4, role: .label, text: "微信", maxChars: 6),
                       Item(id: 3, block: 5, role: .paragraph, text: "更改仅适用于此对话。", maxChars: 30)]
        accepted = judged(#"{"1": "Send", "2": null, "3": "更改只适用于这个对话。"}"#, chinese, from: .zhHans, to: .en)
        check(accepted.translations == [3: "Send"] && accepted.kept == [4] && accepted.rejected == 1, "into English: an answer still in Chinese is not used, \(accepted)")
        accepted = judged(#"{"1": "Send", "2": "null", "3": "NULL"}"#, chinese, from: .zhHans, to: .en)
        check(accepted.translations == [3: "Send"] && accepted.kept == [4, 5], "null written as a word is still null: \(accepted)")
        accepted = judged(#"{"1": "Send (the button that sends the message to the other person)", "3": "Changes apply to this conversation only."}"#, chinese, from: .zhHans, to: .en)
        check(accepted.translations == [5: "Changes apply to this conversation only."] && accepted.rejected == 1 && accepted.long == 1, "an explanation instead of a word: \(accepted)")

        // MARK: Over the quick translation

        let quick = [10: "份额", 11: "GitHub 网站", 12: "过", 13: "未受困的", 14: "更改仅适用于此对话。", 15: "老虎机"]
        let merged = PreciseTranslation.merge(quick, judged(#"{"1": "共享", "2": null, "3": "直播", "4": "免费的免费的免费的免费的免费的免费的免费的免费的免费的免费的"}"#))
        check(merged == [10: "共享", 12: "直播", 13: "未受困的", 14: "更改仅适用于此对话。", 15: "老虎机"], "precise where it is good, quick where it is missing or bad, nothing where it says keep: \(merged)")
        check(PreciseTranslation.merge(quick, PreciseTranslation.Accepted()) == quick, "no answer: the quick translation as it was")

        // MARK: Sending: one request, several, late, failing

        let table: [String: String?] = ["Share": "共享", "GitHub": nil, "Live": "直播", "Free": "免费", "Slots": "插槽"]
        let seen = Gauge()
        let recorded = ScreenPreciseTranslator(transport: { system, user in
            precondition(system == PreciseTranslation.instruction && user.contains("\"blocks\""))
            await seen.enter()
            defer { Task { await seen.leave() } }
            return try await ScreenPreciseTranslator.canned(table)(system, user)
        })
        var outcome = await recorded.translate([screen], source: .en, target: .zhHans, app: "Mail")
        check(outcome.failure == nil && outcome.requests == 1 && outcome.accepted.translations == [10: "共享", 12: "直播", 13: "免费", 15: "插槽"]
            && outcome.accepted.kept == [11], "one request, answered from the table: \(outcome)")
        let sent = await seen.total
        check(sent == 1, "a capture within the caps is one request")
        check(await ScreenPreciseTranslator(transport: { _, _ in "{}" }).translate([], source: .en, target: .zhHans).requests == 0, "nothing to ask, nothing sent")

        // Seven requests, three at a time.
        let parts = (0..<7).map { part in [Item(id: part + 1, block: part, role: .label, text: "Share", maxChars: 3)] }
        let gauge = Gauge()
        let slow = ScreenPreciseTranslator(transport: { system, user in
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(60))
            await gauge.leave()
            return try await ScreenPreciseTranslator.canned(table)(system, user)
        })
        outcome = await slow.translate(parts, source: .en, target: .zhHans)
        let most = await gauge.most, total = await gauge.total
        check(outcome.failure == nil && outcome.accepted.translations.count == 7 && total == 7, "every part is asked and answered: \(outcome)")
        check(most == 3, "never more than three at once: \(most)")

        // The model takes too long: what has answered counts, the rest is not waited for.
        var late = ScreenPreciseTranslator(transport: { system, user in
            if user.contains("\"id\":2,") { try await Task.sleep(for: .seconds(20)) }
            return try await ScreenPreciseTranslator.canned(table)(system, user)
        })
        late.timeout = 0.3
        var started = Date()
        outcome = await late.translate(Array(parts[..<2]), source: .en, target: .zhHans)
        check(outcome.failure == .timeout && outcome.accepted.translations == [0: "共享"], "late: \(outcome)")
        check(Date().timeIntervalSince(started) < 3, "and the wait ends at the deadline, not when the model is done")
        late.timeout = 0.2
        outcome = await late.translate([parts[1]], source: .en, target: .zhHans)
        check(outcome.failure == .timeout && outcome.accepted.isEmpty, "nothing in time: \(outcome)")

        // The endpoint fails, refuses, or answers in prose.
        struct Refused: LocalizedError { var errorDescription: String? { "HTTP 401" } }
        outcome = await ScreenPreciseTranslator(transport: { _, _ in throw Refused() }).translate([screen], source: .en, target: .zhHans)
        check(outcome.failure == .endpoint("HTTP 401") && outcome.accepted.isEmpty, "an error from the endpoint: \(outcome)")
        outcome = await ScreenPreciseTranslator(transport: { _, _ in "I'm sorry, I can't help with that." }).translate([screen], source: .en, target: .zhHans)
        check(outcome.failure == .unusable && outcome.accepted.isEmpty, "a refusal in prose: \(outcome)")
        outcome = await ScreenPreciseTranslator(transport: { _, _ in #"{"1": "Share it", "3": "Live now"}"# }).translate([screen], source: .en, target: .zhHans)
        check(outcome.failure == .unusable && outcome.accepted.isEmpty && outcome.accepted.rejected == 2, "an answer in the wrong language: \(outcome)")
        // One part of several fails: the others are used, and the failure is still reported.
        outcome = await ScreenPreciseTranslator(transport: { system, user in
            if user.contains("\"id\":3,") { throw Refused() }
            return try await ScreenPreciseTranslator.canned(table)(system, user)
        }).translate(Array(parts[..<4]), source: .en, target: .zhHans)
        check(outcome.failure == .endpoint("HTTP 401") && outcome.accepted.translations == [0: "共享", 1: "共享", 3: "共享"], "one part fails: \(outcome)")

        // The pin is closed while the model is still writing: the request is cancelled with it.
        started = Date()
        let abandoned = Task { await ScreenPreciseTranslator(transport: { _, _ in
            try await Task.sleep(for: .seconds(20))
            return "{}"
        }).translate([screen], source: .en, target: .zhHans) }
        try await Task.sleep(for: .milliseconds(100))
        abandoned.cancel()
        outcome = await abandoned.value
        check(Date().timeIntervalSince(started) < 3 && outcome.accepted.isEmpty && outcome.failure == nil, "cancelled: no answer and nothing to report, \(outcome)")

        // MARK: From the pixels: roles and how much fits

        for scale in [1.0, 2.0] as [CGFloat] {
            let label = "@\(Int(scale))x"
            guard let analysis = try ScreenPipeline.analyze(picture(scale: scale), scale: scale, source: .en, target: .zhHans) else { fatalError("no analysis") }
            let requests = PreciseTranslation.requests(analysis.blocks, scale: scale, target: .zhHans)
            check(requests.count == 1, "\(label) one request")
            let found = requests[0]
            func item(_ word: String) -> Item {
                guard let item = found.first(where: { $0.text.contains(word) }) else { fatalError("\(label): \(word) not in \(found.map(\.text))") }
                return item
            }
            check(found.map(\.id) == Array(1...found.count), "\(label) ids count up in reading order")
            check(found.map(\.text) == ["Privacy and security settings", "Choose which applications may read the screen while you work.", "Share", "Drafts", "Archive"],
                  "\(label) reading order: \(found.map(\.text))")
            check(item("Privacy").role == .heading && item("Choose").role == .paragraph && item("Share").role == .button
                && item("Drafts").role == .label && item("Archive").role == .label, "\(label) roles: \(found.map { "\($0.text.prefix(8)) \($0.role.rawValue)" })")
            // The button is 72 points wide with 14-point type: its own word and a little of its padding.
            check((3...4).contains(item("Share").maxChars), "\(label) the button holds \(item("Share").maxChars) Han characters")
            check(item("Drafts").maxChars > 30, "\(label) a label with the page to its right has room: \(item("Drafts").maxChars)")
            // What max_chars promises, the fitter keeps: that many characters at the original size in
            // the original lines; clearly more, and it has to shrink, wrap or cut.
            for item in found {
                var block = analysis.blocks[item.block]
                block.translation = String(repeating: "字", count: item.maxChars)
                let fits = Fitter.place(block, scale: scale)
                check(fits.shrink == 1 && fits.addedLines == 0 && !fits.truncated, "\(label) \(item.maxChars) Han characters fit where “\(item.text.prefix(12))” was")
                block.translation = String(repeating: "字", count: item.maxChars * 2 + 2)
                let over = Fitter.place(block, scale: scale)
                check(over.shrink < 1 || over.addedLines > 0 || over.truncated, "\(label) twice as many do not")
            }
            // The same blocks, were they to become English: characters are narrower, so more of them fit.
            let latin = Fitter.capacity(analysis.blocks[item("Share").block], scale: scale, fullWidth: false)
            check((6...9).contains(latin), "\(label) the button holds about \(latin) Latin characters")
            var button = analysis.blocks[item("Share").block]
            button.translation = "Teilen"
            check(Fitter.place(button, scale: scale).shrink == 1, "\(label) a word of six letters fits it")
            button.translation = "Weiterleiten"
            let crowded = Fitter.place(button, scale: scale)
            check(crowded.shrink < 1 || crowded.addedLines > 0, "\(label) one of twelve does not: it is set smaller or broken")
            // What only the pipeline can know about a block decides its role.
            var block = analysis.blocks[item("Drafts").block]
            let body = PreciseTranslation.bodySize(analysis.blocks)
            check(abs(body - 14) < 1, "\(label) body size \(body)")
            block.background = .complex(typical: RGB(r: 40, g: 60, b: 80))
            check(PreciseTranslation.role(of: block, scale: scale, body: body) == .caption, "\(label) over a picture: a caption")
            block = analysis.blocks[item("Drafts").block]
            block.lines[0].startsListItem = true
            check(PreciseTranslation.role(of: block, scale: scale, body: body) == .listItem, "\(label) after a bullet: a list item")
            // Through the whole path with a table for a model, then into the picture.
            let translator = ScreenPreciseTranslator(transport: ScreenPreciseTranslator.canned(["Share": "共享", "Drafts": "草稿", "Archive": nil]))
            let answer = await translator.translate(requests, source: .en, target: .zhHans)
            let apple = [item("Privacy").block: "隐私与安全设置", item("Share").block: "份额", item("Drafts").block: "汇票", item("Archive").block: "档案"]
            let translations = PreciseTranslation.merge(apple, answer.accepted)
            let composed = ScreenPipeline.compose(analysis, translations: translations)
            check(Set(composed.placed.map(\.index)) == [item("Privacy").block, item("Share").block, item("Drafts").block], "\(label) placed: heading (quick), button and label (precise); the kept one is not")
            check(composed.blocks[item("Share").block].translation == "共享" && composed.blocks[item("Privacy").block].translation == "隐私与安全设置", "\(label) the words that were set")
            let kept = analysis.blocks[item("Archive").block].rect
            var same = true
            for y in Int(kept.minY)...Int(kept.maxY) { for x in Int(kept.minX)...Int(kept.maxX) where composed.pixels[x, y] != analysis.pixels[x, y] { same = false } }
            check(same, "\(label) what is kept keeps its pixels")
        }

        print("PreciseTranslationTests: \(passed) checks passed; no network requests")
    }
}
