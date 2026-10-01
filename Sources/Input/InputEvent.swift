import AppKit
import CoreGraphics

/// One raw key/mouse event, whichever path delivered it. Every producer converts
/// to this before the router sees it, so gesture logic never touches NSEvent/CGEvent.
struct InputEvent: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// CGEvent tap on the session (background thread).
        case tap
        /// `IMKInputController.handle` while Saylane is the selected input source.
        case imk
        /// Local NSEvent monitor while the settings window is key.
        case settingsWindow
    }

    var source: Source
    var type: NSEvent.EventType
    var keyCode: UInt16
    var flags: UInt64
    var isRepeat: Bool
    /// `ProcessInfo.systemUptime` at receipt.
    var timestamp: TimeInterval

    /// `eventSourceUserData` of the key events Saylane posts itself (the ⌘V of a
    /// pasted dictation). The event tap lets them through without interpreting them.
    static let syntheticUserData: Int64 = 0x5341_594C

    init(source: Source, type: NSEvent.EventType, keyCode: UInt16, flags: UInt64, isRepeat: Bool, timestamp: TimeInterval) {
        self.source = source
        self.type = type
        self.keyCode = keyCode
        self.flags = flags
        self.isRepeat = isRepeat
        self.timestamp = timestamp
    }

    init?(_ event: NSEvent, source: Source, timestamp: TimeInterval) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown: break
        default: return nil
        }
        self.init(source: source, type: event.type, keyCode: event.keyCode,
                  flags: UInt64(event.modifierFlags.rawValue),
                  isRepeat: event.type == .keyDown && event.isARepeat, timestamp: timestamp)
    }

    init?(cgType: CGEventType, event: CGEvent, timestamp: TimeInterval) {
        let type: NSEvent.EventType
        switch cgType {
        case .keyDown: type = .keyDown
        case .keyUp: type = .keyUp
        case .flagsChanged: type = .flagsChanged
        case .leftMouseDown: type = .leftMouseDown
        case .rightMouseDown: type = .rightMouseDown
        default: return nil
        }
        self.init(source: .tap, type: type,
                  keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                  flags: event.flags.rawValue,
                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                  timestamp: timestamp)
    }

    /// Two deliveries of the same physical key event (tap + IMK) look alike
    /// apart from the source and a few milliseconds.
    func isDuplicate(of other: InputEvent, window: TimeInterval) -> Bool {
        source != other.source && type == other.type && keyCode == other.keyCode
            && canonicalFlags == other.canonicalFlags && isRepeat == other.isRepeat
            && abs(timestamp - other.timestamp) <= window
    }

    /// CGEvent and NSEvent may disagree on bookkeeping bits while describing
    /// the same hardware event. Preserve public modifier flags and the private
    /// left/right device bits that our one-key gestures need.
    private var canonicalFlags: UInt64 {
        let publicMask = UInt64(NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)
        let deviceMask: UInt64 = 0x0000_207f
        return flags & (publicMask | deviceMask)
    }
}

/// What the arbiter needs to know about the rest of the app, as a snapshot.
struct InputContext: Equatable, Sendable {
    var trigger: PushToTalkHotkey = .rightOption
    var switchEnabled = true
    var tapToTalk = false
    var isListening = false
    var voiceEnabled = true
    var isOursSelected = false
    var screenShortcut: ScreenCaptureShortcut = .optionT
    var screenHoldEnabled = false
    var screenActive = false
    var pinVisible = false
    var recordingShortcut = false
    /// A listen-only event tap can observe global keys but cannot prevent the
    /// triggering key from reaching the foreground app.
    var globalEventsCanBeConsumed = false
    /// The microphone still accepts a stop/cancel gesture. Finalization keeps the
    /// session busy but must not treat ordinary typing as a recording gesture.
    var voiceCapturing = false
}

/// Keys the router owns while a screen pin is on screen.
enum ScreenPinKey: Equatable, Sendable {
    case close, toggleOverlay, copy, retry, cycleDirection
}

/// Everything the arbiter can ask the app to do.
enum InputAction: Equatable, Sendable {
    case voice(InputShortcutHandler.Action)
    case switchDirection
    case screenCapture
    case screenHold(ScreenHoldHandler.Action)
    case screenPin(ScreenPinKey)
    case recordedShortcut(ScreenCaptureShortcut?)
}
