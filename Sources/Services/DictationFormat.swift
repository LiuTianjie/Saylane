import Foundation

/// How a finished dictation is written, as chosen in the settings. Applied to
/// the text that lands at the caret, after recognition, translation and
/// proofreading; previews are not touched.
enum DictationFormat {
    struct Options: Equatable, Sendable {
        /// No full stop at the very end, as people write in chats.
        var dropFinalStop = false
        /// A space between Chinese and Latin letters or digits. Off means none:
        /// recognizers put one there in some sentences and not in others.
        var spaceBetweenScripts = false
    }

    static func apply(_ text: String, _ options: Options) -> String {
        var result = unspaced(text)
        if options.spaceBetweenScripts { result = spaced(result) }
        if options.dropFinalStop { result = withoutFinalStop(result) }
        return result
    }

    /// No space where Chinese meets Latin letters or digits, and none beside
    /// Chinese punctuation. Spaces between Latin words stay.
    static func unspaced(_ text: String) -> String {
        guard text.contains(" ") else { return text }
        var result = text
        for pattern in ["(?<=\\p{Han})[ \\t]+(?=[A-Za-z0-9])", "(?<=[A-Za-z0-9])[ \\t]+(?=\\p{Han})",
                        "(?<=[，。；！？、：（）《》])[ \\t]+", "[ \\t]+(?=[，。；！？、：（）《》])"] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    /// Only a full stop goes: a question or an exclamation says something.
    static func withoutFinalStop(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, last == "。" || last == "." else { return text }
        let body = trimmed.dropLast()
        // "3.14." keeps nothing odd, but an ellipsis or an abbreviation's dot stays.
        if last == ".", body.last == "." { return text }
        return String(body)
    }

    static func spaced(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if let previous, (isHan(previous) && isLatin(character)) || (isLatin(previous) && isHan(character)) {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    private static func isLatin(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
