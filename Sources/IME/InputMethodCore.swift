import AppKit
import Carbon.HIToolbox

extension KeyMeta {
    init?(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            self.init(kind: .keyDown, keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue),
                      isRepeat: event.isARepeat, timestamp: event.timestamp)
        case .flagsChanged:
            self.init(kind: .flagsChanged, keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue),
                      isRepeat: false, timestamp: event.timestamp)
        default:
            return nil
        }
    }
}

/// Everything the input method decides about a key, and everything the main
/// program may ask it to write. It never waits for the main program: what a
/// key does is decided here, from the last context that was pushed.
@MainActor
final class InputMethodCore {
    private struct DeferredKey {
        let event: NSEvent
        let leaseID: UUID
        let generation: Int
    }

    private let manager: IMEManager
    private let pinyin: any PinyinHandling
    private let send: (BridgeEvent) -> Void
    private let now: () -> TimeInterval
    private let fence: InputDeferralDeadline
    /// Metadata-only trace: stages and states, never key codes of typing or text.
    var trace: (String, String) -> Void = { _, _ in }

    private(set) var context = BridgeContext()
    private(set) var trigger: PushToTalkHotkey = .rightOption
    private var phaseSince: TimeInterval = 0
    private var deferred: [DeferredKey] = []
    /// The user typed on while the final text was pending: keys are no longer
    /// held back for the rest of this dictation.
    private var typingResumed = false
    private var announcedTyping = false
    private var lastMarkedSeq: UInt64 = 0
    /// A dictation whose text has been written or dropped; late previews are ignored.
    private var closedSession: UUID?
    /// The last modifier change. Electron clients deliver each one twice
    /// (seen on device: every talk-key edge arrived as a pair).
    private var lastModifier: KeyMeta?
    /// The key of the screen chord while it is held: its auto-repeat is part of the chord.
    private var chordKeyHeld: UInt16?

    /// A phase that outlives these was left behind by a main program that hung.
    static let listeningLimit: TimeInterval = 240
    static let finalizingLimit: TimeInterval = 45
    private static let modifierMask = UInt64(NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue)
    /// Function and arrow keys carry `.function`, so they are forwarded too.
    private static let chordMask = UInt64(NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue)

    init(manager: IMEManager, pinyin: any PinyinHandling, send: @escaping (BridgeEvent) -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         fence: InputDeferralDeadline = InputDeferralDeadline()) {
        self.manager = manager
        self.pinyin = pinyin
        self.send = send
        self.now = now
        self.fence = fence
    }

    // MARK: - Keys

    /// A key delivered by InputMethodKit. Returns whether the client must not see it.
    func handle(_ event: NSEvent) -> Bool {
        pinyin.ensureClient(manager.currentLeaseID)
        guard let meta = KeyMeta(event) else { return false }
        expireStalePhase()
        // The same event a second time is reported and forwarded once.
        let repeated = meta.kind == .flagsChanged && meta == lastModifier
        if meta.kind == .flagsChanged { lastModifier = meta }
        if !repeated, meta.kind == .flagsChanged, meta.keyCode == UInt16(trigger.keyCode) {
            let down = meta.flags & UInt64(trigger.nsModifierFlag.rawValue) != 0
            // Whether InputMethodKit delivers the talk key in this application at all.
            trace("talk-key", "\(down ? "down" : "up") forwarded=\(!context.appOwnsKeys)")
            if down { send(.talkKey(bundleID: manager.clientBundleID, at: meta.timestamp)) }
        }
        if !repeated, !context.appOwnsKeys, forwards(meta) { send(.key(meta)) }
        if consumesLocally(meta) { return true }
        switch context.phase {
        case .idle:
            return pinyin.handle(event, pushToTalk: trigger)
        case .listening:
            // The microphone is open. While the talk key is held, a key is a
            // chord or a slip and the application gets it untouched. In
            // hands-free dictation it ends the utterance: it is what the user
            // types next, so it waits for the text it follows.
            guard context.keysEndDictation, meta.kind == .keyDown, !typingResumed else { return false }
            return hold(event) ?? false
        case .finalizing, .polishing:
            // A bare modifier is not typing.
            guard meta.kind == .keyDown else { return pinyin.handle(event, pushToTalk: trigger) }
            if !typingResumed, let held = hold(event) { return held }
            // Commands cannot be rebuilt through IMKTextInput, so they stay on
            // this callback. The dictation is not lost: its preview is
            // withdrawn and the text is written when it is ready.
            resumeTyping()
            return pinyin.handle(event, pushToTalk: trigger)
        }
    }

    /// Queue a key behind the pending text. Nil when this key cannot wait.
    private func hold(_ event: NSEvent) -> Bool? {
        guard deferred.count < 64, PinyinKeyEvent(event).canDeferForVoiceFinalization,
              let snapshot = manager.deferredInputSnapshot else { return nil }
        deferred.append(DeferredKey(event: event, leaseID: snapshot.leaseID, generation: snapshot.generation))
        if !announcedTyping, let session = context.session {
            // A finished result that is only being polished can be written now.
            announcedTyping = true
            send(.userTyped(session: session))
        }
        fence.arm(after: context.userInputFence) { [weak self] in self?.fenceExpired() }
        return true
    }

    /// Gestures are recognised in the main program, and only what a gesture can
    /// be made of leaves this process: modifier changes, modified keys, Esc and
    /// function keys. Plain typing is not forwarded.
    private func forwards(_ meta: KeyMeta) -> Bool {
        if meta.kind == .flagsChanged { return true }
        if context.phase != .idle || context.screenSelecting { return true }
        if meta.flags & Self.chordMask != 0 { return true }
        return meta.keyCode == UInt16(kVK_Escape)
    }

    /// Decisions that cannot wait for the main program.
    private func consumesLocally(_ meta: KeyMeta) -> Bool {
        guard meta.kind == .keyDown else { return false }
        // Held down, the chord key repeats; passed on, it makes the application beep or types the letter.
        if meta.isRepeat { return meta.keyCode == chordKeyHeld }
        chordKeyHeld = nil
        if meta.keyCode == UInt16(kVK_Escape), meta.flags & Self.modifierMask == 0 {
            // Esc cancels a dictation or a screen selection and nothing else.
            if context.phase != .idle || context.screenSelecting { return true }
        }
        if !context.appOwnsKeys, let code = context.screenShortcutKeyCode, let flags = context.screenShortcutFlags,
           meta.keyCode == code, meta.flags & Self.modifierMask == flags & Self.modifierMask {
            chordKeyHeld = meta.keyCode
            return true
        }
        return false
    }

    // MARK: - Main program

    func apply(_ next: BridgeContext) {
        // A push from an earlier moment of the same main program is stale.
        if next.appPID == context.appPID, next.revision <= context.revision, context.revision != 0 { return }
        let previous = context
        context = next
        trigger = PushToTalkHotkey(rawValue: next.trigger) ?? trigger
        if next.phase != previous.phase || next.session != previous.session {
            phaseSince = now()
            trace("dictation", "\(next.phase.rawValue)\(next.sessionBundleID.map { " in " + $0 } ?? "")")
        }
        if next.appOwnsKeys != previous.appOwnsKeys {
            trace("keys", next.appOwnsKeys ? "the main program listens to keys itself" : "keys are forwarded to the main program")
        }
        if next.session != previous.session, next.session != nil {
            lastMarkedSeq = 0
            typingResumed = false
            announcedTyping = false
        }
        if previous.phase == .idle, next.phase == .listening {
            // A composition in progress is committed before speech is written.
            if pinyin.isComposing { pinyin.commit() }
        }
        if next.phase == .idle, previous.phase != .idle { finish() }
    }

    /// Show a dictation preview. False when no client of that application accepts it.
    func voiceMarked(session: UUID, seq: UInt64, text: String) -> Bool {
        guard session == context.session, session != closedSession, !typingResumed,
              seq > lastMarkedSeq else { return false }
        lastMarkedSeq = seq
        return manager.setVoiceMarked(text, inFront: context.sessionBundleID)
    }

    func voiceClear(session: UUID) {
        guard session == context.session else { return }
        manager.clearVoiceMarked()
    }

    /// Write the final text, then the keys that waited behind it.
    func voiceInsert(session: UUID, text: String, deadline: TimeInterval) -> Bool {
        guard session == context.session, session != closedSession, now() <= deadline,
              manager.canWriteVoice(inFront: context.sessionBundleID) else { return false }
        // `insertText` would replace a composition typed meanwhile.
        if pinyin.isComposing { pinyin.commit() }
        guard manager.insertVoiceText(text, inFront: context.sessionBundleID) else { return false }
        closedSession = session
        replayDeferred()
        return true
    }

    func voiceEnd(session: UUID) {
        guard session == context.session else { return }
        closedSession = session
        manager.clearVoiceMarked()
        replayDeferred()
    }

    /// The main program is gone: nothing it promised will arrive.
    func appExited() {
        var reset = BridgeContext()
        reset.trigger = context.trigger
        context = reset
        finish()
    }

    // MARK: - Typing behind a dictation

    private func finish() {
        manager.clearVoiceMarked()
        typingResumed = false
        announcedTyping = false
        replayDeferred()
    }

    /// Typing wins over the wait for the final text, never at its expense:
    /// queued keys are written now, the dictation when it is ready.
    private func resumeTyping() {
        trace("dictation", "typing went ahead of the pending text")
        typingResumed = true
        manager.clearVoiceMarked()
        replayDeferred()
        if let session = context.session { send(.typingResumed(session: session)) }
    }

    private func fenceExpired() {
        guard context.phase != .idle, !deferred.isEmpty else { return }
        resumeTyping()
    }

    private func replayDeferred() {
        fence.cancel()
        let pending = deferred
        deferred.removeAll(keepingCapacity: true)
        for item in pending {
            guard manager.matchesDeferredInput(leaseID: item.leaseID, generation: item.generation) else { continue }
            if !pinyin.handle(item.event, pushToTalk: trigger) {
                _ = manager.insertDeferredText(item.event.characters ?? "", leaseID: item.leaseID, generation: item.generation)
            }
        }
    }

    private func expireStalePhase() {
        let limit: TimeInterval
        switch context.phase {
        case .idle: return
        case .listening: limit = Self.listeningLimit
        case .finalizing, .polishing: limit = Self.finalizingLimit
        }
        guard now() - phaseSince > limit else { return }
        trace("dictation", "\(context.phase.rawValue) outlived its limit; released")
        context.phase = .idle
        context.session = nil
        finish()
    }
}
