import Foundation

@main struct ReadinessTests {
    static func main() {
        var state = Readiness()
        precondition(state.blocker == .microphoneNotRequested)
        state = ReadinessReducer.reduce(state, .permissions(Readiness.Permissions(microphone: .denied)))
        precondition(state.blocker == .microphoneDenied)
        state = ReadinessReducer.reduce(state, .permissions(Readiness.Permissions(microphone: .granted)))
        precondition(state.blocker == .inputMethodNotEnabled)
        state = ReadinessReducer.reduce(state, .inputSource(Readiness.InputSource(installedLocation: true, installed: true, enabled: true, selected: false)))
        precondition(state.blocker == .modelsMissing, "another input method being the current one blocks nothing")
        state = ReadinessReducer.reduce(state, .globalInvoke(available: true))
        precondition(state.blocker == .modelsMissing && state.globalInvokeAvailable)
        state = ReadinessReducer.reduce(state, .modelsChecking(true))
        precondition(state.blocker == .modelsChecking)
        state = ReadinessReducer.reduce(state, .modelsChecking(false))
        state = ReadinessReducer.reduce(state, .speechModel(ready: true, detail: "ok"))
        precondition(state.blocker == .modelsMissing && state.models.speechDetail == "ok")
        state = ReadinessReducer.reduce(state, .translationModel(ready: true, detail: "ok"))
        precondition(state.isReady)
        precondition(state.requiredSetupComplete)
        // The guide's list: the input method counts when it is current, or when the talk key does not need it to be.
        precondition(state.checklist.isDone(.inputMethod) && state.checklist.isDone(.microphone), "global keys are available")
        precondition(!state.checklist.isDone(.accessibility) && state.checklist.next == .accessibility)
        var noGlobal = state
        noGlobal.globalInvokeAvailable = false
        precondition(!noGlobal.checklist.isDone(.inputMethod), "another input method is current and the talk key cannot arrive")
        var all = state
        all.permissions.accessibility = true
        all.permissions.screenCapture = true
        precondition(all.checklist.isComplete)
        // Preparing or downloading something else blocks nothing that is ready; invalidation drops readiness.
        precondition(ReadinessReducer.reduce(state, .modelsDownloading(true)).isReady)
        precondition(ReadinessReducer.reduce(state, .modelsPreparing(true)).isReady)
        let invalidated = ReadinessReducer.reduce(state, .modelsInvalidated)
        precondition(invalidated.blocker == .modelsChecking && !invalidated.models.speechReady)
        // Destinations route the user to the right page.
        precondition(ReadinessReducer.destination(for: .modelsMissing) == .models)
        precondition(ReadinessReducer.destination(for: .microphoneDenied) == .permissions)
        // Notices carry presentation policy.
        precondition(UserNotice.transient("x").hudDuration > 0 && UserNotice.diagnostic("x").hudDuration == 0)
        precondition(UserNotice.actionable("x", .models).destination == .models)
        print("PASS: readiness reducer covers every blocker transition, invalidation and notice routing")
    }
}
