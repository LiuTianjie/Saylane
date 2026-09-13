import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Global PTT tap. The callback must never block: no AppKit, TIS, MainActor, or mouse events.
/// Swallowing mouse in a session tap on the main run loop is what froze clicks.
final class GlobalHotkeyMonitor: @unchecked Sendable {
    static let shared = GlobalHotkeyMonitor()

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var keys = InputShortcutHandler()
    private var selected = false
    private var listening = false
    private var switchEnabled = true
    private var trigger = PushToTalkHotkey.rightOption
    private var tapToTalk = false
    private(set) var isFiltering = false
    private(set) var router = GlobalHotkeyRouter()
    private var globalMonitor: Any?
    var onAction: ((InputShortcutHandler.Action) -> Void)?
    var onScreenCapture: (() -> Void)?
    var onScreenHold: ((ScreenHoldHandler.Action) -> Void)?
    var onRecordedShortcut: ((ScreenCaptureShortcut?) -> Void)?
    private var screenShortcut = ScreenCaptureShortcut.optionT
    private var recordingShortcut = false
    private var screenHold = ScreenHoldHandler()
    private var rightCommandTap = RightCommandDoubleTap()
    private var screenActive = false

    var isListeningToEvents: Bool {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return true }
        return globalMonitor != nil
    }

    var isOwningGesture: Bool {
        lock.lock(); defer { lock.unlock() }
        return router.owningGesture
    }

    func updateContext(selected: Bool, trigger: PushToTalkHotkey, switchEnabled: Bool, listening: Bool, tapToTalk: Bool = false) {
        lock.lock()
        self.selected = selected
        self.trigger = trigger
        self.switchEnabled = switchEnabled
        self.listening = listening
        self.tapToTalk = tapToTalk
        lock.unlock()
    }

    func resetGesture() {
        lock.lock()
        keys.reset()
        router.reset()
        screenHold.reset()
        rightCommandTap.reset()
        lock.unlock()
    }

    func resetScreenHold() {
        lock.lock()
        screenHold.noteEndedSelection()
        lock.unlock()
    }

    func setPinVisible(_ visible: Bool) {
        lock.lock()
        screenHold.setPinVisible(visible)
        lock.unlock()
    }

    func setScreenActive(_ active: Bool) {
        lock.lock()
        screenActive = active
        lock.unlock()
    }

    func screenHoldDeadline(now: TimeInterval) -> ScreenHoldHandler.Action {
        lock.lock()
        let next = screenHold.holdDeadline(now: now)
        lock.unlock()
        return next
    }

    func setScreenCaptureShortcut(_ shortcut: ScreenCaptureShortcut) {
        lock.lock()
        screenShortcut = shortcut
        lock.unlock()
    }

    func setRecordingShortcut(_ recording: Bool) {
        lock.lock()
        recordingShortcut = recording
        lock.unlock()
    }

    func holdDeadline(now: TimeInterval) -> InputShortcutHandler.Action {
        lock.lock()
        let next = keys.holdDeadline(now: now)
        router.note(next)
        lock.unlock()
        return next
    }

    @discardableResult
    func start() -> Bool {
        stop()
        var mask: CGEventMask = 0
        for type: CGEventType in [.keyDown, .keyUp, .flagsChanged] {
            mask |= (1 << type.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        if let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback, userInfo: refcon) {
            attach(created, filtering: true)
            return true
        }
        if let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: callback, userInfo: refcon) {
            attach(created, filtering: false)
            return true
        }
        // Doubao ASRShortcutMonitor also has source=globalMonitor when the tap is unavailable.
        return installGlobalMonitorBackup()
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        source = nil
        runLoop = nil
        thread = nil
        isFiltering = false
        resetGesture()
    }

    private func attach(_ tap: CFMachPort, filtering: Bool) {
        self.tap = tap
        self.isFiltering = filtering
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        let thread = Thread { [weak self] in
            guard let self, let source = self.source else { return }
            let rl = CFRunLoopGetCurrent()
            self.runLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "saylane.global-hotkey"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    @discardableResult
    private func installGlobalMonitorBackup() -> Bool {
        var installed = false
        let work = {
            if self.globalMonitor != nil { return }
            self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self, let cgEvent = event.cgEvent else { return }
                let type: CGEventType
                switch event.type {
                case .keyDown: type = .keyDown
                case .keyUp: type = .keyUp
                case .flagsChanged: type = .flagsChanged
                default: return
                }
                _ = self.handle(type: type, event: cgEvent)
            }
            installed = self.globalMonitor != nil
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return installed
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let nsType: NSEvent.EventType
        switch type {
        case .keyDown: nsType = .keyDown
        case .keyUp: nsType = .keyUp
        case .flagsChanged: nsType = .flagsChanged
        default:
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        lock.lock()
        let selected = self.selected
        let trigger = self.trigger
        let switchEnabled = self.switchEnabled
        let listening = self.listening
        let tapToTalk = self.tapToTalk
        let shortcut = self.screenShortcut
        let recording = self.recordingShortcut
        let screenActive = self.screenActive
        lock.unlock()

        if recording, nsType == .keyDown, !isRepeat {
            if keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async { self.onRecordedShortcut?(nil) }
                return isFiltering ? nil : Unmanaged.passUnretained(event)
            }
            if !Self.isModifierKey(keyCode) {
                let recorded = ScreenCaptureShortcut(keyCode: keyCode, modifierFlags: flags)
                if recorded.isUsable {
                    DispatchQueue.main.async { self.onRecordedShortcut?(recorded) }
                    return isFiltering ? nil : Unmanaged.passUnretained(event)
                }
            }
        }

        lock.lock()
        let screenAction = screenHold.handle(type: nsType, keyCode: keyCode, flags: flags,
                                             now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        if screenAction != .none {
            DispatchQueue.main.async { self.onScreenHold?(screenAction) }
        }

        if switchEnabled, nsType == .flagsChanged, trigger != .rightCommand || screenActive {
            lock.lock()
            let switched = rightCommandTap.handle(flags: flags, now: ProcessInfo.processInfo.systemUptime)
            lock.unlock()
            if switched {
                DispatchQueue.main.async { self.onAction?(.switchTarget) }
            }
        }

        if nsType == .keyDown, !isRepeat, shortcut.matches(keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { self.onScreenCapture?() }
            return isFiltering ? nil : Unmanaged.passUnretained(event)
        }

        if screenActive {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let interpret = router.shouldInterpret(
            isOursSelected: selected,
            keyCode: keyCode,
            triggerKeyCode: UInt16(trigger.keyCode)
        ) || (tapToTalk && listening)
        guard interpret else {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        let (action, consumed) = keys.handle(type: nsType, keyCode: keyCode, flags: flags,
                                             repeatKey: isRepeat, trigger: trigger,
                                             switchEnabled: switchEnabled, active: listening,
                                             now: ProcessInfo.processInfo.systemUptime, tapToTalk: tapToTalk)
        router.note(action)
        lock.unlock()

        if action != .none {
            DispatchQueue.main.async { self.onAction?(action) }
        }
        if consumed && isFiltering {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private static func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand, kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl, kVK_Shift, kVK_RightShift, kVK_Function:
            return true
        default:
            return false
        }
    }
}
