import AppKit

/// System operations used by voice wake-up. Keeping them together lets tests
/// exercise real session orchestration without changing the user's input source.
@MainActor
struct VoiceInputEnvironment {
    var ownBundleID: String
    var ownInputSourceID: String
    var frontmostBundleID: () -> String?
    var frontmostPID: () -> pid_t?
    var currentInputSource: () -> String?
    var inputSourceEnabled: () -> Bool
    var inputSourceSelected: () -> Bool
    var selectOwnInputSource: () -> Bool
    var selectInputSource: (String) -> Bool
    var asciiInputSourceID: () -> String?
    var selectASCIILayout: () -> Bool
    var trace: (String, String) -> Void
    var monotonicTime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    static var system: Self {
        Self(ownBundleID: InputSourceInstall.bundleID,
             ownInputSourceID: InputSourceInstall.modeID,
             frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
             frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
             currentInputSource: { InputSourceInstall.currentID },
             inputSourceEnabled: { InputSourceInstall.isEnabled },
             inputSourceSelected: { InputSourceInstall.isSelected },
             selectOwnInputSource: { InputSourceInstall.selectEnabledMode() },
             selectInputSource: { InputSourceInstall.select(inputSourceID: $0) },
             asciiInputSourceID: { InputSourceInstall.asciiLayoutID },
             selectASCIILayout: { InputSourceInstall.selectASCIILayout() },
             trace: { InputDiagnostics.record($0, $1) },
             monotonicTime: { ProcessInfo.processInfo.systemUptime })
    }
}
