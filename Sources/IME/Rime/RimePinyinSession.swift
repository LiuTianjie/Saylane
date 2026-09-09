import AppKit
import Carbon.HIToolbox

/// Frontend-only state: key routing, highlight and mode switching. Rime owns the
/// composition, segmentation, candidates, selection, cancellation and user DB.
final class RimePinyinSession {
    static let pageSize = 9
    private let native: SLSession
    private(set) var preedit = ""
    private(set) var markedText = ""
    private(set) var markedCaret = 0
    private(set) var markedHighlight = NSRange(location: 0, length: 0)
    private(set) var candidates: [PinyinCandidate] = []
    private(set) var highlighted = 0
    private(set) var englishMode: Bool
    private(set) var fuzzyEnabled: Bool
    // The core schema does not provide post-commit prediction. Do not silently
    // keep using the old bigram decoder to make this setting appear supported.
    let associationEnabled = false
    let isAssociating = false
    private var pendingCommit = ""
    private var shiftDown = false
    private var shiftSawKey = false
    private var shiftCanToggle = false
    private var englishPunctAfterDigit = false
    private var doubleQuoteOpen = false
    private var singleQuoteOpen = false
    private var candidateLimit = 90
    private var hasMore = false
    private let pinnedURL: URL
    private var pinned: [String: String]
    var onModeChange: ((Bool) -> Void)?

    init(runtime: RimeRuntime, englishMode: Bool = false, fuzzyEnabled: Bool = false) throws {
        native = try runtime.makeSession(fuzzy: fuzzyEnabled)
        self.englishMode = englishMode
        self.fuzzyEnabled = fuzzyEnabled
        pinnedURL = runtime.userData.appendingPathComponent("first_is_best.json")
        pinned = Self.loadPinned(pinnedURL)
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
            if event.keyCode == UInt16(kVK_CapsLock), event.flags.contains(.capsLock) {
                shiftSawKey = true
                let hadComposition = isComposing
                commitRawInput()
                return hadComposition
            }
            return handleShift(event, enabled: shiftToggleEnabled)
        }
        guard event.type == .keyDown else { return false }
        if shiftDown { shiftSawKey = true }
        guard event.flags.intersection([.command, .control, .option]).isEmpty else { return false }
        // Doubao ignores auto-repeat on letters/space so a held key does not flood.
        if event.isRepeat && !Self.repeatableKeys.contains(Int(event.keyCode)) {
            return isComposing
        }
        // Latin input remains owned by the client and its actual keyboard layout.
        if englishMode || (event.flags.contains(.capsLock) && !isComposing) { return false }
        if event.flags.contains(.shift) && !isComposing && event.letter != nil { return false }

        switch Int(event.keyCode) {
        case kVK_Escape:
            guard isComposing else { return false }
            cancel()
            return true
        case kVK_Delete, kVK_ForwardDelete:
            guard isComposing else { return false }
            _ = process(0xff08) // X11 BackSpace, the codes used by librime's C API.
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard isComposing else { englishPunctAfterDigit = false; return false }
            commitRawInput()
            return true
        case kVK_Tab:
            guard showsCandidates else { return false }
            pageCandidates(event.flags.contains(.shift) ? -1 : 1)
            return true
        case kVK_Space:
            guard isComposing else { englishPunctAfterDigit = false; return false }
            if showsCandidates { selectCandidate(at: highlighted) } else { commitRawInput() }
            return true
        case kVK_LeftArrow, kVK_UpArrow:
            guard showsCandidates else { return false }
            moveHighlight(-1)
            return true
        case kVK_RightArrow, kVK_DownArrow:
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
            // Doubao default paging keys: minus/equal and PageUp/Down.
            // Other punctuation always commits, then inserts.
            if [kVK_PageDown, kVK_ANSI_Equal, kVK_ANSI_KeypadPlus].contains(Int(event.keyCode)) || ["+", "="].contains(event.characters) {
                pageCandidates(1)
                return true
            }
            if [kVK_PageUp, kVK_ANSI_Minus, kVK_ANSI_KeypadMinus].contains(Int(event.keyCode)) || ["-"].contains(event.characters) {
                pageCandidates(-1)
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
        return false
    }

    func selectCandidate(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        let typed = preedit.lowercased().filter(\.isLetter)
        let word = candidates[index].word
        acceptDisplayedCandidate(at: index)
        refresh()
        if !isComposing, typed.count >= 2, !word.isEmpty {
            pinned[typed] = word
            savePinned()
        }
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
        onModeChange?(enabled)
    }

    @discardableResult
    func setFuzzyEnabled(_ enabled: Bool) -> Bool {
        guard enabled != fuzzyEnabled else { return true }
        // Changing the schema destroys composition. Explicitly preserve raw text.
        commitRawInput()
        guard SLRimeSelectSchema(native, RimeRuntime.schema(fuzzy: enabled)) != 0 else { return false }
        fuzzyEnabled = enabled
        refresh()
        return true
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
            shiftSawKey = !event.flags.intersection([.command, .control, .option]).isEmpty
            shiftCanToggle = enabled
        } else if !event.flags.contains(.shift) && shiftDown {
            shiftDown = false
            if enabled && shiftCanToggle && !shiftSawKey {
                setEnglishMode(!englishMode)
                return true
            }
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
        if resetHighlight { candidateLimit = 90; highlighted = 0 }
        var snapshot = SLRimeRead(native, candidateLimit)
        defer { SLRimeFreeSnapshot(&snapshot) }
        preedit = snapshot.input.map { String(cString: $0) } ?? ""
        markedText = snapshot.preedit.map { String(cString: $0) } ?? ""
        let markedLen = (markedText as NSString).length
        let selStart = min(max(0, Int(snapshot.sel_start)), markedLen)
        let selEnd = min(max(selStart, Int(snapshot.sel_end)), markedLen)
        markedHighlight = NSRange(location: selStart, length: selEnd - selStart)
        let cursor = min(max(0, Int(snapshot.cursor)), markedLen)
        markedCaret = cursor == 0 && markedLen > 0 ? markedLen : cursor
        candidates = (0..<snapshot.count).compactMap { i in
            guard let text = snapshot.candidates?[i] else { return nil }
            let comment = snapshot.comments?[i].map { String(cString: $0) } ?? ""
            return PinyinCandidate(word: String(cString: text), pinyin: "", inputLength: 0, frequency: 0,
                                   engineIndex: i, comment: comment)
        }
        hasMore = snapshot.has_more != 0
        if resetHighlight { rankCandidates() }
        highlighted = min(highlighted, max(0, candidates.count - 1))
    }

    /// If the letters are still readable as pinyin (complete syllables or an
    /// unfinished last syllable, including the always-on typo spellings), Chinese
    /// leads. Otherwise an exact English match may lead; unmatched latin of
    /// length 4+ may be echoed first.
    private func rankCandidates() {
        let typed = preedit.lowercased().filter(\.isLetter)
        if let preferred = pinned[typed],
           let index = candidates.firstIndex(where: { $0.word == preferred }), index > 0 {
            let item = candidates.remove(at: index)
            candidates.insert(item, at: 0)
            return
        }
        guard typed.count >= 2, typed.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) else { return }
        if Self.looksLikePinyin(typed) {
            if let chinese = candidates.firstIndex(where: Self.isChinese), chinese > 0 {
                let item = candidates.remove(at: chinese)
                candidates.insert(item, at: 0)
            }
            return
        }
        if let english = candidates.firstIndex(where: { $0.word.lowercased() == typed }) {
            if english > 0 {
                let item = candidates.remove(at: english)
                candidates.insert(item, at: 0)
            }
            return
        }
        if typed.count >= 4 {
            candidates.insert(PinyinCandidate(word: typed, pinyin: "", inputLength: typed.count, frequency: 0), at: 0)
        }
    }

    private static func isChinese(_ item: PinyinCandidate) -> Bool {
        item.word.contains(where: { !$0.isASCII })
    }

    private static func looksLikePinyin(_ typed: String) -> Bool {
        if PinyinSyllable.coversQuanpin(typed) || PinyinSyllable.segment(typed) != nil { return true }
        var fixed = typed
        for (wrong, right) in [("ign", "ing"), ("img", "ing"), ("uei", "ui"), ("iou", "iu"), ("uen", "un")] {
            if fixed.hasSuffix(wrong) {
                fixed = String(fixed.dropLast(wrong.count)) + right
            }
        }
        return fixed != typed && (PinyinSyllable.coversQuanpin(fixed) || PinyinSyllable.segment(fixed) != nil)
    }

    private static func loadPinned(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    private func savePinned() {
        guard let data = try? JSONEncoder().encode(pinned) else { return }
        try? data.write(to: pinnedURL, options: .atomic)
    }

    private func loadMoreIfNeeded(_ index: Int) {
        if hasMore && index + Self.pageSize * 2 >= candidates.count {
            candidateLimit += 90
            refresh(resetHighlight: false)
        }
    }

    func pageCandidates(_ delta: Int) {
        guard showsCandidates else { return }
        let target = (pageIndex + delta) * Self.pageSize
        loadMoreIfNeeded(target)
        let pages = max(1, (candidates.count + Self.pageSize - 1) / Self.pageSize)
        highlighted = min(((pageIndex + delta + pages) % pages) * Self.pageSize, candidates.count - 1)
    }

    private func moveHighlight(_ delta: Int) {
        loadMoreIfNeeded(highlighted + delta)
        highlighted = (highlighted + delta + candidates.count) % candidates.count
    }

    private static let repeatableKeys: Set<Int> = [
        kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow,
        kVK_UpArrow, kVK_DownArrow, kVK_PageUp, kVK_PageDown
    ]

    private func mappedPunctuation(_ raw: String) -> String? {
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
