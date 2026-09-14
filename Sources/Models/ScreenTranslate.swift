import AppKit
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
        case kVK_Space: return "空格"
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
        default: return "键\(keyCode)"
        }
    }
}

struct ScreenOCRLine: Equatable {
    var text: String
    var visionBox: CGRect
    var translation: String = ""
    var confidence: Float = 1
}

struct ScreenParagraph: Equatable {
    var original: String
    var translation: String = ""
    var visionBox: CGRect
    var lineHeight: CGFloat
    var linePitch: CGFloat
    var isHeading: Bool
    var lineCount: Int
}

struct ScreenLaidOutBlock: Equatable {
    var text: String
    var rect: CGRect
    var sourceRect: CGRect = .zero
    var fontSize: CGFloat
    var linePitch: CGFloat = 0
    var isHeading: Bool
    var centered: Bool = false
    var background: NSColor = .white
    var foreground: NSColor = .black
    /// True when a translation had to be truncated to keep the selected
    /// screen rectangle fixed. The renderer uses the last-visible-line clamp;
    /// this flag is kept explicit so layout tests do not mistake clipping for
    /// a successful fit.
    var isClipped: Bool = false
}

enum ScreenTranslate {
    static let minimumSelection: CGFloat = 12
    static let dragThreshold: CGFloat = 5
    static let windowCornerRadius: CGFloat = 10
    /// Scale the system font so its typographic line box fills the OCR box.
    /// SF Pro's (ascender − descender) is ~1.18× the point size; using the
    /// point size as the box height makes Core Text skip the line.
    static let fontToLineHeight: CGFloat = 1.0
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

    /// Vision normalized box (origin bottom-left) → canvas rect (origin top-left).
    static func topLeftRect(visionBox: CGRect, canvasSize: CGSize) -> CGRect {
        CGRect(
            x: visionBox.origin.x * canvasSize.width,
            y: (1 - visionBox.origin.y - visionBox.height) * canvasSize.height,
            width: visionBox.width * canvasSize.width,
            height: visionBox.height * canvasSize.height
        )
    }

    static func readingFont(size: CGFloat, heading: Bool) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: heading ? .semibold : .regular)
    }

    static func fontSize(lineHeight: CGFloat, heading: Bool = false) -> CGFloat {
        let probe = readingFont(size: 100, heading: heading)
        let lineBox = max(1, probe.ascender - probe.descender)
        return min(64, max(5, lineHeight * 100 / lineBox * fontToLineHeight))
    }

    /// How far a plate may grow before it hits another OCR box.
    static func padLimits(box: CGRect, obstacles: [CGRect]) -> (x: CGFloat, y: CGFloat) {
        var padX = CGFloat.greatestFiniteMagnitude
        var padY = CGFloat.greatestFiniteMagnitude
        for other in obstacles {
            if abs(other.midX - box.midX) < 0.8 && abs(other.midY - box.midY) < 0.8 {
                continue
            }
            let horizontallyOverlaps = other.maxX > box.minX && other.minX < box.maxX
            if horizontallyOverlaps {
                if other.maxY <= box.minY + 0.6 {
                    padY = min(padY, (box.minY - other.maxY) / 2)
                } else if other.minY >= box.maxY - 0.6 {
                    padY = min(padY, (other.minY - box.maxY) / 2)
                }
            }
            if abs(other.midY - box.midY) < max(box.height, other.height) * 0.65 {
                if other.maxX <= box.minX + 0.6 {
                    padX = min(padX, (box.minX - other.maxX) / 2)
                } else if other.minX >= box.maxX - 0.6 {
                    padX = min(padX, (other.minX - box.maxX) / 2)
                }
            }
        }
        return (padX, padY)
    }

    /// Adjacent Vision fragments on the same baseline become one line.
    /// Vertical neighbors stay separate: never reflow a paragraph.
    static func mergeFragments(_ lines: [ScreenOCRLine]) -> [ScreenOCRLine] {
        guard lines.count > 1 else { return lines }
        let heights = lines.map(\.visionBox.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let rowTolerance = medianHeight * 0.42
        let maxGap = medianHeight * 1.5
        let ordered = lines.sorted { lhs, rhs in
            if abs(lhs.visionBox.midY - rhs.visionBox.midY) > rowTolerance {
                return lhs.visionBox.midY > rhs.visionBox.midY
            }
            return lhs.visionBox.minX < rhs.visionBox.minX
        }
        var rows: [[ScreenOCRLine]] = [[ordered[0]]]
        for line in ordered.dropFirst() {
            let rowY = rows[rows.count - 1][0].visionBox.midY
            if abs(line.visionBox.midY - rowY) <= rowTolerance {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { row -> [ScreenOCRLine] in
            let sorted = row.sorted { $0.visionBox.minX < $1.visionBox.minX }
            var merged: [ScreenOCRLine] = [sorted[0]]
            for line in sorted.dropFirst() {
                var last = merged[merged.count - 1]
                let gap = line.visionBox.minX - last.visionBox.maxX
                if gap <= maxGap {
                    last.text += " " + line.text
                    last.visionBox = last.visionBox.union(line.visionBox)
                    last.confidence = min(last.confidence, line.confidence)
                    if !line.translation.isEmpty {
                        last.translation = [last.translation, line.translation]
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                    }
                    merged[merged.count - 1] = last
                } else {
                    merged.append(line)
                }
            }
            return merged
        }
    }

    /// Code, formulas, line numbers, paths. Prefer leaving original pixels
    /// over covering a math line with a wrong translation.
    static func isMachineText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.count <= 2 { return true }
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

    static func shouldReplace(_ line: ScreenOCRLine) -> Bool {
        line.confidence >= minimumOCRConfidence && shouldReplace(line.text)
    }

    static func shouldReplace(_ line: ScreenOCRLine, medianHeight: CGFloat) -> Bool {
        guard shouldReplace(line) else { return false }
        if line.confidence < 0.6 && line.visionBox.height > medianHeight * 1.4 {
            return false
        }
        return true
    }

    /// Snap Vision jitter to the page's typical line height, but keep
    /// real size changes (timestamps, headings) that sit clearly apart.
    static func smoothedHeight(_ height: CGFloat, median: CGFloat) -> CGFloat {
        guard median > 0 else { return height }
        let ratio = height / median
        if ratio > 1.7 { return median }
        if ratio >= 0.65 && ratio <= 1.40 { return median }
        return height
    }

    /// Height of the dominant body cluster. Score by occupied width so a
    /// few wide chat/body lines beat many narrow sidebar labels. Absolute
    /// page fractions are not used: a tight crop and a full window of the
    /// same text must pick the same cluster.
    static func bodyLineHeight(_ heights: [CGFloat]) -> CGFloat {
        bodyLineHeight(heights.map { ($0, 1) })
    }

    static func bodyLineHeight(_ samples: [(height: CGFloat, weight: CGFloat)]) -> CGFloat {
        let sorted = samples.filter { $0.height > 0 }.sorted { $0.height < $1.height }
        guard let first = sorted.first else { return 0.02 }
        if sorted.count == 1 { return first.height }
        var best = first.height
        var bestScore: CGFloat = 0
        for candidate in sorted {
            let slack = candidate.height * 0.22
            let members = sorted.filter { abs($0.height - candidate.height) <= slack }
            let widths = members.map(\.weight).sorted()
            let typicalWidth = widths[widths.count / 2]
            // Widest cluster is the body (chat/article), not a pile of
            // sidebar labels. Count only breaks ties.
            let score = typicalWidth * 100 + CGFloat(members.count)
            if score > bestScore || (score == bestScore && candidate.height < best) {
                bestScore = score
                best = candidate.height
            }
        }
        return best
    }

    static func textHeight(text: String, fontSize: CGFloat, width: CGFloat, heading: Bool, linePitch: CGFloat = 0) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        let pitch = linePitch > 0 ? max(linePitch, fontSize) : fontSize
        paragraph.minimumLineHeight = pitch
        paragraph.maximumLineHeight = pitch
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(8, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: readingFont(size: max(5, fontSize), heading: heading),
                .paragraphStyle: paragraph
            ]
        )
        return ceil(bounds.height)
    }

    static func overlapsX(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX - 1 && b.minX < a.maxX - 1
    }

    /// Keep every plate on its original OCR box. A long translation may
    /// grow into the empty gap before the next box; it never moves, and
    /// it never covers the next line.
    static func expandAndStack(_ items: [ScreenLaidOutBlock], gap: CGFloat = 4) -> [ScreenLaidOutBlock] {
        guard !items.isEmpty else { return items }
        let sources = items.map { $0.sourceRect.width > 1 ? $0.sourceRect : $0.rect }
        return items.enumerated().map { index, item in
            var next = item
            let source = sources[index]
            let insetX = max(3, item.fontSize * 0.12)
            let width = max(8, source.width - insetX * 2)
            var font = item.fontSize
            var pitch = item.linePitch > 0 ? item.linePitch : item.fontSize
            if pitch > source.height, source.height > 4 {
                pitch = source.height
                font = min(font, source.height)
            }
            var needed = textHeight(
                text: item.text,
                fontSize: font,
                width: width,
                heading: item.isHeading,
                linePitch: pitch
            )
            let room = padLimits(box: source, obstacles: sources).y
            let extra = room.isFinite ? max(0, room) : needed
            let maxHeight = source.height + extra
            while needed > maxHeight + 1, font > item.fontSize * 0.72 {
                font = max(item.fontSize * 0.72, font * 0.9)
                pitch = font
                needed = textHeight(
                    text: item.text,
                    fontSize: font,
                    width: width,
                    heading: item.isHeading,
                    linePitch: pitch
                )
            }
            next.fontSize = font
            next.linePitch = pitch
            next.rect = source
            if needed > source.height + 1 {
                next.rect.size.height = min(needed, maxHeight)
            }
            next.isClipped = needed > maxHeight + 1
            return next
        }
    }

    static func contentHeight(items: [ScreenLaidOutBlock], canvasHeight: CGFloat) -> CGFloat {
        // The selected screen rectangle is the only canvas. Plates may use
        // empty space inside it, but never grow the pin or scroll its height.
        return canvasHeight
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

    static func isNumberedHeading(_ text: String) -> Bool {
        text.range(of: #"^\d+(\.\d+)*\s+\S"#, options: .regularExpression) != nil
    }

    static func isWrappedBlock(_ box: CGRect) -> Bool {
        box.height > 0 && box.width / box.height < 3.5
    }

    static func isStandaloneLine(_ line: ScreenOCRLine, bodyHeight: CGFloat) -> Bool {
        if isNumberedHeading(line.text) { return true }
        if line.text.count > 48 { return false }
        if line.visionBox.height <= bodyHeight * 1.45 { return false }
        if isWrappedBlock(line.visionBox) { return false }
        return true
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

    static func canJoinParagraph(
        previous: ScreenOCRLine,
        next: ScreenOCRLine
    ) -> Bool {
        let gap = previous.visionBox.minY - next.visionBox.maxY
        let line = min(previous.visionBox.height, next.visionBox.height)
        if line <= 0 { return false }
        if gap < -line * 0.25 { return false }
        // A gap as tall as a line is a new block (next bubble, next paragraph),
        // not a wrapped continuation. Thresholds are in line heights so a
        // tight crop and a full-window capture of the same text agree.
        if gap > line { return false }
        let indent = next.visionBox.minX - previous.visionBox.minX
        if indent < -line * 2 { return false }
        if indent > line * 4 { return false }
        let overlap = min(previous.visionBox.maxX, next.visionBox.maxX)
            - max(previous.visionBox.minX, next.visionBox.minX)
        let minWidth = min(previous.visionBox.width, next.visionBox.width)
        if minWidth > line * 0.5, overlap < minWidth * 0.55 { return false }
        if previous.visionBox.width < line * 8, next.visionBox.width < line * 8,
           previous.text.count < 36, next.text.count < 36 {
            return false
        }
        return true
    }

    /// Consecutive body lines with the same indent become one paragraph.
    /// Headings, formulas, and code stay out of the group.
    static func groupParagraphs(from lines: [ScreenOCRLine]) -> [ScreenParagraph] {
        guard !lines.isEmpty else { return [] }
        let heights = lines.map(\.visionBox.height).sorted()
        let median = heights[heights.count / 2]
        let replaceable = lines.filter { shouldReplace($0, medianHeight: median) }
        let bodyHeight = bodyLineHeight(replaceable.map { ($0.visionBox.height, $0.visionBox.width) })
        var groups: [[ScreenOCRLine]] = []
        var current: [ScreenOCRLine] = []
        func flush() {
            guard !current.isEmpty else { return }
            groups.append(current)
            current = []
        }
        for line in lines {
            guard shouldReplace(line, medianHeight: median) else {
                flush()
                continue
            }
            if current.isEmpty {
                current = [line]
                continue
            }
            let previous = current[current.count - 1]
            if isStandaloneLine(line, bodyHeight: bodyHeight)
                || isStandaloneLine(previous, bodyHeight: bodyHeight)
                || !canJoinParagraph(previous: previous, next: line) {
                flush()
                current = [line]
            } else {
                current.append(line)
            }
        }
        flush()
        return groups.map { group in
            let box = group.dropFirst().reduce(group[0].visionBox) { $0.union($1.visionBox) }
            let translations = group.map(\.translation).filter { !$0.isEmpty }
            return ScreenParagraph(
                original: joinParagraphLines(group.map(\.text)),
                translation: joinParagraphLines(translations),
                visionBox: box,
                lineHeight: group.map(\.visionBox.height).reduce(0, +) / CGFloat(group.count),
                linePitch: box.height / CGFloat(max(1, group.count)),
                isHeading: group.count == 1 && isStandaloneLine(group[0], bodyHeight: bodyHeight),
                lineCount: group.count
            )
        }
    }

    /// OCR line height for this block, in canvas points.
    /// Snap jitter to the page body; keep real headings/captions; a tall
    /// wrapped column is body text, not a title.
    static func lineSlot(
        _ paragraph: ScreenParagraph,
        bodyNorm: CGFloat,
        canvasHeight: CGFloat
    ) -> CGFloat {
        let own = paragraph.lineHeight
        if paragraph.lineCount == 1, isWrappedBlock(paragraph.visionBox), own > bodyNorm * 1.2 {
            return max(1, bodyNorm * canvasHeight)
        }
        if bodyNorm > 0 {
            let ratio = own / bodyNorm
            if ratio >= 0.7 && ratio <= 1.35 {
                return max(1, bodyNorm * canvasHeight)
            }
        }
        return max(1, own * canvasHeight)
    }

    static func layoutPlates(_ paragraphs: [ScreenParagraph], canvasSize: CGSize) -> [ScreenLaidOutBlock] {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return [] }
        let bodyNorm = bodyLineHeight(paragraphs.map { ($0.lineHeight, $0.visionBox.width * CGFloat($0.lineCount)) })
        let items: [ScreenLaidOutBlock] = paragraphs.compactMap { paragraph in
            let text = paragraph.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let rect = topLeftRect(visionBox: paragraph.visionBox, canvasSize: canvasSize)
            guard rect.width > 2, rect.height > 1.5 else { return nil }
            let slot = lineSlot(paragraph, bodyNorm: bodyNorm, canvasHeight: canvasSize.height)
            let pitch = paragraph.lineCount > 1
                ? paragraph.linePitch * canvasSize.height
                : slot
            return ScreenLaidOutBlock(
                text: text,
                rect: rect,
                sourceRect: rect,
                fontSize: fontSize(lineHeight: slot),
                linePitch: pitch,
                isHeading: paragraph.isHeading
            )
        }
        return expandAndStack(items).map { item in
            var next = item
            if next.rect.maxY > canvasSize.height {
                next.rect.size.height = max(1, canvasSize.height - next.rect.minY)
                next.isClipped = true
            }
            return next
        }
    }

    static func layoutPlates(_ lines: [ScreenOCRLine], canvasSize: CGSize) -> [ScreenLaidOutBlock] {
        layoutPlates(groupParagraphs(from: lines), canvasSize: canvasSize)
    }

    static func assignTranslations(to lines: [ScreenOCRLine], translated: String) -> [ScreenOCRLine]? {
        let parts = translated.components(separatedBy: "\n")
        guard parts.count == lines.count else { return nil }
        return zip(lines, parts).map { line, part in
            var next = line
            next.translation = part
            return next
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
