import Foundation
import Observation

/// One thing learned from the user's edits: the recognizer wrote `heard`, the
/// user made it `corrected`. A pair of spellings and nothing of the sentence
/// they stood in.
struct LearnedCorrection: Codable, Equatable, Sendable, Identifiable {
    var heard: String
    var corrected: String
    /// In how many dictations the user made this same correction.
    var seen: Int
    /// See `CorrectionRules.Pair.replaceable`.
    var replaceable: Bool
    /// When it was last learned, applied, or its corrected spelling written.
    var lastUsed: Date

    var id: String { heard + "\u{1F}" + corrected }
}

/// Everything learned, as a value.
///
/// How a pair is used:
/// - Its corrected spelling biases recognition from the next dictation on,
///   like a term of the personal vocabulary. A bias only makes a spelling more
///   likely, so one correction is enough to earn it.
/// - The heard spelling is replaced in later final texts only once the same
///   correction was made in two dictations. One edit can be a one-off: another
///   person with a similar name, a slip in the edit itself. The second time
///   the recognizer has already had the hint and still wrote the same thing,
///   and the user fixed it the same way: that is a pattern. Even then only
///   when the heard spelling is not ordinary language, and only while it has
///   one corrected spelling — two mean it depends on the sentence. The
///   replacement is literal: unlike a term the user typed into their
///   vocabulary, a learned pair is not stretched to everything that sounds
///   like it, and it is made only where the heard spelling stands as a word
///   of its own (see `apply`).
/// - A correction made the other way round takes the pair back: the user
///   undid what Saylane wrote.
/// - A pair that is neither made again nor seen in a dictation for 90 days is
///   dropped, and the list holds at most 200.
struct LearnedCorrections: Equatable, Sendable {
    private(set) var items: [LearnedCorrection] = []

    static let capacity = 200
    static let lifetime: TimeInterval = 90 * 86_400
    static let sightingsToReplace = 2
    /// How many corrected spellings are offered to the recognizer.
    static let biasLimit = 30

    init(_ items: [LearnedCorrection] = []) {
        var seen = Set<String>()
        self.items = items.filter { Self.isValid($0) && seen.insert($0.id).inserted }
        trim()
    }

    /// What a file may hold; anything else in it is not ours.
    private static func isValid(_ item: LearnedCorrection) -> Bool {
        CorrectionRules.heardLength.contains(item.heard.count) && CorrectionRules.correctedLength.contains(item.corrected.count)
            && CorrectionRules.isReplacement(heard: item.heard, corrected: item.corrected) && item.seen >= 1
    }

    var isEmpty: Bool { items.isEmpty }

    /// The pairs most recently used first, as the settings list them.
    var listed: [LearnedCorrection] { items.sorted { $0.lastUsed > $1.lastUsed } }

    /// Take in the pairs of one dictation. Returns how many are new and how many now replace.
    @discardableResult
    mutating func learn(_ pairs: [CorrectionRules.Pair], now: Date) -> (new: Int, replacing: Int) {
        expire(now: now)
        let before = Set(replacements.map(\.heard))
        var new = 0
        for pair in pairs {
            if let undone = items.firstIndex(where: { $0.heard == pair.corrected && $0.corrected == pair.heard }) {
                items.remove(at: undone)
            } else if let known = items.firstIndex(where: { $0.heard == pair.heard && $0.corrected == pair.corrected }) {
                items[known].seen += 1
                items[known].lastUsed = now
                // Ordinary once is ordinary: a pair is never upgraded to replacing.
                items[known].replaceable = items[known].replaceable && pair.replaceable
            } else {
                items.append(LearnedCorrection(heard: pair.heard, corrected: pair.corrected, seen: 1,
                                               replaceable: pair.replaceable, lastUsed: now))
                new += 1
            }
        }
        trim()
        return (new, replacements.count { !before.contains($0.heard) })
    }

    mutating func remove(_ id: LearnedCorrection.ID) { items.removeAll { $0.id == id } }

    mutating func removeAll() { items.removeAll() }

    mutating func expire(now: Date) {
        items.removeAll { now.timeIntervalSince($0.lastUsed) > Self.lifetime }
    }

    /// A dictation was written: the pairs whose corrected spelling it contains
    /// are in use, and the ones nobody has used for too long go. Coarse on
    /// purpose — a day is close enough, and the file is not rewritten after
    /// every sentence. Returns whether anything changed.
    mutating func noteWritten(_ text: String, now: Date) -> Bool {
        let before = items.count
        expire(now: now)
        var changed = items.count != before
        for index in items.indices where now.timeIntervalSince(items[index].lastUsed) > 86_400
            && text.range(of: items[index].corrected, options: .caseInsensitive) != nil {
            items[index].lastUsed = now
            changed = true
        }
        return changed
    }

    private mutating func trim() {
        guard items.count > Self.capacity else { return }
        items = Array(listed.prefix(Self.capacity))
    }

    // MARK: - Use

    /// Corrected spellings for the recognizer, most recently used first.
    var biasTerms: [String] {
        var seen = Set<String>()
        return Array(listed.map(\.corrected).filter { seen.insert($0).inserted }.prefix(Self.biasLimit))
    }

    /// What a pair does now.
    enum Standing: Equatable, Sendable {
        /// Its heard spelling is replaced in final texts, where it stands as a word of its own.
        case replaces
        /// It will be, once the same correction is made again.
        case replacesAfterNext
        /// Its corrected spelling is a hint to the recognizer and nothing more.
        case hint
    }

    func standing(of item: LearnedCorrection) -> Standing {
        let contested = items.contains { $0.id != item.id && $0.heard.lowercased() == item.heard.lowercased() }
        guard item.replaceable, !contested else { return .hint }
        return item.seen >= Self.sightingsToReplace ? .replaces : .replacesAfterNext
    }

    /// The pairs that have earned a replacement, longest heard spelling first.
    var replacements: [LearnedCorrection] {
        items.filter { standing(of: $0) == .replaces }.sorted { $0.heard.count > $1.heard.count }
    }

    /// Write the corrected spelling where a heard one that earned it stands
    /// as a unit. A Latin spelling is a whole word, in any case: "say lane"
    /// yes, "essay lanes" no. A Chinese one must begin and end where
    /// `lexicon` cuts this sentence into words or names: "章三" → "张三"
    /// leaves "文章三篇" alone.
    func apply(to text: String, lexicon: CorrectionLexicon) -> String {
        var result = text
        for item in replacements {
            let current = result as NSString
            let options: NSString.CompareOptions = item.heard.allSatisfy(\.isASCII) ? .caseInsensitive : []
            var found: [NSRange] = []
            var from = 0
            while from < current.length {
                let hit = current.range(of: item.heard, options: options, range: NSRange(location: from, length: current.length - from))
                guard hit.location != NSNotFound, hit.length > 0 else { break }
                found.append(hit)
                from = hit.location + hit.length
            }
            guard !found.isEmpty else { continue }
            // The sentence is only cut when a heard spelling is in it at all.
            var cuts: Set<Int>?
            func isCut(_ offset: Int) -> Bool {
                if cuts == nil {
                    cuts = Set((lexicon.words(result) + lexicon.names(result)).flatMap { [$0.lowerBound, $0.upperBound] })
                }
                return cuts?.contains(offset) == true
            }
            let rewritten = NSMutableString(string: result)
            for hit in found.reversed() {
                let end = hit.location + hit.length
                let first = current.character(at: hit.location), last = current.character(at: end - 1)
                let before = hit.location > 0 ? current.character(at: hit.location - 1) : 0
                let after = end < current.length ? current.character(at: end) : 0
                guard Self.isLatin(first) ? !Self.isLatin(before) : Self.isSign(first) || isCut(hit.location),
                      Self.isLatin(last) ? !Self.isLatin(after) : Self.isSign(last) || isCut(end) else { continue }
                rewritten.replaceCharacters(in: hit, with: item.corrected)
            }
            result = rewritten as String
        }
        return result
    }

    private static func isLatin(_ unit: unichar) -> Bool {
        (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    /// A sign a term is written with ("C++"): it ends the spelling by itself.
    private static func isSign(_ unit: unichar) -> Bool { unit < 0x80 && !isLatin(unit) }
}

/// Learns from what the input method reads back, and keeps what was learned in
/// one file on this Mac (`Learned/corrections.json`: pairs, counts and dates).
/// The text of a dictation is held in memory only until its edits are judged.
@MainActor @Observable
final class CorrectionLearner {
    private struct Watched {
        let written: String
        let since: Date
        /// What the latest reading that still showed the dictation would teach.
        var pairs: [CorrectionRules.Pair] = []
    }

    private struct File: Codable {
        var schema: Int
        var pairs: [LearnedCorrection]
    }

    /// What became of a report from the input method. Counts only: this is what diagnostics may say.
    struct Outcome: Equatable {
        /// Nothing more is expected from this dictation; the input method can stop watching it.
        var finished = false
        var learned = 0
        var new = 0
        var replacing = 0
    }

    private(set) var corrections = LearnedCorrections()
    @ObservationIgnored private var watched: [UUID: Watched] = [:]
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let lexicon: CorrectionLexicon
    @ObservationIgnored private let now: () -> Date

    /// Dictations whose edits may still arrive. The input method watches three.
    static let watchLimit = 4
    static let watchLifetime: TimeInterval = 600
    private static let fileLimit = 256_000

    init(fileURL: URL = AppDirectories.learnedCorrectionsFile, lexicon: CorrectionLexicon = .system,
         now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.lexicon = lexicon
        self.now = now
        load()
        warmLexicon()
    }

    /// The system loads its name tagger on first use, which takes a moment
    /// (about 80 ms). A replacement consults it while a final text is being
    /// written, so once there is one the first use is made ahead of time.
    private func warmLexicon() {
        guard !corrections.replacements.isEmpty else { return }
        let lexicon = lexicon
        Task.detached(priority: .utility) {
            _ = lexicon.names("预热")
            _ = lexicon.words("预热")
        }
    }

    // MARK: - Learning

    /// A dictation was written through the input method, which may report edits to it.
    func wrote(_ text: String, session: UUID) {
        retire { now().timeIntervalSince($0.since) > Self.watchLifetime }
        if watched.count >= Self.watchLimit, let oldest = watched.min(by: { $0.value.since < $1.value.since })?.key {
            finish(oldest)
        }
        watched[session] = Watched(written: text, since: now())
    }

    /// The input method read a dictation back.
    func received(_ report: BridgeReadBack) -> Outcome {
        guard var entry = watched[report.session] else { return Outcome(finished: true) }
        var gone = false
        if let text = report.text {
            switch CorrectionRules.read(written: entry.written, now: text, startsDocument: report.startsDocument,
                                        endsDocument: report.endsDocument, lexicon: lexicon) {
            case .gone: gone = true
            case .pairs(let pairs): entry.pairs = pairs
            }
            watched[report.session] = entry
        }
        // While the dictation is still there the user may still be editing it:
        // what counts is how it reads when it is sent, left or gone.
        guard gone || report.closed else { return Outcome() }
        return finish(report.session)
    }

    /// Learning was switched off: nothing that was being watched is learned from.
    func stopWatching() { watched.removeAll() }

    @discardableResult
    private func finish(_ session: UUID) -> Outcome {
        guard let entry = watched.removeValue(forKey: session) else { return Outcome(finished: true) }
        guard !entry.pairs.isEmpty else { return Outcome(finished: true) }
        let result = corrections.learn(entry.pairs, now: now())
        save()
        if result.replacing > 0 { warmLexicon() }
        return Outcome(finished: true, learned: entry.pairs.count, new: result.new, replacing: result.replacing)
    }

    private func retire(where ended: (Watched) -> Bool) {
        for (session, entry) in watched where ended(entry) { finish(session) }
    }

    // MARK: - Use and control

    /// A dictation was written, by whatever route.
    func noteWritten(_ text: String) {
        if corrections.noteWritten(text, now: now()) { save() }
    }

    func forget(_ id: LearnedCorrection.ID) {
        corrections.remove(id)
        save()
    }

    func forgetAll() {
        corrections.removeAll()
        watched.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - File

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), data.count <= Self.fileLimit,
              let file = try? JSONDecoder().decode(File.self, from: data), file.schema == 1 else { return }
        var loaded = LearnedCorrections(file.pairs)
        loaded.expire(now: now())
        corrections = loaded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(File(schema: 1, pairs: corrections.items)) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {}
    }
}
