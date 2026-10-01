import Foundation
@main struct SetupReadinessTests {
    static func main() {
        func blocker(mic: Bool = true, unasked: Bool = false, enabled: Bool = true,
                     checking: Bool = false, speech: Bool = true, translation: Bool = true) -> SetupReadiness.Blocker? {
            SetupReadiness(microphoneGranted: mic, microphoneNeverRequested: unasked,
                inputMethodEnabled: enabled,
                checkingModels: checking, speechReady: speech, translationReady: translation).blocker
        }
        precondition(blocker() == nil)
        precondition(blocker(mic: false, unasked: true) == .microphoneNotRequested)
        precondition(blocker(mic: false) == .microphoneDenied)
        precondition(blocker(mic: false, checking: true) == .microphoneDenied)
        precondition(blocker(enabled: false) == .inputMethodNotEnabled)
        precondition(blocker(checking: true, speech: false) == .modelsChecking)
        precondition(blocker(checking: true) == nil, "a check, a load or a download in progress refuses nothing that is ready")
        precondition(blocker(speech: false) == .modelsMissing)
        precondition(blocker(translation: false) == .modelsMissing)
        print("PASS: setup blockers distinguish microphone consent, the input method being added, and model readiness")
    }
}
