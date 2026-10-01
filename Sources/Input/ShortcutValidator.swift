import AppKit
import Carbon.HIToolbox

/// Binding rules shared by every recorder in the app (modelled on Wispr Flow's
/// published hotkey policy): a chord needs a modifier unless it is a function
/// key, at most three keys, no system-reserved combinations, and a warning for
/// combinations that commonly collide with other apps.
enum ShortcutValidator {
    enum Verdict: Equatable {
        case ok
        case warning(String)
        case rejected(String)
    }

    private static let command = ScreenModifier.command
    private static let option = ScreenModifier.option
    private static let control = ScreenModifier.control
    private static let shift = ScreenModifier.shift

    /// Combinations macOS or every app relies on. Recording them is refused.
    private static let reserved: [(UInt16, UInt64, String)] = [
        (UInt16(kVK_Space), command, "⌘空格（聚焦搜索）"),
        (UInt16(kVK_Space), command | option, "⌥⌘空格（Finder 搜索）"),
        (UInt16(kVK_Space), control, "⌃空格（切换输入法）"),
        (UInt16(kVK_Space), control | option, "⌃⌥空格（切换输入法）"),
        (UInt16(kVK_Tab), command, "⌘Tab（切换应用）"),
        (UInt16(kVK_Delete), command, "⌘⌫"),
        (UInt16(kVK_ANSI_F), command | control, "⌃⌘F（全屏）"),
        (UInt16(kVK_ANSI_Q), command, "⌘Q（退出）"),
        (UInt16(kVK_ANSI_W), command, "⌘W（关闭窗口）"),
        (UInt16(kVK_ANSI_H), command, "⌘H（隐藏）"),
        (UInt16(kVK_ANSI_M), command, "⌘M（最小化）"),
        (UInt16(kVK_ANSI_C), command, "⌘C（复制）"),
        (UInt16(kVK_ANSI_V), command, "⌘V（粘贴）"),
        (UInt16(kVK_ANSI_X), command, "⌘X（剪切）"),
        (UInt16(kVK_ANSI_Z), command, "⌘Z（撤销）"),
        (UInt16(kVK_ANSI_A), command, "⌘A（全选）"),
        (UInt16(kVK_ANSI_S), command, "⌘S（保存）"),
        (UInt16(kVK_ANSI_Comma), command, "⌘,（设置）"),
        (UInt16(kVK_ANSI_3), command | shift, "⇧⌘3（系统截屏）"),
        (UInt16(kVK_ANSI_4), command | shift, "⇧⌘4（系统截屏）"),
        (UInt16(kVK_ANSI_5), command | shift, "⇧⌘5（系统截屏）"),
        (UInt16(kVK_Escape), command | option, "⌥⌘Esc（强制退出）"),
        (UInt16(kVK_ANSI_Period), command, "⌘.（取消）")
    ]

    static func validate(_ shortcut: ScreenCaptureShortcut,
                         conflicts: [(ScreenCaptureShortcut, String)] = []) -> Verdict {
        let flags = shortcut.normalizedFlags
        if GestureArbiter.isModifierKey(shortcut.keyCode) {
            return .rejected(String(localized: "快捷键需要一个字母、数字或功能键作为主键。"))
        }
        if !shortcut.isFunctionKey, flags == 0 {
            return .rejected(String(localized: "单独的字母、数字或标点不能作为快捷键，请加上 ⌘、⌥、⌃ 或 ⇧。"))
        }
        if flags.nonzeroBitCount > 2 {
            return .rejected(String(localized: "最多使用三个键（两个修饰键加一个主键）。"))
        }
        if !shortcut.isFunctionKey, flags == shift {
            return .rejected(String(localized: "只按 ⇧ 加字母会在输入时误触，请再加一个修饰键。"))
        }
        if let hit = reserved.first(where: { $0.0 == shortcut.keyCode && $0.1 == flags }) {
            return .rejected(String(localized: "\(hit.2) 是系统保留组合，不能绑定。"))
        }
        if let conflict = conflicts.first(where: { $0.0 == shortcut }) {
            return .rejected(String(localized: "已被「\(conflict.1)」使用。"))
        }
        if [UInt16(kVK_Space), UInt16(kVK_Escape), UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow),
            UInt16(kVK_UpArrow), UInt16(kVK_DownArrow), UInt16(kVK_Return)].contains(shortcut.keyCode),
           flags & (command | option) != 0 {
            return .warning(String(localized: "这个组合常被其他应用占用，可能在部分应用里失效。"))
        }
        if shortcut.isFunctionKey, flags == 0 {
            return .warning(String(localized: "单独的功能键在系统设置里可能被映射为亮度、音量等功能。"))
        }
        return .ok
    }

    /// Wispr Flow's rule for a second, hands-free style shortcut: it may not be a
    /// subset of the primary chord, or pressing it would fire the primary first.
    static func isSubset(_ candidate: ScreenCaptureShortcut, of primary: ScreenCaptureShortcut) -> Bool {
        candidate.keyCode == primary.keyCode && candidate.normalizedFlags & ~primary.normalizedFlags == 0
            && candidate.normalizedFlags != primary.normalizedFlags
    }

    /// Apple Dictation's default trigger overlaps with a few of Saylane's presets.
    static func appleDictationConflict(for trigger: PushToTalkHotkey) -> String? {
        switch trigger {
        case .function:
            return String(localized: "Apple 听写默认“连按两次 fn”。若同时开启，请在系统设置 → 键盘 → 听写里改掉它，或让 Saylane 使用其他键。")
        case .leftControl, .rightControl:
            return String(localized: "外接键盘上 Apple 听写默认“连按两次 ⌃”。若同时开启，请在系统设置 → 键盘 → 听写里改掉它。")
        default:
            return nil
        }
    }
}
