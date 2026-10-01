import Foundation

/// The downloaded recognizers spell numbers out ("M一芯片", "三十六G内存",
/// "iPhone十五"); the system's recognizer writes them the way they are written
/// ("M1", "36G", "iPhone 15"). Where both heard the same number, the final
/// text takes the system's way of writing it. Nothing else is changed: a
/// number the two disagree about stays as the model heard it.
enum NumeralFormat {
    static func followingSystem(model: String, system: String) -> String {
        var a: [Character] = []
        // Whether a space stood in front of each character: "iPhone 15 Pro" keeps its spaces.
        var spaced: [Bool] = []
        var sawSpace = false
        for character in system {
            if character.isWhitespace { sawSpace = true; continue }
            a.append(character); spaced.append(sawSpace); sawSpace = false
        }
        let b = Array(model)
        guard a.contains(where: \.isASCIIDigit), b.contains(where: { numerals.contains($0) }),
              a.count * b.count <= 4_000_000 else { return model }
        let partner = align(a, b)
        var result = b
        var edits: [(Range<Int>, [Character])] = []
        var i = 0
        while i < a.count {
            guard a[i].isASCIIDigit else { i += 1; continue }
            // The whole written number: 40,000 · 3.5 · 11:35 · 20%.
            var end = i
            while end < a.count, a[end].isASCIIDigit
                    || ((a[end] == "." || a[end] == "," || a[end] == ":") && end + 1 < a.count && a[end + 1].isASCIIDigit && end > i) { end += 1 }
            if end < a.count, a[end] == "%" { end += 1 }
            defer { i = end }
            // The stretch of the model's text between the neighbours of this number.
            let before = (0..<i).reversed().compactMap { partner[$0] }.first.map { $0 + 1 } ?? 0
            let after = (end..<a.count).compactMap { partner[$0] }.first ?? b.count
            guard before < after else { continue }
            let written = String(a[i..<end])
            // Only the number in it; a neighbour that was heard differently may have slipped in on either side.
            // A percentage and a time are spoken with words of their own.
            let allowed = written.hasSuffix("%") ? numerals.union(["分", "之"])
                : written.contains(":") ? numerals.union(["分", "整", "半"]) : numerals
            var low = before, high = after
            while low < high, !allowed.contains(b[low]) { low += 1 }
            while high > low, !allowed.contains(b[high - 1]) { high -= 1 }
            guard low < high, b[low..<high].allSatisfy({ allowed.contains($0) }),
                  says(String(b[low..<high]), written) else { continue }
            var replacement = Array(written)
            // "iPhone 15", but not "M 16": a single letter and its number are one name.
            if i > 1, spaced[i], a[i - 1].isASCIILetter, a[i - 2].isASCIILetter, low > 0, b[low - 1].isASCIILetter { replacement.insert(" ", at: 0) }
            if end < a.count, spaced[end], a[end].isASCIILetter, high < b.count, b[high].isASCIILetter { replacement.append(" ") }
            edits.append((low..<high, replacement))
        }
        for (range, digits) in edits.reversed() { result.replaceSubrange(range, with: digits) }
        return String(result)
    }

    private static let numerals: Set<Character> = ["零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "两", "幺", "点"]
    private static let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "幺": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                                  "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    private static let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10_000]

    /// Whether the spoken form and the written form are the same number.
    static func says(_ spoken: String, _ written: String) -> Bool {
        if written.hasSuffix("%") {
            guard spoken.hasPrefix("百分之") else { return false }
            return readings(of: String(spoken.dropFirst(3))).contains(String(written.dropLast()).replacingOccurrences(of: ",", with: ""))
        }
        if written.contains(":") {
            let clock = written.split(separator: ":").map(String.init)
            let parts = spoken.split(separator: "点", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard clock.count == 2, parts.count == 2, let minutes = Int(clock[1]),
                  readings(of: parts[0]).contains(clock[0]) || readings(of: parts[0]).contains(String(Int(clock[0]) ?? -1)) else { return false }
            var rest = parts[1]
            if rest.hasSuffix("分") { rest.removeLast() }
            switch rest {
            // 两点 alone is two o'clock or two points; the system guesses, and guesses wrong
            // ("在两点之间的运动" came back as "在2:00之间"). Only a time with minutes is taken over.
            case "", "整": return false
            case "半": return minutes == 30
            default: return readings(of: rest).contains(String(minutes)) || (rest.hasPrefix("零") && readings(of: String(rest.dropFirst())).contains(String(minutes)))
            }
        }
        guard !spoken.contains(where: { "分之整半".contains($0) }) else { return false }
        return readings(of: spoken).contains(written.replacingOccurrences(of: ",", with: ""))
    }

    /// The ways a spelled-out number can be written in digits: read as a
    /// quantity (三十六 → 36, 三百八 → 380) and read digit by digit (一五 → 15).
    static func readings(of spelled: String) -> Set<String> {
        let parts = spelled.split(separator: "点", maxSplits: 1, omittingEmptySubsequences: false).map(Array.init)
        guard let whole = parts.first, !whole.isEmpty else { return [] }
        var wholes = Set<String>()
        if whole.allSatisfy({ digits[$0] != nil }) { wholes.insert(String(whole.map { Character(String(digits[$0]!)) })) }
        if let value = quantity(whole) { wholes.insert(String(value)) }
        guard parts.count == 2 else { return wholes }
        guard !parts[1].isEmpty, parts[1].allSatisfy({ digits[$0] != nil }) else { return [] }
        let fraction = String(parts[1].map { Character(String(digits[$0]!)) })
        return Set(wholes.map { $0 + "." + fraction })
    }

    private static func quantity(_ characters: [Character]) -> Int? {
        guard characters.contains(where: { units[$0] != nil }) else {
            return characters.count == 1 ? digits[characters[0]] : nil
        }
        var total = 0, section = 0, pending: Int?, lastUnit = 0
        for character in characters {
            if let digit = digits[character] {
                guard pending == nil || digit == 0 || pending == 0 else { return nil }
                pending = digit
            } else if let unit = units[character] {
                if unit == 10_000 {
                    total += (section + (pending ?? 0)) * unit
                    section = 0
                } else {
                    section += (pending ?? (unit == 10 ? 1 : 0)) * unit
                    guard pending != nil || unit == 10 else { return nil }
                }
                pending = nil
                lastUnit = unit
            } else {
                return nil
            }
        }
        // 三百八 is 380, 一万二 is 12000: a last bare digit counts in the unit below the last one.
        if let pending, pending != 0, lastUnit >= 100, characters.count >= 2, units[characters[characters.count - 2]] != nil {
            section += pending * (lastUnit / 10)
        } else {
            section += pending ?? 0
        }
        return total + section
    }

    /// For each character of `a`, the index of the character of `b` it lines up
    /// with, or nil. Letters compare without case; a digit lines up with a numeral for free.
    private static func align(_ a: [Character], _ b: [Character]) -> [Int?] {
        func cost(_ x: Character, _ y: Character) -> Int {
            if x == y || x.lowercased() == y.lowercased() { return 0 }
            if x.isASCIIDigit, numerals.contains(y) { return 0 }
            return 2
        }
        let n = a.count, m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { table[i][0] = i }
        for j in 0...m { table[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    table[i][j] = min(table[i - 1][j - 1] + cost(a[i - 1], b[j - 1]), table[i - 1][j] + 1, table[i][j - 1] + 1)
                }
            }
        }
        var partner = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0, j > 0 {
            let step = cost(a[i - 1], b[j - 1])
            if table[i][j] == table[i - 1][j - 1] + step {
                // Only what matched is an anchor; a substitution is not.
                if step == 0, !a[i - 1].isASCIIDigit { partner[i - 1] = j - 1 }
                i -= 1; j -= 1
            } else if table[i][j] == table[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return partner
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
