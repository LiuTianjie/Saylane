import Foundation

@main struct SetupFlowTests {
    static func main() {
        precondition(!SetupFlow.isComplete(installationPathValid: false, inputMethodEnabled: false, microphoneGranted: false))
        precondition(!SetupFlow.isComplete(installationPathValid: true, inputMethodEnabled: false, microphoneGranted: true))
        precondition(!SetupFlow.isComplete(installationPathValid: true, inputMethodEnabled: true, microphoneGranted: false))
        precondition(SetupFlow.isComplete(installationPathValid: true, inputMethodEnabled: true, microphoneGranted: true))
        // The guide: four items, asked for in order, finished only when all are on.
        var list = SetupChecklist(inputMethod: false, microphone: false, accessibility: false, screenRecording: false)
        precondition(list.next == .inputMethod && list.count == 0 && !list.isComplete)
        list = SetupChecklist(inputMethod: true, microphone: false, accessibility: true, screenRecording: false)
        precondition(list.next == .microphone && list.count == 2 && list.isDone(.accessibility) && !list.isDone(.screenRecording))
        list = SetupChecklist(inputMethod: true, microphone: true, accessibility: true, screenRecording: false)
        precondition(list.next == .screenRecording && !list.isComplete)
        precondition(SetupChecklist.complete.next == nil && SetupChecklist.complete.isComplete && SetupChecklist.complete.count == 4)
        print("PASS: setup is complete only when the input method is installed, enabled, and the microphone is allowed")
    }
}
