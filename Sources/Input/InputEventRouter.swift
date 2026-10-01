import AppKit
import Foundation

private enum InputRouterMessage: Sendable {
    case actions([InputAction])
    /// The event tap lost continuity. Gesture state is already reset under the
    /// shared lock; the main actor still needs to cancel timers and live work.
    case interrupted([InputAction], GlobalHotkeyMonitor.KeyboardCapability)
}

/// The only consumer of raw key events. Three producers feed it — the CGEvent tap
/// (any thread), IMK `handle` and the settings-window monitor (main thread) — and
/// one `GestureArbiter` decides. Duplicate deliveries of one physical event are
/// dropped here, and the hold/double-tap timers live here, not in the app model.
@MainActor
final class InputEventRouter {
    /// A tap-delivered event and its IMK copy arrive within a few milliseconds.
    nonisolated static let dedupeWindow: TimeInterval = 0.03

    var onAction: ((InputAction) -> Void)?
    var onGlobalCapabilityChanged: ((_ listening: Bool, _ filtering: Bool) -> Void)?

    private let shared = SharedArbiter()
    private let tap: GlobalHotkeyMonitor
    private var voiceDeadline: Task<Void, Never>?
    private var screenDeadline: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        let shared = self.shared
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        shared.continuation = continuation
        tap = GlobalHotkeyMonitor(handler: { event in shared.feedFromTap(event) },
                                  onInterruption: { capability in
                                      shared.interruptFromTap(capability: capability)
                                  })
        pump = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                for message in self.shared.takePendingMessages() {
                    self.dispatch(message)
                }
            }
        }
    }

    // MARK: - Context

    var context: InputContext { shared.snapshotContext() }

    func updateContext(_ mutate: (inout InputContext) -> Void) {
        shared.updateContext(mutate)
    }

    func reset() {
        voiceDeadline?.cancel(); voiceDeadline = nil
        screenDeadline?.cancel(); screenDeadline = nil
        shared.reset()
    }

    func noteEndedSelection() { shared.withArbiter { $0.noteEndedSelection() } }
    func setPinVisible(_ visible: Bool) {
        shared.withArbiter { $0.setPinVisible(visible) }
        updateContext { $0.pinVisible = visible }
    }

    // MARK: - Global tap

    /// Start (or restart) global keyboard observation. Mouse-only monitoring does
    /// not make this return value true.
    @discardableResult
    func startGlobalTap() -> Bool {
        tap.start()
    }
    func stopGlobalTap() {
        tap.stop()
    }
    var isGlobalTapListening: Bool { tap.isListeningToEvents }
    /// Events can be swallowed before they reach other applications.
    var isGlobalTapFiltering: Bool { tap.isFiltering }

    /// Recovery seam used by the monitor and deterministic router tests.
    func globalTapDidInterrupt(capability: GlobalHotkeyMonitor.KeyboardCapability) {
        shared.interruptFromTap(capability: capability)
    }

    // MARK: - Main-thread sources

    /// Feed an event from IMK or the settings window. Returns whether a gesture consumed it.
    @discardableResult
    func feed(_ event: NSEvent, source: InputEvent.Source) -> Bool {
        let timestamp = event.timestamp > 0 ? event.timestamp : now()
        guard let converted = InputEvent(event, source: source, timestamp: timestamp) else { return false }
        return feed(converted)
    }

    @discardableResult
    func feed(_ event: InputEvent) -> Bool {
        let (earlier, result) = shared.feedFromMain(event, window: Self.dedupeWindow)
        for message in earlier { dispatch(message) }
        for action in result.actions { dispatch(action) }
        return result.consume
    }

    // MARK: - Dispatch and timers

    private func dispatch(_ action: InputAction) {
        switch action {
        case .voice(.armHold):
            armVoiceDeadline(after: InputShortcutHandler.holdDelay)
        case .voice(.armTap):
            armVoiceDeadline(after: InputShortcutHandler.doubleTapGap)
        case .voice(.disarm), .voice(.press), .voice(.release), .voice(.cancel), .voice(.switchTarget):
            voiceDeadline?.cancel(); voiceDeadline = nil
        case .screenHold(.armHold):
            screenDeadline?.cancel()
            screenDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(ScreenHoldHandler.holdDelay)) } catch { return }
                guard let self else { return }
                if let next = self.shared.withArbiter({ $0.screenHoldDeadline(now: self.now()) }) {
                    self.dispatch(next)
                }
            }
        case .screenHold:
            screenDeadline?.cancel(); screenDeadline = nil
        default:
            break
        }
        onAction?(action)
    }

    private func dispatch(_ message: InputRouterMessage) {
        switch message {
        case .actions(let actions):
            for action in actions { dispatch(action) }
        case .interrupted(let actions, let capability):
            voiceDeadline?.cancel(); voiceDeadline = nil
            screenDeadline?.cancel(); screenDeadline = nil
            onGlobalCapabilityChanged?(capability != .unavailable, capability == .filtering)
            for action in actions { dispatch(action) }
        }
    }

    private func armVoiceDeadline(after delay: TimeInterval) {
        voiceDeadline?.cancel()
        voiceDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            if let next = self.shared.withArbiter({ $0.voiceDeadline(now: self.now()) }) {
                self.dispatch(next)
            }
        }
    }
}

/// Lock-protected arbiter shared between the tap thread and the main actor.
/// The tap callback must never block on AppKit or the main actor.
final class SharedArbiter: @unchecked Sendable {
    private let lock = NSLock()
    private var arbiter = GestureArbiter()
    private var context = InputContext()
    /// Producers run on different queues, so delivery order is not part of the
    /// contract. Keep a short bidirectional history so either order produces
    /// exactly one action.
    private var recent: [(event: InputEvent, consumed: Bool)] = []
    private var pendingMessages: [InputRouterMessage] = []
    var continuation: AsyncStream<Void>.Continuation?

    func snapshotContext() -> InputContext {
        lock.lock(); defer { lock.unlock() }
        return context
    }

    func updateContext(_ mutate: (inout InputContext) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&context)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        arbiter.reset()
        recent.removeAll(keepingCapacity: true)
        let latestCapability = pendingMessages.reversed().compactMap { message -> GlobalHotkeyMonitor.KeyboardCapability? in
            if case .interrupted(_, let capability) = message { return capability }
            return nil
        }.first
        pendingMessages.removeAll(keepingCapacity: true)
        if let latestCapability { pendingMessages.append(.interrupted([], latestCapability)) }
    }

    func withArbiter<T>(_ body: (inout GestureArbiter) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&arbiter)
    }

    /// Preserve synchronous main-thread action semantics while draining every
    /// earlier tap message in the same critical section that advances state.
    fileprivate func feedFromMain(_ event: InputEvent, window: TimeInterval) -> ([InputRouterMessage], GestureArbiter.Result) {
        lock.lock(); defer { lock.unlock() }
        let earlier = pendingMessages
        pendingMessages.removeAll(keepingCapacity: true)
        return (earlier, feedLocked(event, window: window))
    }

    /// Called on the tap thread. Returns whether the event should be swallowed.
    func feedFromTap(_ event: InputEvent) -> Bool {
        lock.lock()
        let result = feedLocked(event, window: InputEventRouter.dedupeWindow)
        let shouldWake = !result.actions.isEmpty
        if shouldWake { pendingMessages.append(.actions(result.actions)) }
        lock.unlock()
        if shouldWake { continuation?.yield(()) }
        return result.consume
    }

    /// Called from the tap thread when the stream was disabled or its worker
    /// exited. Reset immediately so a timer cannot promote a stale key-down while
    /// the main actor is busy, then ask the app to cancel only work that still
    /// depends on keyboard continuity.
    func interruptFromTap(capability: GlobalHotkeyMonitor.KeyboardCapability) {
        lock.lock()
        let cancelVoice = context.voiceCapturing || arbiter.isOwningGesture
        let cancelSelection = context.screenActive && !context.pinVisible
        context.globalEventsCanBeConsumed = capability == .filtering
        arbiter.reset()
        recent.removeAll(keepingCapacity: true)
        var actions: [InputAction] = []
        if cancelVoice { actions.append(.voice(.cancel)) }
        if cancelSelection { actions.append(.screenHold(.cancel)) }
        pendingMessages.append(.interrupted(actions, capability))
        lock.unlock()
        continuation?.yield(())
    }

    fileprivate func takePendingMessages() -> [InputRouterMessage] {
        lock.lock(); defer { lock.unlock() }
        let messages = pendingMessages
        pendingMessages.removeAll(keepingCapacity: true)
        return messages
    }

    private func feedLocked(_ event: InputEvent, window: TimeInterval) -> GestureArbiter.Result {
        if let duplicate = recent.reversed().first(where: { event.isDuplicate(of: $0.event, window: window) }) {
            return GestureArbiter.Result(actions: [], consume: duplicate.consumed)
        }
        let result = arbiter.feed(event, context: context)
        // A passive tap deliberately defers the screen chord to IMK so the local
        // path can consume it. Do not let that empty observation suppress the
        // later local copy. Other passive observations (notably function-key
        // triggers) stay cached so their IMK echo cannot start a hold without a
        // reliable, globally observed key-up.
        if event.source == .tap, !context.globalEventsCanBeConsumed,
           result.actions.isEmpty, !result.consume,
           event.type == .keyDown, !event.isRepeat,
           context.screenShortcut.matches(keyCode: event.keyCode, flags: event.flags) {
            return result
        }
        recent.append((event, result.consume))
        if recent.count > 16 { recent.removeFirst(recent.count - 16) }
        return result
    }
}
