import AppKit
import Carbon.HIToolbox

/// Pinyin front end. Like Squirrel, every IMK client gets its own Rime session so
/// switching windows never commits one client's composition into another; the
/// candidate window is shared. Preferences are pushed by the host, never read here.
@MainActor
final class PinyinEngine: PinyinHandling {
    private final class ClientSession {
        let rime: RimePinyinSession
        var undeliveredCommit = ""

        init(_ rime: RimePinyinSession) {
            self.rime = rime
        }
    }

    private let runtime: Result<RimeRuntime, Error>
    private(set) var initializationError: String?
    private let window = CandidateWindowController()
    private var sessions: [UUID: ClientSession] = [:]
    private var order: [UUID] = []
    private var activeKey: UUID?
    private var englishModePreference = false
    private(set) var fuzzyEnabled = true
    private(set) var barPreeditEnabled = false
    private var keys = PinyinKeyOptions()
    var onEnglishModeChanged: ((Bool) -> Void)?
    private static let maxSessions = 12

    private var active: ClientSession? { activeKey.flatMap { sessions[$0] } }
    var englishMode: Bool { active?.rime.englishMode ?? englishModePreference }
    var isComposing: Bool { active?.rime.isComposing ?? false }

    init(runtime: Result<RimeRuntime, Error> = RimeRuntime.shared) {
        self.runtime = runtime
        if case .failure(let error) = runtime { initializationError = error.localizedDescription }
        window.setOnPick { [weak self] index in
            guard let self, let key = self.activeKey,
                  IMEManager.shared.isCurrentLease(key) else { return }
            self.active?.rime.selectCandidate(at: index)
            self.publish()
        }
        window.setOnPage { [weak self] delta in
            guard let self, let key = self.activeKey,
                  IMEManager.shared.isCurrentLease(key) else { return }
            self.active?.rime.pageCandidates(delta)
            self.publish()
        }
    }

    func applyPreferences(_ p: BridgePinyinPreferences) {
        englishModePreference = p.englishMode
        barPreeditEnabled = p.barPreedit
        keys = p.keys
        if fuzzyEnabled != p.fuzzy {
            fuzzyEnabled = p.fuzzy
        }
        synchronizeActivePreferences()
        publish()
    }

    /// A different client is now in front. Hide the candidates of the old one
    /// and continue with (or create) the session that belongs to the new one.
    func switchClient(to key: UUID?) {
        window.hide()
        guard let key else { activeKey = nil; return }
        if sessions[key] != nil {
            activeKey = key
            touch(key)
            synchronizeActivePreferences()
            publish()
            return
        }
        guard case .success(let runtime) = runtime else { activeKey = nil; return }
        do {
            let session = try RimePinyinSession(runtime: runtime, englishMode: englishModePreference, fuzzyEnabled: fuzzyEnabled)
            session.keys = keys
            session.onModeChange = { [weak self] enabled in
                self?.englishModePreference = enabled
                self?.onEnglishModeChanged?(enabled)
            }
            sessions[key] = ClientSession(session)
            activeKey = key
            touch(key)
            evictIfNeeded()
            publish()
        } catch {
            initializationError = error.localizedDescription
            activeKey = nil
        }
    }

    /// Typing must never depend on the order of earlier callbacks: before a key
    /// is handled, the session of the client that delivered it is the active one.
    func ensureClient(_ key: UUID?) {
        guard activeKey != key || active == nil else { return }
        switchClient(to: key)
    }

    /// The controller is going away for good.
    func forgetClient(_ key: UUID) {
        if sessions.removeValue(forKey: key) != nil, activeKey == key {
            activeKey = nil
            window.hide()
        }
        order.removeAll { $0 == key }
    }

    private func touch(_ key: UUID) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > Self.maxSessions {
            guard let victim = order.first(where: { key in
                guard key != activeKey, let state = sessions[key] else { return false }
                return !state.rime.isComposing && state.undeliveredCommit.isEmpty
            }) else { break }
            sessions.removeValue(forKey: victim)
            order.removeAll { $0 == victim }
        }
    }

    /// Preference changes may force Rime to resolve its current composition.
    /// Apply them only after that session's IMK client is attached, so any raw
    /// commit is written back to the client that owns the composition.
    private func synchronizeActivePreferences() {
        guard let session = active?.rime else { return }
        if session.fuzzyEnabled != fuzzyEnabled, !session.setFuzzyEnabled(fuzzyEnabled) {
            initializationError = String(localized: "拼音方案切换失败，请重新启动输入法后重试。")
        }
        if session.englishMode != englishModePreference {
            session.setEnglishMode(englishModePreference)
        }
        session.keys = keys
    }

    func handle(_ event: NSEvent, pushToTalk: PushToTalkHotkey) -> Bool {
        guard let session = active?.rime else { return false }
        let shiftEnabled = shiftToggleEnabled(event.keyCode, pushToTalk: pushToTalk)
        let consumed = session.handle(PinyinKeyEvent(event), shiftToggleEnabled: shiftEnabled)
        if consumed { publish() }
        return consumed
    }

    func commit() {
        active?.rime.commit()
        publish()
    }

    func commitRaw() {
        active?.rime.commitRaw()
        publish()
    }

    func cancel() {
        active?.rime.cancel()
        publish()
    }

    private func publish() {
        guard let key = activeKey, let state = active else { window.hide(); return }
        let session = state.rime
        state.undeliveredCommit += session.takeCommit()
        guard IMEManager.shared.isCurrentLease(key) else {
            window.hide()
            return
        }
        if !state.undeliveredCommit.isEmpty {
            guard IMEManager.shared.insertPinyin(state.undeliveredCommit, leaseID: key) else {
                window.hide()
                return
            }
            state.undeliveredCommit = ""
        }
        guard IMEManager.shared.setPinyinMarked(session.markedText, caret: session.markedCaret,
                                                highlight: session.markedHighlight, leaseID: key) else {
            window.hide()
            return
        }
        if session.showsCandidates {
            window.update(candidates: session.candidates, highlight: session.highlighted,
                          caret: IMEManager.shared.caretScreenRect(leaseID: key),
                          preedit: barPreeditEnabled ? session.preeditDisplay : "")
        } else {
            window.hide()
        }
    }

    /// Shift toggles Chinese/English unless that very key is the talk trigger.
    private func shiftToggleEnabled(_ keyCode: UInt16, pushToTalk: PushToTalkHotkey) -> Bool {
        if keyCode == UInt16(kVK_Shift) { return pushToTalk != .leftShift }
        if keyCode == UInt16(kVK_RightShift) { return pushToTalk != .rightShift }
        return true
    }
}
