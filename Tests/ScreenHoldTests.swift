import AppKit
import Carbon.HIToolbox
import Foundation

@main struct ScreenHoldTests {
    static func main() {
        var handler = ScreenHoldHandler()
        let left = UInt16(kVK_Control)
        let right = UInt16(kVK_RightControl)
        let controlFlag = UInt64(NSEvent.ModifierFlags.control.rawValue)
        let leftMask = PushToTalkHotkey.leftControl.deviceMask
        let optionFlag = UInt64(NSEvent.ModifierFlags.option.rawValue)
        let shiftFlag = UInt64(NSEvent.ModifierFlags.shift.rawValue)
        let command = UInt16(kVK_Command)
        let commandMask = PushToTalkHotkey.leftCommand.deviceMask
        let delay = ScreenHoldHandler.holdDelay

        precondition(delay >= 0.4, "Hold must be slow enough to avoid Control chords")
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 1.0) == .armHold)
        precondition(handler.holdDeadline(now: 1.0 + delay - 0.05) == .none)
        precondition(handler.holdDeadline(now: 1.0 + delay) == .begin)

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 2.0) == .armHold)
        precondition(handler.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_C), flags: controlFlag | leftMask, now: 2.05) == .none)
        precondition(handler.holdDeadline(now: 2.0 + delay + 0.1) == .none, "Control+C must not start screen select")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 3.0) == .armHold)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 3.10) == .none)
        precondition(handler.holdDeadline(now: 3.0 + delay) == .none, "A short Control tap must not start screen select")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: right, flags: PushToTalkHotkey.rightControl.deviceMask, now: 4.0) == .none)
        precondition(handler.holdDeadline(now: 4.0 + delay) == .none, "Right Control is not the screen gesture")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: command, flags: commandMask, now: 4.5) == .none)
        precondition(handler.holdDeadline(now: 4.5 + delay) == .none, "Left Command is not the screen gesture")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask | optionFlag, now: 5.0) == .none)

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 5.5) == .armHold)
        precondition(
            handler.handle(
                type: .flagsChanged,
                keyCode: UInt16(kVK_Shift),
                flags: leftMask | shiftFlag,
                now: 5.6
            ) == .none
        )
        precondition(handler.holdDeadline(now: 5.5 + delay) == .none, "Control+Shift must not start screen select")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 6.0) == .armHold)
        precondition(handler.holdDeadline(now: 6.0 + delay) == .begin)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 6.0 + delay + 0.3) == .cancel, "Release Control while selecting cancels")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 7.0) == .armHold)
        precondition(handler.holdDeadline(now: 7.0 + delay) == .begin)
        handler.noteEndedSelection()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 7.0 + delay + 0.6) == .none, "After a finished selection, releasing Control keeps the pin")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 8.0) == .armHold)
        precondition(handler.holdDeadline(now: 8.0 + delay) == .begin)
        precondition(handler.handle(type: .keyDown, keyCode: UInt16(kVK_Escape), flags: leftMask, now: 8.0 + delay + 0.2) == .cancel)

        handler.reset()
        handler.setPinVisible(true)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 9.0) == .armHold)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 9.10) == .toggle, "A short left Control tap on the pin toggles original/translation")

        handler.reset()
        handler.setPinVisible(false)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 10.0) == .armHold)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 10.10) == .none, "A short Control tap does nothing when nothing is pinned")

        var tap = RightCommandDoubleTap()
        let rightMask = PushToTalkHotkey.rightCommand.deviceMask
        precondition(tap.handle(flags: rightMask, now: 20.0) == false)
        precondition(tap.handle(flags: 0, now: 20.10) == false)
        precondition(tap.handle(flags: rightMask, now: 20.25) == false)
        precondition(tap.handle(flags: 0, now: 20.32) == true, "Double-tap right Command switches direction")
        precondition(tap.handle(flags: rightMask, now: 21.0) == false)
        precondition(tap.handle(flags: 0, now: 21.10) == false)
        precondition(tap.handle(flags: rightMask, now: 22.0) == false)
        precondition(tap.handle(flags: 0, now: 22.10) == false, "A slow second tap is not a double tap")

        print("PASS: long-press left Control arms screen select; chords and short taps do not")
    }
}
