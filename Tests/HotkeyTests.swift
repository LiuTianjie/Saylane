import AppKit
import Carbon.HIToolbox

@main struct HotkeyTests {
    static func main() {
        var keys = PushToTalkHandler()
        func event(_ type: NSEvent.EventType, _ code: Int64, _ flags: UInt64 = 0, active: Bool = false, repeatKey: Bool = false, trigger: PushToTalkHotkey = .rightOption) -> (PushToTalkHandler.Action, Bool) {
            keys.handle(type: type, keyCode: UInt16(code), flags: flags, repeatKey: repeatKey, trigger: trigger, active: active)
        }
        let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
        precondition(event(.flagsChanged, PushToTalkHotkey.leftOption.keyCode, option | 0x20).0 == .none)
        precondition(event(.flagsChanged, PushToTalkHotkey.rightOption.keyCode, option | 0x60).0 == .press)
        precondition(event(.flagsChanged, PushToTalkHotkey.rightOption.keyCode, option | 0x60).0 == .none)
        precondition(event(.flagsChanged, PushToTalkHotkey.rightOption.keyCode, option | 0x20, active: true).0 == .release)
        keys.reset()
        precondition(event(.keyDown, Int64(kVK_F8), trigger: .f8).0 == .press)
        precondition(event(.keyDown, Int64(kVK_F8), repeatKey: true, trigger: .f8).0 == .none)
        precondition(event(.keyUp, Int64(kVK_F8), option, active: true, trigger: .f8).0 == .release)
        precondition(event(.keyDown, Int64(kVK_Escape), active: true).0 == .cancel)
        precondition(event(.keyDown, Int64(kVK_Escape)).1 == false)
        precondition(event(.leftMouseDown, 0, active: true).0 == .cancel)
        precondition(event(.keyDown, Int64(kVK_ANSI_A), active: true).0 == .cancel)
        precondition(event(.keyDown, Int64(kVK_ANSI_A)).1 == false)
        keys.reset()
        precondition(event(.flagsChanged, PushToTalkHotkey.rightOption.keyCode, option).0 == .press)
        precondition(event(.flagsChanged, PushToTalkHotkey.rightOption.keyCode, 0, active: true).0 == .release)
        keys.reset()
        let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
        precondition(event(.flagsChanged, PushToTalkHotkey.rightCommand.keyCode, command, trigger: .rightCommand).0 == .press)
        precondition(event(.flagsChanged, PushToTalkHotkey.rightCommand.keyCode, 0, active: true, trigger: .rightCommand).0 == .release)
        keys.reset()
        precondition(event(.flagsChanged, PushToTalkHotkey.rightOption.keyCode, option).0 == .press)
        var tap = PushToTalkHandler()
        func tapEvent(_ type: NSEvent.EventType, _ code: Int64, _ flags: UInt64 = 0, active: Bool = false) -> (PushToTalkHandler.Action, Bool) {
            tap.handle(type: type, keyCode: UInt16(code), flags: flags, repeatKey: false, trigger: .rightOption, active: active, tapToTalk: true)
        }
        precondition(tapEvent(.flagsChanged, PushToTalkHotkey.rightOption.keyCode, option).0 == .press)
        precondition(tapEvent(.flagsChanged, PushToTalkHotkey.rightOption.keyCode, 0, active: true).0 == .none)
        precondition(tapEvent(.keyDown, Int64(kVK_ANSI_A), active: true).0 == .release)
        print("PASS: 19 hotkey checks, including tap-to-talk")
    }
}
