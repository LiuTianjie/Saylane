import Carbon

/// The one question the input method asks about input sources: is ours the
/// selected one right now? Registration and enabling belong to the main program.
enum CurrentInputSource {
    static let modeID = "com.rtranslate.inputmethod.rtranslate.voice"

    static var isSaylane: Bool {
        // A test home has no input source of its own.
        if TestHome.isActive { return true }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) else { return false }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String == modeID
    }
}
