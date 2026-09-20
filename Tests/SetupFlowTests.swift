import Foundation

@main struct SetupFlowTests {
    static func main() {
        precondition(!SetupFlow.isComplete(installationPathValid: false, inputMethodEnabled: false, microphoneGranted: false))
        precondition(!SetupFlow.isComplete(installationPathValid: true, inputMethodEnabled: false, microphoneGranted: true))
        precondition(!SetupFlow.isComplete(installationPathValid: true, inputMethodEnabled: true, microphoneGranted: false))
        precondition(SetupFlow.isComplete(installationPathValid: true, inputMethodEnabled: true, microphoneGranted: true))
        print("PASS: setup is complete only when the input method is installed, enabled, and the microphone is allowed")
    }
}
