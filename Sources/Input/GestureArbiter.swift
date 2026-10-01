import AppKit
import Carbon.HIToolbox

/// One value type recognises every gesture Saylane reacts to, in a fixed priority
/// order, from a single event stream. Time is injected so tests need no timers.
///
/// Priority: shortcut recording → pin keys → screen hold → direction double-tap →
/// screen capture shortcut → voice trigger. A screen session suppresses voice.
struct GestureArbiter {
    struct Result: Equatable {
        var actions: [InputAction] = []
        /// The event should not reach the target application.
        var consume = false
    }

    private var voice = VoiceGesture()
    private var screenHold = ScreenHoldHandler()
    private var rightCommandTap = RightCommandDoubleTap()

    /// A talk-key press is in progress (pending, talking or void until released).
    var voiceGestureActive: Bool { voice.isActive }
    /// When `voiceDeadline(now:)` must be called next.
    var nextVoiceDeadline: TimeInterval? { voice.nextDeadline }

    mutating func reset() {
        voice.reset()
        screenHold.reset()
        rightCommandTap.reset()
    }

    /// The owner found out that the current press is a chord after all.
    mutating func abandonVoice() -> [InputAction] { voice.abandon().map(InputAction.voice) }

    /// The talk key is physically up but its release never arrived.
    mutating func voiceTriggerLost(now: TimeInterval, context c: InputContext) -> [InputAction] {
        voice.trigger(down: false, alone: true, now: now, config: Self.config(c)).map(InputAction.voice)
    }

    mutating func noteEndedSelection() { screenHold.noteEndedSelection() }
    mutating func setPinVisible(_ visible: Bool) { screenHold.setPinVisible(visible) }

    /// Timer callback for the talk key.
    mutating func voiceDeadline(now: TimeInterval) -> [InputAction] {
        voice.deadline(now: now).map(InputAction.voice)
    }

    /// Timer callback for the left-Control screen hold.
    mutating func screenHoldDeadline(now: TimeInterval) -> InputAction? {
        let next = screenHold.holdDeadline(now: now)
        return next == .none ? nil : .screenHold(next)
    }

    private static func config(_ c: InputContext) -> VoiceGesture.Config {
        VoiceGesture.Config(toggle: c.tapToTalk, doubleTapSwitches: c.switchEnabled && c.trigger == .rightCommand)
    }

    mutating func feed(_ event: InputEvent, context c: InputContext) -> Result {
        var result = Result()
        let now = event.timestamp

        // 1. Recording a new screen-capture shortcut swallows the first chord.
        if c.recordingShortcut {
            guard event.type == .keyDown, !event.isRepeat else { return result }
            if event.keyCode == UInt16(kVK_Escape) {
                result.actions.append(.recordedShortcut(nil)); result.consume = true
                return result
            }
            if !Self.isModifierKey(event.keyCode) {
                let recorded = ScreenCaptureShortcut(keyCode: event.keyCode, modifierFlags: event.flags)
                result.actions.append(.recordedShortcut(recorded)); result.consume = true
            }
            return result
        }

        // 2. While a selection overlay is up, Esc cancels it from anywhere. A pinned
        //    result never steals keys from other apps; its keys work once it is clicked.
        if c.screenActive, !c.pinVisible, event.type == .keyDown, !event.isRepeat,
           let key = Self.localPinKey(event, selecting: true) {
            result.actions.append(.screenPin(key)); result.consume = true
            return result
        }

        // Final translation/polish is still cancellable with Esc, but ordinary
        // typing is no longer interpreted as a recording gesture after key-up.
        if c.isListening, !c.voiceCapturing, event.type == .keyDown,
           event.keyCode == UInt16(kVK_Escape), !event.isRepeat {
            result.actions.append(.voice(.cancel)); result.consume = true
            return result
        }

        // Ordinary Command shortcuts or a click invalidate a right-Command tap
        // candidate. Two quick ⌘C/⌘V sequences must never switch direction.
        if event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown {
            rightCommandTap.reset()
        }

        // 3. Long-press left Control (opt-in) starts a selection.
        if c.screenActive || (c.screenHoldEnabled && !(c.voiceEnabled && c.trigger == .leftControl)) {
            let action = screenHold.handle(type: event.type, keyCode: event.keyCode, flags: event.flags, now: now,
                                           deliversKeyUp: event.source != .imk)
            if action != .none { result.actions.append(.screenHold(action)) }
        }

        // 4. Double-tap right Command cycles the direction, unless it is the talk key.
        if c.voiceEnabled, c.switchEnabled, event.type == .flagsChanged, c.trigger != .rightCommand || c.screenActive {
            if rightCommandTap.handle(flags: event.flags, now: now) {
                result.actions.append(.switchDirection)
            }
        }

        // 5. Screen-capture chord.
        if event.type == .keyDown, !event.isRepeat, c.screenShortcut.matches(keyCode: event.keyCode, flags: event.flags) {
            // A listen-only tap cannot swallow the chord; let IMK handle it when
            // our source is selected and otherwise leave the foreground app alone.
            if event.source == .tap && !c.globalEventsCanBeConsumed { return result }
            // ⌥T with ⌥ as the talk key: the press was a chord, not a hold.
            result.actions.append(contentsOf: voice.other(.key).map(InputAction.voice))
            result.actions.append(.screenCapture); result.consume = true
            return result
        }

        // 6. Talk key, suppressed while a screen session is active.
        if c.screenActive || !c.voiceEnabled {
            voice.reset()
            if !c.voiceEnabled { rightCommandTap.reset() }
            return result
        }
        let config = Self.config(c)
        var actions: [VoiceGesture.Action] = []
        let isTrigger = event.keyCode == UInt16(c.trigger.keyCode)
        switch event.type {
        case .flagsChanged:
            guard c.trigger.isModifier else { break }
            if isTrigger {
                let down = Self.isDown(c.trigger, flags: event.flags)
                // Observed, never swallowed: a modifier does nothing by itself,
                // applications that follow modifiers keep seeing it, and the
                // input method learns from it which client has the keyboard.
                actions = voice.trigger(down: down, alone: Self.isAlone(c.trigger, flags: event.flags),
                                        now: now, config: config)
            } else if event.keyCode != UInt16(kVK_CapsLock), Self.otherModifierDown(c.trigger, flags: event.flags) {
                actions = voice.other(.modifier)
            }
        case .keyDown:
            if !c.trigger.isModifier, isTrigger {
                // A function key has visible behaviour of its own and needs its
                // key-up: only a listener that can swallow it may start from it.
                guard c.globalEventsCanBeConsumed, event.source != .imk else { return result }
                guard event.flags & Self.chordFlags == 0 else { break }
                if !event.isRepeat { actions = voice.functionKey(down: true, config: config) }
                result.consume = true
            } else if event.keyCode == UInt16(kVK_Escape), c.voiceCapturing || voice.isTalking, !event.isRepeat {
                // The session decides, not only the gesture: it may have been
                // started from the settings window or outlived a reset.
                let escaped = voice.escape()
                actions = escaped.isEmpty ? [.cancel] : escaped
                result.consume = true
            } else if !event.isRepeat {
                actions = voice.other(.key)
            }
        case .keyUp:
            if !c.trigger.isModifier, isTrigger, c.globalEventsCanBeConsumed {
                actions = voice.functionKey(down: false, config: config)
                result.consume = true
            }
        case .leftMouseDown, .rightMouseDown:
            actions = voice.other(.mouse)
        default:
            break
        }
        result.actions.append(contentsOf: actions.map(InputAction.voice))
        return result
    }

    private static let chordFlags = UInt64(NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue)
    private static let modifierClasses = UInt64(NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue)

    /// Left and right are told apart by the device bits when the event carries
    /// them (the event tap); InputMethodKit only reports the modifier class.
    private static func isDown(_ trigger: PushToTalkHotkey, flags: UInt64) -> Bool {
        if trigger.deviceMask != 0, flags & (trigger.deviceMask | trigger.siblingMask) != 0 {
            return flags & trigger.deviceMask != 0
        }
        return flags & UInt64(trigger.nsModifierFlag.rawValue) != 0
    }

    private static func isAlone(_ trigger: PushToTalkHotkey, flags: UInt64) -> Bool {
        flags & modifierClasses & ~UInt64(trigger.nsModifierFlag.rawValue) == 0 && flags & trigger.siblingMask == 0
    }

    /// Another modifier is held (as opposed to one having just been released).
    private static func otherModifierDown(_ trigger: PushToTalkHotkey, flags: UInt64) -> Bool {
        flags & modifierClasses & ~UInt64(trigger.nsModifierFlag.rawValue) != 0 || flags & trigger.siblingMask != 0
    }

    /// Key → pin action. While only a selection is in progress, just Esc applies.
    static func localPinKey(_ event: InputEvent, selecting: Bool) -> ScreenPinKey? {
        guard event.type == .keyDown else { return nil }
        let key = pinKey(event)
        if selecting { return key == .close ? .close : nil }
        return key
    }

    private static func pinKey(_ event: InputEvent) -> ScreenPinKey? {
        let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
        let others = UInt64(NSEvent.ModifierFlags([.option, .control, .shift]).rawValue)
        guard event.flags & others == 0 else { return nil }
        switch Int(event.keyCode) {
        case kVK_Escape: return event.flags & command == 0 ? .close : nil
        case kVK_Tab, kVK_Space: return event.flags & command == 0 ? .toggleOverlay : nil
        case kVK_ANSI_C: return event.flags & command != 0 ? .copy : nil
        case kVK_ANSI_R: return event.flags & command == 0 ? .retry : nil
        case kVK_ANSI_D: return event.flags & command == 0 ? .cycleDirection : nil
        default: return nil
        }
    }

    static func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand, kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl, kVK_Shift, kVK_RightShift, kVK_Function, kVK_CapsLock:
            return true
        default:
            return false
        }
    }
}
