import Foundation

/// The downloaded recognizers write Latin text the way it sounded. Letters
/// said one by one come back apart ("A P P"), and a name said in two breaths
/// comes back as two words ("Chat GPT", "Mac OS"). Here they are put the way
/// they are written. What was heard is not changed: only spaces and case are.
enum LatinWriting {
    static func tidied(_ model: String, system: String) -> String {
        names(lettersJoined(model, system: system))
    }

    // MARK: - Letters said one by one

    private static let spelled = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])[A-Za-z](?: [A-Za-z])+(?![A-Za-z0-9])")

    /// "A P P" → "APP". Inside an English sentence a single letter is also a
    /// word ("Plan A", "I"), so there two letters are joined only where the
    /// system's recognizer wrote them as one, and three or more only when they
    /// are written alike.
    static func lettersJoined(_ text: String, system: String = "") -> String {
        let source = text as NSString
        var result = text
        for match in spelled.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let run = source.substring(with: match.range)
            let letters = run.replacingOccurrences(of: " ", with: "")
            if inEnglish(source, match.range) {
                let alike = letters == letters.uppercased() || letters == letters.lowercased()
                guard letters.count >= 3 ? alike : word(letters, in: system) else { continue }
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: letters.uppercased())
        }
        return result
    }

    /// The nearest thing on either side, past spaces, is a Latin word.
    private static func inEnglish(_ text: NSString, _ range: NSRange) -> Bool {
        func isLetter(_ index: Int) -> Bool {
            let unit = text.character(at: index)
            return (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
        }
        var before = range.location - 1
        while before >= 0, text.character(at: before) == 0x20 { before -= 1 }
        var after = range.location + range.length
        while after < text.length, text.character(at: after) == 0x20 { after += 1 }
        return (before >= 0 && isLetter(before)) || (after < text.length && isLetter(after))
    }

    private static func word(_ letters: String, in text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pattern = "(?i)(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: letters))(?![A-Za-z0-9])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Names

    /// Names with a way of writing of their own. `|` is where a space is
    /// heard when the name is said slowly; it is closed only in a sentence
    /// with Chinese in it, where the two halves are not words of their own.
    /// Without it only the case is put right.
    private static let canonical = [
        "Chat|GPT", "Open|AI", "Git|Hub", "Git|Lab", "You|Tube", "Deep|Seek", "Tik|Tok", "Linked|In", "Whats|App", "Pay|Pal",
        "i|Phone", "i|Pad", "i|Cloud", "i|Mac", "iOS", "iPadOS", "mac|OS", "watch|OS", "vision|OS", "Mac|Book", "Air|Pods",
        "AirDrop", "AirTag", "FaceTime", "CarPlay", "HomePod", "MagSafe", "TestFlight", "App Store", "Xcode", "VS Code",
        "Java|Script", "Type|Script", "Power|Point", "Swift|UI", "UI|Kit", "App|Kit", "Web|Kit", "Web|Socket", "Graph|QL",
        "Py|Torch", "Tensor|Flow", "Num|Py", "MySQL", "Postgre|SQL", "SQLite", "Mongo|DB", "Dev|Ops", "FastAPI",
        "WeChat", "OneDrive", "OneNote", "Harmony|OS", "GPT",
    ]

    private static let rules: [(joined: NSRegularExpression, cased: NSRegularExpression, written: String)] = canonical.map { entry in
        let parts = entry.components(separatedBy: "|").map { NSRegularExpression.escapedPattern(for: $0) }
        func pattern(_ separator: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])\(parts.joined(separator: separator))(?![A-Za-z0-9])", options: .caseInsensitive)
        }
        return (pattern(" ?"), pattern(""), entry.replacingOccurrences(of: "|", with: ""))
    }

    static func names(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }) else { return text }
        let chinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        var result = text
        for rule in rules {
            let expression = chinese ? rule.joined : rule.cased
            result = expression.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                                         withTemplate: NSRegularExpression.escapedTemplate(for: rule.written))
        }
        return result
    }
}
