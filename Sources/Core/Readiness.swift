import Foundation

/// Everything that decides whether a press can start a session, as one value
/// derived only by `ReadinessReducer`. Views read it; services send events.
struct Readiness: Equatable, Sendable {
    enum PermissionStatus: Equatable, Sendable { case granted, denied, notDetermined }

    struct Permissions: Equatable, Sendable {
        var microphone: PermissionStatus = .notDetermined
        var speechRecognition: PermissionStatus = .notDetermined
        var inputMonitoring = false
        var screenCapture = false
        var accessibility = false
    }

    struct InputSource: Equatable, Sendable {
        var installedLocation = false
        var installed = false
        var enabled = false
        var selected = false
    }

    struct Models: Equatable, Sendable {
        var checking = false
        var preparing = false
        var downloading = false
        var speechReady = false
        var translationReady = false
        var speechDetail = ""
        var translationDetail = ""
        var busy: Bool { checking || preparing || downloading }
    }

    var permissions = Permissions()
    var inputSource = InputSource()
    var models = Models()
    /// The global event tap (or its NSEvent fallback) is receiving key events.
    var globalInvokeAvailable = false

    var setup: SetupReadiness {
        SetupReadiness(microphoneGranted: permissions.microphone == .granted,
                       microphoneNeverRequested: permissions.microphone == .notDetermined,
                       inputMethodEnabled: inputSource.enabled,
                       inputMethodSelected: inputSource.selected,
                       checkingModels: models.busy,
                       speechReady: models.speechReady,
                       translationReady: models.translationReady,
                       globalInvokeAvailable: globalInvokeAvailable)
    }
    var blocker: SetupReadiness.Blocker? { setup.blocker }
    var isReady: Bool { blocker == nil }

    /// Required onboarding items are satisfied (permissions may still be pending for optional features).
    var requiredSetupComplete: Bool {
        SetupFlow.isComplete(installationPathValid: inputSource.installedLocation,
                             inputMethodEnabled: inputSource.enabled,
                             microphoneGranted: permissions.microphone == .granted)
    }
}

enum ReadinessEvent: Equatable, Sendable {
    case permissions(Readiness.Permissions)
    case inputSource(Readiness.InputSource)
    case globalInvoke(available: Bool)
    case modelsChecking(Bool)
    case modelsPreparing(Bool)
    case modelsDownloading(Bool)
    case speechModel(ready: Bool, detail: String)
    case translationModel(ready: Bool, detail: String)
    /// A settings change invalidates model readiness until re-checked.
    case modelsInvalidated
}

/// Pure. Given the current readiness and one event, produce the next readiness.
enum ReadinessReducer {
    static func reduce(_ state: Readiness, _ event: ReadinessEvent) -> Readiness {
        var next = state
        switch event {
        case .permissions(let permissions): next.permissions = permissions
        case .inputSource(let source): next.inputSource = source
        case .globalInvoke(let available): next.globalInvokeAvailable = available
        case .modelsChecking(let checking): next.models.checking = checking
        case .modelsPreparing(let preparing): next.models.preparing = preparing
        case .modelsDownloading(let downloading): next.models.downloading = downloading
        case .speechModel(let ready, let detail):
            next.models.speechReady = ready
            next.models.speechDetail = detail
        case .translationModel(let ready, let detail):
            next.models.translationReady = ready
            next.models.translationDetail = detail
        case .modelsInvalidated:
            next.models.speechReady = false
            next.models.translationReady = false
            next.models.checking = true
        }
        return next
    }

    /// Which blocker changes matter enough to tell the user about, and where to send them.
    static func destination(for blocker: SetupReadiness.Blocker) -> UserNotice.Destination {
        switch blocker {
        case .modelsMissing, .modelsChecking: return .models
        case .microphoneNotRequested, .microphoneDenied, .inputMethodNotEnabled, .inputMethodNotSelected: return .permissions
        }
    }
}
