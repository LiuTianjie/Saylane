import Foundation

enum PinyinMatchKind: Equatable {
    case exact, typing, prefix
}

/// Syllable DAG used by Doubao (`SyllableLattice` + `CreateSuperJpLattice`)
/// and by libpinyin/Google Pinyin: full-syllable arcs plus abbreviated initials.
enum PinyinArcType: Equatable { case full, jianpin, typing, fuzzy, correct }

struct PinyinArc: Equatable {
    var start: Int
    var end: Int
    var type: PinyinArcType
    var syllable: String
    var initial: String
}

enum PinyinSyllable {
    static let all: Set<String> = [
        "a", "ai", "an", "ang", "ao",
        "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi", "bian", "biao", "bie", "bin", "bing", "bo", "bu",
        "ca", "cai", "can", "cang", "cao", "ce", "cei", "cen", "ceng", "ci", "cong", "cou", "cu", "cuan", "cui", "cun", "cuo",
        "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong", "chou", "chu", "chua", "chuai",
        "chuan", "chuang", "chui", "chun", "chuo",
        "da", "dai", "dan", "dang", "dao", "de", "dei", "den", "deng", "di", "dia", "dian", "diao", "die", "ding", "diu",
        "dong", "dou", "du", "duan", "dui", "dun", "duo",
        "e", "ei", "en", "eng", "er",
        "fa", "fan", "fang", "fei", "fen", "feng", "fiao", "fo", "fou", "fu",
        "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu", "gua", "guai", "guan", "guang",
        "gui", "gun", "guo",
        "ha", "hai", "han", "hang", "hao", "he", "hei", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan", "huang",
        "hui", "hun", "huo",
        "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu", "ju", "juan", "jue", "jun",
        "ka", "kai", "kan", "kang", "kao", "ke", "kei", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang",
        "kui", "kun", "kuo",
        "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia", "lian", "liang", "liao", "lie", "lin", "ling",
        "liu", "lo", "long", "lou", "lu", "luan", "lue", "lun", "luo", "lv", "lve",
        "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian", "miao", "mie", "min", "ming", "miu",
        "mo", "mou", "mu",
        "n", "na", "nai", "nan", "nang", "nao", "ne", "nei", "nen", "neng", "ng", "ni", "nian", "niang", "niao", "nie",
        "nin", "ning", "niu", "nong", "nou", "nu", "nuan", "nue", "nun", "nuo", "nv", "nve",
        "o", "ou",
        "pa", "pai", "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po", "pou", "pu",
        "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan", "que", "qun",
        "ran", "rang", "rao", "re", "ren", "reng", "ri", "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo",
        "sa", "sai", "san", "sang", "sao", "se", "sen", "seng", "si", "song", "sou", "su", "suan", "sui", "sun", "suo",
        "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng", "shi", "shou", "shu", "shua", "shuai",
        "shuan", "shuang", "shui", "shun", "shuo",
        "ta", "tai", "tan", "tang", "tao", "te", "tei", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu",
        "tuan", "tui", "tun", "tuo",
        "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu",
        "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun",
        "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu", "yuan", "yue", "yun",
        "za", "zai", "zan", "zang", "zao", "ze", "zei", "zen", "zeng", "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo",
        "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng", "zhi", "zhong", "zhou", "zhu", "zhua",
        "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo"
    ]

    static let weakSyllables: Set<String> = ["a", "e", "o", "n", "m", "ng"]

    static let prefixes: Set<String> = {
        var set = Set<String>()
        for syllable in all {
            var prefix = ""
            for character in syllable {
                prefix.append(character)
                set.insert(prefix)
            }
        }
        return set
    }()

    static func normalize(_ raw: String) -> String {
        var scaled = raw.replacingOccurrences(of: "ü", with: "v")
            .replacingOccurrences(of: "Ü", with: "v")
            .replacingOccurrences(of: "u:", with: "v")
        scaled = scaled.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en"))
        var output = ""
        output.reserveCapacity(scaled.count)
        for character in scaled.lowercased() {
            if character == "'" { continue }
            guard character.isASCII, character.isLetter else { continue }
            output.append(character)
        }
        if output.hasPrefix("lue") || output.contains("lue") {
            output = output.replacingOccurrences(of: "lue", with: "lve")
        }
        if output.hasPrefix("nue") || output.contains("nue") {
            output = output.replacingOccurrences(of: "nue", with: "nve")
        }
        return output
    }

    static func consumedLength(of preedit: String, normalizedCount: Int) -> Int {
        var seen = 0
        var count = 0
        for character in preedit {
            if character == "'" {
                count += 1
                continue
            }
            if seen == normalizedCount { break }
            seen += 1
            count += 1
        }
        return count
    }

    static func isSyllablePrefix(_ value: String) -> Bool { prefixes.contains(value) }

    static func coversQuanpin(_ input: String) -> Bool {
        let chars = Array(input)
        guard !chars.isEmpty else { return false }
        var complete = Array(repeating: false, count: chars.count + 1)
        complete[0] = true
        for index in 0..<chars.count where complete[index] {
            for length in 1...6 {
                let end = index + length
                guard end <= chars.count else { break }
                let piece = String(chars[index..<end])
                if length == 1 && end != chars.count && weakSyllables.contains(piece) { continue }
                if all.contains(piece) { complete[end] = true }
            }
        }
        if complete[chars.count] { return true }
        for index in 0..<chars.count where complete[index] {
            if isSyllablePrefix(String(chars[index...])) { return true }
        }
        return false
    }

    static func segment(_ input: String) -> [String]? {
        let chars = Array(input)
        var previous = Array(repeating: -1, count: chars.count + 1)
        previous[0] = 0
        for index in 0..<chars.count where previous[index] >= 0 {
            for length in (1...6).reversed() {
                let end = index + length
                guard end <= chars.count else { continue }
                let piece = String(chars[index..<end])
                if length == 1 && end != chars.count && weakSyllables.contains(piece) { continue }
                if all.contains(piece) && previous[end] < 0 { previous[end] = index }
            }
        }
        guard previous[chars.count] >= 0 else { return nil }
        var parts: [String] = []
        var end = chars.count
        while end > 0 {
            let start = previous[end]
            parts.append(String(chars[start..<end]))
            end = start
        }
        return parts.reversed()
    }

    /// Classify how `typed` covers a word's syllables.
    /// exact: typed is the whole word; typing: last syllable still incomplete;
    /// prefix: typed is whole syllables of a longer word.
    static func matchKind(units: [String], typed: String) -> PinyinMatchKind? {
        guard !typed.isEmpty, !units.isEmpty else { return nil }
        var remaining = typed[...]
        for (index, unit) in units.enumerated() {
            if remaining.hasPrefix(unit) {
                remaining = remaining.dropFirst(unit.count)
                if remaining.isEmpty {
                    return index == units.count - 1 ? .exact : .prefix
                }
            } else if unit.hasPrefix(remaining) {
                return .typing
            } else {
                return nil
            }
        }
        return remaining.isEmpty ? .exact : nil
    }

    static func longestSyllable(in input: String, from pos: Int) -> String? {
        let chars = Array(input)
        guard pos >= 0, pos < chars.count else { return nil }
        var best: String?
        for length in 1...6 {
            let end = pos + length
            guard end <= chars.count else { break }
            let piece = String(chars[pos..<end])
            if length == 1 && end != chars.count && weakSyllables.contains(piece) { continue }
            if all.contains(piece) { best = piece }
        }
        if let best { return best }
        let rest = String(chars[pos...])
        if rest.count <= 6 && isSyllablePrefix(rest) { return rest }
        return nil
    }

    static let initials: Set<String> = {
        var set = Set<String>()
        for syllable in all {
            set.insert(initial(of: syllable))
            set.insert(String(syllable.prefix(1)))
        }
        return set
    }()

    static func initial(of syllable: String) -> String {
        if syllable.hasPrefix("zh") || syllable.hasPrefix("ch") || syllable.hasPrefix("sh") {
            return String(syllable.prefix(2))
        }
        return String(syllable.prefix(1))
    }

    /// Doubao `OimeEngineFuzzyPair` / `SyllableLattice.CreatePinYinLattice(..., FuzzyType)`.
    /// Applied only to complete syllables so a single letter like `k` still cannot jump to 可以.
    static func fuzzyVariants(_ syllable: String) -> [String] {
        var found: [String] = []
        func add(_ value: String) {
            if value != syllable, all.contains(value) { found.append(value) }
        }
        if syllable.hasPrefix("zh") { add("z" + syllable.dropFirst(2)) }
        else if syllable.hasPrefix("ch") { add("c" + syllable.dropFirst(2)) }
        else if syllable.hasPrefix("sh") { add("s" + syllable.dropFirst(2)) }
        else if syllable.hasPrefix("z") { add("zh" + syllable.dropFirst(1)) }
        else if syllable.hasPrefix("c") { add("ch" + syllable.dropFirst(1)) }
        else if syllable.hasPrefix("s") { add("sh" + syllable.dropFirst(1)) }

        let head = initial(of: syllable)
        let tail = String(syllable.dropFirst(head.count))
        switch head {
        case "n": add("l" + tail)
        case "l": add("n" + tail); add("r" + tail)
        case "r": add("l" + tail)
        case "h": add("f" + tail)
        case "f": add("h" + tail)
        default: break
        }

        let finals: [(String, String)] = [
            ("iang", "ian"), ("uang", "uan"), ("ang", "an"), ("eng", "en"),
            ("ing", "in"), ("ong", "eng"), ("ong", "un")
        ]
        for (left, right) in finals {
            if syllable.hasSuffix(left) { add(String(syllable.dropLast(left.count)) + right) }
            if syllable.hasSuffix(right) { add(String(syllable.dropLast(right.count)) + left) }
        }
        if syllable == "huang" { add("wang") }
        if syllable == "wang" { add("huang") }
        if syllable == "hui" { add("fei") }
        if syllable == "fei" { add("hui") }
        return Array(Set(found))
    }

    /// Salvage an illegal last syllable (huancum → cun, zonggue → guo).
    /// Never runs on single letters, so `k` cannot become 可以.
    static func correctionVariants(_ piece: String) -> [String] {
        guard piece.count >= 2, piece.count <= 6, !all.contains(piece) else { return [] }
        var ranked: [(Int, String)] = []
        var seen = Set<String>()
        func add(_ value: String, _ rank: Int) {
            guard value != piece, all.contains(value), seen.insert(value).inserted else { return }
            ranked.append((rank, value))
        }
        let chars = Array(piece)
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) {
                var next = chars
                next.swapAt(i, i + 1)
                add(String(next), 0)
            }
        }
        let neighbors: [Character: [Character]] = [
            "q": ["w", "a"], "w": ["q", "e", "s", "a"], "e": ["w", "r", "d", "s"],
            "r": ["e", "t", "f", "d"], "t": ["r", "y", "g", "f"], "y": ["t", "u", "h", "g"],
            "u": ["y", "i", "j", "h"], "i": ["u", "o", "k", "j"], "o": ["i", "p", "l", "k"],
            "p": ["o", "l"], "a": ["q", "w", "s", "z"], "s": ["a", "w", "e", "d", "x", "z"],
            "d": ["s", "e", "r", "f", "c", "x"], "f": ["d", "r", "t", "g", "v", "c"],
            "g": ["f", "t", "y", "h", "b", "v"], "h": ["g", "y", "u", "j", "n", "b"],
            "j": ["h", "u", "i", "k", "m", "n"], "k": ["j", "i", "o", "l", "m"],
            "l": ["k", "o", "p"], "z": ["a", "s", "x"], "x": ["z", "s", "d", "c"],
            "c": ["x", "d", "f", "v"], "v": ["c", "f", "g", "b"], "b": ["v", "g", "h", "n"],
            "n": ["b", "h", "j", "m"], "m": ["n", "j", "k"]
        ]
        for i in chars.indices {
            for nb in neighbors[chars[i]] ?? [] {
                var next = chars
                next[i] = nb
                add(String(next), 1)
            }
        }
        if chars.count >= 3 {
            for i in chars.indices {
                var next = chars
                next.remove(at: i)
                add(String(next), 2)
            }
        }
        if chars.count <= 5 {
            for i in 0...chars.count {
                for ch in "abcdefghijklmnopqrstuvwxyz" {
                    var next = chars
                    next.insert(ch, at: i)
                    add(String(next), 3)
                }
            }
        }
        for i in chars.indices {
            for ch in "abcdefghijklmnopqrstuvwxyz" where ch != chars[i] {
                var next = chars
                next[i] = ch
                add(String(next), 4)
            }
        }
        ranked.sort { $0.0 < $1.0 }
        return Array(ranked.prefix(12).map(\.1))
    }

    /// Doubao `SyllableDict.CommonPrefixSearch` + `CreateSuperJpLattice`.
    static func lattice(_ input: String, fuzzy: Bool = true) -> [[PinyinArc]] {
        let chars = Array(input)
        let n = chars.count
        var arcs = Array(repeating: [PinyinArc](), count: max(n, 1))
        guard n > 0 else { return arcs }
        for i in 0..<n {
            var seen = Set<String>()
            func add(_ arc: PinyinArc) {
                let key = "\(arc.type)-\(arc.end)-\(arc.syllable)-\(arc.initial)"
                if seen.insert(key).inserted { arcs[i].append(arc) }
            }
            for length in 1...6 {
                let end = i + length
                guard end <= n else { break }
                let piece = String(chars[i..<end])
                if length == 1 && end != n && weakSyllables.contains(piece) { continue }
                if all.contains(piece) {
                    add(PinyinArc(start: i, end: end, type: .full, syllable: piece, initial: initial(of: piece)))
                    // Doubao OimeEngineFuzzyPair: z2zh/c2ch/s2sh/an2ang/en2eng/in2ing/...
                    if fuzzy {
                        for variant in fuzzyVariants(piece) {
                            add(PinyinArc(start: i, end: end, type: .fuzzy, syllable: variant, initial: initial(of: variant)))
                        }
                    }
                }
            }
            let one = String(chars[i])
            if i + 1 < n, chars[i + 1] == "h", one == "z" || one == "c" || one == "s" {
                let digraph = String(chars[i...i + 1])
                if initials.contains(digraph) {
                    add(PinyinArc(start: i, end: i + 2, type: .jianpin, syllable: digraph, initial: digraph))
                }
            }
            if initials.contains(one) {
                add(PinyinArc(start: i, end: i + 1, type: .jianpin, syllable: one, initial: one))
            }
            let rest = String(chars[i...])
            if rest.count <= 6, isSyllablePrefix(rest), !all.contains(rest) {
                add(PinyinArc(start: i, end: n, type: .typing, syllable: rest, initial: initial(of: rest)))
            }
        }
        for i in arcs.indices {
            arcs[i].sort { lhs, rhs in
                func rank(_ type: PinyinArcType) -> Int {
                    switch type {
                    case .full: return 0
                    case .typing: return 1
                    case .fuzzy: return 2
                    case .correct: return 3
                    case .jianpin: return 4
                    }
                }
                if lhs.type != rhs.type { return rank(lhs.type) < rank(rhs.type) }
                return (lhs.end - lhs.start) > (rhs.end - rhs.start)
            }
        }
        if fuzzy {
            func appendCorrect(at index: Int, rest: String) {
                guard (2...6).contains(rest.count), !all.contains(rest) else { return }
                for variant in correctionVariants(rest) {
                    arcs[index].append(PinyinArc(start: index, end: n, type: .correct,
                                                 syllable: variant, initial: initial(of: variant)))
                }
            }
            var index = 0
            var progressed = false
            while index < n {
                if let full = arcs[index].first(where: { $0.type == .full }) {
                    appendCorrect(at: full.end, rest: String(chars[full.end...]))
                    index = full.end
                    progressed = true
                    continue
                }
                appendCorrect(at: index, rest: String(chars[index...]))
                break
            }
            if !progressed {
                appendCorrect(at: 0, rest: String(chars))
            }
        }
        return arcs
    }

    /// Doubao marked-text style: `nihao` → `ni'hao`, keep user-typed quotes.
    static func display(_ preedit: String) -> String {
        if preedit.isEmpty { return "" }
        if preedit.contains("'") { return preedit }
        let input = normalize(preedit)
        guard !input.isEmpty else { return preedit }
        var parts: [String] = []
        var index = 0
        while index < input.count {
            guard let syllable = longestSyllable(in: input, from: index) else {
                parts.append(String(input.dropFirst(index)))
                break
            }
            parts.append(syllable)
            index += syllable.count
        }
        return parts.joined(separator: "'")
    }
}
