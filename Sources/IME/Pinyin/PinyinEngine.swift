import AppKit
import Carbon.HIToolbox

@MainActor
final class PinyinEngine {
    private let session: RimePinyinSession?
    private(set) var initializationError: String?
    private let window = CandidateWindowController()
    var englishMode: Bool { session?.englishMode ?? UserDefaults.standard.bool(forKey: "pinyinEnglishMode") }
    var associationEnabled: Bool { session?.associationEnabled ?? false }
    private(set) var barPreeditEnabled: Bool
    private(set) var fuzzyEnabled: Bool
    var isComposing: Bool { session?.isComposing ?? false }

    init() {
        let stored = UserDefaults.standard.bool(forKey: "pinyinEnglishMode")
        barPreeditEnabled = UserDefaults.standard.bool(forKey: "pinyinBarPreeditEnabled")
        fuzzyEnabled = UserDefaults.standard.object(forKey: "pinyinFuzzyEnabled") as? Bool ?? true
        do {
            session = try RimePinyinSession(runtime: RimeRuntime.shared.get(), englishMode: stored, fuzzyEnabled: fuzzyEnabled)
        } catch {
            session = nil
            initializationError = error.localizedDescription
        }
        session?.onModeChange = { enabled in
            UserDefaults.standard.set(enabled, forKey: "pinyinEnglishMode")
        }
        window.setOnPick { [weak self] index in
            guard let self else { return }
            self.session?.selectCandidate(at: index)
            self.publish()
        }
        window.setOnPage { [weak self] delta in
            guard let self else { return }
            self.session?.pageCandidates(delta)
            self.publish()
        }
    }

    func handle(_ event: NSEvent, pushToTalk: PushToTalkHotkey) -> Bool {
        guard let session else { return false }
        let shiftEnabled = shiftToggleEnabled(event.keyCode, pushToTalk: pushToTalk)
        let consumed = session.handle(PinyinKeyEvent(event), shiftToggleEnabled: shiftEnabled)
        if consumed { publish() }
        return consumed
    }

    func commit() {
        session?.commit()
        publish()
    }

    func commitRaw() {
        session?.commitRaw()
        publish()
    }

    func cancel() {
        session?.cancel()
        publish()
    }

    func setEnglishMode(_ enabled: Bool) {
        session?.setEnglishMode(enabled)
        publish()
    }

    func setAssociationEnabled(_ enabled: Bool) {
        // Prediction requires a separate model/plugin; the shipped core does not
        // expose this capability. Preserve the saved preference for a later upgrade.
        publish()
    }

    func setBarPreeditEnabled(_ enabled: Bool) {
        barPreeditEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "pinyinBarPreeditEnabled")
        publish()
    }

    func setFuzzyEnabled(_ enabled: Bool) {
        guard session?.setFuzzyEnabled(enabled) == true else { return }
        fuzzyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "pinyinFuzzyEnabled")
        publish()
    }

    private func publish() {
        guard let session else { window.hide(); return }
        let committed = session.takeCommit()
        if !committed.isEmpty { IMEManager.shared.insertPinyin(committed) }
        IMEManager.shared.setPinyinMarked(session.markedText, caret: session.markedCaret, highlight: session.markedHighlight)
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
