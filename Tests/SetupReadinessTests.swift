import Foundation
@main struct SetupReadinessTests {
    static func main() {
        func blocker(mic: Bool = true, unasked: Bool = false, enabled: Bool = true, selected: Bool = true,
                     checking: Bool = false, speech: Bool = true, translation: Bool = true,
                     global: Bool = false) -> SetupReadiness.Blocker? {
            SetupReadiness(microphoneGranted: mic, microphoneNeverRequested: unasked,
                inputMethodEnabled: enabled, inputMethodSelected: selected,
                checkingModels: checking, speechReady: speech, translationReady: translation,
                globalInvokeAvailable: global).blocker
        }
        precondition(blocker() == nil)
        precondition(blocker(mic: false, unasked: true) == .microphoneNotRequested)
        precondition(blocker(mic: false) == .microphoneDenied)
        precondition(blocker(mic: false, selected: false, checking: true) == .microphoneDenied)
        precondition(blocker(enabled: false) == .inputMethodNotEnabled)
        precondition(blocker(selected: false) == .inputMethodNotSelected)
        precondition(blocker(selected: false, global: true) == nil)
        precondition(blocker(checking: true, speech: false) == .modelsChecking)
        precondition(blocker(speech: false) == .modelsMissing)
        precondition(blocker(translation: false) == .modelsMissing)
        print("PASS: setup blockers distinguish microphone consent, input-source selection, global invoke and model readiness")
    }
}
