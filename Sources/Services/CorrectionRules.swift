import Foundation
import NaturalLanguage

/// What the rules need to know about ordinary language. The main program asks
/// the system's segmenter and name tagger, which run on this Mac; tests use a
/// fixed one. Ranges are UTF-16 offsets into the text that was passed in.
struct CorrectionLexicon: Sendable {
    /// Names of people, places and organisations in a sentence.
    var names: @Sendable (String) -> [Range<Int>]
    /// A sentence cut into words.
    var words: @Sendable (String) -> [Range<Int>]
}

/// From what was dictated and what stands there after the user's edits: the
/// names and terms the user corrected, as pairs (heard → corrected). Pure.
///
/// The rules are narrow on purpose. A correction that is missed costs the user
/// one more edit; a wrong one rewrites their words behind their back.
///
/// 1. Both texts are cut into tokens — one Chinese character, one run of Latin
///    letters and digits, one run of spaces, any other character — and aligned
///    (longest common subsequence). What lies between two unchanged tokens is
///    one edit. Two edits with a single space between them are one ("cloud
///    code" → "Claude Code").
/// 2. The dictation must still be there: when less than a third of it is left
///    (nothing at all, for one of fewer than six tokens) the text is `gone` —
///    sent, cleared or replaced — and is not looked at again. When more than
///    a third of it changed (six tokens are always allowed: a name said in
///    Chinese characters is easily that long) the user rewrote the sentence:
///    nothing is learned.
/// 3. Only a replacement counts: both sides non-empty once spaces and sentence
///    punctuation at their ends are dropped. Deletions, additions and changes
///    of punctuation or spacing alone teach nothing.
/// 4. An edit needs unchanged dictated text on both sides, or the edge of the
///    document itself. At the end of a dictation that has other text after it,
///    nobody can tell where the correction stops. A dictation of up to three
///    tokens that was retyped whole counts when it is all the client holds.
/// 5. Too little to stand alone — a single character, or only digits and
///    numerals — is widened: by the Latin word it is written against ("GPT四"
///    → "GPT-4"), else, for Chinese, to the name the system finds around it
///    ("黄根诚" → "黄根成") or, failing that, to the word it is part of. What
///    cannot be widened is dropped, so a pair's heard side is never a single
///    character, and a number that became another number is not a term.
/// 6. Bounds: heard 2–16 characters, corrected 2–24. Chinese characters, Latin
///    letters, digits, spaces and the signs terms are written with (- . + # ' / &)
///    only; any other script or sign inside means this is not a term.
/// 7. The two sides must sound alike, because the correction of a mishearing
///    does and a change of mind does not ("飞书" → "Lark" is a rewording).
///    Chinese against Chinese: the same syllables, tones and the usual
///    confusions (z/zh, n/l, in/ing) aside. Anything else: the consonants of
///    the spelling, with pinyin standing in for Chinese characters.
///    Capitalising one ordinary word ("code" → "Code") is not a respelling.
/// 8. Ordinary language is not a name. When both sides are ordinary words
///    ("权利" → "权力", "then" → "than") the right one depends on the sentence:
///    nothing is learned. When only the heard side is ordinary ("cloud" →
///    "Claude") the corrected spelling may bias recognition but must never
///    replace the heard one (`replaceable` is false).
/// 9. More than three pairs from one dictation is a rewrite: nothing is learned.
enum CorrectionRules {
    struct Pair: Equatable, Sendable {
        let heard: String
        let corrected: String
        /// The heard spelling is not ordinary language: writing the corrected
        /// one in its place cannot break a sentence that meant what it said.
        let replaceable: Bool
    }

    enum Reading: Equatable, Sendable {
        /// The dictation is no longer where it was written.
        case gone
        case pairs([Pair])
    }

    static let heardLength = 2...16
    static let correctedLength = 2...24
    static let mostPairs = 3
    /// Tokens that may change in a dictation of any length: a name said in
    /// Chinese characters and corrected to English is easily five or six.
    static let alwaysAllowed = 6
    /// UTF-16 units. The input method reads far less; this bounds the work whatever arrives.
    static let longestText = 800

    /// `now` is what stands at the place of `written`, with at most a few
    /// characters of whatever follows it. `startsDocument` / `endsDocument`:
    /// the client's text begins where the dictation was written / ends inside `now`.
    static func read(written: String, now: String, startsDocument: Bool, endsDocument: Bool,
                     lexicon: CorrectionLexicon) -> Reading {
        guard written.utf16.count <= longestText, now.utf16.count <= longestText else { return .pairs([]) }
        let heard = tokens(written), current = tokens(now)
        let matches = align(heard, current)
        let total = heard.count { $0.kind != .space }
        let kept = matches.count { heard[$0.0].kind != .space }
        guard total > 0 else { return .pairs([]) }
        if total >= 6 ? kept * 3 < total : kept == 0 {
            // A dictation of a word or two that was retyped whole may still
            // teach its pair, when it is all the client holds: there is
            // nothing else the new text could be a correction of.
            guard kept == 0, total <= 3, startsDocument, endsDocument else { return .gone }
        }
        guard total - kept <= max(Self.alwaysAllowed, total / 3) else { return .pairs([]) }

        let alignment = Alignment(heard: heard, current: current, matches: matches)
        var names: [Range<Int>]?
        var words: [Range<Int>]?
        var pairs: [Pair] = []
        for edit in alignment.edits(startsDocument: startsDocument, endsDocument: endsDocument) {
            // `span` always begins and ends where the two texts line up;
            // `sides` is what it holds once the padding at its ends is dropped.
            var span = edit
            guard var sides = alignment.sides(span) else { continue }
            if isWeak(sides) {
                span = alignment.glued(span)
                guard let wider = alignment.sides(span) else { continue }
                sides = wider
            }
            var isName = false
            if sides.heard.allSatisfy({ $0.kind == .han }), sides.corrected.allSatisfy({ $0.kind == .han }) {
                // Chinese has no spaces: where the name or the word begins and
                // ends is the system's judgment of the corrected sentence.
                let changed = alignment.utf16(of: sides.span.current)
                func around(_ ranges: [Range<Int>]) -> Range<Int>? {
                    ranges.first { $0.lowerBound <= changed.lowerBound && changed.upperBound <= $0.upperBound }
                }
                if names == nil { names = lexicon.names(now) }
                var target = around(names ?? [])
                isName = target != nil
                if target == nil, sides.heard.count == 1 {
                    if words == nil { words = lexicon.words(now) }
                    target = around(words ?? [])
                    guard let target, target.count >= 2 else { continue }
                }
                if let target {
                    span = alignment.widened(span, toCover: target)
                    guard let wider = alignment.sides(span) else { continue }
                    sides = wider
                }
            }
            guard !isWeak(sides), let pair = pair(sides, isName: isName, lexicon: lexicon),
                  !pairs.contains(pair) else { continue }
            pairs.append(pair)
        }
        if kept == 0, pairs.isEmpty { return .gone }
        return .pairs(pairs.count > mostPairs ? [] : pairs)
    }

    // MARK: - Tokens

    fileprivate enum Kind { case han, word, space, mark }

    fileprivate struct Token {
        let text: String
        let kind: Kind
        /// UTF-16 offset in the text it came from.
        let offset: Int
        var end: Int { offset + text.utf16.count }
    }

    fileprivate static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var run = "", runKind = Kind.word, runStart = 0, offset = 0
        func flush() {
            guard !run.isEmpty else { return }
            result.append(Token(text: run, kind: runKind, offset: runStart))
            run = ""
        }
        for character in text {
            let kind: Kind
            if character.isASCII, character.isLetter || character.isNumber { kind = .word }
            else if character.isWhitespace { kind = .space }
            else if DictationVocabulary.isHan(String(character)) { kind = .han }
            else { kind = .mark }
            if kind == .word || kind == .space {
                if run.isEmpty || runKind != kind { flush(); runKind = kind; runStart = offset }
                run.append(character)
            } else {
                flush()
                result.append(Token(text: String(character), kind: kind, offset: offset))
            }
            offset += character.utf16.count
        }
        flush()
        return result
    }

    /// Pairs of indices of the tokens that are unchanged, in order.
    fileprivate static func align(_ a: [Token], _ b: [Token]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        // lengths[i][j]: the longest common subsequence of a[i...] and b[j...].
        var lengths = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = a[i].text == b[j].text ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i].text == b[j].text, lengths[i][j] == lengths[i + 1][j + 1] + 1 {
                matches.append((i, j)); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }

    /// A stretch of tokens on each side: one edit, or what it was widened to.
    fileprivate struct Span: Equatable {
        var heard: Range<Int>
        var current: Range<Int>
    }

    fileprivate struct Sides {
        let heard: ArraySlice<Token>
        let corrected: ArraySlice<Token>
        /// Where the two slices lie.
        let span: Span
    }

    fileprivate struct Alignment {
        let heard: [Token]
        let current: [Token]
        /// What lies between the unchanged tokens, in order: every change, one-sided ones too.
        let gaps: [Span]

        init(heard: [Token], current: [Token], matches: [(Int, Int)]) {
            self.heard = heard
            self.current = current
            var gaps: [Span] = []
            var previous = (-1, -1)
            for match in matches + [(heard.count, current.count)] {
                let gap = Span(heard: previous.0 + 1..<match.0, current: previous.1 + 1..<match.1)
                if !gap.heard.isEmpty || !gap.current.isEmpty { gaps.append(gap) }
                previous = match
            }
            self.gaps = gaps
        }

        /// The replacements that are held in place on both sides (rules 1, 3 and 4).
        func edits(startsDocument: Bool, endsDocument: Bool) -> [Span] {
            var edits: [Span] = []
            for gap in gaps where !gap.heard.isEmpty && !gap.current.isEmpty {
                // Without an unchanged token next to it, an edit is held only by the edge of the document.
                if gap.heard.lowerBound == 0 || gap.current.lowerBound == 0, !startsDocument { continue }
                if gap.heard.upperBound == heard.count || gap.current.upperBound == current.count, !endsDocument { continue }
                if let last = edits.last, last.heard.upperBound + 1 == gap.heard.lowerBound,
                   last.current.upperBound + 1 == gap.current.lowerBound, heard[last.heard.upperBound].kind == .space {
                    edits[edits.count - 1] = Span(heard: last.heard.lowerBound..<gap.heard.upperBound,
                                                  current: last.current.lowerBound..<gap.current.upperBound)
                } else {
                    edits.append(gap)
                }
            }
            return edits
        }

        /// The tokens of a span without the spaces and sentence punctuation at its ends.
        func sides(_ span: Span) -> Sides? {
            func trimmed(_ tokens: [Token], _ range: Range<Int>) -> Range<Int> {
                var range = range
                while let first = range.first, CorrectionRules.isPadding(tokens[first]) { range = first + 1..<range.upperBound }
                while let last = range.last, CorrectionRules.isPadding(tokens[last]) { range = range.lowerBound..<last }
                return range
            }
            let a = trimmed(heard, span.heard), b = trimmed(current, span.current)
            guard !a.isEmpty, !b.isEmpty else { return nil }
            return Sides(heard: heard[a], corrected: current[b], span: Span(heard: a, current: b))
        }

        func utf16(of range: Range<Int>) -> Range<Int> {
            current[range.lowerBound].offset..<current[range.upperBound - 1].end
        }

        /// Take in the Latin word the edit is written against, on either side.
        func glued(_ span: Span) -> Span {
            var span = span
            if span.heard.lowerBound > 0, span.current.lowerBound > 0, heard[span.heard.lowerBound - 1].kind == .word,
               heard[span.heard.lowerBound - 1].text == current[span.current.lowerBound - 1].text {
                span = Span(heard: span.heard.lowerBound - 1..<span.heard.upperBound,
                            current: span.current.lowerBound - 1..<span.current.upperBound)
            }
            if span.heard.upperBound < heard.count, span.current.upperBound < current.count,
               heard[span.heard.upperBound].kind == .word,
               heard[span.heard.upperBound].text == current[span.current.upperBound].text {
                span = Span(heard: span.heard.lowerBound..<span.heard.upperBound + 1,
                            current: span.current.lowerBound..<span.current.upperBound + 1)
            }
            return span
        }

        /// Grow a span until its corrected side covers `target` (UTF-16
        /// offsets in the corrected text): over unchanged tokens, which are
        /// the same on the heard side, and over a neighbouring change as a
        /// whole ("皇根诚" → "黄根成" is one name with two changes).
        func widened(_ span: Span, toCover target: Range<Int>) -> Span {
            var span = span
            while span.current.lowerBound > 0, current[span.current.lowerBound].offset > target.lowerBound {
                if let gap = gaps.first(where: { $0.heard.upperBound == span.heard.lowerBound && $0.current.upperBound == span.current.lowerBound }) {
                    span = Span(heard: gap.heard.lowerBound..<span.heard.upperBound, current: gap.current.lowerBound..<span.current.upperBound)
                } else if span.heard.lowerBound > 0 {
                    span = Span(heard: span.heard.lowerBound - 1..<span.heard.upperBound,
                                current: span.current.lowerBound - 1..<span.current.upperBound)
                } else {
                    break
                }
            }
            while span.current.upperBound < current.count, current[span.current.upperBound - 1].end < target.upperBound {
                if let gap = gaps.first(where: { $0.heard.lowerBound == span.heard.upperBound && $0.current.lowerBound == span.current.upperBound }) {
                    span = Span(heard: span.heard.lowerBound..<gap.heard.upperBound, current: span.current.lowerBound..<gap.current.upperBound)
                } else if span.heard.upperBound < heard.count {
                    span = Span(heard: span.heard.lowerBound..<span.heard.upperBound + 1,
                                current: span.current.lowerBound..<span.current.upperBound + 1)
                } else {
                    break
                }
            }
            return span
        }
    }

    // MARK: - One pair

    private static let sentencePunctuation = Set("，。！？、；：,.!?;:…—“”‘’\"()（）《》〈〉【】[]「」『』·~～")
    /// Signs that names of products and technical terms are written with.
    private static let termSigns = Set("-.+#'’/&")
    private static let digits: [Character: String] = [
        "零": "0", "〇": "0", "一": "1", "二": "2", "两": "2", "三": "3", "四": "4",
        "五": "5", "六": "6", "七": "7", "八": "8", "九": "9",
    ]
    private static let numerals = Set(digits.keys).union("十百千万亿点半")
    private static let numberSigns = Set(".,%％:：-/+~")

    fileprivate static func isPadding(_ token: Token) -> Bool {
        token.kind == .space || (token.kind == .mark && sentencePunctuation.contains(Character(token.text)))
    }

    private static func text(_ tokens: ArraySlice<Token>) -> String { tokens.map(\.text).joined() }

    /// Only digits, Chinese numerals and the signs numbers are written with.
    private static func isNumber(_ tokens: ArraySlice<Token>) -> Bool {
        tokens.allSatisfy { token in
            switch token.kind {
            case .space: return true
            case .word: return token.text.allSatisfy(\.isNumber)
            case .han: return numerals.contains(Character(token.text))
            case .mark: return numberSigns.contains(Character(token.text))
            }
        }
    }

    /// Too little to stand alone (rule 5).
    private static func isWeak(_ sides: Sides) -> Bool {
        text(sides.heard).count < 2 || isNumber(sides.heard) || isNumber(sides.corrected)
    }

    private static func pair(_ sides: Sides, isName: Bool, lexicon: CorrectionLexicon) -> Pair? {
        let heard = text(sides.heard), corrected = text(sides.corrected)
        guard heardLength.contains(heard.count), correctedLength.contains(corrected.count),
              isReplacement(heard: heard, corrected: corrected) else { return nil }
        for token in Array(sides.heard) + Array(sides.corrected) where token.kind == .mark {
            guard termSigns.contains(Character(token.text)) else { return nil }
        }
        guard soundsAlike(heard, corrected) else { return nil }
        if sides.heard.count == 1, sides.corrected.count == 1, sides.heard.first?.kind == .word,
           heard.dropFirst() == corrected.dropFirst(), heard.lowercased() == corrected.lowercased() {
            // Only the first letter's case: an ordinary word at the start of a
            // sentence, or a name nobody can tell from one.
            return nil
        }
        let heardOrdinary = isOrdinary(sides.heard, lexicon: lexicon)
        if heardOrdinary, !isName, isOrdinary(sides.corrected, lexicon: lexicon) { return nil }
        return Pair(heard: heard, corrected: corrected, replaceable: !heardOrdinary)
    }

    /// Two different spellings, the corrected one not a longer spelling that
    /// contains the heard one: replacing would then be applied to its own result.
    static func isReplacement(heard: String, corrected: String) -> Bool {
        heard != corrected && (heard.count == corrected.count || corrected.range(of: heard, options: .caseInsensitive) == nil)
    }

    /// Words anybody might say: Chinese that the segmenter cuts into whole
    /// words of two characters or more, English in lower case. A capital, a
    /// digit, a sign, or a character left over on its own is the mark of a
    /// name, a term or a mishearing.
    private static func isOrdinary(_ tokens: ArraySlice<Token>, lexicon: CorrectionLexicon) -> Bool {
        var han = ""
        func hanIsOrdinary() -> Bool {
            guard !han.isEmpty else { return true }
            let words = lexicon.words(han)
            return words.reduce(0) { $0 + $1.count } == han.utf16.count && words.allSatisfy { $0.count >= 2 }
        }
        for token in tokens {
            switch token.kind {
            case .han:
                han += token.text
                continue
            case .space:
                break
            case .word:
                guard token.text.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return false }
            case .mark:
                return false
            }
            guard hanIsOrdinary() else { return false }
            han = ""
        }
        return hanIsOrdinary()
    }

    // MARK: - Sound

    /// Whether one spelling can be a mishearing of the other (rule 7).
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        if DictationVocabulary.isHan(a), DictationVocabulary.isHan(b) {
            return a.count == b.count
                && DictationVocabulary.pinyinKey(a, toned: false) == DictationVocabulary.pinyinKey(b, toned: false)
        }
        let x = letters(a), y = letters(b)
        let p = consonants(x), q = consonants(y)
        guard !p.isEmpty, !q.isEmpty else { return false }
        // The consonants carry the word; the vowels only have to be in the
        // same neighbourhood, which keeps apart two short words that share a consonant.
        return DictationVocabulary.editDistance(p, q) * 2 <= max(p.count, q.count)
            && DictationVocabulary.editDistance(x, y) * 3 <= max(x.count, y.count) * 2
    }

    /// Lower-case letters and digits as they are said: pinyin for a Chinese
    /// character, a digit for 零 to 九, and the consonants a Mandarin speaker
    /// does not tell apart written the same way (c/k/q, l/r).
    static func letters(_ text: String) -> String {
        var result = ""
        for character in text {
            if let digit = digits[character] {
                result += digit
            } else if DictationVocabulary.isHan(String(character)) {
                result += DictationVocabulary.pinyin(String(character)).syllable
            } else if character.isASCII, character.isLetter || character.isNumber {
                result += character.lowercased()
            }
        }
        return String(result.map { $0 == "c" || $0 == "q" ? "k" : $0 == "r" ? "l" : $0 })
    }

    private static func consonants(_ letters: String) -> String {
        var result = ""
        for character in letters where !"aeiouhyw".contains(character) && result.last != character {
            result.append(character)
        }
        return result
    }
}

extension CorrectionLexicon {
    /// The system's word segmenter and name tagger. Both work on this Mac and
    /// send nothing anywhere.
    static let system = CorrectionLexicon(
        names: { text in
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            tagger.setLanguage(.simplifiedChinese, range: text.startIndex..<text.endIndex)
            var found: [Range<Int>] = []
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                                 options: [.joinNames, .omitWhitespace, .omitPunctuation]) { tag, range in
                if tag == .personalName || tag == .placeName || tag == .organizationName {
                    found.append(range.lowerBound.utf16Offset(in: text)..<range.upperBound.utf16Offset(in: text))
                }
                return true
            }
            return found
        },
        words: { text in
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            tokenizer.setLanguage(.simplifiedChinese)
            return tokenizer.tokens(for: text.startIndex..<text.endIndex).map {
                $0.lowerBound.utf16Offset(in: text)..<$0.upperBound.utf16Offset(in: text)
            }
        })
}
