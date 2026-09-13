import AppKit
import Carbon.HIToolbox
import Foundation

@main struct ScreenHoldTests {
    static func main() {
        var handler = ScreenHoldHandler()
        let left = UInt16(kVK_Command)
        let right = UInt16(kVK_RightCommand)
        let commandFlag = UInt64(NSEvent.ModifierFlags.command.rawValue)
        let leftMask = PushToTalkHotkey.leftCommand.deviceMask
        let optionFlag = UInt64(NSEvent.ModifierFlags.option.rawValue)

        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 1.0) == .armHold)
        precondition(handler.holdDeadline(now: 1.10) == .none)
        precondition(handler.holdDeadline(now: 1.20) == .begin)

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 2.0) == .armHold)
        precondition(handler.handle(type: .keyDown, keyCode: UInt16(kVK_ANSI_C), flags: commandFlag | leftMask, now: 2.05) == .none)
        precondition(handler.holdDeadline(now: 2.30) == .none, "Command+C must not start screen select")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 3.0) == .armHold)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 3.10) == .none)
        precondition(handler.holdDeadline(now: 3.30) == .none, "A short Command tap must not start screen select")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: right, flags: PushToTalkHotkey.rightCommand.deviceMask, now: 4.0) == .none)
        precondition(handler.holdDeadline(now: 4.30) == .none, "Right Command is not the screen gesture")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask | optionFlag, now: 5.0) == .none)

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 6.0) == .armHold)
        precondition(handler.holdDeadline(now: 6.20) == .begin)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 6.50) == .cancel, "Release Command while selecting cancels")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 7.0) == .armHold)
        precondition(handler.holdDeadline(now: 7.20) == .begin)
        handler.noteEndedSelection()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 7.80) == .none, "After a finished selection, releasing Command keeps the pin")

        handler.reset()
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 8.0) == .armHold)
        precondition(handler.holdDeadline(now: 8.20) == .begin)
        precondition(handler.handle(type: .keyDown, keyCode: UInt16(kVK_Escape), flags: leftMask, now: 8.40) == .cancel)

        handler.reset()
        handler.setPinVisible(true)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 9.0) == .armHold)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 9.10) == .toggle, "A short left Command tap on the pin toggles original/translation")

        handler.reset()
        handler.setPinVisible(false)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: leftMask, now: 10.0) == .armHold)
        precondition(handler.handle(type: .flagsChanged, keyCode: left, flags: 0, now: 10.10) == .none, "A short Command tap does nothing when nothing is pinned")

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

        print("PASS: long-press left Command arms screen select; chords and short taps do not")
    }
}
