import AppKit
import Carbon.HIToolbox

struct PinyinKeyEvent {
    var type: NSEvent.EventType
    var keyCode: UInt16
    var characters: String
    var letter: Character?
    var flags: NSEvent.ModifierFlags
    var isRepeat: Bool

    init(type: NSEvent.EventType, keyCode: UInt16, characters: String, letter: Character?,
         flags: NSEvent.ModifierFlags, isRepeat: Bool) {
        self.type = type; self.keyCode = keyCode; self.characters = characters
        self.letter = letter; self.flags = flags; self.isRepeat = isRepeat
    }

    init(_ event: NSEvent) {
        type = event.type
        keyCode = event.keyCode
        characters = event.characters ?? ""
        flags = event.modifierFlags
        isRepeat = event.isARepeat
        if let raw = event.charactersIgnoringModifiers?.lowercased(), raw.count == 1,
           let character = raw.first, character.isASCII, character.isLetter {
            letter = character
        } else {
            letter = nil
        }
    }
}

