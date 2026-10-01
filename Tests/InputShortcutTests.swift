import AppKit
import Carbon.HIToolbox

@main struct InputShortcutTests {
    static func main() {
        let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
        var handler = InputShortcutHandler()
        func right(_ down: Bool, _ time: Double, enabled: Bool = true, active: Bool = false,
                   trigger: PushToTalkHotkey = .rightCommand) -> InputShortcutHandler.Action {
            handler.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightCommand), flags: down ? command : 0,
                repeatKey: false, trigger: trigger, switchEnabled: enabled, active: active, now: time).0
        }
        precondition(right(true, 0) == .armHold)
        precondition(right(false, 0.06) == .disarm)
        precondition(right(true, 0.15) == .armHold)
        precondition(right(false, 0.21) == .switchTarget)
        precondition(handler.holdDeadline(now: 0.5) == .none)
        handler.reset()
        precondition(right(true, 1) == .armHold)
        precondition(handler.holdDeadline(now: 1.2) == .none)
        precondition(handler.holdDeadline(now: 1.3) == .press)
        precondition(right(false, 1.8, active: true) == .release)
        // A release after a real hold must not become the first tap of a switch.
        _ = right(true, 1.9); precondition(right(false, 1.95) != .switchTarget)
        handler.reset()
        _ = right(true, 2); _ = right(false, 2.05)
        _ = right(true, 2.6); precondition(right(false, 2.65) != .switchTarget)
        handler.reset()
        // Every modifier is hold-to-talk: a quick press is a tap, not a dictation.
        precondition(right(true, 3, enabled: false) == .armHold)
        precondition(right(false, 3.01, enabled: false) == .disarm)
        precondition(handler.holdDeadline(now: 3.5) == .none)
        handler.reset()
        // ⌘W with left Command as the talk key: the chord abandons the hold for good.
        func left(_ down: Bool, _ time: Double, active: Bool = false) -> InputShortcutHandler.Action {
            handler.handle(type: .flagsChanged, keyCode: UInt16(kVK_Command), flags: down ? command : 0,
                repeatKey: false, trigger: .leftCommand, switchEnabled: true, active: active, now: time).0
        }
        precondition(left(true, 3.6) == .armHold)
        precondition(handler.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_W), flags: command, repeatKey: false,
            trigger: .leftCommand, switchEnabled: true, active: false, now: 3.7).0 == .disarm)
        precondition(handler.holdDeadline(now: 4.2) == .none)
        precondition(left(false, 4.25) == .none)
        // A modified click (⌘-click) abandons it as well.
        precondition(left(true, 4.4) == .armHold)
        precondition(handler.handle(type: .leftMouseDown, keyCode: 0, flags: command, repeatKey: false,
            trigger: .leftCommand, switchEnabled: true, active: false, now: 4.5).0 == .disarm)
        precondition(handler.holdDeadline(now: 4.9) == .none)
        precondition(left(false, 4.95) == .none)
        // Another modifier joining (⌘⇧) abandons it too.
        precondition(left(true, 5.1) == .armHold)
        precondition(handler.handle(type: .flagsChanged, keyCode: UInt16(kVK_Shift),
            flags: command | UInt64(NSEvent.ModifierFlags.shift.rawValue), repeatKey: false,
            trigger: .leftCommand, switchEnabled: true, active: false, now: 5.15).0 == .disarm)
        precondition(handler.holdDeadline(now: 5.6) == .none)
        handler.reset()
        // Held on its own, it becomes a dictation and the release ends it.
        precondition(left(true, 5.7) == .armHold)
        precondition(handler.holdDeadline(now: 5.9) == .none)
        precondition(handler.holdDeadline(now: 5.99) == .press)
        precondition(left(false, 7, active: true) == .release)
        handler.reset()
        _ = right(true, 4)
        _ = handler.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_C), flags: command,
            repeatKey: false, trigger: .rightCommand, switchEnabled: true, active: false, now: 4.03)
        precondition(handler.holdDeadline(now: 4.3) == .none)
        _ = right(false, 4.31); _ = right(true, 4.4)
        precondition(right(false, 4.45) != .switchTarget)
        handler.reset()
        _ = right(true, 6.1, trigger: .rightOption); _ = right(false, 6.15, trigger: .rightOption)
        _ = right(true, 6.25, trigger: .rightOption)
        precondition(right(false, 6.3, trigger: .rightOption) == .switchTarget)
        handler.reset()
        _ = right(true, 6.5); handler.reset()
        precondition(handler.holdDeadline(now: 7) == .none)
        _ = right(true, 8, active: true); _ = right(false, 8.05, active: true)
        _ = right(true, 8.15, active: true)
        precondition(right(false, 8.2, active: true) != .switchTarget)
        handler.reset()
        func tap(_ down: Bool, _ time: Double, active: Bool = false,
                 enabled: Bool = true) -> InputShortcutHandler.Action {
            handler.handle(type: .flagsChanged, keyCode: UInt16(kVK_RightCommand),
                flags: down ? command : 0, repeatKey: false, trigger: .rightCommand,
                switchEnabled: enabled, active: active, now: time, tapToTalk: true).0
        }
        precondition(tap(true, 10) == .armTap)
        precondition(tap(false, 10.05) == .armTap)
        precondition(handler.holdDeadline(now: 10.2) == .none)
        precondition(tap(true, 10.2) == .armTap)
        precondition(handler.holdDeadline(now: 10.4) == .none)
        precondition(tap(false, 10.45) == .switchTarget)
        precondition(handler.holdDeadline(now: 11) == .none)
        // Single click starts once, after release + double-tap window.
        handler.reset()
        _ = tap(true, 12); _ = tap(false, 12.05)
        precondition(handler.holdDeadline(now: 12.3) == .none)
        precondition(handler.holdDeadline(now: 12.38) == .press)
        precondition(handler.holdDeadline(now: 12.8) == .none)
        precondition(tap(true, 13, active: true) == .release)
        precondition(tap(false, 13.05) == .none)
        precondition(handler.holdDeadline(now: 13.5) == .none)
        // Typing a chord or resetting focus cancels a pending single click.
        handler.reset(); _ = tap(true, 14); _ = tap(false, 14.05)
        _ = handler.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_C), flags: command,
            repeatKey: false, trigger: .rightCommand, switchEnabled: true,
            active: false, now: 14.1, tapToTalk: true)
        precondition(handler.holdDeadline(now: 14.5) == .none)
        handler.reset(); _ = tap(true, 15); _ = tap(false, 15.05)
        handler.reset(); precondition(handler.holdDeadline(now: 16) == .none)
        // Without language switching, tap-to-talk retains immediate behavior.
        precondition(tap(true, 17, enabled: false) == .press)
        print("PASS: shared-key tap-to-talk single/double arbitration, stop, chords and reset")
        print("PASS: shortcut gestures: double taps, hold on its own, ⌘W / ⌘-click / ⌘⇧ chords, focus reset, recording guard")
    }
}
