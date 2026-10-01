import AppKit
import Carbon.HIToolbox
import Foundation

@main struct RightCommandDoubleTapTests {
    static func main() {
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

        print("PASS: double-tap right Command; a slow second tap is not one")
    }
}
