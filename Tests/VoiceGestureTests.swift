import Foundation

@main struct VoiceGestureTests {
    typealias Action = VoiceGesture.Action

    static func main() {
        var passed = 0
        let hold = VoiceGesture.Config()
        let holdSwitch = VoiceGesture.Config(toggle: false, doubleTapSwitches: true)
        let toggle = VoiceGesture.Config(toggle: true)
        let toggleSwitch = VoiceGesture.Config(toggle: true, doubleTapSwitches: true)

        do { // Held on its own: microphone first, then the dictation, then the release writes it.
            var g = VoiceGesture()
            precondition(g.trigger(down: true, alone: true, now: 10, config: hold).isEmpty)
            precondition(g.nextDeadline == 10.12)
            precondition(g.deadline(now: 10.05).isEmpty)
            precondition(g.deadline(now: 10.12) == [.prewarm])
            precondition(g.nextDeadline == 10.28)
            precondition(g.deadline(now: 10.2).isEmpty)
            precondition(g.deadline(now: 10.28) == [.start] && g.isTalking)
            precondition(g.nextDeadline == nil)
            precondition(g.trigger(down: false, alone: true, now: 13, config: hold) == [.stop] && !g.isActive)
            passed += 1
        }
        do { // A timer that fires late still opens the microphone before starting.
            var g = VoiceGesture()
            _ = g.trigger(down: true, alone: true, now: 10, config: hold)
            precondition(g.deadline(now: 10.5) == [.prewarm, .start])
            passed += 1
        }
        do { // ⌘W: the key arrives before anything happened. Nothing happens, ever, for this press.
            var g = VoiceGesture()
            _ = g.trigger(down: true, alone: true, now: 10, config: hold)
            precondition(g.other(.key).isEmpty)
            precondition(g.nextDeadline == nil && g.deadline(now: 11).isEmpty)
            precondition(g.other(.key).isEmpty, "⌘W, W, W")
            precondition(g.trigger(down: false, alone: true, now: 12, config: hold).isEmpty && !g.isActive)
            // The next press is a fresh gesture.
            _ = g.trigger(down: true, alone: true, now: 13, config: hold)
            precondition(g.deadline(now: 13.3) == [.prewarm, .start])
            passed += 1
        }
        do { // A slow chord: the microphone was already open; what it captured is thrown away.
            var g = VoiceGesture()
            _ = g.trigger(down: true, alone: true, now: 10, config: hold)
            precondition(g.deadline(now: 10.13) == [.prewarm])
            precondition(g.other(.key) == [.discard])
            precondition(g.deadline(now: 10.3).isEmpty)
            precondition(g.trigger(down: false, alone: true, now: 10.4, config: hold).isEmpty)
            passed += 1
        }
        do { // ⌘-click and ⌘⇧ are chords as well.
            for kind in [VoiceGesture.Other.mouse, .modifier] {
                var g = VoiceGesture()
                _ = g.trigger(down: true, alone: true, now: 10, config: hold)
                precondition(g.other(kind).isEmpty && g.deadline(now: 10.3).isEmpty)
            }
            passed += 1
        }
        do { // ⇧⌘: the talk key pressed second is part of a chord from the start.
            var g = VoiceGesture()
            precondition(g.trigger(down: true, alone: false, now: 10, config: hold).isEmpty)
            precondition(g.nextDeadline == nil && g.deadline(now: 10.3).isEmpty)
            precondition(g.trigger(down: false, alone: false, now: 10.5, config: hold).isEmpty && !g.isActive)
            passed += 1
        }
        do { // A quick press is a tap: nothing starts, and a prewarmed microphone is closed.
            var g = VoiceGesture()
            _ = g.trigger(down: true, alone: true, now: 10, config: hold)
            precondition(g.trigger(down: false, alone: true, now: 10.08, config: hold).isEmpty)
            _ = g.trigger(down: true, alone: true, now: 11, config: hold)
            _ = g.deadline(now: 11.12)
            precondition(g.trigger(down: false, alone: true, now: 11.2, config: hold) == [.discard])
            precondition(g.deadline(now: 11.5).isEmpty)
            passed += 1
        }
        do { // While talking: a key or a click interrupts once, a modifier does not, Esc cancels.
            var g = VoiceGesture()
            _ = g.trigger(down: true, alone: true, now: 10, config: hold); _ = g.deadline(now: 10.3)
            precondition(g.other(.modifier).isEmpty && g.isTalking)
            precondition(g.other(.key) == [.interrupt] && !g.isTalking)
            precondition(g.other(.key).isEmpty && g.other(.mouse).isEmpty)
            precondition(g.trigger(down: false, alone: true, now: 12, config: hold).isEmpty)
            _ = g.trigger(down: true, alone: true, now: 13, config: hold); _ = g.deadline(now: 13.3)
            precondition(g.escape() == [.cancel])
            precondition(g.trigger(down: false, alone: true, now: 14, config: hold).isEmpty && !g.isActive)
            passed += 1
        }
        do { // The same event from two sources is one event.
            var g = VoiceGesture()
            _ = g.trigger(down: true, alone: true, now: 10, config: hold)
            precondition(g.trigger(down: true, alone: true, now: 10.001, config: hold).isEmpty)
            precondition(g.deadline(now: 10.3) == [.prewarm, .start])
            precondition(g.trigger(down: false, alone: true, now: 11, config: hold) == [.stop])
            precondition(g.trigger(down: false, alone: true, now: 11.001, config: hold).isEmpty)
            passed += 1
        }
        do { // Two quick taps switch the direction; a hold in between does not.
            var g = VoiceGesture()
            _ = g.trigger(down: true, alone: true, now: 10, config: holdSwitch)
            precondition(g.trigger(down: false, alone: true, now: 10.06, config: holdSwitch).isEmpty)
            _ = g.trigger(down: true, alone: true, now: 10.15, config: holdSwitch)
            precondition(g.trigger(down: false, alone: true, now: 10.21, config: holdSwitch) == [.switchDirection])
            // Not a third time.
            _ = g.trigger(down: true, alone: true, now: 10.3, config: holdSwitch)
            precondition(g.trigger(down: false, alone: true, now: 10.36, config: holdSwitch).isEmpty)
            // Two fast ⌘C / ⌘V are not a double tap.
            g.reset()
            _ = g.trigger(down: true, alone: true, now: 20, config: holdSwitch); _ = g.other(.key)
            _ = g.trigger(down: false, alone: true, now: 20.05, config: holdSwitch)
            _ = g.trigger(down: true, alone: true, now: 20.1, config: holdSwitch); _ = g.other(.key)
            precondition(g.trigger(down: false, alone: true, now: 20.15, config: holdSwitch).isEmpty)
            // A release after a real hold is not the first tap.
            g.reset()
            _ = g.trigger(down: true, alone: true, now: 30, config: holdSwitch); _ = g.deadline(now: 30.3)
            _ = g.trigger(down: false, alone: true, now: 31, config: holdSwitch)
            _ = g.trigger(down: true, alone: true, now: 31.1, config: holdSwitch)
            precondition(g.trigger(down: false, alone: true, now: 31.16, config: holdSwitch).isEmpty)
            passed += 1
        }
        do { // Toggle: a clean tap starts on release, the next press stops, a chord does neither.
            var g = VoiceGesture()
            precondition(g.trigger(down: true, alone: true, now: 10, config: toggle).isEmpty)
            precondition(g.trigger(down: false, alone: true, now: 10.1, config: toggle) == [.start] && g.isTalking)
            precondition(g.other(.mouse).isEmpty && g.isTalking, "a click does not end hands-free dictation")
            precondition(g.trigger(down: true, alone: true, now: 15, config: toggle) == [.stop])
            precondition(g.trigger(down: false, alone: true, now: 15.1, config: toggle).isEmpty && !g.isActive)
            // ⌘C in toggle mode.
            _ = g.trigger(down: true, alone: true, now: 20, config: toggle)
            precondition(g.other(.key).isEmpty)
            precondition(g.trigger(down: false, alone: true, now: 20.1, config: toggle).isEmpty && !g.isActive)
            // Holding the key for a long time is not a tap.
            _ = g.trigger(down: true, alone: true, now: 30, config: toggle)
            precondition(g.trigger(down: false, alone: true, now: 31, config: toggle).isEmpty)
            // Typing ends a hands-free utterance and writes it.
            _ = g.trigger(down: true, alone: true, now: 40, config: toggle)
            _ = g.trigger(down: false, alone: true, now: 40.1, config: toggle)
            precondition(g.other(.key) == [.stop] && !g.isActive)
            // Esc drops it.
            _ = g.trigger(down: true, alone: true, now: 50, config: toggle)
            _ = g.trigger(down: false, alone: true, now: 50.1, config: toggle)
            precondition(g.escape() == [.cancel] && !g.isActive)
            passed += 1
        }
        do { // Toggle with double tap on the same key: one tap waits for the gap, two switch.
            var g = VoiceGesture()
            _ = g.trigger(down: true, alone: true, now: 10, config: toggleSwitch)
            precondition(g.trigger(down: false, alone: true, now: 10.05, config: toggleSwitch).isEmpty)
            precondition(g.nextDeadline == 10.05 + VoiceGesture.doubleTapGap)
            precondition(g.deadline(now: 10.2).isEmpty)
            precondition(g.deadline(now: 10.38) == [.start])
            precondition(g.trigger(down: true, alone: true, now: 12, config: toggleSwitch) == [.stop])
            _ = g.trigger(down: false, alone: true, now: 12.05, config: toggleSwitch)
            _ = g.trigger(down: true, alone: true, now: 20, config: toggleSwitch)
            _ = g.trigger(down: false, alone: true, now: 20.05, config: toggleSwitch)
            _ = g.trigger(down: true, alone: true, now: 20.2, config: toggleSwitch)
            precondition(g.deadline(now: 20.4).isEmpty, "the gap timer must not fire while the key is down again")
            precondition(g.trigger(down: false, alone: true, now: 20.25, config: toggleSwitch) == [.switchDirection])
            precondition(g.deadline(now: 21).isEmpty && !g.isActive)
            // A key between the taps cancels the pending start.
            _ = g.trigger(down: true, alone: true, now: 30, config: toggleSwitch)
            _ = g.trigger(down: false, alone: true, now: 30.05, config: toggleSwitch)
            _ = g.other(.key)
            precondition(g.deadline(now: 30.5).isEmpty && !g.isActive)
            passed += 1
        }
        do { // A function key has no chords: down starts, up stops; in toggle mode each press flips.
            var g = VoiceGesture()
            precondition(g.functionKey(down: true, config: hold) == [.start])
            precondition(g.functionKey(down: true, config: hold).isEmpty, "key repeat")
            precondition(g.functionKey(down: false, config: hold) == [.stop])
            precondition(g.functionKey(down: true, config: toggle) == [.start])
            precondition(g.functionKey(down: false, config: toggle).isEmpty)
            precondition(g.functionKey(down: true, config: toggle) == [.stop])
            passed += 1
        }
        do { // The owner learns of a hidden chord: before the start nothing shows, after it the session is its to end.
            var g = VoiceGesture()
            _ = g.trigger(down: true, alone: true, now: 10, config: hold); _ = g.deadline(now: 10.12)
            precondition(g.abandon() == [.discard])
            precondition(g.deadline(now: 10.3).isEmpty)
            precondition(g.trigger(down: false, alone: true, now: 10.5, config: hold).isEmpty)
            // Reset (session ended elsewhere) while the key is still down: its release means nothing.
            _ = g.trigger(down: true, alone: true, now: 20, config: hold); _ = g.deadline(now: 20.3)
            g.reset()
            precondition(g.trigger(down: false, alone: true, now: 21, config: hold).isEmpty)
            passed += 1
        }
        print("PASS: \(passed) talk-key gestures: hold alone, ⌘W, slow chords, modified clicks, taps, double taps, toggle, function keys, duplicates")
    }
}
