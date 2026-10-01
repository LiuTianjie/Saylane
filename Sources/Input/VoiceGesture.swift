import Foundation

/// The talk key, as a state machine over time. A modifier is part of every
/// shortcut, so a press of it means nothing until it has been held on its own:
///
///     down, alone ─► pending ──0.12 s──► prewarm (microphone, nothing visible)
///                           ──0.28 s──► start
///     a key, a click or another modifier while pending ─► void until released
///     released before 0.28 s ─► a tap (never a dictation)
///
/// Time is injected; the owner fires `deadline(now:)` at `nextDeadline`.
struct VoiceGesture: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Open the microphone quietly; the hold is not confirmed yet.
        case prewarm
        /// Throw away what `prewarm` captured.
        case discard
        case start
        /// Finish and write.
        case stop
        /// Esc: drop the dictation.
        case cancel
        /// A key or a click while talking: a chord or a slip, decided by the session's age.
        case interrupt
        case switchDirection
    }

    enum Other: Equatable, Sendable { case key, mouse, modifier }

    struct Config: Equatable, Sendable {
        /// Tap once to start and once more to stop, instead of holding.
        var toggle = false
        /// Two quick taps of the talk key switch the translation direction.
        var doubleTapSwitches = false
    }

    static let prewarmDelay: TimeInterval = 0.12
    static let holdDelay: TimeInterval = 0.28
    /// The longest press that still counts as a tap.
    static let tapLimit: TimeInterval = 0.4
    static let doubleTapGap: TimeInterval = 0.32

    private enum State: Equatable, Sendable {
        case idle
        /// Held alone, not yet a dictation.
        case pending(downAt: TimeInterval, prewarmed: Bool)
        /// Still held, but this press can no longer become anything.
        case void
        /// Talking while the key is held.
        case holding
        /// Toggle mode: the key is down on its own.
        case tapDown(downAt: TimeInterval, second: Bool)
        /// Toggle mode with double tap: one clean tap, waiting for a second.
        case tapWaiting(releasedAt: TimeInterval)
        /// Talking hands-free.
        case toggled
    }

    private var state: State = .idle
    private var lastTapReleasedAt: TimeInterval?

    var isActive: Bool { state != .idle }
    /// Talking, as far as the gesture knows.
    var isTalking: Bool { state == .holding || state == .toggled }

    /// When `deadline(now:)` must be called next (system uptime).
    var nextDeadline: TimeInterval? {
        switch state {
        case .pending(let downAt, let prewarmed):
            return downAt + (prewarmed ? Self.holdDelay : Self.prewarmDelay)
        case .tapWaiting(let releasedAt):
            return releasedAt + Self.doubleTapGap
        default:
            return nil
        }
    }

    mutating func reset() {
        state = .idle
        lastTapReleasedAt = nil
    }

    /// The owner decided this press is a chord after all (a key the gesture never saw).
    mutating func abandon() -> [Action] {
        switch state {
        case .pending(_, let prewarmed):
            state = .void
            return prewarmed ? [.discard] : []
        case .holding:
            state = .void
            return []
        default:
            return []
        }
    }

    // MARK: - Modifier talk key

    /// The talk key went down or up. `alone`: no other modifier is held.
    mutating func trigger(down: Bool, alone: Bool, now: TimeInterval, config: Config) -> [Action] {
        down ? triggerDown(alone: alone, now: now, config: config) : triggerUp(now: now, config: config)
    }

    private mutating func triggerDown(alone: Bool, now: TimeInterval, config: Config) -> [Action] {
        switch state {
        case .idle:
            guard alone else { state = .void; return [] }
            state = config.toggle ? .tapDown(downAt: now, second: false) : .pending(downAt: now, prewarmed: false)
            return []
        case .tapWaiting:
            guard alone else { reset(); state = .void; return [] }
            state = .tapDown(downAt: now, second: true)
            return []
        case .toggled:
            // The second press ends the utterance; its release means nothing.
            state = .void
            return [.stop]
        default:
            // The same key reported down twice (two event sources).
            return []
        }
    }

    private mutating func triggerUp(now: TimeInterval, config: Config) -> [Action] {
        switch state {
        case .pending(let downAt, let prewarmed):
            state = .idle
            var actions: [Action] = prewarmed ? [.discard] : []
            // A short press is a tap; two of them switch the direction.
            if config.doubleTapSwitches, now - downAt <= Self.tapLimit {
                if let previous = lastTapReleasedAt, now - previous <= Self.doubleTapGap {
                    lastTapReleasedAt = nil
                    actions.append(.switchDirection)
                } else {
                    lastTapReleasedAt = now
                }
            } else {
                lastTapReleasedAt = nil
            }
            return actions
        case .holding:
            state = .idle
            lastTapReleasedAt = nil
            return [.stop]
        case .tapDown(let downAt, let second):
            guard now - downAt <= Self.tapLimit else { reset(); return [] }
            if second {
                reset()
                return [.switchDirection]
            }
            if config.doubleTapSwitches {
                state = .tapWaiting(releasedAt: now)
                return []
            }
            state = .toggled
            return [.start]
        case .void:
            state = .idle
            return []
        case .idle, .tapWaiting, .toggled:
            return []
        }
    }

    // MARK: - Function-key talk key

    /// A function key has no chords: it starts at once.
    mutating func functionKey(down: Bool, config: Config) -> [Action] {
        if config.toggle {
            guard down else { return [] }
            if state == .toggled { state = .idle; return [.stop] }
            guard state == .idle else { return [] }
            state = .toggled
            return [.start]
        }
        if down {
            guard state == .idle else { return [] }
            state = .holding
            return [.start]
        }
        guard state == .holding else { state = .idle; return [] }
        state = .idle
        return [.stop]
    }

    // MARK: - Everything else

    /// A key, a click or another modifier that is not the talk key.
    mutating func other(_ kind: Other) -> [Action] {
        switch state {
        case .pending(_, let prewarmed):
            state = .void
            lastTapReleasedAt = nil
            return prewarmed ? [.discard] : []
        case .tapDown:
            state = .void
            lastTapReleasedAt = nil
            return []
        case .tapWaiting:
            reset()
            return []
        case .holding:
            // A modifier alone does nothing in the application: keep talking.
            guard kind != .modifier else { return [] }
            state = .void
            return [.interrupt]
        case .toggled:
            // Hands-free: typing ends the utterance, a click does not.
            guard kind == .key else { return [] }
            state = .idle
            return [.stop]
        case .idle:
            if kind != .modifier { lastTapReleasedAt = nil }
            return []
        case .void:
            return []
        }
    }

    /// Esc while talking.
    mutating func escape() -> [Action] {
        switch state {
        case .holding:
            state = .void
            return [.cancel]
        case .toggled:
            state = .idle
            return [.cancel]
        default:
            return []
        }
    }

    mutating func deadline(now: TimeInterval) -> [Action] {
        switch state {
        case .pending(let downAt, let prewarmed):
            if now >= downAt + Self.holdDelay {
                state = .holding
                lastTapReleasedAt = nil
                // A timer that fired late must not skip the microphone.
                return prewarmed ? [.start] : [.prewarm, .start]
            }
            if !prewarmed, now >= downAt + Self.prewarmDelay {
                state = .pending(downAt: downAt, prewarmed: true)
                return [.prewarm]
            }
            return []
        case .tapWaiting(let releasedAt):
            guard now >= releasedAt + Self.doubleTapGap else { return [] }
            state = .toggled
            return [.start]
        default:
            return []
        }
    }
}
