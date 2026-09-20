import Foundation

enum SetupFlow {
    static func isComplete(installationPathValid: Bool, inputMethodEnabled: Bool,
                           microphoneGranted: Bool) -> Bool {
        installationPathValid && inputMethodEnabled && microphoneGranted
    }
}
