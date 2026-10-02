import AppKit

/// A short sound when the microphone starts and stops listening, so the eyes
/// can stay on the text. A recording with the start cue mixed over the first
/// words is recognised exactly as without it.
@MainActor
enum VoiceCue {
    case started, stopped

    /// How long the sound is loud enough for the microphone to take it for a voice (the file rings for 0.56 s).
    var audible: TimeInterval { self == .started ? 0.45 : 0.6 }

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
