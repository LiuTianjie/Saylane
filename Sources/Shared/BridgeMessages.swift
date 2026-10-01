import Foundation

/// The contract between the two Saylane processes: the input method
/// (`SaylaneIME`, typing and writing into the focused client) and the main
/// program (`Saylane`, everything else). See `docs/DESIGN_0.3.md`.
enum Bridge {
    static let protocolVersion = 3
    /// The input method answers requests from the main program here.
    static let imePortName = "com.rtranslate.saylane.ime-bridge" + TestHome.suffix
    /// The main program receives events from the input method here.
    static let appPortName = "com.rtranslate.saylane.app-bridge" + TestHome.suffix
    static let imeBundleID = "com.rtranslate.inputmethod.rtranslate"
    static let appBundleID = "com.rtranslate.saylane"
    /// Preferences stay in the input method's domain so an upgrade keeps them.
    static let defaultsSuite = TestHome.isActive ? "local.saylane.test" : imeBundleID
    static let imeBundlePath = "/Library/Input Methods/Saylane.app"

    /// A dictation starts at most this long after its talk key went down
    /// (a hold, or a tap that waited for a possible second tap).
    static let talkKeyFreshness: TimeInterval = 2

    /// Whether a text client reported by InputMethodKit belongs to an
    /// application. Chromium and Electron host their text fields in helper
    /// processes whose identifier extends the application's
    /// (`com.electron.lark` → `com.electron.lark.helper`).
    static func client(_ clientBundleID: String?, belongsTo applicationBundleID: String?) -> Bool {
        guard let applicationBundleID else { return true }
        guard let clientBundleID else { return false }
        return clientBundleID == applicationBundleID || clientBundleID.hasPrefix(applicationBundleID + ".")
    }

    static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// A dictation as the input method needs to know it.
enum VoicePhase: String, Codable, Sendable {
    case idle
    /// The microphone is open.
    case listening
    /// Released; the final text is on its way.
    case finalizing
    /// The ordinary result is complete; an optional rewrite is still running.
    case polishing
}

/// A key the input method saw: codes and modifier bits only, never characters.
struct KeyMeta: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case keyDown, flagsChanged }
    var kind: Kind
    var keyCode: UInt16
    var flags: UInt64
    var isRepeat: Bool
    /// System uptime, the same clock in both processes.
    var timestamp: TimeInterval
}

/// What the input-method menu shows; the main program owns the wording.
struct BridgeMenuState: Codable, Equatable, Sendable {
    /// The ways to speak and write with the chosen pair of languages ("中文 听写", "中文 → EN", …).
    var modes: [String] = []
    var currentMode: Int?
    /// A mode can be chosen now: nothing is being dictated or prepared.
    var canChooseMode = false
    var hasLastDictation = false
    var notice: String?
}

/// Everything the input method must know about the main program, pushed whole
/// on every change so a lost or reordered update cannot leave it half-applied.
struct BridgeContext: Codable, Equatable, Sendable {
    var revision: UInt64 = 0
    var appPID: Int32 = 0
    var phase: VoicePhase = .idle
    var session: UUID?
    /// The application the dictation belongs to.
    var sessionBundleID: String?
    /// The main program has its own key listener; the input method forwards nothing.
    var appOwnsKeys = false
    /// `PushToTalkHotkey` raw value.
    var trigger = "rightOption"
    var screenSelecting = false
    var screenShortcutKeyCode: UInt16?
    var screenShortcutFlags: UInt64?
    /// Hands-free dictation: a typed key ends the utterance, so it waits for the text.
    var keysEndDictation = false
    /// How long typed keys wait for the final text before typing wins.
    var userInputFence: TimeInterval = 0.6
    var menu = BridgeMenuState()
}

struct BridgePinyinPreferences: Codable, Equatable, Sendable {
    var englishMode = false
    var fuzzy = true
    var barPreedit = false
    var keys = PinyinKeyOptions()
    /// Whether the optional language model is installed. A change makes the
    /// input method reload its schema; the file itself is what it looks at.
    var languageModel = false
}

struct BridgeIMEStatus: Codable, Equatable, Sendable {
    var protocolVersion = Bridge.protocolVersion
    var version = ""
    var pid: Int32 = 0
    var attachedBundleID: String?
    /// The client has delivered a key or an activation since its last focus change.
    var attachedFresh = false
    var pinyinError: String?
}

/// Main program → input method.
enum BridgeRequest: Codable, Sendable {
    case status
    case context(BridgeContext)
    case pinyin(BridgePinyinPreferences)
    /// Show a dictation preview as marked text. `seq` grows within a session.
    case voiceMarked(session: UUID, seq: UInt64, text: String)
    case voiceClear(session: UUID)
    /// Write the final text. Refused after `deadline` (system uptime) so a
    /// request that was stuck in a queue cannot write after the sender gave up.
    case voiceInsert(session: UUID, text: String, deadline: TimeInterval)
    case voiceEnd(session: UUID)
}

enum BridgeReply: Codable, Sendable {
    case done(Bool)
    case status(BridgeIMEStatus)
}

enum BridgeMenuAction: String, Codable, Sendable {
    case openSettings, showNotice, screenCapture, copyLastDictation
}

/// Input method → main program.
enum BridgeEvent: Codable, Sendable {
    case hello(BridgeIMEStatus)
    /// A client of this application is attached; nil when none is.
    case attachment(bundleID: String?)
    case key(KeyMeta)
    /// The talk key went down in the attached client (system uptime). Keys go
    /// to whoever has the keyboard, so this client has it, whichever
    /// application is in front. Sent whether or not keys are forwarded.
    case talkKey(bundleID: String?, at: TimeInterval)
    /// The first key typed while the final text is pending. It waits; a result
    /// that is only being polished should be written now.
    case userTyped(session: UUID)
    /// Typing went ahead of the pending text; the preview is gone.
    case typingResumed(session: UUID)
    case menu(BridgeMenuAction)
    /// One of `BridgeMenuState.modes` was chosen in the menu.
    case menuMode(Int)
    case pinyinMode(english: Bool)
}
