import AppKit
import Carbon.HIToolbox

final class PinyinSession {
    static let pageSize = PinyinLexicon.pageSize
    private var lexicon: PinyinLexicon
    private(set) var preedit = ""
    private(set) var candidates: [PinyinCandidate] = []
    private(set) var highlighted = 0
    private(set) var englishMode: Bool
    private(set) var associationEnabled: Bool
    private(set) var associating = false
    private var pendingCommit = ""
    private var shiftDown = false
    private var shiftSawKey = false
    private var doubleQuoteOpen = false
    private var singleQuoteOpen = false
    private var history: [String] = []
    private var learnedSyllables: [String] = []
    private var learnedWord = ""
    private var learnedParts = 0
    private var englishPunctAfterDigit = false
    var onModeChange: ((Bool) -> Void)?

    init(lexicon: PinyinLexicon, englishMode: Bool = false, associationEnabled: Bool = false) {
        self.lexicon = lexicon
        self.englishMode = englishMode
        self.associationEnabled = associationEnabled
    }

    var isComposing: Bool { !preedit.isEmpty }
    var isAssociating: Bool { associating && preedit.isEmpty && !candidates.isEmpty }
    var isSelecting: Bool { isComposing || isAssociating }
    var showsCandidates: Bool { !candidates.isEmpty }
    var pageIndex: Int { candidates.isEmpty ? 0 : highlighted / Self.pageSize }
    var pageCount: Int { max(1, (candidates.count + Self.pageSize - 1) / Self.pageSize) }

    /// Doubao `preEditText`: composing pinyin with syllable separators, empty while associating.
    var markedText: String {
        guard isComposing else { return "" }
        return PinyinSyllable.display(preedit)
    }

    var preeditDisplay: String { markedText }

    func takeCommit() -> String {
        defer { pendingCommit = "" }
        return pendingCommit
    }

    func handle(_ event: PinyinKeyEvent, shiftToggleEnabled: Bool) -> Bool {
        if event.type == .flagsChanged {
            if event.keyCode == UInt16(kVK_CapsLock), event.flags.contains(.capsLock) {
                let hadSelection = isSelecting
                commitRawInput()
                return hadSelection
            }
            return handleShift(event, enabled: shiftToggleEnabled)
        }
        guard event.type == .keyDown else { return false }
        let blocking = event.flags.intersection([.command, .control, .option])
        if !blocking.isEmpty {
            if isAssociating { dismissAssociation() }
            return false
        }
        if shiftDown { shiftSawKey = true }
        // Caps Lock uses the client's Latin input, including ASCII punctuation.
        if event.flags.contains(.capsLock) && !isSelecting { return false }

        if event.keyCode == UInt16(kVK_Escape) {
            guard isSelecting else { return false }
            cancel()
            return true
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            if isAssociating {
                dismissAssociation()
                return false
            }
            guard isComposing else { return false }
            preedit.removeLast()
            refresh()
            return true
        }
        if event.isRepeat { return isSelecting }
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            if isAssociating {
                dismissAssociation()
                return true
            }
            guard isComposing else {
                englishPunctAfterDigit = false
                return false
            }
            pendingCommit += preedit
            clearComposition()
            return true
        }
        if event.keyCode == UInt16(kVK_Tab) {
            guard isSelecting else { return false }
            page(by: event.flags.contains(.shift) ? -1 : 1)
            return true
        }
        if event.keyCode == UInt16(kVK_Space) {
            guard isSelecting else { return false }
            choose(highlighted)
            return true
        }
        if event.keyCode == UInt16(kVK_LeftArrow) || event.keyCode == UInt16(kVK_UpArrow) {
            guard isSelecting else { return false }
            moveHighlight(-1)
            return true
        }
        if event.keyCode == UInt16(kVK_RightArrow) || event.keyCode == UInt16(kVK_DownArrow) {
            guard isSelecting else { return false }
            moveHighlight(1)
            return true
        }

        let character = event.characters
        if isSelecting, let number = Int(character), (1...9).contains(number) {
            let index = pageIndex * Self.pageSize + (number - 1)
            if candidates.indices.contains(index) { choose(index) }
            return true
        }
        if !isSelecting, character.count == 1, let ch = character.first, ch.isASCII, ch.isNumber {
            englishPunctAfterDigit = true
            return false
        }
        if !isSelecting, character == " " {
            englishPunctAfterDigit = false
            return false
        }
        if isSelecting, isPageDown(event, character: character) {
            page(by: 1)
            return true
        }
        if isSelecting, isPageUp(event, character: character) {
            page(by: -1)
            return true
        }
        if let letter = event.letter {
            englishPunctAfterDigit = false
            if englishMode {
                if isAssociating { dismissAssociation() }
                return false
            }
            if event.flags.contains(.capsLock) && !isComposing {
                if isAssociating { dismissAssociation() }
                return false
            }
            if event.flags.contains(.shift) && !isComposing {
                if isAssociating { dismissAssociation() }
                return false
            }
            if isAssociating { dismissAssociation() }
            preedit.append(letter)
            refresh()
            return true
        }
        if isComposing && character == "'" {
            preedit.append("'")
            refresh()
            return true
        }
        if Self.punctuationKeys.contains(character) {
            if englishMode { return false }
            if isComposing {
                commitChoice(highlighted, associate: false)
            } else if isAssociating {
                dismissAssociation()
            }
            // Apple Pinyin: the first punctuation after a digit stays ASCII (3.14).
            if englishPunctAfterDigit {
                englishPunctAfterDigit = false
                pendingCommit += character
                return true
            }
            if let mapped = mappedPunctuation(character) {
                pendingCommit += mapped
                return true
            }
            return false
        }
        return false
    }

    func selectCandidate(at index: Int) {
        choose(index)
    }

    func pageCandidates(_ delta: Int) {
        page(by: delta)
    }

    func commit() {
        if isComposing {
            commitChoice(highlighted, associate: false)
        }
        dismissAssociation()
        history = []
    }

    func cancel() {
        if isAssociating {
            dismissAssociation()
            return
        }
        clearComposition()
    }

    func setEnglishMode(_ enabled: Bool) {
        guard englishMode != enabled else { return }
        if enabled { commitRawInput() }
        englishMode = enabled
        onModeChange?(enabled)
    }

    /// Switching to Latin input submits the literal buffer, never a Chinese candidate.
    /// Do not learn this buffer as a Chinese phrase or carry its context into later input.
    private func commitRawInput() {
        pendingCommit += preedit
        clearComposition()
        dismissAssociation()
        history = []
    }

    func setAssociationEnabled(_ enabled: Bool) {
        associationEnabled = enabled
        if !enabled { dismissAssociation() }
    }

    private func handleShift(_ event: PinyinKeyEvent, enabled: Bool) -> Bool {
        let isShiftKey = event.keyCode == UInt16(kVK_Shift) || event.keyCode == UInt16(kVK_RightShift)
        guard isShiftKey else { return false }
        let down = event.flags.contains(.shift)
        if down && !shiftDown {
            shiftDown = true
            shiftSawKey = false
            return false
        }
        if !down && shiftDown {
            shiftDown = false
            if enabled && !shiftSawKey {
                setEnglishMode(!englishMode)
                return true
            }
        }
        return false
    }

    private func choose(_ index: Int) {
        commitChoice(index, associate: true)
    }

    private func commitChoice(_ index: Int, associate: Bool) {
        guard candidates.indices.contains(index) else {
            if isComposing { pendingCommit += preedit }
            clearComposition()
            return
        }
        let choice = candidates[index]
        let wasAssociating = isAssociating
        pendingCommit += choice.word
        if !choice.pinyin.isEmpty {
            lexicon.boost(pinyin: choice.pinyin, word: choice.word)
        }
        let typed = PinyinSyllable.normalize(String(preedit.prefix(choice.inputLength)))
        if !typed.isEmpty {
            PinyinLanguageModel.shared.rememberChoice(input: typed, word: choice.word)
        }
        if !choice.pinyin.isEmpty, choice.pinyin != typed {
            PinyinLanguageModel.shared.rememberChoice(input: choice.pinyin, word: choice.word)
        }
        PinyinLanguageModel.shared.record(previous: history.last, word: choice.word)
        history.append(choice.word)
        if !wasAssociating {
            rememberCompositionPart(choice, typed: typed)
        }

        if wasAssociating || choice.commitsAll {
            preedit = ""
            finishLearning()
            if associate { showAssociations() } else { dismissAssociation() }
            return
        }
        var remainder = String(preedit.dropFirst(choice.inputLength))
        while remainder.hasPrefix("'") { remainder.removeFirst() }
        preedit = remainder
        if preedit.isEmpty {
            finishLearning()
            if associate { showAssociations() } else { dismissAssociation() }
        } else {
            associating = false
            refresh()
        }
    }

    private func rememberCompositionPart(_ choice: PinyinCandidate, typed: String) {
        let piece = choice.pinyin.isEmpty ? typed : choice.pinyin
        if let parts = PinyinSyllable.segment(piece), !parts.isEmpty {
            learnedSyllables.append(contentsOf: parts)
        } else if !piece.isEmpty {
            learnedSyllables.append(piece)
        }
        learnedWord += choice.word
        learnedParts += 1
    }

    private func finishLearning() {
        let syllables = learnedSyllables
        let word = learnedWord
        let parts = learnedParts
        learnedSyllables = []
        learnedWord = ""
        learnedParts = 0
        guard parts >= 2, word.count >= 2, !syllables.isEmpty else { return }
        lexicon.learn(word: word, syllables: syllables)
        PinyinLanguageModel.shared.rememberChoice(input: syllables.joined(), word: word)
    }

    private func resetLearning() {
        learnedSyllables = []
        learnedWord = ""
        learnedParts = 0
    }

    private func showAssociations() {
        guard associationEnabled else {
            dismissAssociation()
            return
        }
        associating = true
        highlighted = 0
        let word = history.last ?? ""
        candidates = lexicon.associations(after: word)
        if candidates.isEmpty {
            associating = false
        }
    }

    private func dismissAssociation() {
        associating = false
        if preedit.isEmpty {
            candidates = []
            highlighted = 0
        }
    }

    private func refresh() {
        associating = false
        if preedit.isEmpty {
            candidates = []
            highlighted = 0
            return
        }
        candidates = lexicon.candidates(for: preedit, context: history)
        highlighted = 0
    }

    private func clearComposition() {
        preedit = ""
        candidates = []
        highlighted = 0
        associating = false
        history = []
        resetLearning()
    }

    private func moveHighlight(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        highlighted = (highlighted + delta + candidates.count) % candidates.count
    }

    private func page(by delta: Int) {
        guard !candidates.isEmpty else { return }
        if pageCount <= 1 {
            moveHighlight(delta)
            return
        }
        let next = (pageIndex + delta + pageCount) % pageCount
        highlighted = min(next * Self.pageSize, candidates.count - 1)
    }

    /// Doubao default: `useMinusAndEqualToTurnPage`. Comma/period stay punctuation.
    private func isPageDown(_ event: PinyinKeyEvent, character: String) -> Bool {
        if event.keyCode == UInt16(kVK_ANSI_Equal) || event.keyCode == UInt16(kVK_ANSI_KeypadPlus) { return true }
        if event.keyCode == UInt16(kVK_PageDown) { return true }
        return ["]", "+", "="].contains(character)
    }

    private func isPageUp(_ event: PinyinKeyEvent, character: String) -> Bool {
        if event.keyCode == UInt16(kVK_ANSI_Minus) || event.keyCode == UInt16(kVK_ANSI_KeypadMinus) { return true }
        if event.keyCode == UInt16(kVK_PageUp) { return true }
        return ["[", "-"].contains(character)
    }

    private static let punctuationKeys: Set<String> = [
        ",", ".", "?", "!", ":", ";", "\\", "^", "$", "`", "<", ">", "[", "]", "(", ")", "\"", "'"
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
        case "[": return isSelecting ? nil : "【"
        case "]": return isSelecting ? nil : "】"
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
