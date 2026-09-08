import Foundation
import Darwin

enum PinyinDecoder {
    private struct Match {
        var entry: PinyinEntry
        var consumed: Int
        var kind: PinyinMatchKind
        var jianpinCount: Int
        var fuzzyCount: Int
    }

    private struct State {
        var pos: Int
        var last: String
        var score: Double
        var path: [PinyinEntry]
    }

    static func decode(preedit: String, lexicon: PinyinLexicon, context: [String], limit: Int) -> [PinyinCandidate] {
        var input = PinyinSyllable.normalize(preedit)
        if input == "i" { input = "yi" }
        if input == "u" { input = "wu" }
        if input == "v" { input = "yu" }
        guard !input.isEmpty else { return [] }
        let lattice = PinyinSyllable.lattice(input, fuzzy: lexicon.fuzzyEnabled)
        let mode = decodeMode(input: input, lattice: lattice)
        let previous = context.last
        guard let best = beam(input: input, lexicon: lexicon, previous: previous, lattice: lattice, mode: mode) else {
            return []
        }
        let sentence = best.path.map(\.word).joined()
        let fullLength = PinyinSyllable.consumedLength(of: preedit, normalizedCount: input.count)
        var ranked: [(Double, PinyinMatchKind, Int, PinyinCandidate)] = []
        var tailCache: [String: [PinyinEntry]] = [:]
        let starts = uniqueStarts(matches(in: input, at: 0, lexicon: lexicon, lattice: lattice, mode: mode))
        let hasFullExact = starts.contains { $0.kind == .exact && $0.consumed == input.count }
        let completeSyllable = PinyinSyllable.all.contains(input)
        var results: [PinyinCandidate] = []
        var seen = Set<String>()
        // Prefer a real lexicon match over a split path: 上海 not 上还, 先 not 下你.
        let allowSentence = !completeSyllable && !hasFullExact
        var splitSentence: PinyinCandidate? = nil
        if allowSentence {
            results.append(PinyinCandidate(word: sentence, pinyin: input, inputLength: fullLength,
                                           frequency: best.path.last?.frequency ?? 1, preview: sentence, commitsAll: true))
            seen.insert(sentence)
        } else if best.path.count > 1 {
            splitSentence = PinyinCandidate(word: sentence, pinyin: input, inputLength: fullLength,
                                            frequency: best.path.last?.frequency ?? 1, preview: sentence, commitsAll: true)
        }
        for item in starts {
            let rest = String(input.dropFirst(item.consumed))
            let tailWords: [PinyinEntry]
            if rest.isEmpty {
                tailWords = []
            } else if let cached = tailCache[rest] {
                tailWords = cached
            } else if tailCache.count >= 1 {
                tailWords = []
            } else if let decoded = beam(input: rest, lexicon: lexicon, previous: item.entry.word, lattice: PinyinSyllable.lattice(rest, fuzzy: lexicon.fuzzyEnabled), mode: mode) {
                tailWords = decoded.path
                tailCache[rest] = tailWords
            } else {
                tailCache[rest] = []
                tailWords = []
            }
            let preview = ([item.entry.word] + tailWords.map(\.word)).joined()
            var score = PinyinLanguageModel.shared.score(word: item.entry.word, previous: previous, letters: item.consumed)
            score += displayBonus(item.kind)
            score += greedyBonus(entry: item.entry, input: input, pos: 0)
            score += shortArcPunish(item.jianpinCount)
            score += fuzzyPunish(item.fuzzyCount)
            score += syllableSplitPunish(entry: item.entry, input: input)
            if item.kind == .exact && item.entry.word.count == 2,
               item.entry.syllables.count <= (PinyinSyllable.segment(input)?.count ?? 1) {
                score += 0.8
            }
            score += userBonus(input: input, word: item.entry.word)
            if completeSyllable && item.entry.word.count == 1 {
                score += readingBonus(frequency: item.entry.frequency, jianpinCount: item.jianpinCount)
            }
            if item.kind == .exact, item.consumed == input.count {
                // Use every typed letter: 缓存 for huancum, 中国 for zonggue.
                score += 6.0
            }
            let length = PinyinSyllable.consumedLength(of: preedit, normalizedCount: item.consumed)
            let candidate = PinyinCandidate(word: item.entry.word, pinyin: item.entry.full, inputLength: length,
                                            frequency: item.entry.frequency, preview: preview,
                                            commitsAll: item.consumed == input.count)
            ranked.append((score, item.kind, item.entry.word.count, candidate))
        }
        let greedyCount = PinyinSyllable.segment(input)?.count ?? 0
        ranked.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return rank(lhs.1) < rank(rhs.1) }
            if lhs.3.commitsAll != rhs.3.commitsAll { return lhs.3.commitsAll && !rhs.3.commitsAll }
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            // Doubao: one syllable -> characters first; two+ syllables -> matching-length phrases first.
            if greedyCount == 1 && lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            if greedyCount >= 2 && lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.2 > rhs.2
        }
        for item in ranked {
            if item.1 == .prefix && results.count >= 8 { continue }
            if seen.insert(item.3.word).inserted {
                results.append(item.3)
            }
            if results.count == limit { break }
        }
        if let extra = splitSentence, seen.insert(extra.word).inserted {
            results.insert(extra, at: min(1, results.count))
            if results.count > limit { results.removeLast() }
        }
        promoteUserChoice(&results, input: input, preedit: preedit, fullLength: fullLength, limit: limit)
        return results
    }

    /// Doubao `FirstIsBestUsrDict`: an explicitly chosen phrase wins next time.
    /// Rank by this reading's frequency so 见/xian does not beat 先.
    /// Jianpin arcs must not inherit a huge unigram like 你 onto a leftover letter.
    private static func readingBonus(frequency: Int, jianpinCount: Int) -> Double {
        let base = 1.25 * log(Double(max(frequency, 1)))
        return jianpinCount > 0 ? 0.12 * base : base
    }

    private static func userBonus(input: String, word: String) -> Double {
        let count = PinyinLanguageModel.shared.choiceCount(input: input, word: word)
        guard count > 0 else { return 0 }
        return 18 + 4 * log(Double(count) + 1)
    }

    private static func promoteUserChoice(_ results: inout [PinyinCandidate], input: String, preedit: String, fullLength: Int, limit: Int) {
        guard let preferred = PinyinLanguageModel.shared.preferredWord(for: input) else { return }
        if let index = results.firstIndex(where: { $0.word == preferred }) {
            let item = results.remove(at: index)
            results.insert(item, at: 0)
            return
        }
        results.insert(
            PinyinCandidate(word: preferred, pinyin: input, inputLength: fullLength,
                            frequency: 1_000_000, preview: preferred, commitsAll: true),
            at: 0
        )
        if results.count > limit { results.removeLast() }
    }

    private static func rank(_ kind: PinyinMatchKind) -> Int {
        switch kind {
        case .exact: return 0
        case .typing: return 1
        case .prefix: return 2
        }
    }

    private static func displayBonus(_ kind: PinyinMatchKind) -> Double {
        switch kind {
        case .exact: return 4.0
        case .typing: return -1.0
        case .prefix: return -8.0
        }
    }

    private static func beamBonus(_ kind: PinyinMatchKind) -> Double {
        switch kind {
        case .exact: return 0.35
        case .typing: return -5.0
        case .prefix: return -12.0
        }
    }

    /// Doubao `IncSentence::ShortArcPunish`: abbreviated (jianpin) arcs score lower than full syllables.
    private static func shortArcPunish(_ jianpinCount: Int) -> Double {
        -1.35 * Double(jianpinCount)
    }

    /// Doubao fuzzy arcs are extra lattice paths; exact syllables must still win.
    private static func fuzzyPunish(_ fuzzyCount: Int) -> Double {
        -8.0 * Double(fuzzyCount)
    }

    /// Doubao CreateLattice prefers the longest syllable: huan is 换, not 胡安.
    private static func syllableSplitPunish(entry: PinyinEntry, input: String) -> Double {
        guard let greedy = PinyinSyllable.segment(input) else { return 0 }
        let extra = entry.syllables.count - greedy.count
        return extra > 0 ? -12.0 * Double(extra) : 0
    }

    /// Prefer the greedy longest-syllable split: "xian" is 先, not 西安.
    private static func greedyBonus(entry: PinyinEntry, input: String, pos: Int) -> Double {
        guard let longest = PinyinSyllable.longestSyllable(in: input, from: pos),
              let first = entry.syllables.first else { return 0 }
        if first == longest { return 1.2 }
        if first.count < longest.count { return -18.0 }
        return 0
    }

    private static func uniqueStarts(_ matches: [Match]) -> [Match] {
        var seen = Set<String>()
        var unique: [Match] = []
        let sorted = matches.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return rank(lhs.kind) < rank(rhs.kind) }
            if lhs.consumed != rhs.consumed { return lhs.consumed > rhs.consumed }
            return lhs.entry.frequency > rhs.entry.frequency
        }
        var kept: [PinyinMatchKind: Int] = [:]
        for item in sorted {
            let isExactChar = item.kind == .exact && item.entry.word.count == 1
            if !isExactChar {
                let cap: Int
                switch item.kind {
                case .exact: cap = 24
                case .typing: cap = 12
                case .prefix: cap = 3
                }
                if kept[item.kind, default: 0] >= cap { continue }
            }
            if seen.insert(item.entry.word).inserted {
                unique.append(item)
                if !isExactChar {
                    kept[item.kind] = kept[item.kind, default: 0] + 1
                }
            }
        }
        return unique
    }

    private enum Mode { case quanpin, jianpin, mixed }

    /// Pure quanpin / pure jianpin use the letter tries; mixed strings like kyishishi
    /// use Doubao's syllable lattice. SuperJp-only strings stay on the initials trie.
    private static func decodeMode(input: String, lattice: [[PinyinArc]]) -> Mode {
        if lattice.contains(where: { $0.contains(where: { $0.type == .correct }) }) {
            return .mixed
        }
        var i = 0
        var usedFull = false
        var usedJP = false
        let n = input.count
        while i < n {
            if let full = lattice[i].first(where: { $0.type == .full }) {
                i = full.end
                usedFull = true
            } else if let jp = lattice[i].first(where: { $0.type == .jianpin }) {
                i = jp.end
                usedJP = true
            } else {
                return .mixed
            }
        }
        if usedFull && usedJP { return .mixed }
        if usedJP { return .jianpin }
        return .quanpin
    }

    private static func matches(in input: String, at start: Int, lexicon: PinyinLexicon, lattice: [[PinyinArc]], mode: Mode) -> [Match] {
        switch mode {
        case .mixed:
            return lexicon.searchLattice(lattice, inputCount: input.utf8.count, from: start).map {
                Match(entry: $0.entry, consumed: $0.consumed, kind: $0.kind,
                      jianpinCount: $0.jianpinCount, fuzzyCount: $0.fuzzyCount)
            }
        case .quanpin, .jianpin:
            let quanpin = mode == .quanpin
            var result: [Match] = []
            for (entry, consumed, _) in lexicon.matches(in: input, at: start, quanpin: quanpin) {
                let typed = String(Array(input)[start..<(start + consumed)])
                let units = quanpin ? entry.syllables : entry.syllables.compactMap { $0.first.map(String.init) }
                guard let kind = PinyinSyllable.matchKind(units: units, typed: typed) else { continue }
                if kind == .typing, let first = units.first, typed.count < first.count, units.count > 1 { continue }
                result.append(Match(entry: entry, consumed: consumed, kind: kind,
                                    jianpinCount: quanpin ? 0 : entry.syllables.count, fuzzyCount: 0))
            }
            if lexicon.fuzzyEnabled {
                for item in lexicon.searchLattice(lattice, inputCount: input.utf8.count, from: start) where item.fuzzyCount > 0 {
                    let typed = String(Array(input)[start..<(start + item.consumed)])
                    // Exact complete syllables keep the first page; fuzzy is only a fallback.
                    if PinyinSyllable.all.contains(typed) { continue }
                    result.append(Match(entry: item.entry, consumed: item.consumed, kind: item.kind,
                                        jianpinCount: item.jianpinCount, fuzzyCount: item.fuzzyCount))
                }
            }
            return result
        }
    }

    private static func beam(input: String, lexicon: PinyinLexicon, previous: String?, lattice: [[PinyinArc]], mode: Mode) -> State? {
        let n = input.utf8.count
        var buckets = Array(repeating: [State](), count: n + 1)
        buckets[0] = [State(pos: 0, last: previous ?? "", score: 0, path: [])]
        let width = 28
        for pos in 0..<n {
            let states = Array(buckets[pos].sorted { $0.score > $1.score }.prefix(width))
            if states.isEmpty { continue }
            let options = matches(in: input, at: pos, lexicon: lexicon, lattice: lattice, mode: mode)
            for state in states {
                for item in options {
                    let end = pos + item.consumed
                    if item.kind == .prefix { continue }
                    if item.kind == .typing && end != n { continue }
                    if item.consumed == 0 { continue }
                    var score = state.score + PinyinLanguageModel.shared.score(
                        word: item.entry.word, previous: state.last.isEmpty ? nil : state.last, letters: item.consumed)
                    score += beamBonus(item.kind)
                    score += greedyBonus(entry: item.entry, input: input, pos: pos)
                    score += shortArcPunish(item.jianpinCount)
                    score += fuzzyPunish(item.fuzzyCount)
                    if item.kind == .exact { score += 0.85 * Double(max(item.entry.syllables.count - 1, 0)) }
                    buckets[end].append(State(pos: end, last: item.entry.word, score: score, path: state.path + [item.entry]))
                }
            }
        }
        for i in buckets.indices where buckets[i].count > width {
            buckets[i] = Array(buckets[i].sorted { $0.score > $1.score }.prefix(width))
        }
        return buckets[n].max(by: { $0.score < $1.score })
    }
}
