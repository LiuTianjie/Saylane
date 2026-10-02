import AppKit
import CoreText
import Carbon.HIToolbox
import Foundation

enum ScreenModifier {
    static let shift: UInt64 = 1 << 17
    static let control: UInt64 = 1 << 18
    static let option: UInt64 = 1 << 19
    static let command: UInt64 = 1 << 20
    static let relevant: UInt64 = shift | control | option | command
}

struct ScreenCaptureShortcut: Equatable, Hashable {
    var keyCode: UInt16
    var modifierFlags: UInt64

    static let optionT = ScreenCaptureShortcut(keyCode: UInt16(kVK_ANSI_T), modifierFlags: ScreenModifier.option)

    var normalizedFlags: UInt64 { modifierFlags & ScreenModifier.relevant }

    func matches(keyCode: UInt16, flags: UInt64) -> Bool {
        keyCode == self.keyCode && (flags & ScreenModifier.relevant) == normalizedFlags
    }

    var isFunctionKey: Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
             kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
             kVK_F18, kVK_F19, kVK_F20:
            return true
        default:
            return false
        }
    }

    var isUsable: Bool {
        if isFunctionKey { return true }
        return normalizedFlags != 0
    }

    var displayName: String {
        ScreenCaptureShortcut.modifierSymbols(normalizedFlags) + ScreenCaptureShortcut.keyName(keyCode)
    }

    static func modifierSymbols(_ flags: UInt64) -> String {
        var text = ""
        if flags & ScreenModifier.control != 0 { text += "⌃" }
        if flags & ScreenModifier.option != 0 { text += "⌥" }
        if flags & ScreenModifier.shift != 0 { text += "⇧" }
        if flags & ScreenModifier.command != 0 { text += "⌘" }
        return text
    }

    static func keyName(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return String(localized: "空格")
        case kVK_Return: return "↩"
        case kVK_Escape: return "Esc"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default: return String(localized: "键\(keyCode)")
        }
    }
}

/// Bounded to the active screenshot session; never persisted to disk.
struct ScreenTranslationCache {
    private struct Key: Hashable { let direction: String; let text: String }
    private var values: [Key: String] = [:]
    private var bytes = 0

    func missing(_ texts: [String], direction: String) -> [String] {
        var seen = Set<String>()
        return texts.filter { seen.insert($0).inserted && values[Key(direction: direction, text: $0)] == nil }
    }

    func value(_ text: String, direction: String) -> String? {
        values[Key(direction: direction, text: text)]
    }

    mutating func store(_ text: String, translation: String, direction: String) {
        let cost = text.utf8.count + translation.utf8.count
        guard cost <= 256_000, !translation.isEmpty else { return }
        let key = Key(direction: direction, text: text)
        guard values[key] == nil else { return }
        if values.count >= 512 || bytes + cost > 256_000 { values.removeAll(); bytes = 0 }
        values[key] = translation
        bytes += cost
    }
}




enum ScreenTranslate {
    static let minimumSelection: CGFloat = 12

    static let dragThreshold: CGFloat = 5

    static let windowCornerRadius: CGFloat = 10

    static let minimumOCRConfidence: Float = 0.3

    static func screenModes(a: AppLanguage, b: AppLanguage) -> [TranslationDirection] {
        if a == b { return [TranslationDirection(source: a, target: a)] }
        return [
            TranslationDirection(source: b, target: a),
            TranslationDirection(source: a, target: b)
        ]
    }

    static func screenMode(current: TranslationDirection?, a: AppLanguage, b: AppLanguage) -> TranslationDirection {
        let modes = screenModes(a: a, b: b)
        if let current, modes.contains(current) { return current }
        return modes[0]
    }

    static func cycled(current: TranslationDirection, a: AppLanguage, b: AppLanguage) -> TranslationDirection {
        let modes = screenModes(a: a, b: b)
        guard let index = modes.firstIndex(of: current) else { return modes[0] }
        return modes[(index + 1) % modes.count]
    }

    /// AppKit global rect → display-local capture rect with origin at the top-left.
    static func captureSourceRect(appKitRect: CGRect, screenFrame: CGRect) -> CGRect {
        let clamped = appKitRect.intersection(screenFrame)
        guard !clamped.isNull, !clamped.isEmpty else { return .zero }
        let local = CGRect(
            x: clamped.origin.x - screenFrame.origin.x,
            y: clamped.origin.y - screenFrame.origin.y,
            width: clamped.width,
            height: clamped.height
        )
        return CGRect(
            x: local.origin.x,
            y: screenFrame.height - local.origin.y - local.height,
            width: local.width,
            height: local.height
        )
    }

    /// Vision uses the order of recognition languages as a hint. Keep the
    /// selected source first and make the list deterministic; a Set here made
    /// OCR quality depend on hash ordering.
    static func ocrLanguageHints(source: AppLanguage, target: AppLanguage) -> [String] {
        var hints: [String] = []
        for value in [source.speechIdentifier, source.rawValue, target.speechIdentifier, target.rawValue] {
            if !value.isEmpty && !hints.contains(value) {
                hints.append(value)
            }
        }
        return hints
    }

    /// Code, formulas, line numbers, paths. Prefer leaving original pixels
    /// over covering a math line with a wrong translation.
    static func isMachineText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // Vision already rejects ambiguous one-glyph OCR. Keep two-character
        // controls such as “设置”, “OK” and “AI” so they can be translated.
        if t.count == 1 { return true }
        let compact = t.filter { !$0.isWhitespace }
        if compact.allSatisfy({ $0.isNumber || ":.,%/+-".contains($0) }) { return true }

        let lowered = t.lowercased()
        if lowered.contains("=>") || lowered.contains("===") || lowered.contains("!==") { return true }
        if lowered.contains("const ") || lowered.contains("console.") { return true }
        if lowered.contains("};") || lowered.contains("());") || lowered.contains("++") { return true }
        if lowered.contains("typeof ") || lowered.contains("interface ") { return true }
        if lowered.contains("function ") && (t.contains("{") || t.contains("=>")) { return true }
        if (lowered.hasPrefix("let ") || lowered.hasPrefix("var ")) && t.contains("=") { return true }
        if (lowered.hasPrefix("import ") || lowered.hasPrefix("export ")) && (t.contains("from") || t.contains("{") || t.contains("*")) { return true }
        if t.hasPrefix("\"") && (t.hasSuffix(",") || t.hasSuffix("\"")) { return true }
        if t.contains("/") && t.contains(".") && !t.contains(" ") { return true }

        let math = CharacterSet(charactersIn: "√∑∫∞×÷−≤≥∂∈∉∀∃∝≪≫⊂⊃⊆⊇∧∨¬⊕⊗≈≠±")
        let mathCount = t.unicodeScalars.filter { math.contains($0) }.count
        if mathCount >= 2 { return true }

        let heavy = CharacterSet(charactersIn: "{}\\`$")
        if t.unicodeScalars.filter({ heavy.contains($0) }).count >= 2 { return true }

        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = t.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if t.count >= 6, letters <= max(1, t.count / 5) { return true }
        if t.count <= 16, letters <= 3, (digits + (t.count - letters)) >= 4 { return true }

        let parens = t.filter { $0 == "(" || $0 == ")" }.count
        if parens >= 4 { return true }
        if parens >= 2, letters < 12 { return true }
        if isEquationLike(t) { return true }
        return false
    }

    /// OCR of a displayed formula: equals plus function-call punctuation,
    /// or a split "where head = Attention(" fragment. Long prose with a
    /// single "=" ("h = 8 parallel heads") stays translatable.
    static func isEquationLike(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbols = t.filter { "=()[]{}^_".contains($0) }.count
        if t.filter({ $0 == "=" }).count >= 2 { return true }
        if t.contains("=") && symbols >= 4 { return true }
        if t.contains("=") && t.contains("(") && t.count < 80 { return true }
        return false
    }

    static func shouldReplace(_ text: String) -> Bool {
        !isMachineText(text)
    }

    /// Visible pin frame on screen. A large original selection may be taller
    /// than the available display area; it is scrolled without scaling.
    static func visiblePinRect(
        content: CGSize,
        originRect: CGRect,
        visible: CGRect,
        chromeHeight: CGFloat = 44,
        margin: CGFloat = 8
    ) -> CGRect {
        let maxHeight = max(80, visible.height - chromeHeight - margin * 2)
        let maxWidth = max(80, visible.width - margin * 2)
        let height = min(max(80, content.height), maxHeight)
        let width = min(max(80, content.width), maxWidth)
        var x = originRect.minX
        var y = originRect.maxY - height
        x = min(max(visible.minX + margin, x), max(visible.minX + margin, visible.maxX - margin - width))
        y = min(max(visible.minY + chromeHeight + margin, y), max(visible.minY + margin, visible.maxY - margin - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func joinParagraphLines(_ texts: [String]) -> String {
        var out = ""
        for raw in texts {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if out.isEmpty {
                out = t
                continue
            }
            if out.hasSuffix("-"), let first = t.first, first.isLetter, first.isLowercase {
                out.removeLast()
                out += t
                continue
            }
            if let last = out.last, let first = t.first, isCJK(last), isCJK(first) {
                out += t
                continue
            }
            out += " " + t
        }
        return out
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    struct HoverCandidate: Equatable {
        var bounds: CGRect
        var owner: String
    }

    /// CGWindow bounds (origin top-left of the main display) → AppKit global rect.
    static func appKitRect(fromCGWindowBounds bounds: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: bounds.origin.x,
            y: mainDisplayHeight - bounds.origin.y - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }

    static func topmostBounds(at point: CGPoint, candidates: [HoverCandidate]) -> CGRect? {
        candidates.first { $0.bounds.insetBy(dx: -1, dy: -1).contains(point) }?.bounds
    }
}
