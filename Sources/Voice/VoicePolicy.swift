import Foundation

/// Every timing constant of a voice session in one testable value.
struct VoicePolicy: Equatable, Sendable {
    /// Recognizer and target must be ready this long after the press.
    var prepareTimeout: TimeInterval = 20
    /// A single utterance is finalized after this long even if the key is still held.
    var maxUtterance: TimeInterval = 180
    /// The optional LLM proofread must answer within this long or the ordinary result commits.
    var polishTimeout: TimeInterval = 8
    /// Ordinary typing may wait this long for an authoritative recognizer tail.
    /// This is deliberately independent of the recognizer/model timeout.
    var userInputFence: TimeInterval = 0.45
    /// Audio captured from the press until the recognizer is ready is kept up to this long.
    var prerollLimit: TimeInterval = 3.0

    static let standard = VoicePolicy()
}
