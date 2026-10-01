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

    private var voice = InputShortcutHandler()
    private var router = GlobalHotkeyRouter()
    private var screenHold = ScreenHoldHandler()
    private var rightCommandTap = RightCommandDoubleTap()

    var isOwningGesture: Bool { router.owningGesture }

    mutating func reset() {
        voice.reset()
        router.reset()
        screenHold.reset()
        rightCommandTap.reset()
    }

    mutating func noteEndedSelection() { screenHold.noteEndedSelection() }
    mutating func setPinVisible(_ visible: Bool) { screenHold.setPinVisible(visible) }

    /// Timer callback for the voice hold/double-tap window.
    mutating func voiceDeadline(now: TimeInterval) -> InputAction? {
        let next = voice.holdDeadline(now: now)
        router.note(next)
        return next == .none ? nil : .voice(next)
    }

    /// Timer callback for the left-Control screen hold.
    mutating func screenHoldDeadline(now: TimeInterval) -> InputAction? {
        let next = screenHold.holdDeadline(now: now)
        return next == .none ? nil : .screenHold(next)
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
            let action = screenHold.handle(type: event.type, keyCode: event.keyCode, flags: event.flags, now: now)
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
            result.actions.append(.screenCapture); result.consume = true
            return result
        }

        // 6. Voice trigger, suppressed while a screen session is active. A click
        //    or a key after the release is not a gesture: the result is written
        //    wherever the caret is when it is ready.
        if c.screenActive || !c.voiceEnabled {
            voice.reset()
            router.reset()
            if !c.voiceEnabled { rightCommandTap.reset() }
            return result
        }
        // Function keys have visible system/app behavior. Never start from a
        // listen-only tap; IMK has no key-up contract in Chromium clients.
        if event.source == .tap, !c.globalEventsCanBeConsumed, !c.trigger.isModifier,
           event.keyCode == UInt16(c.trigger.keyCode) { return result }
        let interpret = router.shouldInterpret(isOursSelected: c.isOursSelected, keyCode: event.keyCode,
                                               triggerKeyCode: UInt16(c.trigger.keyCode))
            || (c.tapToTalk && c.voiceCapturing)
        guard interpret else { return result }
        let (action, consumed) = voice.handle(type: event.type, keyCode: event.keyCode, flags: event.flags,
                                              repeatKey: event.isRepeat, trigger: c.trigger,
                                              switchEnabled: c.switchEnabled, active: c.voiceCapturing,
                                              now: now, tapToTalk: c.tapToTalk)
        router.note(action)
        if action != .none { result.actions.append(.voice(action)) }
        if consumed { result.consume = true }
        return result
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
