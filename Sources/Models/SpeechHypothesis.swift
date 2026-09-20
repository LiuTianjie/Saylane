import Foundation

/// Provider-owned stability, not a frontend guess based on repeated words.
/// Local batch decoders report the entire hypothesis as volatile. Neither part
/// is committed to the client until the input session finishes.
struct SpeechHypothesis: Equatable, Sendable {
    var stableText: String
    var volatileText: String

    init(stableText: String = "", volatileText: String = "") {
        self.stableText = stableText
        self.volatileText = volatileText
    }

    var text: String { stableText + volatileText }
}
