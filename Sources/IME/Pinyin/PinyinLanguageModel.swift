import Foundation
import Darwin

final class PinyinLanguageModel: @unchecked Sendable {
    static let shared = PinyinLanguageModel()
    static var persistEnabled = true
    private let lock = NSLock()
    private var unigram: [String: Int] = [:]
    private var history: [String: Int] = [:]
    private var bigram: [String: Int] = [:]
    private var totalUnigram = 1
    private var userUnigram: [String: Int] = [:]
    private var userBigram: [String: Int] = [:]
    private var successors: [String: [(word: String, count: Int)]] = [:]
    private var userSuccessors: [String: [(word: String, count: Int)]] = [:]
    private var userChoices: [String: [String: Int]] = [:]

    func loadUnigrams(_ counts: [String: Int]) {
        lock.lock()
        unigram = counts
        totalUnigram = max(counts.values.reduce(0, +), 1)
        lock.unlock()
    }

    func loadDefaultBigrams() {
        let url = Bundle.main.url(forResource: "pinyin", withExtension: "bigram.tsv")
            ?? URL(fileURLWithPath: "Sources/Resources/pinyin.bigram.tsv")
        loadBigrams(from: url)
        loadUser()
    }

    func loadBigrams(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var next: [String: Int] = [:]
        var hist: [String: Int] = [:]
        text.enumerateLines { line, _ in
            if line.isEmpty || line.hasPrefix("#") { return }
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let count = Int(parts[2]), count > 0 else { return }
            let left = String(parts[0]), right = String(parts[1])
            next[Self.key(left, right)] = count
            hist[left, default: 0] += count
        }
        let nextSuccessors = Self.rebuildSuccessors(next)
        lock.lock()
        bigram = next
        history = hist
        successors = nextSuccessors
        lock.unlock()
    }

    /// Doubao `Associate::UsrBigramAsso` then `AssoCommonHandle::AssoNgramAsso`.
    func associations(after word: String, limit: Int = 18) -> [(word: String, count: Int)] {
        guard !word.isEmpty else { return [] }
        var scored: [String: Int] = [:]
        lock.lock()
        let user = userSuccessors
        let sys = successors
        lock.unlock()
        for key in Self.contextKeys(word) {
            for item in user[key] ?? [] { scored[item.word, default: 0] += item.count * 24 }
            for item in sys[key] ?? [] { scored[item.word, default: 0] += item.count }
        }
        return scored.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.prefix(limit).map { (word: $0.key, count: $0.value) }
    }

    func score(word: String, previous: String?, letters: Int) -> Double {
        lock.lock()
        let uni = (unigram[word] ?? 0) + (userUnigram[word] ?? 0)
        let prev = previous ?? ""
        let biCount = prev.isEmpty ? 0 : (bigram[Self.key(prev, word)] ?? 0) + (userBigram[Self.key(prev, word)] ?? 0)
        let prevCount = prev.isEmpty ? 0 : (history[prev] ?? 0) + (userUnigram[prev] ?? 0)
        let total = totalUnigram
        lock.unlock()
        let uniLog = log(Double(max(uni, 1)))
        let biLog: Double
        if !prev.isEmpty, biCount > 0, prevCount > 0 {
            biLog = log(Double(biCount) / Double(prevCount))
        } else if prev.isEmpty {
            biLog = log(Double(max(uni, 1)) / Double(total))
        } else {
            biLog = log(0.4) + log(Double(max(uni, 1)) / Double(total))
        }
        return 0.25 * uniLog + biLog + 2.8 * Double(letters) - 2.0
    }

    /// Doubao `UsrDict` / `FirstIsBestUsrDict`: remember an explicit candidate choice.
    func clearUserForTests() {
        lock.lock()
        userUnigram = [:]
        userBigram = [:]
        userSuccessors = [:]
        userChoices = [:]
        lock.unlock()
    }

    func rememberChoice(input: String, word: String) {
        let key = PinyinSyllable.normalize(input)
        guard !key.isEmpty, !word.isEmpty else { return }
        lock.lock()
        var map = userChoices[key] ?? [:]
        map[word] = (map.values.max() ?? 0) + 1
        userChoices[key] = map
        let snapshotUni = userUnigram
        let snapshotBi = userBigram
        let snapshotChoices = userChoices
        lock.unlock()
        persist(unigram: snapshotUni, bigram: snapshotBi, choices: snapshotChoices)
    }

    func preferredWord(for input: String) -> String? {
        let key = PinyinSyllable.normalize(input)
        lock.lock()
        let map = userChoices[key] ?? [:]
        lock.unlock()
        return map.max(by: { $0.value < $1.value })?.key
    }

    func choiceCount(input: String, word: String) -> Int {
        let key = PinyinSyllable.normalize(input)
        lock.lock()
        let count = userChoices[key]?[word] ?? 0
        lock.unlock()
        return count
    }

    func record(previous: String?, word: String) {
        lock.lock()
        userUnigram[word, default: 0] += 8
        if let previous, !previous.isEmpty {
            userBigram[Self.key(previous, word), default: 0] += 12
            var list = userSuccessors[previous] ?? []
            if let index = list.firstIndex(where: { $0.word == word }) {
                list[index].count += 12
            } else {
                list.append((word: word, count: 12))
            }
            userSuccessors[previous] = Array(list.sorted { $0.count > $1.count }.prefix(24))
        }
        let snapshotUni = userUnigram
        let snapshotBi = userBigram
        let snapshotChoices = userChoices
        lock.unlock()
        persist(unigram: snapshotUni, bigram: snapshotBi, choices: snapshotChoices)
    }

    private static func key(_ left: String, _ right: String) -> String { left + "\u{1f}" + right }

    private static func contextKeys(_ word: String) -> [String] {
        var keys: [String] = []
        if !word.isEmpty { keys.append(word) }
        if word.count >= 2 { keys.append(String(word.suffix(2))) }
        if word.count >= 1 { keys.append(String(word.suffix(1))) }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private static func rebuildSuccessors(_ bigram: [String: Int]) -> [String: [(word: String, count: Int)]] {
        var map: [String: [(word: String, count: Int)]] = [:]
        for (key, count) in bigram {
            let parts = key.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            map[parts[0], default: []].append((word: parts[1], count: count))
        }
        for (left, list) in map {
            map[left] = Array(list.sorted { $0.count > $1.count }.prefix(24))
        }
        return map
    }

    private func persist(unigram: [String: Int], bigram: [String: Int], choices: [String: [String: Int]]) {
        guard Self.persistEnabled, let url = Self.userURL() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = ["# user pinyin counts"]
        for (word, count) in unigram { lines.append("U\t\(word)\t\(count)") }
        for (key, count) in bigram {
            let parts = key.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            if parts.count == 2 { lines.append("B\t\(parts[0])\t\(parts[1])\t\(count)") }
        }
        for (input, map) in choices {
            for (word, count) in map { lines.append("C\t\(input)\t\(word)\t\(count)") }
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func loadUser() {
        guard let url = Self.userURL(), let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var uni: [String: Int] = [:]
        var bi: [String: Int] = [:]
        var choices: [String: [String: Int]] = [:]
        text.enumerateLines { line, _ in
            let parts = line.split(separator: "\t").map(String.init)
            if parts.first == "U", parts.count == 3, let count = Int(parts[2]) {
                uni[parts[1]] = count
            } else if parts.first == "B", parts.count == 4, let count = Int(parts[3]) {
                bi[Self.key(parts[1], parts[2])] = count
            } else if parts.first == "C", parts.count == 4, let count = Int(parts[3]) {
                choices[parts[1], default: [:]][parts[2]] = count
            }
        }
        lock.lock()
        for (word, count) in uni { userUnigram[word] = max(userUnigram[word] ?? 0, count) }
        for (key, count) in bi { userBigram[key] = max(userBigram[key] ?? 0, count) }
        for (input, map) in choices {
            var current = userChoices[input] ?? [:]
            for (word, count) in map { current[word] = max(current[word] ?? 0, count) }
            userChoices[input] = current
        }
        userSuccessors = Self.rebuildSuccessors(userBigram)
        lock.unlock()
    }

    private static func userURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RTranslate", isDirectory: true)
            .appendingPathComponent("pinyin-user.tsv")
    }
}
