import Foundation

/// Applies the user's vocabulary after recognition, for every engine. Chinese terms match
/// by pinyin ("章三" → "张三"); aliases additionally ignore tone ("Saylane|赛兰" fixes "塞蓝").
/// Latin terms match by case-insensitive spelling with a small edit distance and tolerate
/// a split ("Say lane" → "Saylane"). Nothing is added or removed, only respelled.
struct DictationVocabulary: Sendable {
    private struct HanMatcher { let key: [String]; let toned: Bool; let canonical: String }
    private struct LatinMatcher { let key: String; let words: Int; let canonical: String }

    private let han: [HanMatcher]
    private let latin: [LatinMatcher]
    private let literal: [(pattern: String, canonical: String)]
    var isEmpty: Bool { han.isEmpty && latin.isEmpty && literal.isEmpty }

    init(entries: [SpeechHotwords.Entry]) {
        var han: [HanMatcher] = [], latin: [LatinMatcher] = [], literal: [(String, String)] = []
        for entry in entries {
            for (index, spelling) in ([entry.canonical] + entry.aliases).enumerated() {
                let isAlias = index > 0
                if Self.isHan(spelling) {
                    // A single character is too ambiguous to respell by sound.
                    guard spelling.count >= 2 else { continue }
                    // The canonical spelling keeps tones so "微信" never claims "为新";
                    // an alias is the user saying "this is how it gets misheard", so tone is ignored.
                    han.append(HanMatcher(key: Self.pinyinKey(spelling, toned: !isAlias), toned: !isAlias, canonical: entry.canonical))
                } else if Self.isLatin(spelling) {
                    let words = spelling.split(whereSeparator: { $0 == " " || $0 == "-" }).count
                    latin.append(LatinMatcher(key: Self.latinKey(spelling), words: words, canonical: entry.canonical))
                } else {
                    literal.append((spelling, entry.canonical))
                }
            }
        }
        // Longer terms first so "北京大学" wins over "北京" inside the same run.
        self.han = han.sorted { $0.key.count > $1.key.count }
        self.latin = latin.sorted { $0.key.count > $1.key.count }
        self.literal = literal.sorted { $0.0.count > $1.0.count }
    }

    init(raw: String) { self.init(entries: SpeechHotwords.entries(raw)) }

    func apply(to text: String) -> String {
        guard !isEmpty, !text.isEmpty else { return text }
        var result = text
        for (pattern, canonical) in literal {
            result = result.replacingOccurrences(of: pattern, with: canonical, options: .caseInsensitive)
        }
        if !han.isEmpty { result = applyHan(result) }
        if !latin.isEmpty { result = applyLatin(result) }
        return result
    }

    // MARK: - Chinese by pinyin

    private func applyHan(_ text: String) -> String {
        let chars = Array(text)
        let readings: [(toneless: String, toned: String)?] = chars.map { char in
            guard Self.isHan(String(char)) else { return nil }
            let reading = Self.pinyin(String(char))
            let base = Self.fuzzy(reading.syllable)
            return (base, base + String(reading.tone))
        }
        var out = ""
        var i = 0
        while i < chars.count {
            guard readings[i] != nil, let matched = han.first(where: { matcher in
                let n = matcher.key.count
                guard i + n <= chars.count else { return false }
                for k in 0..<n {
                    guard let reading = readings[i + k], (matcher.toned ? reading.toned : reading.toneless) == matcher.key[k] else { return false }
                }
                return String(chars[i..<i + n]) != matcher.canonical
            }) else {
                out.append(chars[i]); i += 1
                continue
            }
            out += matched.canonical
            i += matched.key.count
        }
        return out
    }

    static func pinyinKey(_ text: String, toned: Bool) -> [String] {
        text.map { character in
            let reading = pinyin(String(character))
            let base = fuzzy(reading.syllable)
            return toned ? base + String(reading.tone) : base
        }
    }

    private static let toneMarks: [(Character, Int)] = [
        ("ā", 1), ("ē", 1), ("ī", 1), ("ō", 1), ("ū", 1), ("ǖ", 1),
        ("á", 2), ("é", 2), ("í", 2), ("ó", 2), ("ú", 2), ("ǘ", 2),
        ("ǎ", 3), ("ě", 3), ("ǐ", 3), ("ǒ", 3), ("ǔ", 3), ("ǚ", 3),
        ("à", 4), ("è", 4), ("ì", 4), ("ò", 4), ("ù", 4), ("ǜ", 4),
    ]

    /// Character-by-character so both sides of a comparison pick the same reading of a polyphone.
    static func pinyin(_ character: String) -> (syllable: String, tone: Int) {
        let mutable = NSMutableString(string: character)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        let marked = (mutable as String).precomposedStringWithCanonicalMapping
        let tone = marked.compactMap { char in toneMarks.first(where: { $0.0 == char })?.1 }.first ?? 0
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return ((mutable as String).lowercased().trimmingCharacters(in: .whitespaces), tone)
    }

    /// Common Mandarin confusions: flat/retroflex initials, n/l, front/back nasals.
    static func fuzzy(_ syllable: String) -> String {
        var s = syllable
        for (from, to) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where s.hasPrefix(from) { s = to + s.dropFirst(from.count) }
        if s.hasPrefix("n") { s = "l" + s.dropFirst() }
        for (from, to) in [("ing", "in"), ("eng", "en"), ("ang", "an")] where s.hasSuffix(from) { s = String(s.dropLast(from.count)) + to }
        return s
    }

    // MARK: - Latin by spelling

    private static let wordRegex = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9'’]*")

    private func applyLatin(_ text: String) -> String {
        let ns = text as NSString
        let words = Self.wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard !words.isEmpty else { return text }
        var out = ""
        var cursor = 0
        var i = 0
        while i < words.count {
            var replaced = false
            for matcher in latin {
                // Allow one extra word so "Say lane" can still become "Saylane".
                for n in stride(from: min(matcher.words + 1, words.count - i), through: 1, by: -1) {
                    let range = NSUnionRange(words[i], words[i + n - 1])
                    let candidate = ns.substring(with: range)
                    guard candidate.range(of: "[^A-Za-z0-9'’ \\-]", options: .regularExpression) == nil else { continue }
                    // Fuzzy spelling only when the word count matches: "Kubernetes is" must not lose "is".
                    guard Self.matches(candidate, matcher, fuzzy: n == matcher.words), candidate != matcher.canonical else { continue }
                    out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
                    out += matcher.canonical
                    cursor = range.location + range.length
                    i += n
                    replaced = true
                    break
                }
                if replaced { break }
            }
            if !replaced { i += 1 }
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func matches(_ candidate: String, _ matcher: LatinMatcher, fuzzy: Bool) -> Bool {
        let key = latinKey(candidate)
        if key == matcher.key { return true }
        guard fuzzy else { return false }
        // "cursors" is the term plus a suffix, not a misspelling of "Cursor".
        guard !key.hasPrefix(matcher.key) else { return false }
        let allowed = matcher.key.count >= 9 ? 2 : matcher.key.count >= 5 ? 1 : 0
        guard allowed > 0, abs(key.count - matcher.key.count) <= allowed else { return false }
        return editDistance(key, matcher.key) <= allowed
    }

    static func latinKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    // MARK: - Classification

    static func isHan(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
            default: return false
            }
        }
    }

    static func isLatin(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " -'".unicodeScalars.contains($0)) }
    }
}
