import AppKit
import Carbon.HIToolbox

/// Double-tap right Command from modifier bits, not key codes.
/// flagsChanged often reports the left Command key code for both keys.
struct RightCommandDoubleTap {
    static let maxDown: TimeInterval = 0.22
    static let gap: TimeInterval = 0.36

    private var down = false
    private var downAt: TimeInterval?
    private var firstUpAt: TimeInterval?

    mutating func reset() {
        down = false
        downAt = nil
        firstUpAt = nil
    }

    mutating func handle(flags: UInt64, now: TimeInterval) -> Bool {
        let mask = PushToTalkHotkey.rightCommand.deviceMask
        let isDown = flags & mask != 0
        if isDown == down { return false }
        down = isDown
        let extras = NSEvent.ModifierFlags([.option, .control, .shift]).rawValue
        if flags & UInt64(extras) != 0 {
            downAt = nil
            firstUpAt = nil
            return false
        }
        if isDown {
            downAt = now
            return false
        }
        guard let start = downAt, now - start < Self.maxDown else {
            firstUpAt = nil
            downAt = nil
            return false
        }
        downAt = nil
        if let previous = firstUpAt, now - previous <= Self.gap {
            firstUpAt = nil
            return true
        }
        firstUpAt = now
        return false
    }
}
