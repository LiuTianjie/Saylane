import AppKit

/// A short sound when the microphone starts and stops listening, so the eyes
/// can stay on the text. A recording with the start cue mixed over the first
/// words is recognised exactly as without it.
@MainActor
enum VoiceCue {
    case started, stopped

    private static let volume: Float = 0.3
    private static var sounds: [String: NSSound] = [:]

    func play() {
        let name = self == .started ? "Tink" : "Pop"
        let sound = Self.sounds[name] ?? NSSound(named: NSSound.Name(name))
        Self.sounds[name] = sound
        sound?.stop()
        sound?.volume = Self.volume
        sound?.play()
    }
}
