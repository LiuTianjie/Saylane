import AppKit
import Carbon.HIToolbox

struct PinyinKeyEvent {
    var type: NSEvent.EventType
    var keyCode: UInt16
    var characters: String
    var letter: Character?
    var flags: NSEvent.ModifierFlags
    var isRepeat: Bool
    /// System uptime of the event, as `NSEvent.timestamp`.
    var timestamp: TimeInterval

    init(type: NSEvent.EventType, keyCode: UInt16, characters: String, letter: Character?,
         flags: NSEvent.ModifierFlags, isRepeat: Bool, timestamp: TimeInterval = 0) {
        self.type = type; self.keyCode = keyCode; self.characters = characters
        self.letter = letter; self.flags = flags; self.isRepeat = isRepeat; self.timestamp = timestamp
    }

    init(_ event: NSEvent) {
        type = event.type
        keyCode = event.keyCode
        timestamp = event.timestamp
        // Character/repeat accessors are only valid for keyboard events, not
        // flagsChanged. Modifiers still go to Rime's Shift/Caps Lock handling.
        characters = event.type == .keyDown ? (event.characters ?? "") : ""
        flags = event.modifierFlags
        isRepeat = event.type == .keyDown && event.isARepeat
        if event.type == .keyDown, let raw = event.charactersIgnoringModifiers?.lowercased(), raw.count == 1,
           let character = raw.first, character.isASCII, character.isLetter {
            letter = character
        } else {
            letter = nil
        }
    }

    /// Text that may wait briefly behind an authoritative voice final result.
    /// Commands must stay on the original IMK stack so the foreground app can
    /// interpret them; an input method cannot faithfully recreate Return,
    /// navigation, deletion or application shortcuts with `insertText`.
    var canDeferForVoiceFinalization: Bool {
        guard type == .keyDown, !characters.isEmpty,
              flags.intersection([.command, .control, .option, .function]).isEmpty else { return false }
        switch Int(keyCode) {
        case kVK_Escape, kVK_Delete, kVK_ForwardDelete,
             kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help:
            return false
        default:
            return characters.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !(0xF700...0xF8FF).contains(Int($0.value))
            }
        }
    }
}
