import AppKit
import Carbon.HIToolbox

@MainActor
final class PinyinEngine {
    private let session: PinyinSession
    private let window = CandidateWindowController()
    var englishMode: Bool { session.englishMode }
    var associationEnabled: Bool { session.associationEnabled }
    private(set) var barPreeditEnabled: Bool
    private(set) var fuzzyEnabled: Bool
    var isComposing: Bool { session.isComposing }

    init() {
        let stored = UserDefaults.standard.bool(forKey: "pinyinEnglishMode")
        let association = UserDefaults.standard.bool(forKey: "pinyinAssociationEnabled")
        barPreeditEnabled = UserDefaults.standard.bool(forKey: "pinyinBarPreeditEnabled")
        fuzzyEnabled = UserDefaults.standard.object(forKey: "pinyinFuzzyEnabled") as? Bool ?? true
        PinyinLexicon.shared.fuzzyEnabled = fuzzyEnabled
        session = PinyinSession(lexicon: PinyinLexicon.shared, englishMode: stored, associationEnabled: association)
        session.onModeChange = { enabled in
            UserDefaults.standard.set(enabled, forKey: "pinyinEnglishMode")
        }
        window.setOnPick { [weak self] index in
            guard let self else { return }
            self.session.selectCandidate(at: index)
            self.publish()
        }
        window.setOnPage { [weak self] delta in
            guard let self else { return }
            self.session.pageCandidates(delta)
            self.publish()
        }
    }

    func handle(_ event: NSEvent, pushToTalk: PushToTalkHotkey) -> Bool {
        let shiftEnabled = shiftToggleEnabled(event.keyCode, pushToTalk: pushToTalk)
        let consumed = session.handle(PinyinKeyEvent(event), shiftToggleEnabled: shiftEnabled)
        if consumed { publish() }
        return consumed
    }

    func commit() {
        session.commit()
        publish()
    }

    func cancel() {
        session.cancel()
        publish()
    }

    func setEnglishMode(_ enabled: Bool) {
        session.setEnglishMode(enabled)
        publish()
    }

    func setAssociationEnabled(_ enabled: Bool) {
        session.setAssociationEnabled(enabled)
        UserDefaults.standard.set(session.associationEnabled, forKey: "pinyinAssociationEnabled")
        publish()
    }

    func setBarPreeditEnabled(_ enabled: Bool) {
        barPreeditEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "pinyinBarPreeditEnabled")
        publish()
    }

    func setFuzzyEnabled(_ enabled: Bool) {
        fuzzyEnabled = enabled
        PinyinLexicon.shared.fuzzyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "pinyinFuzzyEnabled")
        publish()
    }

    private func publish() {
        let committed = session.takeCommit()
        if !committed.isEmpty { IMEManager.shared.insertPinyin(committed) }
        IMEManager.shared.setPinyinMarked(session.markedText)
        if session.showsCandidates {
            window.update(candidates: session.candidates, highlight: session.highlighted,
                          caret: IMEManager.shared.caretScreenRect(),
                          preedit: barPreeditEnabled ? session.preeditDisplay : "",
                          associating: session.isAssociating)
        } else {
            window.hide()
        }
    }

    private func shiftToggleEnabled(_ keyCode: UInt16, pushToTalk: PushToTalkHotkey) -> Bool {
        if keyCode == UInt16(kVK_Shift) { return pushToTalk != .leftShift }
        if keyCode == UInt16(kVK_RightShift) { return pushToTalk != .rightShift }
        return true
    }
}
