import AppKit
import Carbon.HIToolbox

@main struct InputEventRouterTests {
    @MainActor static func settle(_ milliseconds: Int = 20) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    @MainActor static func main() async {
        let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
        let rightOption = UInt16(kVK_RightOption)
        var clock: TimeInterval = 100
        let router = InputEventRouter(now: { clock })
        router.updateContext { $0.trigger = .rightOption }
        var actions: [InputAction] = []
        var capabilities: [String] = []
        router.onAction = { actions.append($0) }
        router.onGlobalCapabilityChanged = { capabilities.append("\($0)-\($1)") }

        func event(_ source: InputEvent.Source, flags: UInt64, at time: TimeInterval) -> InputEvent {
            InputEvent(source: source, type: .flagsChanged, keyCode: rightOption, flags: flags, isRepeat: false, timestamp: time)
        }

        // One physical hold delivered by IMK alone: nothing on key-down, then the
        // router's own timer opens the microphone and starts the dictation.
        precondition(!router.feed(event(.imk, flags: option, at: clock)), "a modifier is never swallowed")
        precondition(actions.isEmpty)
        await settle(60)
        precondition(actions.isEmpty, "fired before its deadline")
        clock += 0.13
        await settle(160)
        precondition(actions == [.voice(.prewarm)], "\(actions)")
        clock += 0.2
        await settle(220)
        precondition(actions == [.voice(.prewarm), .voice(.start)], "\(actions)")
        router.updateContext { $0.isListening = true; $0.voiceCapturing = true }
        clock += 0.5
        precondition(!router.feed(event(.imk, flags: 0, at: clock)))
        precondition(actions == [.voice(.prewarm), .voice(.start), .voice(.stop)])
        router.updateContext { $0.isListening = false; $0.voiceCapturing = false }
        actions = []

        // Right Command hold: the router itself fires the deadline and promotes to press.
        router.updateContext { $0.trigger = .rightCommand }
        let rightCommand = UInt16(kVK_RightCommand)
        let command = UInt64(NSEvent.ModifierFlags.command.rawValue) | PushToTalkHotkey.rightCommand.deviceMask
        clock += 1
        _ = router.feed(InputEvent(source: .imk, type: .flagsChanged, keyCode: rightCommand, flags: command, isRepeat: false, timestamp: clock))
        await settle(90)
        precondition(actions.isEmpty, "hold fired before its deadline")
        clock += 0.3
        await settle(260)
        precondition(actions == [.voice(.prewarm), .voice(.start)], "\(actions)")
        // A release the router is told about (the key-up never arrived) ends it.
        router.voiceTriggerLost()
        precondition(actions == [.voice(.prewarm), .voice(.start), .voice(.stop)], "\(actions)")
        actions = []
        router.reset()
        router.updateContext { $0.trigger = .rightOption; $0.isListening = false }

        // Screen hold deadline is also router-driven.
        router.updateContext { $0.screenHoldEnabled = true }
        clock += 1
        _ = router.feed(InputEvent(source: .imk, type: .flagsChanged, keyCode: UInt16(kVK_Control),
                                   flags: PushToTalkHotkey.leftControl.deviceMask, isRepeat: false, timestamp: clock))
        precondition(actions == [.screenHold(.armHold)])
        await settle(140)
        precondition(actions == [.screenHold(.armHold)], "screen hold fired before its deadline")
        clock += 0.35
        await settle(230)
        precondition(actions == [.screenHold(.armHold), .screenHold(.begin)], "\(actions)")
        actions = []
        router.reset()

        // Context snapshots are readable back.
        router.updateContext { $0.pinVisible = true }
        precondition(router.context.pinVisible)
        router.setPinVisible(false)
        precondition(!router.context.pinVisible)

        // Producer scheduling must not matter: one hardware event produces one
        // action even when the main-thread delivery is observed first.
        actions = []
        router.reset()
        router.updateContext { $0.trigger = .rightOption; $0.voiceCapturing = false; $0.isListening = false }
        clock = 200
        let first = event(.imk, flags: option, at: 200)
        let laterTap = event(.tap, flags: option, at: 200.01)
        precondition(!router.feed(first))
        precondition(!router.feed(laterTap))
        clock = 200.3
        await settle(340)
        precondition(actions == [.voice(.prewarm), .voice(.start)], "reverse-order duplicate dispatched twice: \(actions)")
        // A hidden chord: the owner abandons the press and its release means nothing.
        actions = []
        router.reset()
        clock = 250
        _ = router.feed(event(.imk, flags: option, at: clock))
        clock += 0.13
        await settle(160)
        precondition(actions == [.voice(.prewarm)])
        router.abandonVoiceGesture()
        clock += 0.3
        await settle(200)
        precondition(actions == [.voice(.prewarm), .voice(.discard)], "\(actions)")
        precondition(!router.feed(event(.imk, flags: 0, at: clock)) && actions.count == 2)

        // Mouse-only monitoring must never promote global keyboard readiness.
        precondition(GlobalHotkeyMonitor.keyboardStartPlan(canObserve: false, canFilter: false).isEmpty)
        precondition(GlobalHotkeyMonitor.keyboardStartPlan(canObserve: true, canFilter: false) == [.observing])
        precondition(GlobalHotkeyMonitor.keyboardStartPlan(canObserve: false, canFilter: true) == [.filtering, .observing])
        precondition(GlobalHotkeyMonitor.capabilityAfterReenable(.filtering, tapIsEnabled: true) == .filtering)
        precondition(GlobalHotkeyMonitor.capabilityAfterReenable(.filtering, tapIsEnabled: false) == .unavailable)

        // A stale worker cannot publish or clear a newer generation's capability.
        var monitorState = GlobalHotkeyMonitor.State()
        let oldGeneration = monitorState.beginGeneration()
        precondition(monitorState.publish(.filtering, generation: oldGeneration))
        let currentGeneration = monitorState.beginGeneration()
        precondition(!monitorState.publish(.observing, generation: oldGeneration))
        precondition(!monitorState.clear(generation: oldGeneration))
        precondition(monitorState.capability == .unavailable)
        precondition(monitorState.publish(.observing, generation: currentGeneration))
        precondition(monitorState.accepts(generation: currentGeneration))
        let oldWorker = NSObject(), currentWorker = NSObject()
        precondition(!GlobalHotkeyMonitor.workerIsCurrent(currentWorker, candidate: oldWorker, generationMatches: true))
        precondition(GlobalHotkeyMonitor.workerIsCurrent(currentWorker, candidate: currentWorker, generationMatches: true))
        precondition(!GlobalHotkeyMonitor.workerIsCurrent(currentWorker, candidate: currentWorker, generationMatches: false))

        // A tap interruption between modifier-down and modifier-up cancels the
        // pending hold and its deadline instead of promoting a stale press.
        actions = []
        router.reset()
        router.updateContext {
            $0.trigger = .rightCommand
            $0.voiceCapturing = false
            $0.isListening = false
            $0.globalEventsCanBeConsumed = true
        }
        clock = 300
        _ = router.feed(InputEvent(source: .tap, type: .flagsChanged, keyCode: rightCommand,
                                   flags: command, isRepeat: false, timestamp: clock))
        precondition(actions.isEmpty)
        router.globalTapDidInterrupt(capability: .filtering)
        clock += 1
        await settle(340)
        precondition(actions == [.voice(.cancel)], "tap interruption left stale work: \(actions)")
        precondition(router.context.globalEventsCanBeConsumed)
        precondition(capabilities == ["true-true"])

        // The same interruption also invalidates the left-Control screen timer.
        actions = []
        router.reset()
        router.updateContext {
            $0.trigger = .rightOption
            $0.screenHoldEnabled = true
            $0.screenActive = false
        }
        clock = 350
        _ = router.feed(InputEvent(source: .tap, type: .flagsChanged, keyCode: UInt16(kVK_Control),
                                   flags: PushToTalkHotkey.leftControl.deviceMask,
                                   isRepeat: false, timestamp: clock))
        precondition(actions == [.screenHold(.armHold)])
        router.globalTapDidInterrupt(capability: .observing)
        clock += 1
        await settle(360)
        precondition(actions == [.screenHold(.armHold)], "tap interruption promoted stale screen hold: \(actions)")
        precondition(!router.context.globalEventsCanBeConsumed)
        precondition(capabilities == ["true-true", "true-false"])

        // A passive tap defers a screen chord to IMK. Its empty observation must
        // not enter dedupe history and suppress the local, consumable copy.
        actions = []
        router.reset()
        router.updateContext {
            $0.trigger = .rightOption
            $0.globalEventsCanBeConsumed = false
            $0.screenShortcut = .optionT
        }
        let tapChord = InputEvent(source: .tap, type: .keyDown, keyCode: UInt16(kVK_ANSI_T),
                                  flags: option, isRepeat: false, timestamp: 400)
        let imkChord = InputEvent(source: .imk, type: .keyDown, keyCode: UInt16(kVK_ANSI_T),
                                  flags: option, isRepeat: false, timestamp: 400)
        precondition(!router.feed(tapChord))
        precondition(router.feed(imkChord))
        precondition(actions == [.screenCapture], "passive tap suppressed IMK screen shortcut: \(actions)")

        // Function-key hold needs a globally observed key-up. A passive tap and
        // its IMK echo therefore remain inert as one deduplicated hardware event.
        actions = []
        router.reset()
        router.updateContext {
            $0.trigger = .f20
            $0.globalEventsCanBeConsumed = false
        }
        let tapFunction = InputEvent(source: .tap, type: .keyDown, keyCode: UInt16(kVK_F20),
                                     flags: 0, isRepeat: false, timestamp: 500)
        let imkFunction = InputEvent(source: .imk, type: .keyDown, keyCode: UInt16(kVK_F20),
                                     flags: 0, isRepeat: false, timestamp: 500)
        precondition(!router.feed(tapFunction))
        precondition(!router.feed(imkFunction))
        precondition(actions.isEmpty, "passive function-key echo started voice: \(actions)")
        // Typing while a result is being finalized is neither consumed nor a gesture.
        let shared = SharedArbiter()
        shared.updateContext { $0.isListening = true; $0.voiceCapturing = false }
        let rawLetter = InputEvent(source: .tap, type: .keyDown, keyCode: UInt16(kVK_ANSI_A),
                                   flags: 0, isRepeat: false, timestamp: 600)
        let consumed = await Task.detached { shared.feedFromTap(rawLetter) }.value
        precondition(!consumed)
        // A mouse NSEvent from the monitors must convert without touching key-only
        // accessors; `keyCode` on a mouse event raises and the click is lost.
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [.command], timestamp: 2,
                                       windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let converted = InputEvent(click, source: .tap, timestamp: 700)
        precondition(converted?.type == .leftMouseDown && converted?.keyCode == 0 && converted?.isRepeat == false)
        precondition(converted?.flags == UInt64(NSEvent.ModifierFlags.command.rawValue))
        precondition(!router.feed(converted!), "a click must never be swallowed")
        print("PASS: input event router dispatch, hold deadlines, mouse conversion and context")
    }
}
