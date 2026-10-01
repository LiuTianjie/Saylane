import AppKit
import Carbon.HIToolbox

@main struct ShortcutValidatorTests {
    static func main() {
        func shortcut(_ code: Int, _ flags: UInt64) -> ScreenCaptureShortcut {
            ScreenCaptureShortcut(keyCode: UInt16(code), modifierFlags: flags)
        }
        func rejected(_ s: ScreenCaptureShortcut) -> Bool {
            if case .rejected = ShortcutValidator.validate(s) { return true }
            return false
        }
        func warned(_ s: ScreenCaptureShortcut) -> Bool {
            if case .warning = ShortcutValidator.validate(s) { return true }
            return false
        }
        let cmd = ScreenModifier.command, opt = ScreenModifier.option, ctl = ScreenModifier.control, shift = ScreenModifier.shift

        precondition(ShortcutValidator.validate(.optionT) == .ok)
        precondition(rejected(shortcut(kVK_ANSI_T, 0)), "bare letter")
        precondition(rejected(shortcut(kVK_ANSI_T, shift)), "shift + letter alone")
        precondition(rejected(shortcut(kVK_Space, cmd)), "⌘Space reserved")
        precondition(rejected(shortcut(kVK_Tab, cmd)), "⌘Tab reserved")
        precondition(rejected(shortcut(kVK_ANSI_C, cmd)), "⌘C reserved")
        precondition(rejected(shortcut(kVK_ANSI_4, cmd | shift)), "system screenshot reserved")
        precondition(rejected(shortcut(kVK_ANSI_T, cmd | opt | ctl)), "more than three keys")
        precondition(rejected(shortcut(kVK_RightOption, 0)), "modifier alone")
        precondition(rejected(shortcut(kVK_ANSI_T, opt | shift)) == false)
        precondition(warned(shortcut(kVK_Space, cmd | opt | 0)) == false, "⌥⌘Space is reserved, not just warned")
        precondition(warned(shortcut(kVK_Space, opt)), "⌥Space warns")
        precondition(warned(shortcut(kVK_F8, 0)), "bare function key warns")
        precondition(ShortcutValidator.validate(shortcut(kVK_F8, cmd)) == .ok)
        if case .rejected = ShortcutValidator.validate(.optionT, conflicts: [(.optionT, "语音")]) {} else { fatalError("conflict must reject") }
        precondition(ShortcutValidator.isSubset(shortcut(kVK_ANSI_T, opt), of: shortcut(kVK_ANSI_T, opt | cmd)))
        precondition(!ShortcutValidator.isSubset(shortcut(kVK_ANSI_T, opt | cmd), of: shortcut(kVK_ANSI_T, opt)))
        precondition(ShortcutValidator.appleDictationConflict(for: .function) != nil)
        precondition(ShortcutValidator.appleDictationConflict(for: .rightOption) == nil)
        print("PASS: shortcut validator rules (modifier required, key count, reserved chords, warnings, subsets, dictation conflicts)")
    }
}
