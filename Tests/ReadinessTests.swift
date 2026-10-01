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
        precondition(state.blocker == .inputMethodNotSelected)
        state = ReadinessReducer.reduce(state, .globalInvoke(available: true))
        precondition(state.blocker == .modelsMissing, "not selected is fine when the global tap can select us")
        state = ReadinessReducer.reduce(state, .modelsChecking(true))
        precondition(state.blocker == .modelsChecking)
        state = ReadinessReducer.reduce(state, .modelsChecking(false))
        state = ReadinessReducer.reduce(state, .speechModel(ready: true, detail: "ok"))
        precondition(state.blocker == .modelsMissing && state.models.speechDetail == "ok")
        state = ReadinessReducer.reduce(state, .translationModel(ready: true, detail: "ok"))
        precondition(state.isReady)
        precondition(state.requiredSetupComplete)
        // Preparing or downloading also blocks, and invalidation drops readiness.
        precondition(ReadinessReducer.reduce(state, .modelsDownloading(true)).blocker == .modelsChecking)
        precondition(ReadinessReducer.reduce(state, .modelsPreparing(true)).blocker == .modelsChecking)
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
