import Foundation

/// Doubao `ASRShortcutHandler(Combined)` + `ASRShortcutHandler(Monitor)`:
/// the session tap always owns the voice shortcut, whether or not we are the
/// selected input source. IMK then only does pinyin. After a press we keep the
/// rest of that gesture so a mid-hold TIS switch cannot start a second session.
struct GlobalHotkeyRouter: Equatable {
    private(set) var owningGesture = false

    func shouldInterpret(isOursSelected: Bool, keyCode: UInt16, triggerKeyCode: UInt16) -> Bool {
        if owningGesture { return true }
        return keyCode == triggerKeyCode
    }

    mutating func note(_ action: InputShortcutHandler.Action) {
        switch action {
        case .press, .armHold:
            owningGesture = true
        case .release, .cancel:
            owningGesture = false
        case .switchTarget, .none:
            break
        }
    }

    mutating func reset() {
        owningGesture = false
    }
}
