import AppKit

/// System state the voice feature reads. Keeping it together lets tests run the
/// real session orchestration without a window server.
@MainActor
struct VoiceInputEnvironment {
    var frontmostBundleID: () -> String?
    var frontmostPID: () -> pid_t?
    var trace: (String, String) -> Void

    static var system: Self {
        Self(frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
             frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
             trace: { InputDiagnostics.record($0, $1) })
    }
}
