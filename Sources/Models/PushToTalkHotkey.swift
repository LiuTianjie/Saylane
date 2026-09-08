import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum PushToTalkHotkey: String, CaseIterable, Identifiable, Hashable {
    case rightOption, leftOption
    case rightShift, leftShift
    case rightCommand, leftCommand
    case rightControl, leftControl
    case function
    case f8, f9, f13, f16, f17, f18, f19, f20

    var id: String { rawValue }

    static var modifiers: [PushToTalkHotkey] {
        [.rightOption, .leftOption, .rightCommand, .leftCommand, .rightControl, .leftControl, .rightShift, .leftShift, .function]
    }

    static var functionKeys: [PushToTalkHotkey] {
        [.f8, .f9, .f13, .f16, .f17, .f18, .f19, .f20]
    }

    var isModifier: Bool {
        switch self {
        case .f8, .f9, .f13, .f16, .f17, .f18, .f19, .f20: return false
        default: return true
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: return "右 Option（⌥）"
        case .leftOption: return "左 Option（⌥）"
        case .rightShift: return "右 Shift（⇧）"
        case .leftShift: return "左 Shift（⇧）"
        case .rightCommand: return "右 Command（⌘）"
        case .leftCommand: return "左 Command（⌘）"
        case .rightControl: return "右 Control（⌃）"
        case .leftControl: return "左 Control（⌃）"
        case .function: return "fn"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f13: return "F13"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        }
    }

    var shortLabel: String {
        switch self {
        case .rightOption: return "右⌥"
        case .leftOption: return "左⌥"
        case .rightShift: return "右⇧"
        case .leftShift: return "左⇧"
        case .rightCommand: return "右⌘"
        case .leftCommand: return "左⌘"
        case .rightControl: return "右⌃"
        case .leftControl: return "左⌃"
        case .function: return "fn"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f13: return "F13"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        }
    }

    var keycap: String {
        switch self {
        case .rightOption, .leftOption: return "⌥"
        case .rightShift, .leftShift: return "⇧"
        case .rightCommand, .leftCommand: return "⌘"
        case .rightControl, .leftControl: return "⌃"
        case .function: return "fn"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f13: return "F13"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .rightOption: return Int64(kVK_RightOption)
        case .leftOption: return Int64(kVK_Option)
        case .rightShift: return Int64(kVK_RightShift)
        case .leftShift: return Int64(kVK_Shift)
        case .rightCommand: return Int64(kVK_RightCommand)
        case .leftCommand: return Int64(kVK_Command)
        case .rightControl: return Int64(kVK_RightControl)
        case .leftControl: return Int64(kVK_Control)
        case .function: return Int64(kVK_Function)
        case .f8: return Int64(kVK_F8)
        case .f9: return Int64(kVK_F9)
        case .f13: return Int64(kVK_F13)
        case .f16: return Int64(kVK_F16)
        case .f17: return Int64(kVK_F17)
        case .f18: return Int64(kVK_F18)
        case .f19: return Int64(kVK_F19)
        case .f20: return Int64(kVK_F20)
        }
    }

    var deviceMask: UInt64 {
        switch self {
        case .leftControl: return 0x0000_0001
        case .leftShift: return 0x0000_0002
        case .rightShift: return 0x0000_0004
        case .leftCommand: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .leftOption: return 0x0000_0020
        case .rightOption: return 0x0000_0040
        case .rightControl: return 0x0000_2000
        default: return 0
        }
    }

    var siblingMask: UInt64 {
        switch self {
        case .leftControl: return 0x0000_2000
        case .rightControl: return 0x0000_0001
        case .leftShift: return 0x0000_0004
        case .rightShift: return 0x0000_0002
        case .leftCommand: return 0x0000_0010
        case .rightCommand: return 0x0000_0008
        case .leftOption: return 0x0000_0040
        case .rightOption: return 0x0000_0020
        default: return 0
        }
    }

    var modifierFlag: CGEventFlags? {
        switch self {
        case .rightOption, .leftOption: return .maskAlternate
        case .rightShift, .leftShift: return .maskShift
        case .rightCommand, .leftCommand: return .maskCommand
        case .rightControl, .leftControl: return .maskControl
        case .function: return .maskSecondaryFn
        default: return nil
        }
    }
}


extension PushToTalkHotkey {
    var nsModifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption: return .option
        case .rightShift, .leftShift: return .shift
        case .rightCommand, .leftCommand: return .command
        case .rightControl, .leftControl: return .control
        case .function: return .function
        default: return []
        }
    }
}
