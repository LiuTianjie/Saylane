import AppKit
import Carbon.HIToolbox

@main struct GestureArbiterTests {
    static func main() {
        let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
        let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
        let rightOption = UInt16(kVK_RightOption)
        let rightCommand = UInt16(kVK_RightCommand)
        let leftControl = UInt16(kVK_Control)
        let leftMask = PushToTalkHotkey.leftControl.deviceMask

        func flags(_ code: UInt16, _ flags: UInt64, _ time: TimeInterval, source: InputEvent.Source = .tap) -> InputEvent {
            InputEvent(source: source, type: .flagsChanged, keyCode: code, flags: flags, isRepeat: false, timestamp: time)
        }
        func key(_ code: UInt16, _ flags: UInt64 = 0, _ time: TimeInterval, down: Bool = true, repeatKey: Bool = false) -> InputEvent {
            InputEvent(source: .tap, type: down ? .keyDown : .keyUp, keyCode: code, flags: flags, isRepeat: repeatKey, timestamp: time)
        }

        var passed = 0
        var context = InputContext()
        context.trigger = .rightOption
        context.globalEventsCanBeConsumed = true

        // Right Option press/release is the voice gesture and is consumed.
        do {
            var arbiter = GestureArbiter()
            let press = arbiter.feed(flags(rightOption, option | 0x40, 1.0), context: context)
            precondition(press.actions == [.voice(.press)] && press.consume)
            precondition(arbiter.isOwningGesture)
            var active = context; active.isListening = true; active.voiceCapturing = true
            let release = arbiter.feed(flags(rightOption, 0, 1.5), context: active)
            precondition(release.actions == [.voice(.release)] && release.consume)
            precondition(!arbiter.isOwningGesture)
            passed += 1
        }
        // Unrelated keys pass through untouched.
        do {
            var arbiter = GestureArbiter()
            let result = arbiter.feed(key(UInt16(kVK_ANSI_A), 0, 2.0), context: context)
            precondition(result.actions.isEmpty && !result.consume)
            passed += 1
        }
        // The screen-capture chord wins over everything and is consumed.
        do {
            var arbiter = GestureArbiter()
            let result = arbiter.feed(key(UInt16(kVK_ANSI_T), option, 3.0), context: context)
            precondition(result.actions == [.screenCapture] && result.consume)
            let repeated = arbiter.feed(key(UInt16(kVK_ANSI_T), option, 3.1, repeatKey: true), context: context)
            precondition(repeated.actions.isEmpty)
            passed += 1
        }
        // While a screen session is active the voice key is ignored; Esc cancels a selection.
        do {
            var arbiter = GestureArbiter()
            var screen = context; screen.screenActive = true
            let press = arbiter.feed(flags(rightOption, option | 0x40, 4.0), context: screen)
            precondition(press.actions.isEmpty && !press.consume)
            let esc = arbiter.feed(key(UInt16(kVK_Escape), 0, 4.1), context: screen)
            precondition(esc.actions == [.screenPin(.close)] && esc.consume)
            // A pinned result must not steal keys from other apps.
            var pinned = screen; pinned.pinVisible = true
            let esc2 = arbiter.feed(key(UInt16(kVK_Escape), 0, 4.2), context: pinned)
            precondition(esc2.actions.isEmpty && !esc2.consume)
            let letter = arbiter.feed(key(UInt16(kVK_ANSI_R), 0, 4.3), context: pinned)
            precondition(letter.actions.isEmpty && !letter.consume)
            passed += 1
        }
        // Left Control hold arms the screen gesture only when enabled.
        do {
            var arbiter = GestureArbiter()
            let off = arbiter.feed(flags(leftControl, leftMask, 5.0), context: context)
            precondition(off.actions.isEmpty)
            var on = context; on.screenHoldEnabled = true
            arbiter = GestureArbiter()
            let armed = arbiter.feed(flags(leftControl, leftMask, 6.0), context: on)
            precondition(armed.actions == [.screenHold(.armHold)])
            precondition(arbiter.screenHoldDeadline(now: 6.2) == nil)
            precondition(arbiter.screenHoldDeadline(now: 6.31) == .screenHold(.begin))
            passed += 1
        }
        // Double-tap right Command switches direction when the trigger is another key.
        do {
            var arbiter = GestureArbiter()
            let mask = PushToTalkHotkey.rightCommand.deviceMask
            _ = arbiter.feed(flags(rightCommand, command | mask, 7.0), context: context)
            _ = arbiter.feed(flags(rightCommand, 0, 7.1), context: context)
            _ = arbiter.feed(flags(rightCommand, command | mask, 7.25), context: context)
            let second = arbiter.feed(flags(rightCommand, 0, 7.32), context: context)
            precondition(second.actions.contains(.switchDirection))
            passed += 1
        }
        // Right Command as the talk key: hold arms first, deadline promotes to press.
        do {
            var arbiter = GestureArbiter()
            var rc = context; rc.trigger = .rightCommand
            let mask = PushToTalkHotkey.rightCommand.deviceMask
            let down = arbiter.feed(flags(rightCommand, command | mask, 8.0), context: rc)
            precondition(down.actions == [.voice(.armHold)] && down.consume)
            precondition(arbiter.voiceDeadline(now: 8.1) == nil)
            precondition(arbiter.voiceDeadline(now: 8.2) == .voice(.press))
            passed += 1
        }
        // Recording owns the first chord even when validation rejects it. This
        // prevents ⌘Q/⌘W or a bare letter from escaping while the recorder is active.
        do {
            var arbiter = GestureArbiter()
            var recording = context; recording.recordingShortcut = true
            let bare = arbiter.feed(key(UInt16(kVK_ANSI_S), 0, 9.0), context: recording)
            precondition(bare.actions == [.recordedShortcut(.init(keyCode: UInt16(kVK_ANSI_S), modifierFlags: 0))]
                         && bare.consume)
            let chord = arbiter.feed(key(UInt16(kVK_ANSI_S), option | command, 9.1), context: recording)
            precondition(chord.consume)
            if case .recordedShortcut(let recorded?) = chord.actions.first! {
                precondition(recorded.keyCode == UInt16(kVK_ANSI_S) && recorded.normalizedFlags == (option | command))
            } else { fatalError("expected recorded shortcut") }
            let esc = arbiter.feed(key(UInt16(kVK_Escape), 0, 9.2), context: recording)
            precondition(esc.actions == [.recordedShortcut(nil)])
            passed += 1
        }
        do { // A click while the result is being finalized moves the caret; it does not discard the dictation.
            var arbiter = GestureArbiter()
            var finalizing = context; finalizing.isListening = true; finalizing.voiceCapturing = false
            let click = InputEvent(source: .tap, type: .leftMouseDown, keyCode: 0,
                                   flags: 0, isRepeat: false, timestamp: 10.91)
            let result = arbiter.feed(click, context: finalizing)
            precondition(result.actions.isEmpty && !result.consume)
            passed += 1
        }
        do { // While the key is still held, a click is a chord and abandons the recording.
            var arbiter = GestureArbiter()
            let press = arbiter.feed(flags(rightOption, option | 0x40, 10.0), context: context)
            precondition(press.actions == [.voice(.press)])
            var holding = context; holding.isListening = true; holding.voiceCapturing = true
            let click = InputEvent(source: .tap, type: .leftMouseDown, keyCode: 0,
                                   flags: option | 0x40, isRepeat: false, timestamp: 10.5)
            let result = arbiter.feed(click, context: holding)
            precondition(result.actions == [.voice(.cancel)] && !result.consume)
            passed += 1
        }
        do { // A mouse click aborts a pending Control hold before its deadline.
            var arbiter = GestureArbiter()
            var hold = context; hold.screenHoldEnabled = true
            let armed = arbiter.feed(flags(leftControl, leftMask, 10.92), context: hold)
            precondition(armed.actions == [.screenHold(.armHold)])
            let click = InputEvent(source: .tap, type: .rightMouseDown, keyCode: 0,
                                   flags: leftMask, isRepeat: false, timestamp: 10.93)
            _ = arbiter.feed(click, context: hold)
            precondition(arbiter.screenHoldDeadline(now: 11.4) == nil)
            passed += 1
        }
        do { // One physical left-Control press cannot start both voice and selection.
            var arbiter = GestureArbiter()
            var shared = context; shared.trigger = .leftControl; shared.screenHoldEnabled = true
            let result = arbiter.feed(flags(leftControl, leftMask, 10.94), context: shared)
            precondition(result.actions == [.voice(.press)] && result.consume)
            passed += 1
        }
        do { // Fast ordinary right-Command shortcuts are not a direction double-tap.
            var arbiter = GestureArbiter()
            let mask = PushToTalkHotkey.rightCommand.deviceMask
            _ = arbiter.feed(flags(rightCommand, command | mask, 10.95), context: context)
            _ = arbiter.feed(key(UInt16(kVK_ANSI_C), command, 10.96), context: context)
            _ = arbiter.feed(flags(rightCommand, 0, 10.97), context: context)
            _ = arbiter.feed(flags(rightCommand, command | mask, 11.05), context: context)
            _ = arbiter.feed(key(UInt16(kVK_ANSI_V), command, 11.06), context: context)
            let up = arbiter.feed(flags(rightCommand, 0, 11.07), context: context)
            precondition(!up.actions.contains(.switchDirection))
            passed += 1
        }
        // Tap-to-talk: any key ends the utterance while listening.
        do {
            var arbiter = GestureArbiter()
            var tap = context; tap.tapToTalk = true
            let press = arbiter.feed(flags(rightOption, option | 0x40, 10.0), context: tap)
            precondition(press.actions == [.voice(.press)])
            tap.isListening = true; tap.voiceCapturing = true
            let stop = arbiter.feed(key(UInt16(kVK_ANSI_A), 0, 10.5), context: tap)
            precondition(stop.actions == [.voice(.release)])
            passed += 1
        }
        do { // During finalization only Esc cancels; ordinary typing is not a recording gesture.
            var arbiter = GestureArbiter()
            var finalizing = context
            finalizing.isListening = true
            finalizing.voiceCapturing = false
            let letter = arbiter.feed(key(UInt16(kVK_ANSI_A), 0, 10.8), context: finalizing)
            precondition(letter.actions.isEmpty && !letter.consume)
            let esc = arbiter.feed(key(UInt16(kVK_Escape), 0, 10.9), context: finalizing)
            precondition(esc.actions == [.voice(.cancel)] && esc.consume)
            passed += 1
        }
        do { // Listen-only taps never leak a screen chord/function trigger while acting on it.
            var arbiter = GestureArbiter()
            var listenOnly = context
            listenOnly.globalEventsCanBeConsumed = false
            let screen = arbiter.feed(key(UInt16(kVK_ANSI_T), option, 10.95), context: listenOnly)
            precondition(screen.actions.isEmpty && !screen.consume)
            listenOnly.trigger = .f20
            let function = arbiter.feed(key(UInt16(kVK_F20), 0, 10.96), context: listenOnly)
            precondition(function.actions.isEmpty && !function.consume)
            listenOnly.globalEventsCanBeConsumed = true
            let filtered = arbiter.feed(key(UInt16(kVK_F20), 0, 10.97), context: listenOnly)
            precondition(filtered.actions == [.voice(.press)] && filtered.consume)
            passed += 1
        }
        // A duplicate delivery (tap then IMK) is recognised by the event itself.
        do {
            let a = flags(rightOption, option, 11.0)
            let b = flags(rightOption, option, 11.02, source: .imk)
            precondition(b.isDuplicate(of: a, window: 0.05))
            precondition(!flags(rightOption, option, 11.2, source: .imk).isDuplicate(of: a, window: 0.05))
            precondition(!flags(rightOption, 0, 11.02, source: .imk).isDuplicate(of: a, window: 0.05), "keyup is not a duplicate keydown")
            precondition(!flags(rightOption, option, 11.02).isDuplicate(of: a, window: 0.05), "same-source events must be interpreted")
            passed += 1
        }
        do { // Removing/disabling the IME must not hijack another input method's keys.
            var arbiter = GestureArbiter()
            var disabled = context
            disabled.voiceEnabled = false
            let down = arbiter.feed(flags(rightOption, option | 0x40, 12), context: disabled)
            precondition(!down.consume && down.actions.isEmpty)
            let up = arbiter.feed(flags(rightOption, 0, 12.2), context: disabled)
            precondition(!up.consume && up.actions.isEmpty && !arbiter.isOwningGesture)
            passed += 1
        }
        print("PASS: \(passed) gesture arbiter scenarios (voice, screen chord, hold, double tap, recording, tap-to-talk, dedupe)")
    }
}
