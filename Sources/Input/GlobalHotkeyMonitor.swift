import AppKit
import ApplicationServices
@preconcurrency import CoreFoundation
import CoreGraphics

/// Session-wide keyboard monitor. Keyboard and mouse monitoring deliberately use
/// separate backends: Core Graphics may silently remove unauthorized key bits
/// from a mixed event mask while leaving mouse bits active, which would make a
/// mouse-only tap look like a working global keyboard shortcut.
final class GlobalHotkeyMonitor: @unchecked Sendable {
    enum KeyboardCapability: Int, Equatable, Sendable {
        case unavailable
        /// Key events are visible, but cannot be removed from the foreground app.
        case observing
        /// Key events are visible and may be consumed.
        case filtering
    }

    /// Pure state used behind `stateLock`. A stale worker may neither publish a
    /// capability nor handle an event after a newer generation has begun.
    struct State: Equatable, Sendable {
        private(set) var generation: UInt64 = 0
        private(set) var capability: KeyboardCapability = .unavailable

        mutating func beginGeneration() -> UInt64 {
            generation &+= 1
            capability = .unavailable
            return generation
        }

        mutating func publish(_ capability: KeyboardCapability, generation candidate: UInt64) -> Bool {
            guard candidate == generation else { return false }
            self.capability = capability
            return true
        }

        mutating func clear(generation candidate: UInt64) -> Bool {
            guard candidate == generation else { return false }
            capability = .unavailable
            return true
        }

        func accepts(generation candidate: UInt64) -> Bool { candidate == generation }
    }

    typealias Handler = @Sendable (InputEvent) -> Bool
    typealias InterruptionHandler = @Sendable (KeyboardCapability) -> Void

    private let handler: Handler
    private let interruptionHandler: InterruptionHandler
    private let stateLock = NSLock()
    private var state = State()
    private var keyboardWorker: TapWorker?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    init(handler: @escaping Handler, onInterruption: @escaping InterruptionHandler = { _ in }) {
        self.handler = handler
        interruptionHandler = onInterruption
    }

    /// The attempt order is a pure seam for permission/capability tests. An
    /// Accessibility-trusted process first tries a filtering tap and may fall
    /// back to observation. Input Monitoring alone only permits observation.
    static func keyboardStartPlan(canObserve: Bool, canFilter: Bool) -> [KeyboardCapability] {
        if canFilter { return [.filtering, .observing] }
        if canObserve { return [.observing] }
        return []
    }

    static func capabilityAfterReenable(_ previous: KeyboardCapability,
                                        tapIsEnabled: Bool) -> KeyboardCapability {
        tapIsEnabled ? previous : .unavailable
    }

    static func workerIsCurrent(_ current: AnyObject?, candidate: AnyObject,
                                generationMatches: Bool) -> Bool {
        generationMatches && current === candidate
    }

    var keyboardCapability: KeyboardCapability {
        stateLock.withLock { state.capability }
    }

    var isListeningToEvents: Bool { keyboardCapability != .unavailable }
    var isFiltering: Bool { keyboardCapability == .filtering }

    /// Starts a key-only event tap. A non-nil tap therefore proves that key bits
    /// survived the system's permission filtering; mouse monitoring cannot turn
    /// this return value into a false positive.
    @discardableResult
    func start() -> Bool {
        precondition(Thread.isMainThread, "GlobalHotkeyMonitor.start must run on the main thread")
        tearDown()
        interruptionHandler(.unavailable)
        let generation = beginGeneration()
        installMouseMonitors(generation: generation)
        installActivationObserver(generation: generation)

        let authorization = Self.currentAuthorization()
        let canFilter = authorization.canFilter
        let canObserve = authorization.canObserve
        for capability in Self.keyboardStartPlan(canObserve: canObserve, canFilter: canFilter) {
            guard let worker = makeKeyboardWorker(capability: capability, generation: generation) else { continue }
            guard publish(worker: worker, capability: capability, generation: generation) else {
                worker.stop()
                continue
            }
            // Publish the capability to the router before this worker can emit
            // its first event.
            interruptionHandler(capability)
            if worker.start() { return true }
            unpublish(worker: worker, generation: generation)
            // Balance the optimistic capability publication. If every backend
            // fails, the router must not process a late "observing/filtering"
            // message after `start()` has already reported unavailable.
            interruptionHandler(.unavailable)
            worker.stop()
        }
        return false
    }

    func stop() {
        precondition(Thread.isMainThread, "GlobalHotkeyMonitor.stop must run on the main thread")
        tearDown()
        interruptionHandler(.unavailable)
    }

    deinit { tearDown() }

    private func tearDown() {
        let detached: (TapWorker?, Any?, Any?, NSObjectProtocol?) = stateLock.withLock {
            _ = state.beginGeneration()
            let values = (keyboardWorker, globalMouseMonitor, localMouseMonitor, activationObserver)
            keyboardWorker = nil
            globalMouseMonitor = nil
            localMouseMonitor = nil
            activationObserver = nil
            return values
        }
        if let monitor = detached.1 { NSEvent.removeMonitor(monitor) }
        if let monitor = detached.2 { NSEvent.removeMonitor(monitor) }
        if let observer = detached.3 { NotificationCenter.default.removeObserver(observer) }
        detached.0?.stop()
    }

    // MARK: - Keyboard tap

    private func beginGeneration() -> UInt64 {
        stateLock.withLock { state.beginGeneration() }
    }

    private static func currentAuthorization() -> (canObserve: Bool, canFilter: Bool) {
        let canFilter = AXIsProcessTrusted()
        return (canFilter || CGPreflightListenEventAccess(), canFilter)
    }

    /// TCC changes have no reliable notification of their own. Returning from
    /// System Settings activates the app, so reconcile the installed backend at
    /// that boundary and upgrade/downgrade it without requiring another click.
    private func installActivationObserver(generation: UInt64) {
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileAuthorization(generation: generation)
        }
        var stale: NSObjectProtocol?
        stateLock.withLock {
            guard state.accepts(generation: generation) else {
                stale = observer
                return
            }
            activationObserver = observer
        }
        if let stale { NotificationCenter.default.removeObserver(stale) }
    }

    private func reconcileAuthorization(generation: UInt64) {
        precondition(Thread.isMainThread)
        let authorization = Self.currentAuthorization()
        let current: KeyboardCapability? = stateLock.withLock {
            state.accepts(generation: generation) ? state.capability : nil
        }
        guard let current else { return }
        let shouldRestart: Bool
        switch current {
        case .filtering:
            shouldRestart = !authorization.canFilter
        case .observing:
            shouldRestart = !authorization.canObserve || authorization.canFilter
        case .unavailable:
            shouldRestart = authorization.canObserve
        }
        guard shouldRestart else { return }
        _ = start()
    }

    private func publish(worker: TapWorker, capability: KeyboardCapability, generation: UInt64) -> Bool {
        stateLock.withLock {
            guard state.publish(capability, generation: generation) else { return false }
            keyboardWorker = worker
            return true
        }
    }

    private func unpublish(worker: TapWorker, generation: UInt64) {
        stateLock.withLock {
            guard Self.workerIsCurrent(keyboardWorker, candidate: worker,
                                       generationMatches: state.accepts(generation: generation)) else { return }
            keyboardWorker = nil
            _ = state.clear(generation: generation)
        }
    }

    private func makeKeyboardWorker(capability: KeyboardCapability, generation: UInt64) -> TapWorker? {
        let context = CallbackContext(monitor: self, generation: generation, filtering: capability == .filtering)
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let context = Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue()
            return context.monitor?.handleKeyboard(type: type, event: event, context: context)
                ?? Unmanaged.passUnretained(event)
        }
        var mask: CGEventMask = 0
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged] {
            mask |= (1 << type.rawValue)
        }
        let options: CGEventTapOptions = capability == .filtering ? .defaultTap : .listenOnly
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: options, eventsOfInterest: mask,
                                          callback: callback, userInfo: refcon) else { return nil }
        context.tap = tap
        let worker = TapWorker(tap: tap, context: context)
        context.worker = worker
        return worker
    }

    private func handleKeyboard(type: CGEventType, event: CGEvent,
                                context: CallbackContext) -> Unmanaged<CGEvent>? {
        guard let worker = context.worker else { return Unmanaged.passUnretained(event) }
        let currentCapability: KeyboardCapability? = stateLock.withLock {
            Self.workerIsCurrent(keyboardWorker, candidate: worker,
                                 generationMatches: state.accepts(generation: context.generation))
                ? state.capability : nil
        }
        guard let currentCapability, currentCapability != .unavailable else {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Reset gesture state before accepting more events. Otherwise a lost
            // modifier-up can leave hold-to-talk or a deadline armed forever.
            if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let enabled = context.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
            let recovered = Self.capabilityAfterReenable(currentCapability, tapIsEnabled: enabled)
            if recovered == .unavailable {
                markWorkerUnavailable(worker: worker, generation: context.generation)
            } else {
                interruptionHandler(recovered)
            }
            return Unmanaged.passUnretained(event)
        }
        // Our own pasted ⌘V is not user input.
        if event.getIntegerValueField(.eventSourceUserData) == InputEvent.syntheticUserData {
            return Unmanaged.passUnretained(event)
        }
        let hardwareTime = TimeInterval(event.timestamp) / 1_000_000_000
        guard let converted = InputEvent(cgType: type, event: event, timestamp: hardwareTime) else {
            return Unmanaged.passUnretained(event)
        }
        let consume: Bool? = stateLock.withLock {
            guard Self.workerIsCurrent(keyboardWorker, candidate: worker,
                                       generationMatches: state.accepts(generation: context.generation)),
                  state.capability != .unavailable else { return nil }
            // Commit the action while lifecycle state is held. `tearDown()` then
            // queues its interruption after this action and drains the callback
            // before installing another worker.
            return handler(converted)
        }
        guard let consume else { return Unmanaged.passUnretained(event) }
        if consume && context.filtering { return nil }
        return Unmanaged.passUnretained(event)
    }

    private func markWorkerUnavailable(worker: TapWorker, generation: UInt64) {
        let changed: Bool = stateLock.withLock {
            guard Self.workerIsCurrent(keyboardWorker, candidate: worker,
                                       generationMatches: state.accepts(generation: generation)) else { return false }
            return state.clear(generation: generation)
        }
        if changed { interruptionHandler(.unavailable) }
    }

    private func workerDidExit(worker: TapWorker, generation: UInt64) {
        let changed: Bool = stateLock.withLock {
            guard Self.workerIsCurrent(keyboardWorker, candidate: worker,
                                       generationMatches: state.accepts(generation: generation)),
                  state.clear(generation: generation) else { return false }
            keyboardWorker = nil
            return true
        }
        if changed { interruptionHandler(.unavailable) }
    }

    // MARK: - Mouse observation

    /// Mouse clicks only stop/cancel an active voice gesture and are never
    /// swallowed. NSEvent mouse monitors need no keyboard-listening capability,
    /// so they cannot affect `keyboardCapability`.
    private func installMouseMonitors(generation: UInt64) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouse(event, generation: generation)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouse(event, generation: generation)
            return event
        }
        var stale: (Any?, Any?)?
        stateLock.withLock {
            guard state.accepts(generation: generation) else {
                stale = (global, local)
                return
            }
            globalMouseMonitor = global
            localMouseMonitor = local
        }
        if let stale {
            if let monitor = stale.0 { NSEvent.removeMonitor(monitor) }
            if let monitor = stale.1 { NSEvent.removeMonitor(monitor) }
        }
    }

    private func handleMouse(_ event: NSEvent, generation: UInt64) {
        let timestamp = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime
        guard let converted = InputEvent(event, source: .tap, timestamp: timestamp) else { return }
        stateLock.withLock {
            guard state.accepts(generation: generation) else { return }
            _ = handler(converted)
        }
    }

    // MARK: - Per-generation worker

    private final class CallbackContext: @unchecked Sendable {
        weak var monitor: GlobalHotkeyMonitor?
        weak var worker: TapWorker?
        let generation: UInt64
        let filtering: Bool
        nonisolated(unsafe) var tap: CFMachPort?

        init(monitor: GlobalHotkeyMonitor, generation: UInt64, filtering: Bool) {
            self.monitor = monitor
            self.generation = generation
            self.filtering = filtering
        }
    }

    /// Owns one immutable tap/source pair. `stop()` waits until this worker's run
    /// loop has processed teardown, so a restart cannot attach a new source to an
    /// old thread or overwrite another generation's run loop.
    private final class TapWorker: @unchecked Sendable {
        nonisolated(unsafe) let tap: CFMachPort
        nonisolated(unsafe) let source: CFRunLoopSource
        let context: CallbackContext
        private let condition = NSCondition()
        private var runLoop: CFRunLoop?
        private var thread: Thread?
        private var ready = false
        private var finished = false
        private var stopRequested = false

        init(tap: CFMachPort, context: CallbackContext) {
            self.tap = tap
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.context = context
        }

        func start() -> Bool {
            let workerThread = Thread { [weak self] in self?.run() }
            workerThread.name = "saylane.global-hotkey.\(context.generation)"
            workerThread.qualityOfService = .userInteractive
            condition.withLock { thread = workerThread }
            workerThread.start()
            return condition.withLock {
                let deadline = Date(timeIntervalSinceNow: 2)
                while !ready && !finished, condition.wait(until: deadline) {}
                return ready && !finished
            }
        }

        func stop() {
            let target: CFRunLoop? = condition.withLock {
                stopRequested = true
                return runLoop
            }
            if let target {
                let port = tap
                let source = source
                CFRunLoopPerformBlock(target, CFRunLoopMode.commonModes.rawValue) {
                    CGEvent.tapEnable(tap: port, enable: false)
                    CFRunLoopRemoveSource(target, source, .commonModes)
                    CFRunLoopStop(target)
                }
                CFRunLoopWakeUp(target)
            }
            condition.withLock {
                if target != nil {
                    while !finished { condition.wait() }
                } else {
                    let deadline = Date(timeIntervalSinceNow: 2)
                    while !finished, condition.wait(until: deadline) {}
                }
            }
        }

        private func run() {
            let current = CFRunLoopGetCurrent()
            let shouldStop = condition.withLock {
                runLoop = current
                return stopRequested
            }
            if shouldStop {
                finish()
                return
            }
            CFRunLoopAddSource(current, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            condition.withLock {
                ready = true
                condition.broadcast()
            }
            CFRunLoopRun()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(current, source, .commonModes)
            finish()
            context.monitor?.workerDidExit(worker: self, generation: context.generation)
        }

        private func finish() {
            condition.withLock {
                runLoop = nil
                thread = nil
                finished = true
                condition.broadcast()
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
