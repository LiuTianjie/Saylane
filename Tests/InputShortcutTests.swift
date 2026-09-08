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
        precondition(right(false, 0.06) == .none)
        precondition(right(true, 0.15) == .armHold)
        precondition(right(false, 0.21) == .switchTarget)
        precondition(handler.holdDeadline(now: 0.5) == .none)
        handler.reset()
        precondition(right(true, 1) == .armHold)
        precondition(handler.holdDeadline(now: 1.1) == .none)
        precondition(handler.holdDeadline(now: 1.2) == .press)
        precondition(right(false, 1.8, active: true) == .release)
        // A release after a real hold must not become the first tap of a switch.
        _ = right(true, 1.9); precondition(right(false, 1.95) != .switchTarget)
        handler.reset()
        _ = right(true, 2); _ = right(false, 2.05)
        _ = right(true, 2.6); precondition(right(false, 2.65) != .switchTarget)
        handler.reset()
        precondition(right(true, 3, enabled: false) == .press)
        precondition(right(false, 3.01, enabled: false) == .release)
        handler.reset()
        _ = right(true, 4)
        _ = handler.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_C), flags: command,
            repeatKey: false, trigger: .rightCommand, switchEnabled: true, active: false, now: 4.03)
        precondition(handler.holdDeadline(now: 4.3) == .none)
        _ = right(false, 4.31); _ = right(true, 4.4)
        precondition(right(false, 4.45) != .switchTarget)
        handler.reset()
        _ = right(true, 5, trigger: .rightOption); _ = right(false, 5.05, trigger: .rightOption)
        _ = right(true, 5.15, trigger: .rightOption)
        precondition(right(false, 5.2, trigger: .rightOption) == .switchTarget)
        handler.reset()
        _ = right(true, 6); handler.reset()
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
        print("PASS: 18 shortcut gesture assertions: double taps, hold, chords, focus reset, recording guard")
    }
}
