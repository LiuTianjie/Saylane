import Foundation
import Darwin

struct PinyinEntry: Equatable {
    var word: String
    var syllables: [String]
    var frequency: Int

    var full: String { syllables.joined() }
    var initials: String { String(syllables.compactMap(\.first)) }

    init(word: String, syllables: [String], frequency: Int) {
        self.word = word
        self.syllables = syllables
        self.frequency = frequency
    }

    init(word: String, pinyin: String, frequency: Int) {
        self.word = word
        self.frequency = frequency
        self.syllables = PinyinSyllable.segment(pinyin) ?? [pinyin]
    }
}

final class PinyinLexicon: @unchecked Sendable {
    static let shared = PinyinLexicon()
    static let pageSize = 9

    fileprivate final class Node {
        var children: [UInt8: Node] = [:]
        var exact: [PinyinEntry] = []
        var partial: [PinyinEntry] = []
    }

    fileprivate final class SylNode {
        var children: [String: SylNode] = [:]
        var byInitial: [String: [String]] = [:]
        var exact: [PinyinEntry] = []
        var maxFreq = 1

        func finish() {
            for child in children.values { child.finish() }
            exact.sort { $0.frequency > $1.frequency }
            // Keep every 1-character reading so 栈/盏/佛 etc. remain pageable.
            let chars = exact.filter { $0.word.count == 1 }
            var phrases = exact.filter { $0.word.count > 1 }
            if phrases.count > 96 { phrases = Array(phrases.prefix(96)) }
            exact = chars + phrases
            exact.sort { $0.frequency > $1.frequency }
            maxFreq = max(exact.first?.frequency ?? 1, children.values.map(\.maxFreq).max() ?? 1)
            var map: [String: [String]] = [:]
            for syllable in children.keys {
                map[PinyinSyllable.initial(of: syllable), default: []].append(syllable)
                map[String(syllable.prefix(1)), default: []].append(syllable)
            }
            for (key, list) in map {
                let unique = Array(Set(list)).sorted { (children[$0]?.maxFreq ?? 0) > (children[$1]?.maxFreq ?? 0) }
                map[key] = unique
            }
            byInitial = map
        }
    }

    private let lock = NSLock()
    private var quanpin = Node()
    private var jianpin = Node()
    private var sylRoot = SylNode()
    private var unigrams: [String: Int] = [:]
    private(set) var isReady = false
    private(set) var entryCount = 0
    var fuzzyEnabled = true

    private var table: [String: PinyinEntry] = [:]

    func loadDefault() {
        let dict = Bundle.main.url(forResource: "pinyin", withExtension: "dict.tsv")
            ?? URL(fileURLWithPath: "Sources/Resources/pinyin.dict.tsv")
        let chars = Bundle.main.url(forResource: "pinyin", withExtension: "chars.tsv")
            ?? URL(fileURLWithPath: "Sources/Resources/pinyin.chars.tsv")
        let core = Bundle.main.url(forResource: "pinyin", withExtension: "core.tsv")
            ?? URL(fileURLWithPath: "Sources/Resources/pinyin.core.tsv")
        let extra = Bundle.main.url(forResource: "pinyin", withExtension: "extra.tsv")
            ?? URL(fileURLWithPath: "Sources/Resources/pinyin.extra.tsv")
        table = [:]
        ingest(dict)
        ingest(chars)
        ingest(core)
        ingest(extra)
        ingestUserPhrases()
        rebuild(loadBigrams: true)
    }

    func load(from url: URL) {
        table = [:]
        ingest(url)
        rebuild(loadBigrams: true)
    }

    func overlay(from url: URL) {
        ingest(url)
        rebuild(loadBigrams: false)
    }

    private func ingest(_ url: URL) {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return }
        data.enumerateLines { line, _ in
            if line.isEmpty || line.hasPrefix("#") { return }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let frequency = Int(parts[1]) else { return }
            let syllables = parts[0].split(separator: " ").map(String.init).filter { !$0.isEmpty }
            let word = String(parts[2])
            guard !syllables.isEmpty, !word.isEmpty else { return }
            let entry = PinyinEntry(word: word, syllables: syllables, frequency: frequency)
            let key = entry.full + "\u{1f}" + word
            if let old = self.table[key] {
                if frequency > old.frequency { self.table[key] = entry }
            } else {
                self.table[key] = entry
            }
        }
    }

    private func rebuild(loadBigrams: Bool) {
        let quanpinRoot = Node()
        let jianpinRoot = Node()
        let syl = SylNode()
        var counts: [String: Int] = [:]
        let entries = Array(table.values)
        for entry in entries {
            Self.insert(entry, into: quanpinRoot, key: entry.full, capPartial: false, initialsKey: false)
            Self.insert(entry, into: jianpinRoot, key: entry.initials, capPartial: false, initialsKey: true)
            Self.insertSyl(entry, into: syl)
            counts[entry.word] = max(counts[entry.word, default: 0], entry.frequency)
        }
        Self.finish(quanpinRoot)
        Self.finish(jianpinRoot)
        syl.finish()
        lock.lock()
        quanpin = quanpinRoot
        jianpin = jianpinRoot
        sylRoot = syl
        unigrams = counts
        entryCount = entries.count
        isReady = !entries.isEmpty
        lock.unlock()
        PinyinLanguageModel.shared.loadUnigrams(counts)
        if loadBigrams { PinyinLanguageModel.shared.loadDefaultBigrams() }
    }

    func replace(with entries: [PinyinEntry]) {
        let quanpinRoot = Node()
        let jianpinRoot = Node()
        let syl = SylNode()
        var counts: [String: Int] = [:]
        for entry in entries {
            Self.insert(entry, into: quanpinRoot, key: entry.full, capPartial: false, initialsKey: false)
            Self.insert(entry, into: jianpinRoot, key: entry.initials, capPartial: false, initialsKey: true)
            Self.insertSyl(entry, into: syl)
            counts[entry.word] = max(counts[entry.word, default: 0], entry.frequency)
        }
        Self.finish(quanpinRoot)
        Self.finish(jianpinRoot)
        syl.finish()
        lock.lock()
        quanpin = quanpinRoot
        jianpin = jianpinRoot
        sylRoot = syl
        unigrams = counts
        entryCount = entries.count
        isReady = !entries.isEmpty
        lock.unlock()
        PinyinLanguageModel.shared.loadUnigrams(counts)
    }

    func boost(pinyin: String, word: String) {
        lock.lock()
        defer { lock.unlock() }
        for root in [quanpin, jianpin] {
            var node: Node? = root
            for byte in Array(pinyin.utf8) {
                node = node?.children[byte]
            }
            guard let node else { continue }
            if let index = node.exact.firstIndex(where: { $0.word == word }) {
                node.exact[index].frequency += 8_000
            }
        }
    }

    /// User-made phrase from committing characters one by one (Doubao 自造词).
    func learn(word: String, syllables: [String], frequency: Int = 400_000) {
        guard word.count >= 2, !syllables.isEmpty else { return }
        let entry = PinyinEntry(word: word, syllables: syllables, frequency: frequency)
        lock.lock()
        let key = entry.full + "\u{1f}" + word
        if let old = table[key] {
            let updated = PinyinEntry(word: word, syllables: syllables, frequency: max(old.frequency, frequency) + 8_000)
            table[key] = updated
            bumpExact(word: word, key: updated.full, initials: updated.initials, frequency: updated.frequency)
            lock.unlock()
            return
        }
        table[key] = entry
        Self.insert(entry, into: quanpin, key: entry.full, capPartial: false, initialsKey: false)
        Self.insert(entry, into: jianpin, key: entry.initials, capPartial: false, initialsKey: true)
        Self.insertSyl(entry, into: sylRoot)
        sortPath(quanpin, key: entry.full)
        sortPath(jianpin, key: entry.initials)
        sortSylPath(entry.syllables)
        lock.unlock()
    }

    private func bumpExact(word: String, key: String, initials: String, frequency: Int) {
        for (root, path) in [(quanpin, key), (jianpin, initials)] {
            var node: Node? = root
            for byte in Array(path.utf8) { node = node?.children[byte] }
            if let node, let index = node.exact.firstIndex(where: { $0.word == word }) {
                node.exact[index].frequency = frequency
                node.exact.sort { $0.frequency > $1.frequency }
            }
        }
        var node: SylNode? = sylRoot
        // syllables recovered from quanpin key via segment
        if let syllables = PinyinSyllable.segment(key) {
            for syllable in syllables { node = node?.children[syllable] }
            if let node, let index = node.exact.firstIndex(where: { $0.word == word }) {
                node.exact[index].frequency = frequency
                node.exact.sort { $0.frequency > $1.frequency }
            }
        }
    }

    private func sortPath(_ root: Node, key: String) {
        var node: Node? = root
        for byte in Array(key.utf8) {
            node = node?.children[byte]
            guard let node else { return }
            node.exact.sort { $0.frequency > $1.frequency }
            node.partial.sort { lhs, rhs in
                if lhs.syllables.count != rhs.syllables.count { return lhs.syllables.count < rhs.syllables.count }
                return lhs.frequency > rhs.frequency
            }
        }
    }

    private func sortSylPath(_ syllables: [String]) {
        var node: SylNode? = sylRoot
        for syllable in syllables {
            node = node?.children[syllable]
            guard let node else { return }
            node.exact.sort { $0.frequency > $1.frequency }
        }
    }

    private func ingestUserPhrases() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RTranslate", isDirectory: true)
            .appendingPathComponent("pinyin-user.tsv")
        guard let url, let data = try? String(contentsOf: url, encoding: .utf8) else { return }
        data.enumerateLines { line, _ in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.first == "C", parts.count == 4, let count = Int(parts[3]) else { return }
            let input = parts[1], word = parts[2]
            guard word.count >= 2, let syllables = PinyinSyllable.segment(input), syllables.count >= 2 else { return }
            let frequency = 200_000 + min(max(count, 1), 20) * 50_000
            let entry = PinyinEntry(word: word, syllables: syllables, frequency: frequency)
            let key = entry.full + "\u{1f}" + word
            if let old = self.table[key] {
                if frequency > old.frequency { self.table[key] = entry }
            } else {
                self.table[key] = entry
            }
        }
    }

    func candidates(for preedit: String, limit: Int = 48, context: [String] = []) -> [PinyinCandidate] {
        let input = PinyinSyllable.normalize(preedit)
        // A complete syllable must list every exact 1-char reading, not just the top 48.
        let resolved = PinyinSyllable.all.contains(input) ? max(limit, 256) : limit
        return PinyinDecoder.decode(preedit: preedit, lexicon: self, context: context, limit: resolved)
    }

    /// Doubao `Associate::UsrBigramAsso` + `AssoCommonHandle::AssoNgramAsso`.
    func associations(after word: String, limit: Int = 18) -> [PinyinCandidate] {
        PinyinLanguageModel.shared.associations(after: word, limit: limit).map { item in
            PinyinCandidate(word: item.word, pinyin: "", inputLength: 0, frequency: item.count,
                            preview: item.word, commitsAll: true)
        }
    }

    private static func insertSyl(_ entry: PinyinEntry, into root: SylNode) {
        var node = root
        for syllable in entry.syllables {
            if node.children[syllable] == nil { node.children[syllable] = SylNode() }
            node = node.children[syllable]!
        }
        node.exact.append(entry)
    }

    struct LatticeMatch {
        var entry: PinyinEntry
        var consumed: Int
        var kind: PinyinMatchKind
        var jianpinCount: Int
        var fuzzyCount: Int
    }

    /// Doubao dict `Search(SyllableLattice)`: walk syllable trie along lattice arcs.
    func searchLattice(_ lattice: [[PinyinArc]], inputCount: Int, from start: Int) -> [LatticeMatch] {
        lock.lock()
        let root = sylRoot
        lock.unlock()
        var found: [LatticeMatch] = []
        var seen = Set<String>()
        var bestJP: [ObjectIdentifier: [Int: Int]] = [:]
        var visits = 0
        func emit(_ node: SylNode, _ pos: Int, _ kind: PinyinMatchKind, _ jp: Int, _ fuzzy: Int) {
            guard pos > start else { return }
            for entry in Self.exactForSearch(node.exact, phraseCap: 32) {
                let key = "\(pos)|\(entry.word)|\(kind == .typing ? "t" : "e")|\(fuzzy)"
                if seen.insert(key).inserted {
                    found.append(LatticeMatch(entry: entry, consumed: pos - start, kind: kind,
                                              jianpinCount: jp, fuzzyCount: fuzzy))
                }
            }
        }
        func dfs(_ node: SylNode, _ pos: Int, _ jp: Int, _ fuzzy: Int, _ depth: Int) {
            visits += 1
            if depth > 8 || visits > 5000 { return }
            let id = ObjectIdentifier(node)
            let cost = jp * 10 + fuzzy * 20
            if let old = bestJP[id]?[pos], old <= cost { return }
            var map = bestJP[id] ?? [:]
            map[pos] = cost
            bestJP[id] = map
            emit(node, pos, .exact, jp, fuzzy)
            guard pos < inputCount, pos < lattice.count else { return }
            let canFull = lattice[pos].contains { $0.type == .full && node.children[$0.syllable] != nil }
            for arc in lattice[pos] {
                switch arc.type {
                case .full:
                    if let child = node.children[arc.syllable] {
                        dfs(child, arc.end, jp, fuzzy, depth + 1)
                    }
                case .fuzzy:
                    if let child = node.children[arc.syllable] {
                        dfs(child, arc.end, jp, fuzzy + 1, depth + 1)
                    }
                case .correct:
                    if let child = node.children[arc.syllable] {
                        dfs(child, arc.end, jp, fuzzy + 2, depth + 1)
                    }
                case .jianpin:
                    if canFull { continue }
                    let keys = (node.byInitial[arc.initial] ?? []).prefix(10)
                    for syllable in keys {
                        if let child = node.children[syllable] {
                            dfs(child, arc.end, jp + 1, fuzzy, depth + 1)
                        }
                    }
                case .typing:
                    guard arc.end == inputCount else { continue }
                    for (syllable, child) in node.children where syllable.hasPrefix(arc.syllable) {
                        emit(child, arc.end, .typing, jp, fuzzy)
                    }
                }
            }
        }
        dfs(root, start, 0, 0, 0)
        return found
    }

    func matches(in input: String, at start: Int, quanpin: Bool) -> [(PinyinEntry, Int, Bool)] {
        lock.lock()
        let root = quanpin ? self.quanpin : self.jianpin
        lock.unlock()
        guard start >= 0, start < input.utf8.count else { return [] }
        let bytes = Array(input.utf8)
        var node: Node? = root
        var found: [(PinyinEntry, Int, Bool)] = []
        for offset in 0..<(bytes.count - start) {
            node = node?.children[bytes[start + offset]]
            guard let node else { break }
            let consumed = offset + 1
            let atEnd = start + consumed == bytes.count
            for entry in Self.exactForSearch(node.exact, phraseCap: 64) {
                found.append((entry, consumed, false))
            }
            if atEnd {
                let typed = String(bytes[start...].map { Character(UnicodeScalar($0)) })
                let weakBlocker = !node.exact.isEmpty && PinyinSyllable.weakSyllables.contains(typed)
                    && node.exact.allSatisfy { $0.syllables.count == 1 && $0.syllables[0] == typed }
                if node.exact.isEmpty || weakBlocker {
                    for entry in node.partial.prefix(24) where Self.allowsPartial(entry, typed: typed, initials: !quanpin) {
                        found.append((entry, consumed, true))
                    }
                } else {
                    for entry in node.partial.prefix(8) where entry.syllables.count > 1 &&
                        Self.allowsPartial(entry, typed: typed, initials: !quanpin) {
                        found.append((entry, consumed, true))
                    }
                }
            }
        }
        return found
    }

    private static func insert(_ entry: PinyinEntry, into root: Node, key: String, capPartial: Bool, initialsKey: Bool) {
        guard !key.isEmpty, let first = entry.syllables.first else { return }
        var node = root
        let bytes = Array(key.utf8)
        for (index, byte) in bytes.enumerated() {
            if node.children[byte] == nil { node.children[byte] = Node() }
            node = node.children[byte]!
            let prefixLen = index + 1
            if prefixLen == bytes.count {
                node.exact.append(entry)
                continue
            }
            let firstComplete = initialsKey ? prefixLen >= 2 : prefixLen >= first.count
            let allowPartial = entry.syllables.count == 1 || firstComplete
            if allowPartial {
                node.partial.append(entry)
                if capPartial && node.partial.count > 32 {
                    node.partial.sort { lhs, rhs in
                        if lhs.syllables.count != rhs.syllables.count { return lhs.syllables.count < rhs.syllables.count }
                        return lhs.frequency > rhs.frequency
                    }
                    node.partial.removeLast(node.partial.count - 24)
                }
            }
        }
    }

    private static func exactForSearch(_ entries: [PinyinEntry], phraseCap: Int) -> [PinyinEntry] {
        if entries.count <= phraseCap { return entries }
        let chars = entries.filter { $0.word.count == 1 }
        let phrases = entries.filter { $0.word.count > 1 }.prefix(phraseCap)
        return chars + phrases
    }

    private static func allowsPartial(_ entry: PinyinEntry, typed: String, initials: Bool) -> Bool {
        guard let first = entry.syllables.first, entry.full.hasPrefix(typed) || entry.initials.hasPrefix(typed) else {
            return false
        }
        if initials {
            return entry.syllables.count == 1 || typed.count >= 2
        }
        // Incomplete first syllable: only single-syllable words. "k" must not become 可以.
        if typed.count < first.count { return entry.syllables.count == 1 }
        return true
    }

    private static func finish(_ node: Node) {
        node.exact.sort { $0.frequency > $1.frequency }
        node.partial.sort { lhs, rhs in
            if lhs.syllables.count != rhs.syllables.count { return lhs.syllables.count < rhs.syllables.count }
            return lhs.frequency > rhs.frequency
        }
        if node.partial.count > 24 { node.partial.removeLast(node.partial.count - 24) }
        for child in node.children.values { finish(child) }
    }

    private static func firstWords(_ input: String, preedit: String, root: Node, limit: Int) -> [PinyinCandidate] {
        var node: Node? = root
        var ranked: [(Int, Int, Int, PinyinCandidate)] = []
        for (index, byte) in Array(input.utf8).enumerated() {
            node = node?.children[byte]
            guard let node else { break }
            let depth = index + 1
            let leftover = depth < input.count
            let length = PinyinSyllable.consumedLength(of: preedit, normalizedCount: depth)
            if leftover {
                for entry in node.exact {
                    ranked.append((1, -depth, -entry.frequency, PinyinCandidate(
                        word: entry.word, pinyin: entry.full, inputLength: length, frequency: entry.frequency)))
                }
            } else {
                for entry in node.exact {
                    ranked.append((0, -entry.frequency, -entry.word.count, PinyinCandidate(
                        word: entry.word, pinyin: entry.full, inputLength: length, frequency: entry.frequency)))
                }
                for entry in node.partial.prefix(12) {
                    ranked.append((2, -entry.frequency, -entry.word.count, PinyinCandidate(
                        word: entry.word, pinyin: entry.full, inputLength: length, frequency: entry.frequency)))
                }
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
        var seen = Set<String>()
        var unique: [PinyinCandidate] = []
        for item in ranked {
            if seen.insert(item.3.word).inserted { unique.append(item.3) }
            if unique.count == limit { break }
        }
        return unique
    }

    private static func bestPhrase(_ input: String, root: Node) -> PinyinEntry? {
        var node: Node? = root
        for byte in Array(input.utf8) {
            node = node?.children[byte]
            guard node != nil else { return nil }
        }
        return node?.exact.max(by: { $0.frequency < $1.frequency })
    }

    private static func viterbi(_ input: String, root: Node) -> PinyinEntry? {

        let count = input.utf8.count
        var bestScore = Array(repeating: -Double.infinity, count: count + 1)
        var bestPath = Array(repeating: [PinyinEntry](), count: count + 1)
        bestScore[0] = 0
        let bytes = Array(input.utf8)
        for start in 0..<count where bestScore[start].isFinite {
            var node: Node? = root
            for offset in 0..<(count - start) {
                node = node?.children[bytes[start + offset]]
                guard let node else { break }
                let depth = offset + 1
                let atEnd = start + depth == count
                let entries: ArraySlice<PinyinEntry>
                if atEnd {
                    entries = node.exact.isEmpty ? node.partial.prefix(8) : node.exact.prefix(24)
                } else {
                    entries = node.exact.prefix(24)
                }

                for entry in entries {
                    let score = bestScore[start] + log(Double(entry.frequency + 1)) + 4.0 * Double(depth) - 16.0
                    let end = start + depth
                    if score > bestScore[end] {
                        bestScore[end] = score
                        bestPath[end] = bestPath[start] + [entry]
                    }
                }
            }
        }
        guard bestScore[count].isFinite else { return nil }
        let words = bestPath[count]
        guard !words.isEmpty else { return nil }
        if words.count == 1 { return words[0] }
        return PinyinEntry(word: words.map(\.word).joined(), syllables: words.flatMap(\.syllables),
                           frequency: words.map(\.frequency).min() ?? 1)
    }
}
