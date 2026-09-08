import AppKit
import Carbon.HIToolbox

/// Pure event interpretation shared by IME and tests; no event taps or global monitors.
struct PushToTalkHandler {
    enum Action: Equatable { case press, release, cancel, none }
    private(set) var holding = false
    mutating func reset() { holding = false }
    mutating func handle(type: NSEvent.EventType, keyCode: UInt16, flags: UInt64,
                         repeatKey: Bool, trigger: PushToTalkHotkey, active: Bool,
                         tapToTalk: Bool = false) -> (Action, Bool) {
        if type == .keyDown && keyCode == UInt16(kVK_Escape) && active {
            holding = false
            return (.cancel, true)
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            holding = false
            if active { return (tapToTalk ? .release : .cancel, false) }
            return (.none, false)
        }
        guard keyCode == UInt16(trigger.keyCode) else {
            // Doubao single-click: any other key ends the utterance.
            if active && type == .keyDown {
                holding = false
                return (tapToTalk ? .release : .cancel, false)
            }
            return (.none, false)
        }
        let down: Bool
        if trigger.isModifier {
            guard type == .flagsChanged else { return (.none, false) }
            if trigger.deviceMask != 0 && flags & (trigger.deviceMask | trigger.siblingMask) != 0 {
                down = flags & trigger.deviceMask != 0
            } else {
                down = flags & UInt64(trigger.nsModifierFlag.rawValue) != 0
            }
        } else {
            guard type == .keyDown || type == .keyUp else { return (.none, false) }
            if type == .keyUp {
                if tapToTalk {
                    holding = false
                    return (.none, true)
                }
                if holding { holding = false; return (.release, true) }
                return (.none, false)
            }
            let extras = NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue
            guard flags & UInt64(extras) == 0 else { return (.none, false) }
            down = type == .keyDown
            if repeatKey { return (.none, holding || active) }
        }
        if down {
            if tapToTalk && active {
                holding = false
                return (.release, true)
            }
            guard !holding else { return (.none, true) }
            holding = true
            return (.press, true)
        }
        if tapToTalk {
            holding = false
            return (.none, true)
        }
        guard holding else { return (.none, false) }
        holding = false
        return (.release, true)
    }
}
