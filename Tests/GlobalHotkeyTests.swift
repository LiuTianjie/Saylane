import AppKit
import Carbon.HIToolbox

@main struct GlobalHotkeyTests {
    static func main() {
        let option = UInt16(PushToTalkHotkey.rightOption.keyCode)
        let letterA = UInt16(kVK_ANSI_A)
        var router = GlobalHotkeyRouter()

        // Doubao Combined handler: the tap always owns the voice key.
        precondition(router.shouldInterpret(isOursSelected: true, keyCode: option, triggerKeyCode: option) == true)
        precondition(router.shouldInterpret(isOursSelected: false, keyCode: option, triggerKeyCode: option) == true)
        precondition(router.shouldInterpret(isOursSelected: false, keyCode: letterA, triggerKeyCode: option) == false)
        precondition(router.shouldInterpret(isOursSelected: true, keyCode: letterA, triggerKeyCode: option) == false)

        router.note(.press)
        precondition(router.owningGesture)
        // After we switch to ourselves mid-hold, the tap still owns the gesture.
        precondition(router.shouldInterpret(isOursSelected: true, keyCode: option, triggerKeyCode: option) == true)
        precondition(router.shouldInterpret(isOursSelected: true, keyCode: letterA, triggerKeyCode: option) == true)

        router.note(.release)
        precondition(router.owningGesture == false)
        precondition(router.shouldInterpret(isOursSelected: true, keyCode: letterA, triggerKeyCode: option) == false)
        precondition(router.shouldInterpret(isOursSelected: true, keyCode: option, triggerKeyCode: option) == true)

        router.note(.armHold)
        precondition(router.owningGesture)
        router.note(.none)
        precondition(router.owningGesture)
        router.note(.cancel)
        precondition(router.owningGesture == false)

        router.note(.press)
        router.reset()
        precondition(router.owningGesture == false)
        precondition(router.shouldInterpret(isOursSelected: false, keyCode: letterA, triggerKeyCode: option) == false)

        print("PASS: 14 global hotkey routing checks, including combined-handler wake")
    }
}
