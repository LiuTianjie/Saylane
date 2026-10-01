import AppKit

/// Hold-to-talk on a modifier key starts only after the key has been held on
/// its own for `holdDelay`: ⌘W, ⌥←, ⇧A or a modified click never start a
/// dictation. An unconfirmed hold owns at most a preroll, which is discarded
/// as soon as the gesture is abandoned.
struct InputShortcutHandler {
    enum Action: Equatable { case none, armHold, armTap, disarm, press, release, cancel, switchTarget }
    static let holdDelay: TimeInterval = 0.28
    static let doubleTapGap: TimeInterval = 0.32
    private var talk = PushToTalkHandler()
    private var language = PushToTalkHandler()
    private var pressedAt: TimeInterval?
    private var firstTapReleasedAt: TimeInterval?
    private var pendingHoldAt: TimeInterval?
    private var pendingTapAt: TimeInterval?
    private var sharedTapDown = false
    private var secondSharedTap = false

    mutating func reset() {
        talk.reset(); language.reset()
        pendingTapAt = nil; sharedTapDown = false; secondSharedTap = false
        pressedAt = nil; firstTapReleasedAt = nil; pendingHoldAt = nil
    }

    mutating func holdDeadline(now: TimeInterval) -> Action {
        if let released = pendingTapAt, !sharedTapDown,
           now - released >= Self.doubleTapGap {
            pendingTapAt = nil
            return .press
        }
        guard let start = pendingHoldAt, talk.holding,
              now - start >= Self.holdDelay else { return .none }
        pendingHoldAt = nil
        pressedAt = nil; firstTapReleasedAt = nil
        return .press
    }

    mutating func handle(type: NSEvent.EventType, keyCode: UInt16, flags: UInt64,
                         repeatKey: Bool, trigger: PushToTalkHotkey,
                         switchEnabled: Bool, active: Bool, now: TimeInterval,
                         tapToTalk: Bool = false) -> (Action, Bool) {
        if tapToTalk && switchEnabled && trigger == .rightCommand {
            return handleSharedTap(type: type, keyCode: keyCode, flags: flags,
                repeatKey: repeatKey, active: active, now: now)
        }
        // Never treat Command+C, another modifier chord, or a click as a tap/hold gesture.
        let chord = type == .keyDown || type == .leftMouseDown || type == .rightMouseDown
            || (type == .flagsChanged && keyCode != UInt16(PushToTalkHotkey.rightCommand.keyCode)
                && keyCode != UInt16(trigger.keyCode))
        let abandonedHold = chord && pendingHoldAt != nil
        if chord {
            pressedAt = nil; firstTapReleasedAt = nil
            if pendingHoldAt != nil { pendingHoldAt = nil; talk.reset() }
        }
        let (talkAction, consumed) = talk.handle(type: type, keyCode: keyCode, flags: flags,
            repeatKey: repeatKey, trigger: trigger, active: active, tapToTalk: tapToTalk)
        var switched = false
        if switchEnabled {
            let (action, _) = language.handle(type: type, keyCode: keyCode, flags: flags,
                repeatKey: repeatKey, trigger: .rightCommand, active: false)
            switch action {
            case .press:
                let forbidden = NSEvent.ModifierFlags([.option, .control, .shift]).rawValue
                pressedAt = !active && flags & UInt64(forbidden) == 0 ? now : nil
            case .release:
                if let start = pressedAt, now - start < Self.holdDelay, !active {
                    if let previous = firstTapReleasedAt, now - previous <= Self.doubleTapGap {
                        switched = true; firstTapReleasedAt = nil
                    } else { firstTapReleasedAt = now }
                } else { firstTapReleasedAt = nil }
                pressedAt = nil
            default: break
            }
        } else {
            language.reset(); pressedAt = nil; firstTapReleasedAt = nil
        }
        if switched {
            pendingHoldAt = nil
            return (.switchTarget, true)
        }
        switch talkAction {
        case .press:
            // A modifier is part of every shortcut; only a hold on its own is a
            // request to talk. Function keys have no chords and start at once.
            if trigger.isModifier && !tapToTalk {
                pendingHoldAt = now
                return (.armHold, true)
            }
            return (.press, consumed)
        case .release:
            if pendingHoldAt != nil {
                pendingHoldAt = nil
                return (.disarm, consumed)
            }
            return (.release, consumed)
        case .cancel: reset(); return (.cancel, consumed)
        case .none: return (abandonedHold ? .disarm : .none, consumed)
        }
    }
    /// Single and double taps share a key: do not start speech until the
    /// double-tap window closes. Recording stop must never also switch language.
    private mutating func handleSharedTap(type: NSEvent.EventType, keyCode: UInt16,
                                         flags: UInt64, repeatKey: Bool,
                                         active: Bool, now: TimeInterval) -> (Action, Bool) {
        if active {
            pendingTapAt = nil; sharedTapDown = false; secondSharedTap = false
            let (action, consumed) = talk.handle(type: type, keyCode: keyCode, flags: flags,
                repeatKey: repeatKey, trigger: .rightCommand, active: true, tapToTalk: true)
            switch action {
            case .release: return (.release, consumed)
            case .cancel: reset(); return (.cancel, consumed)
            default: return (.none, consumed)
            }
        }
        let forbidden = NSEvent.ModifierFlags([.option, .control, .shift]).rawValue
        guard type == .flagsChanged, keyCode == UInt16(PushToTalkHotkey.rightCommand.keyCode),
              flags & UInt64(forbidden) == 0 else {
            let wasArmed = sharedTapDown || pendingTapAt != nil
            let interrupted = type == .keyDown || type == .flagsChanged || type == .leftMouseDown || type == .rightMouseDown
            if interrupted {
                reset()
            }
            return (wasArmed && interrupted ? .disarm : .none, false)
        }
        let (action, consumed) = talk.handle(type: type, keyCode: keyCode, flags: flags,
            repeatKey: repeatKey, trigger: .rightCommand, active: false)
        switch action {
        case .press:
            sharedTapDown = true
            secondSharedTap = pendingTapAt.map { now - $0 < Self.doubleTapGap } ?? false
            // If the timer was delayed, never let it fire while a new key is down.
            pendingTapAt = nil
            return (.armTap, consumed)
        case .release:
            guard sharedTapDown else { return (.none, consumed) }
            sharedTapDown = false
            if secondSharedTap {
                secondSharedTap = false
                return (.switchTarget, true)
            }
            pendingTapAt = now
            return (.armTap, true)
        default: return (.none, consumed)
        }
    }

}
