import AppKit

/// Distinguish hold-to-talk from two short taps without opening the microphone
/// during taps. Time is injected so boundary cases can be tested without timers.
struct InputShortcutHandler {
    enum Action: Equatable { case none, armHold, press, release, cancel, switchTarget }
    static let holdDelay: TimeInterval = 0.18
    static let doubleTapGap: TimeInterval = 0.32
    private var talk = PushToTalkHandler()
    private var language = PushToTalkHandler()
    private var pressedAt: TimeInterval?
    private var firstTapReleasedAt: TimeInterval?
    private var pendingHoldAt: TimeInterval?

    mutating func reset() {
        talk.reset(); language.reset()
        pressedAt = nil; firstTapReleasedAt = nil; pendingHoldAt = nil
    }

    mutating func holdDeadline(now: TimeInterval) -> Action {
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
        // Never treat Command+C, another modifier chord, or a click as a tap/hold gesture.
        let chord = type == .keyDown || type == .leftMouseDown || type == .rightMouseDown
            || (type == .flagsChanged && keyCode != UInt16(PushToTalkHotkey.rightCommand.keyCode))
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
            if switchEnabled && trigger == .rightCommand && !tapToTalk {
                pendingHoldAt = now
                return (.armHold, true)
            }
            return (.press, consumed)
        case .release:
            if pendingHoldAt != nil {
                pendingHoldAt = nil
                return (.none, consumed)
            }
            return (.release, consumed)
        case .cancel: reset(); return (.cancel, consumed)
        case .none: return (.none, consumed)
        }
    }
}
