import Foundation

/// Deterministic, on-device post-processing for dictated text. No model, no network.
/// It runs on every live hypothesis and on the final utterance, so it must stay cheap
/// and must never invent content: it only drops fillers and stutters, applies the
/// speaker's own spoken corrections ("不对，我是说…" / "no, I mean…") and normalizes punctuation.
enum DictationCleanup {
    struct Options: Sendable {
        var fillers = true
        var stutters = true
        var selfCorrection = true
        var punctuation = true
        static let all = Options()
    }

    static func clean(_ text: String, options: Options = .all) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }
        let cjk = isCJKDominant(result)
        if options.punctuation { result = normalizePunctuation(result, cjk: cjk) }
        if options.fillers { result = removeFillers(result, cjk: cjk) }
        if options.stutters { result = collapseStutters(result, cjk: cjk) }
        if options.selfCorrection { result = applySelfCorrections(result, cjk: cjk) }
        if options.punctuation { result = normalizePunctuation(result, cjk: cjk) }
        if !cjk { result = capitalizeSentences(result) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Language

    static func isCJKDominant(_ text: String) -> Bool {
        var han = 0, latinWords = 0, inWord = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3040...0x30FF, 0xAC00...0xD7AF:
                han += 1; inWord = false
            case 0x41...0x5A, 0x61...0x7A:
                if !inWord { latinWords += 1; inWord = true }
            default: inWord = false
            }
        }
        // Compare CJK characters with Latin words: "我用 iPhone 和 MacBook" is still Chinese.
        return han > 0 && han >= latinWords
    }

    private static let clausePunctuation = "，。；！？、,.;!?\n"
    private static let clauseClass = "[，。；！？、,.;!?\\n]"

    // MARK: - Punctuation

    static func normalizePunctuation(_ text: String, cjk: Bool) -> String {
        var s = text
        if cjk {
            s = replace(s, "(?<=[\\p{Han}，。；！？、：])[ \\t]+(?=[\\p{Han}，。；！？、：])", "")
            s = replace(s, "(?<=\\p{Han})[ \\t]*,[ \\t]*(?=\\p{Han}|$)", "，")
            s = replace(s, "(?<=\\p{Han})[ \\t]*\\?[ \\t]*(?=\\p{Han}|$)", "？")
            s = replace(s, "(?<=\\p{Han})[ \\t]*![ \\t]*(?=\\p{Han}|$)", "！")
            s = replace(s, "(?<=\\p{Han})[ \\t]*;[ \\t]*(?=\\p{Han}|$)", "；")
            s = replace(s, "(?<=\\p{Han})[ \\t]*:[ \\t]*(?=\\p{Han}|$)", "：")
            s = replace(s, "(?<=\\p{Han})[ \\t]*\\.(?=\\p{Han}|$)", "。")
            // Dropped fillers and applied corrections leave doubled or mixed marks behind.
            s = replace(s, "[，、]+(?=[，。；！？、])", "")
            s = replace(s, "([。；！？])[，、]+", "$1")
            s = replace(s, "([，。；！？、])\\1+", "$1")
            s = replace(s, "^[，、；\\s]+", "")
            s = replace(s, "[，、；\\s]+$", "")
        } else {
            s = replace(s, "\\s+([,.;!?])", "$1")
            s = replace(s, "([,;])(?:\\s*\\1)+", "$1")
            s = replace(s, ",\\s*(?=[.!?])", "")
            s = replace(s, "([.!?])(?:\\s*[.!?])+", "$1")
            // Not after "." so dictated domains ("gmail.com") survive.
            s = replace(s, "(?<=[,;!?])(?=[A-Za-z])", " ")
            s = replace(s, "[ \\t]{2,}", " ")
            s = replace(s, "^[,;\\s]+", "")
            s = replace(s, "[,;\\s]+$", "")
        }
        return s
    }

    private static func capitalizeSentences(_ text: String) -> String {
        var s = text
        if let first = s.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first), first.isASCII {
            s = String(first).uppercased() + s.dropFirst()
        }
        return replace(s, "(?<=[.!?]\\s)([a-z])", "$1", transform: { $0.uppercased() })
    }

    // MARK: - Fillers

    private static let chineseFillers = [
        // Hesitation sounds that are never content when they start a clause.
        "(?:^|(?<=\(clauseClass)))[ \\t]*(?:嗯|呃|唔|呣)+[ \\t]*(?:[，,][ \\t]*)?",
        // Placeholders only when spoken as a standalone lead-in ("那个，我们…"); "额度" stays.
        "(?:^|(?<=\(clauseClass)))[ \\t]*(?:那个|这个|啊|哎|额)[ \\t]*[，,][ \\t]*",
        // Lead-ins that carry no meaning at clause start.
        "(?:^|(?<=\(clauseClass)))[ \\t]*(?:就是说|然后呢)[ \\t]*[，,][ \\t]*",
    ]

    // "I mean" is deliberately absent: it is the self-correction marker handled later.
    // The commas around a hesitation were inserted for the pause, so they go with it.
    private static let englishFillers = [
        "(?i)(?:^|,\\s*|\\s)(?:um+|uh+|uhm+|erm+|er|hmm+|ah+)(?:,\\s*|\\s+|(?=[.!?])|$)",
        "(?i)(?:^|(?<=[,.;!?]))\\s*(?:you know|like),\\s+",
    ]

    static func removeFillers(_ text: String, cjk: Bool) -> String {
        var s = text
        if cjk {
            for pattern in chineseFillers { s = replace(s, pattern, "") }
        } else {
            s = replace(s, englishFillers[0], " ")
            s = replace(s, englishFillers[1], "")
        }
        return s
    }

    // MARK: - Stutters

    // Words whose immediate repetition is a stutter, never emphasis ("一个一个", "什么什么" are excluded).
    private static let chineseStutterWords =
        "我们|你们|他们|她们|这个|那个|然后|就是|但是|因为|所以|如果|可以|应该|需要|可能|其实|现在|已经|还是|或者|比如|为什么|不是|没有|觉得|知道|这里|那里|这种|那种|这边|那边|反正|感觉|而且|不过|虽然|当然|刚才|今天|明天|昨天|我要|我想|我是|我有|你要|你想|你是"

    static func collapseStutters(_ text: String, cjk: Bool) -> String {
        var s = text
        if cjk {
            s = replace(s, "(\(chineseStutterWords))(?:[ \\t]*[，,、]?[ \\t]*\\1)+", "$1")
            // Three identical characters are a stutter, except laughter and interjections; two may be reduplication (看看, 谢谢).
            s = replace(s, "([\\p{Han}&&[^哈呵嘿嘻哦啊呀呜嘎咯]])\\1{2,}", "$1")
            // Pronouns never legitimately reduplicate ("在在线" and "就就业" do, so function words stay out).
            s = replace(s, "([我你他她它这那])(?:[ \\t]*[，,、]?[ \\t]*\\1)+", "$1")
            // A comma between identical characters is a hesitation, not a list.
            s = replace(s, "(\\p{Han})[ \\t]*[，,][ \\t]*\\1(?=\\p{Han})", "$1")
        } else {
            let expression = Self.regex("(?i)\\b([A-Za-z']+)((?:,?\\s+\\1\\b)+)")
            let ns = s as NSString
            var out = ""
            var cursor = 0
            for match in expression.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: match.range(at: 1))
                let repeats = ns.substring(with: match.range(at: 2)).components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
                // "had had", "that that" and "no no" are grammatical; only a run of three is a stutter.
                if repeats == 1 && ["had", "that", "is", "no", "very", "bye", "so", "really", "yes", "okay", "ok", "there", "do"].contains(word.lowercased()) { continue }
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                out += word
                cursor = match.range.location + match.range.length
            }
            out += ns.substring(from: cursor)
            s = out
        }
        return s
    }

    // MARK: - Self-correction

    private static let chineseRetract = "(?:哦|啊|呃|嗯|哎)?(?:不对(?:不对)*|不是不是|说错了|错了|哦不|啊不|哎不)"
    private static let chineseRestate = "(?:我是说|应该是|应该说|改成|换成|我想说的是|是(?![是不的吗否]))"
    /// A retraction must be followed by a comma or a restating phrase so "不对称" / "不对劲" stay untouched.
    private static let chineseMarker =
        "(?:^|(?<=\(clauseClass)))[ \\t]*(?:\(chineseRetract)[ \\t]*[，,][ \\t]*\(chineseRestate)?|\(chineseRetract)[ \\t]*\(chineseRestate)|我是说)(?:[ \\t]*[，,])?[ \\t]*"

    // Only at a clause boundary: "you know what I mean, right" is content, not a correction.
    private static let englishMarker =
        "(?i)(?:^|(?<=[,.;!?]\\s))(?:(?:no|oh no|wait|sorry|nope|oops),?\\s+)*(?:I mean|I meant|scratch that|correction|let me rephrase),?\\s*"

    /// "周三开会，不是周三，是周四" → "周四开会". Applied only when the retracted term
    /// really occurred earlier, so "不是我，是他" as plain content is preserved.
    private static let chineseContrast =
        "(?:^|(?<=\(clauseClass)))[ \\t]*不是[ \\t]*([^，。；！？、,.;!?\\n]{1,12}?)[ \\t]*[，,]?[ \\t]*(?:而)?是[ \\t]*([^，。；！？、,.;!?\\n]{1,24})"

    static func applySelfCorrections(_ text: String, cjk: Bool) -> String {
        var s = text
        for _ in 0..<6 {
            let next = cjk ? applyContrast(s) : s
            let after = applyMarker(next, cjk: cjk)
            if after == s { break }
            s = after
        }
        return s
    }

    private static func applyContrast(_ text: String) -> String {
        let expression = Self.regex(chineseContrast)
        let ns = text as NSString
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let wrong = ns.substring(with: match.range(at: 1))
            let right = ns.substring(with: match.range(at: 2))
            let head = ns.substring(to: match.range.location)
            guard let found = head.range(of: wrong, options: .backwards) else { continue }
            // "不是二十六，是二十四度" restates the unit that already follows the term; keep it once.
            var replacement = right
            let following = head[found.upperBound...]
            for length in stride(from: min(replacement.count - 1, following.count), through: 1, by: -1) {
                if following.hasPrefix(replacement.suffix(length)) { replacement = String(replacement.dropLast(length)); break }
            }
            var fixedHead = head
            fixedHead.replaceSubrange(found, with: replacement)
            let rest = ns.substring(from: match.range.location + match.range.length)
            return fixedHead + rest
        }
        return text
    }

    private static func applyMarker(_ text: String, cjk: Bool) -> String {
        let expression = Self.regex(cjk ? chineseMarker : englishMarker)
        let ns = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.range.length > 0 else { return text }
        let markerEnd = match.range.location + match.range.length
        let tail = ns.substring(from: markerEnd)
        // The correction is the clause right after the marker; the rest continues unchanged.
        let clauseEnd = cjk
            ? tail.rangeOfCharacter(from: CharacterSet(charactersIn: clausePunctuation))
            : firstEnglishClauseEnd(in: tail)
        let correction = String(clauseEnd.map { tail[..<$0.lowerBound] } ?? tail[...]).trimmingCharacters(in: .whitespaces)
        let rest = clauseEnd.map { String(tail[$0.lowerBound...]) } ?? ""
        guard !correction.isEmpty else { return text }

        let before = ns.substring(to: match.range.location)
        // With nothing before it, "I mean it" / "不对，你听我说" is content, not a correction.
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let (head, previous) = splitLastClause(before)
        let merged = merge(previous: previous, correction: correction, cjk: cjk)
        let joiner = head.isEmpty || head.hasSuffix(" ") || cjk || merged.isEmpty ? "" : " "
        return head + joiner + merged + rest
    }

    private static func firstEnglishClauseEnd(in text: String) -> Range<String.Index>? {
        let expression = Self.regex("[,;!?\\n]|\\.(?=\\s|$)")
        let ns = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Range(match.range, in: text)
    }

    /// Splits "head + last clause" where the head keeps its trailing punctuation and spacing.
    private static func splitLastClause(_ text: String) -> (head: String, clause: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let punctuation = CharacterSet(charactersIn: clausePunctuation)
        var clause = Substring(trimmed)
        while let last = clause.last, last.unicodeScalars.allSatisfy(punctuation.contains) || last == " " { clause = clause.dropLast() }
        guard let boundary = clause.rangeOfCharacter(from: punctuation, options: .backwards) else {
            return ("", String(clause))
        }
        let head = String(clause[..<boundary.upperBound])
        let last = clause[boundary.upperBound...].trimmingCharacters(in: .whitespaces)
        return (head, last)
    }

    /// Rewrites the previous clause with the correction. The correction usually restates a
    /// prefix ("去北京"→"去上海"), a suffix ("三点"→"四点开会") or only the replaced tail ("北京"→"上海").
    static func merge(previous: String, correction: String, cjk: Bool) -> String {
        guard !previous.isEmpty else { return correction }
        let prev: [String] = cjk ? previous.map(String.init) : previous.split(separator: " ").map(String.init)
        let corr: [String] = cjk ? correction.map(String.init) : correction.split(separator: " ").map(String.init)
        let separator = cjk ? "" : " "
        func same(_ a: String, _ b: String) -> Bool { cjk ? a == b : a.lowercased() == b.lowercased() }
        func lastOccurrence(of pattern: ArraySlice<String>, in haystack: [String]) -> Int? {
            guard !pattern.isEmpty, pattern.count <= haystack.count else { return nil }
            for start in stride(from: haystack.count - pattern.count, through: 0, by: -1) {
                if zip(haystack[start..<start + pattern.count], pattern).allSatisfy({ same($0, $1) }) { return start }
            }
            return nil
        }
        // Prefix anchor: the correction repeats some leading words of what it replaces.
        for k in stride(from: min(corr.count, prev.count), through: 1, by: -1) {
            if let start = lastOccurrence(of: corr[0..<k], in: prev) {
                if k == prev.count && start == 0 && k == corr.count { return correction }
                return (prev[0..<start] + corr).joined(separator: separator)
            }
        }
        // Suffix anchor: the correction carries the old continuation ("四点" ← "三点开会").
        if corr.count < prev.count {
            for j in stride(from: corr.count, through: 1, by: -1) {
                if let start = lastOccurrence(of: corr[(corr.count - j)...], in: prev) {
                    let end = start + j
                    guard end >= corr.count else { continue }
                    return (Array(prev[0..<(end - corr.count)]) + corr + Array(prev[end...])).joined(separator: separator)
                }
            }
        }
        // Numeral anchor: a correction that opens with a number replaces from the last number
        // spoken ("明天下午三点" ← "四点半开会"), the most common kind of slip.
        if let first = corr.first, isNumeral(first), let last = prev.lastIndex(where: isNumeral) {
            var runStart = last
            while runStart > 0, isNumeral(prev[runStart - 1]) { runStart -= 1 }
            // Keep what followed the old number when the correction repeats its unit:
            // "下午三点要去开会" ← "四点半" keeps "要去开会"; "三本" ← "五个" replaces the unit too.
            let prevAfter = Array(prev[(last + 1)...])
            let corrAfter = Array(corr.drop(while: isNumeral))
            var common = 0
            while common < min(prevAfter.count, corrAfter.count), same(prevAfter[common], corrAfter[common]) { common += 1 }
            let remainder = common > 0 ? Array(prevAfter[common...]) : []
            return (Array(prev[0..<runStart]) + corr + remainder).joined(separator: separator)
        }
        if corr.count >= prev.count { return correction }
        // No anchor: assume the speaker replaced the same-length tail.
        return (prev[0..<(prev.count - corr.count)] + corr).joined(separator: separator)
    }

    private static let numerals = CharacterSet(charactersIn: "0123456789零〇一二三四五六七八九十两百千万亿")
    private static func isNumeral(_ token: String) -> Bool {
        token.unicodeScalars.first.map { numerals.contains($0) || CharacterSet.decimalDigits.contains($0) } ?? false
    }

    // MARK: - Helpers

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    /// Live hypotheses arrive many times a second; compile each pattern once.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[pattern] { return cached }
        let compiled = try! NSRegularExpression(pattern: pattern)
        cache[pattern] = compiled
        return compiled
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String,
                                transform: ((String) -> String)? = nil) -> String {
        let expression = Self.regex(pattern)
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let transform else { return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template) }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in expression.matches(in: text, range: range) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += transform(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
