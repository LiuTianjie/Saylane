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

/// Long-press left Command to start screen selection. A short press must
/// still be Command+C and other chords. Time is injected for tests.
struct ScreenHoldHandler {
    enum Action: Equatable { case none, armHold, begin, cancel, toggle }

    static let holdDelay: TimeInterval = 0.18

    private var holding = false
    private var pendingAt: TimeInterval?
    private var selecting = false
    private var pinVisible = false

    mutating func reset() {
        holding = false
        pendingAt = nil
        selecting = false
    }

    mutating func setPinVisible(_ visible: Bool) {
        pinVisible = visible
    }

    mutating func noteEndedSelection() {
        selecting = false
        pendingAt = nil
    }

    mutating func holdDeadline(now: TimeInterval) -> Action {
        guard let start = pendingAt, holding, now - start >= Self.holdDelay else { return .none }
        pendingAt = nil
        selecting = true
        return .begin
    }

    mutating func handle(
        type: NSEvent.EventType,
        keyCode: UInt16,
        flags: UInt64,
        now: TimeInterval
    ) -> Action {
        let trigger = PushToTalkHotkey.leftCommand
        let forbidden = NSEvent.ModifierFlags([.option, .control, .shift]).rawValue

        if type == .keyDown {
            if keyCode == UInt16(kVK_Escape), selecting {
                reset()
                return .cancel
            }
            if pendingAt != nil {
                pendingAt = nil
                holding = false
            }
            return .none
        }

        guard type == .flagsChanged, keyCode == UInt16(trigger.keyCode) else { return .none }

        let down: Bool
        if flags & (trigger.deviceMask | trigger.siblingMask) != 0 {
            down = flags & trigger.deviceMask != 0
        } else {
            down = flags & UInt64(trigger.nsModifierFlag.rawValue) != 0
        }

        if down {
            if flags & UInt64(forbidden) != 0 { return .none }
            if holding { return .none }
            holding = true
            pendingAt = now
            return .armHold
        }

        let startedAt = pendingAt
        holding = false
        pendingAt = nil
        if selecting {
            selecting = false
            return .cancel
        }
        if pinVisible, let startedAt, now - startedAt < Self.holdDelay {
            return .toggle
        }
        return .none
    }
}
