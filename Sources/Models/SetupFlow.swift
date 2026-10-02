import Foundation

enum SetupFlow {
    static func isComplete(installationPathValid: Bool, inputMethodEnabled: Bool,
                           microphoneGranted: Bool) -> Bool {
        installationPathValid && inputMethodEnabled && microphoneGranted
    }
}

/// What Saylane needs from the Mac, in the order the guide asks for it. All
/// four are settled on the first run, so that nothing is asked for later in
/// the middle of a sentence or a capture.
enum SetupStep: Int, CaseIterable, Sendable {
    /// In the list of input sources and usable: typing, and writing dictated text.
    case inputMethod
    case microphone
    /// The talk key in every application and under every input method; text written at the caret.
    case accessibility
    /// Screen translation.
    case screenRecording
}

struct SetupChecklist: Equatable, Sendable {
    var done: Set<SetupStep>

    init(inputMethod: Bool, microphone: Bool, accessibility: Bool, screenRecording: Bool) {
        var done = Set<SetupStep>()
        if inputMethod { done.insert(.inputMethod) }
        if microphone { done.insert(.microphone) }
        if accessibility { done.insert(.accessibility) }
        if screenRecording { done.insert(.screenRecording) }
        self.done = done
    }

    static let complete = SetupChecklist(inputMethod: true, microphone: true, accessibility: true, screenRecording: true)

    func isDone(_ step: SetupStep) -> Bool { done.contains(step) }
    /// The first step that is still open: the one the guide's button settles next.
    var next: SetupStep? { SetupStep.allCases.first { !done.contains($0) } }
    var isComplete: Bool { next == nil }
    var count: Int { done.count }
}
