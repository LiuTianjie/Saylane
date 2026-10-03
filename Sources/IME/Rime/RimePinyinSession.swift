import AppKit
import Carbon.HIToolbox

/// Frontend-only state: key routing, highlight and mode switching. Rime owns the
/// composition, segmentation, candidates, selection, cancellation and user DB.
final class RimePinyinSession {
    static let pageSize = 9
    private let native: SLSession
    private let runtime: RimeRuntime
    private(set) var preedit = ""
    private(set) var markedText = ""
    private(set) var markedCaret = 0
    private(set) var markedHighlight = NSRange(location: 0, length: 0)
    private(set) var candidates: [PinyinCandidate] = []
    private(set) var highlighted = 0
    private(set) var englishMode: Bool
    private(set) var fuzzyEnabled: Bool
    private var pendingCommit = ""
    private var shiftDown = false
    private var shiftDownAt: TimeInterval = 0
    private var shiftSawKey = false
    private var shiftCanToggle = false
    private var englishPunctAfterDigit = false
    private var doubleQuoteOpen = false
    private var singleQuoteOpen = false
    private var candidateLimit = 90
    private var hasMore = false
    private var inputCaret = 0
    private var canRankWholeInput = false
    private var engineCoversInput = false
    /// A Shift tap switched Chinese and English. Not called when the mode is set from outside.
    var onModeChange: ((Bool) -> Void)?
    /// Metadata-only trace: why a letter was left to the client, why a Shift tap was not taken.
    var trace: (String, String) -> Void = { _, _ in }
    /// Whether the pointer was used while Shift was down. InputMethodKit
    /// delivers no mouse events, so Shift-click looks like a bare Shift tap.
    var pointerUsedDuring: (_ hold: TimeInterval, _ endedAt: TimeInterval) -> Bool = PointerActivity.used
    /// Which keys page and pick, as chosen in the settings.
    var keys = PinyinKeyOptions()
    /// Held longer than this, Shift was a modifier, not a tap.
    static let shiftTapLimit: TimeInterval = 0.5

    init(runtime: RimeRuntime, englishMode: Bool = false, fuzzyEnabled: Bool = false) throws {
        self.runtime = runtime
        native = try runtime.makeSession(fuzzy: fuzzyEnabled)
        self.englishMode = englishMode
        self.fuzzyEnabled = fuzzyEnabled
    }

    deinit { SLRimeDestroy(native) }
    var isComposing: Bool { !preedit.isEmpty }
    var showsCandidates: Bool { !candidates.isEmpty }
    var preeditDisplay: String { markedText }
    var pageIndex: Int { highlighted / Self.pageSize }

    func takeCommit() -> String {
        defer { pendingCommit = "" }
        return pendingCommit
    }

    func handle(_ event: PinyinKeyEvent, shiftToggleEnabled: Bool) -> Bool {
        if event.type == .flagsChanged {
            if event.keyCode == UInt16(kVK_CapsLock) {
                shiftSawKey = true
                guard isComposing else { return false }
                commitRawInput()
                return true
            }
            return handleShift(event, enabled: shiftToggleEnabled)
        }
        guard event.type == .keyDown else { return false }
        if shiftDown { shiftSawKey = true }
        guard event.flags.intersection([.command, .control, .option]).isEmpty else { return false }
        // Auto-repeat on letters/space is ignored so a held key does not flood.
        if event.isRepeat && !Self.repeatableKeys.contains(Int(event.keyCode)) {
            return isComposing
        }
        // Latin input remains owned by the client and its actual keyboard layout.
        if englishMode {
            if event.letter != nil { trace("pinyin", "letter left to the application: English mode") }
            return false
        }
        if event.flags.contains(.capsLock) && !isComposing {
            if event.letter != nil { trace("pinyin", "letter left to the application: Caps Lock") }
            return false
        }
        if event.flags.contains(.shift) && !isComposing && event.letter != nil { return false }

        switch Int(event.keyCode) {
        case kVK_Escape:
            guard isComposing else { return false }
            cancel()
            return true
        case kVK_Delete:
            guard isComposing else { return false }
            _ = process(0xff08) // X11 BackSpace, the codes used by librime's C API.
            return true
        case kVK_ForwardDelete:
            guard isComposing else { return false }
            _ = process(0xffff) // X11 Delete, not BackSpace.
            return true
        case kVK_LeftArrow, kVK_RightArrow, kVK_Home, kVK_End:
            guard isComposing else { return false }
            // Rime owns editing and confirmed segments. Use character movement;
            // prevent its default wrap from jumping across the whole composition.
            switch Int(event.keyCode) {
            case kVK_LeftArrow:
                if inputCaret > 0 { _ = process(0xff96) } // KP_Left
            case kVK_RightArrow:
                if inputCaret < preedit.utf8.count { _ = process(0xff98) } // KP_Right
            case kVK_Home: _ = process(0xff50)
            default: _ = process(0xff57)
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard isComposing else { englishPunctAfterDigit = false; return false }
            commitRawInput()
            return true
        case kVK_Tab:
            guard showsCandidates, keys.pageWithTab else { return false }
            pageCandidates(event.flags.contains(.shift) ? -1 : 1)
            return true
        case kVK_Space:
            guard isComposing else { englishPunctAfterDigit = false; return false }
            if showsCandidates { selectCandidate(at: highlighted) } else { commitRawInput() }
            return true
        case kVK_UpArrow:
            guard showsCandidates else { return false }
            moveHighlight(-1)
            return true
        case kVK_DownArrow:
            guard showsCandidates else { return false }
            moveHighlight(1)
            return true
        default: break
        }
        if showsCandidates, let number = Int(event.characters), (1...9).contains(number) {
            selectCandidate(at: pageIndex * Self.pageSize + number - 1)
            return true
        }
        if showsCandidates {
            // Page Up/Down always turn the page; the other pairs are the
            // user's choice. Punctuation that pages nothing commits, then inserts.
            var next = Int(event.keyCode) == kVK_PageDown, previous = Int(event.keyCode) == kVK_PageUp
            if keys.pageWithMinusEqual { next = next || ["+", "="].contains(event.characters); previous = previous || event.characters == "-" }
            if keys.pageWithCommaPeriod { next = next || event.characters == "."; previous = previous || event.characters == "," }
            if keys.pageWithBrackets { next = next || event.characters == "]"; previous = previous || event.characters == "[" }
            if next || previous {
                pageCandidates(next ? 1 : -1)
                return true
            }
            // The second and third candidate under the right hand, without reaching for the digits.
            if keys.pickWithSemicolonQuote, let offset = [";": 1, "'": 2][event.characters] {
                let index = pageIndex * Self.pageSize + offset
                if candidates.indices.contains(index) { selectCandidate(at: index) }
                return true
            }
        }
        if let letter = event.letter, let ascii = letter.asciiValue {
            englishPunctAfterDigit = false
            return process(Int32(ascii))
        }
        if isComposing && event.characters == "'" { return process(39) }
        if !isComposing, let ch = event.characters.first, event.characters.count == 1, ch.isASCII, ch.isNumber {
            englishPunctAfterDigit = true
            return false
        }
        if let punctuation = mappedPunctuation(event.characters) {
            if isComposing { commit() }
            pendingCommit += englishPunctAfterDigit ? event.characters : punctuation
            englishPunctAfterDigit = false
            return true
        }
        // Printable symbols without a Chinese mapping (/, @, _, 0, …) must
        // follow the composition, rather than reach the client ahead of it.
        if isComposing, event.characters.utf8.count == 1,
           let byte = event.characters.utf8.first, (33...126).contains(byte) {
            commit()
            pendingCommit += event.characters
            englishPunctAfterDigit = false
            return true
        }
        return false
    }

    func selectCandidate(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        // The native user dictionary learns both complete and partial selections.
        acceptDisplayedCandidate(at: index)
        refresh()
    }

    func commit() {
        if isComposing {
            if showsCandidates, let engineIndex = candidates[highlighted].engineIndex {
                _ = SLRimeSelect(native, engineIndex)
                SLRimeCommit(native)
            } else if showsCandidates {
                pendingCommit += candidates[highlighted].word
                SLRimeClear(native)
            } else {
                SLRimeCommit(native)
            }
        }
        refresh()
    }

    func commitRaw() {
        commitRawInput()
    }

    private func acceptDisplayedCandidate(at index: Int) {
        let choice = candidates[index]
        if let engineIndex = choice.engineIndex {
            _ = SLRimeSelect(native, engineIndex)
        } else {
            pendingCommit += choice.word
            SLRimeClear(native)
        }
    }

    func cancel() {
        SLRimeClear(native)
        shiftDown = false
        shiftSawKey = false
        shiftCanToggle = false
        refresh()
    }

    func setEnglishMode(_ enabled: Bool) {
        guard englishMode != enabled else { return }
        if enabled { commitRawInput() }
        englishMode = enabled
    }

    @discardableResult
    func setFuzzyEnabled(_ enabled: Bool) -> Bool {
        guard enabled != fuzzyEnabled else { return true }
        // Changing the schema destroys composition. Explicitly preserve raw text.
        commitRawInput()
        guard SLRimeSelectSchema(native, runtime.schema(fuzzy: enabled)) != 0 else { return false }
        fuzzyEnabled = enabled
        refresh()
        return true
    }

    /// The language model was installed or removed: type with the schema that fits.
    @discardableResult
    func reloadSchema() -> Bool {
        commitRawInput()
        let ok = SLRimeSelectSchema(native, runtime.schema(fuzzy: fuzzyEnabled)) != 0
        refresh()
        return ok
    }

    private func commitRawInput() {
        guard isComposing else { return }
        // express_editor Return commits raw input while retaining only explicitly
        // confirmed Chinese segments. It does not accept the highlighted candidate.
        // Example: selected 你 + unconverted hao -> 你hao, not 你好 or nihao.
        if SLRimeProcess(native, 0xff0d, 0) == 0 {
            pendingCommit += preedit
            SLRimeClear(native)
        }
        refresh()
    }

    private func handleShift(_ event: PinyinKeyEvent, enabled: Bool) -> Bool {
        guard [kVK_Shift, kVK_RightShift].contains(Int(event.keyCode)) else {
            if shiftDown { shiftSawKey = true }
            return false
        }
        if event.flags.contains(.shift) && !shiftDown {
            shiftDown = true
            shiftDownAt = event.timestamp
            shiftSawKey = !event.flags.intersection([.command, .control, .option]).isEmpty
            shiftCanToggle = enabled
        } else if !event.flags.contains(.shift) && shiftDown {
            shiftDown = false
            guard enabled && shiftCanToggle && !shiftSawKey else { return false }
            let hold = shiftDownAt > 0 && event.timestamp > 0 ? event.timestamp - shiftDownAt : 0
            if hold > Self.shiftTapLimit {
                trace("pinyin", "Shift held too long to switch")
                return false
            }
            if pointerUsedDuring(hold, event.timestamp) {
                trace("pinyin", "Shift used with the pointer; no switch")
                return false
            }
            setEnglishMode(!englishMode)
            onModeChange?(englishMode)
            return true
        }
        return false
    }

    private func process(_ key: Int32) -> Bool {
        let handled = SLRimeProcess(native, key, 0) != 0
        refresh()
        return handled
    }

    private func refresh(resetHighlight: Bool = true) {
        if let text = SLRimeTakeCommit(native) {
            pendingCommit += String(cString: text)
            SLRimeFreeString(text)
        }
        let previousChoice = candidates.indices.contains(highlighted) ? candidates[highlighted] : nil
        if resetHighlight { candidateLimit = 90; highlighted = 0 }
        var snapshot = SLRimeRead(native, candidateLimit)
        defer { SLRimeFreeSnapshot(&snapshot) }
        preedit = snapshot.input.map { String(cString: $0) } ?? ""
        markedText = snapshot.preedit.map { String(cString: $0) } ?? ""
        // librime offsets are UTF-8 bytes; InputMethodKit uses UTF-16 units.
        // Clamping byte offsets to NSString.length corrupts ranges after 你/emoji.
        let selStart = Self.utf16Offset(snapshot.sel_start, in: markedText)
        let selEnd = max(selStart, Self.utf16Offset(snapshot.sel_end, in: markedText))
        markedHighlight = NSRange(location: selStart, length: selEnd - selStart)
        markedCaret = Self.utf16Offset(snapshot.cursor, in: markedText)
        inputCaret = Int(snapshot.input_cursor)
        canRankWholeInput = selStart == 0 && inputCaret == preedit.utf8.count
            && preedit.utf8.allSatisfy { (97...122).contains($0) }
        engineCoversInput = Int(snapshot.sel_end) == markedText.utf8.count
        candidates = (0..<snapshot.count).compactMap { i in
            guard let text = snapshot.candidates?[i] else { return nil }
            let comment = snapshot.comments?[i].map { String(cString: $0) } ?? ""
            return PinyinCandidate(word: String(cString: text), pinyin: "", inputLength: 0, frequency: 0,
                                   engineIndex: i, comment: comment)
        }
        hasMore = snapshot.has_more != 0
        rankCandidates()
        demoteEmoji()
        if !resetHighlight, let previousChoice,
           let index = candidates.firstIndex(where: {
               $0.engineIndex == previousChoice.engineIndex && $0.word == previousChoice.word
           }) {
            highlighted = index
        }
        highlighted = min(highlighted, max(0, candidates.count - 1))
    }

    /// Only promote an exact English word for whole, non-quanpin input.
    /// Segmentation, typo correction and Chinese learning stay in Rime. In
    /// particular, a selected Chinese prefix must never be cleared by a raw echo.
    private func rankCandidates() {
        guard canRankWholeInput, preedit.count >= 2,
              !PinyinSyllable.coversQuanpin(preedit) else { return }
        if let english = candidates.firstIndex(where: { $0.word.lowercased() == preedit }) {
            let item = candidates.remove(at: english)
            candidates.insert(item, at: 0)
        } else if preedit.count >= 4 {
            // A native correction/abbreviation covering the input keeps priority.
            // Unknown Latin remains directly selectable on the first page.
            let index = engineCoversInput ? min(Self.pageSize - 1, candidates.count) : 0
            candidates.insert(PinyinCandidate(word: preedit, pinyin: "", inputLength: preedit.count,
                                              frequency: 0), at: index)
        }
    }

    /// Emoji are a nicety, never the answer. The engine puts each one right
    /// behind the word it illustrates, which hands the second to fourth places
    /// to pictures for everyday words (可以 🙆‍♂️ 🙆‍♀️ 🉑 刻意 可疑). One per word
    /// is kept, and on the first page the pictures go behind the words.
    /// Candidates keep their engine index, so choosing one is unaffected.
    private func demoteEmoji() {
        guard candidates.contains(where: \.isEmoji) else { return }
        var kept: [PinyinCandidate] = []
        var previousWasEmoji = false
        for candidate in candidates {
            let emoji = candidate.isEmoji
            if emoji && previousWasEmoji { continue }
            previousWasEmoji = emoji
            kept.append(candidate)
        }
        let first = kept.prefix(Self.pageSize)
        candidates = first.filter { !$0.isEmoji } + first.filter(\.isEmoji) + kept.dropFirst(Self.pageSize)
    }

    private static func utf16Offset(_ byteOffset: Int32, in text: String) -> Int {
        let bytes = text.utf8
        var offset = min(max(0, Int(byteOffset)), bytes.count)
        while offset > 0 {
            let index = bytes.index(bytes.startIndex, offsetBy: offset)
            if let boundary = String.Index(index, within: text) {
                return text[..<boundary].utf16.count
            }
            offset -= 1
        }
        return 0
    }

    private func loadMoreIfNeeded(_ index: Int) {
        if hasMore && index + Self.pageSize * 2 >= candidates.count {
            candidateLimit += 90
            refresh(resetHighlight: false)
        }
    }

    func pageCandidates(_ delta: Int) {
        guard showsCandidates else { return }
        let target = max(0, pageIndex + delta) * Self.pageSize
        loadMoreIfNeeded(target)
        let lastPage = (candidates.count - 1) / Self.pageSize
        highlighted = min(target, lastPage * Self.pageSize)
    }

    private func moveHighlight(_ delta: Int) {
        loadMoreIfNeeded(highlighted + delta)
        highlighted = min(max(0, highlighted + delta), candidates.count - 1)
    }

    private static let repeatableKeys: Set<Int> = [
        kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow,
        kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown
    ]

    private func mappedPunctuation(_ raw: String) -> String? {
        // Western punctuation while typing Chinese: nothing is mapped.
        if keys.englishPunctuation { return nil }
        switch raw {
        case ",": return "，"
        case ".": return "。"
        case "?": return "？"
        case "!": return "！"
        case ":": return "："
        case ";": return "；"
        case "\\": return "、"
        case "^": return "……"
        case "$": return "￥"
        case "`": return "·"
        case "<": return "《"
        case ">": return "》"
        case "[": return "【"
        case "]": return "】"
        case "(": return "（"
        case ")": return "）"
        case "\"":
            doubleQuoteOpen.toggle()
            return doubleQuoteOpen ? "“" : "”"
        case "'":
            singleQuoteOpen.toggle()
            return singleQuoteOpen ? "‘" : "’"
        default: return nil
        }
    }
}
