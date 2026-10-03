import AppKit

struct BridgePinyinPreferences {
    var englishMode = false
    var fuzzy = true
    var barPreedit = false
    var keys = PinyinKeyOptions()
    var languageModel = false
}

enum PushToTalkHotkey { case leftShift, rightShift, other }
struct PinyinKeyEvent { var letter: Character? = nil; init(_ event: NSEvent) {} }
struct PinyinCandidate: Equatable { let word: String }

final class RimeRuntime: @unchecked Sendable {
    static let shared: Result<RimeRuntime, Error> = .success(RimeRuntime())
}

@MainActor
final class RimePinyinSession {
    static var created: [RimePinyinSession] = []

    var englishMode: Bool
    var fuzzyEnabled: Bool
    var keys = PinyinKeyOptions()
    var isComposing = false
    var markedText = ""
    var markedCaret = 0
    var markedHighlight = NSRange(location: 0, length: 0)
    var candidates: [PinyinCandidate] = []
    var highlighted = 0
    var showsCandidates: Bool { !candidates.isEmpty }
    var preeditDisplay: String { markedText }
    var onModeChange: ((Bool) -> Void)?
    var trace: (String, String) -> Void = { _, _ in }
    private(set) var selections = 0
    private var commitBuffer = ""

    init(runtime: RimeRuntime, englishMode: Bool, fuzzyEnabled: Bool) throws {
        self.englishMode = englishMode
        self.fuzzyEnabled = fuzzyEnabled
        Self.created.append(self)
    }

    func emitCommit(_ text: String) { commitBuffer += text }
    func takeCommit() -> String { defer { commitBuffer = "" }; return commitBuffer }
    func setFuzzyEnabled(_ enabled: Bool) -> Bool { fuzzyEnabled = enabled; return true }
    var reloads = 0
    @discardableResult func reloadSchema() -> Bool { reloads += 1; return true }
    func setEnglishMode(_ enabled: Bool) { englishMode = enabled }
    /// A Shift tap, as the real session reports it.
    func tapShift() { englishMode.toggle(); onModeChange?(englishMode) }
    func handle(_ event: PinyinKeyEvent, shiftToggleEnabled: Bool) -> Bool { false }
    func selectCandidate(at index: Int) { selections += 1 }
    func pageCandidates(_ delta: Int) {}
    func commit() {}
    func commitRaw() {}
    func cancel() { isComposing = false }
}

@MainActor
final class CandidateWindowController {
    static weak var last: CandidateWindowController?
    private var pick: ((Int) -> Void)?
    private var page: ((Int) -> Void)?
    init() { Self.last = self }
    func setOnPick(_ handler: @escaping (Int) -> Void) { pick = handler }
    func setOnPage(_ handler: @escaping (Int) -> Void) { page = handler }
    func update(candidates: [PinyinCandidate], highlight: Int, caret: NSRect?, preedit: String) {}
    func hide() {}
    func simulatePick(_ index: Int) { pick?(index) }
}

@MainActor
final class IMEManager {
    static let shared = IMEManager()
    var currentLease: UUID?
    var acceptsInsert = true
    private(set) var inserted: [(UUID, String)] = []
    private(set) var marked: [(UUID, String)] = []

    func reset() {
        currentLease = nil
        acceptsInsert = true
        inserted = []
        marked = []
    }
    func isCurrentLease(_ leaseID: UUID) -> Bool { currentLease == leaseID }
    func insertPinyin(_ text: String, leaseID: UUID) -> Bool {
        guard currentLease == leaseID, acceptsInsert else { return false }
        inserted.append((leaseID, text))
        return true
    }
    func setPinyinMarked(_ text: String, caret: Int?, highlight: NSRange, leaseID: UUID) -> Bool {
        guard currentLease == leaseID else { return false }
        marked.append((leaseID, text))
        return true
    }
    func caretScreenRect(leaseID: UUID) -> NSRect? { nil }
}

@main
struct PinyinEngineLeaseTests {
    @MainActor
    static func main() {
        pendingCommitAndClientIsolation()
        preferenceSynchronization()
        composingSessionsAreNotEvicted()
        print("PASS: pinyin sessions per IME lease, missing-session recovery, pending commit acknowledgement, client isolation, preference sync")
    }

    @MainActor
    static func pendingCommitAndClientIsolation() {
        let manager = IMEManager.shared
        manager.reset()
        RimePinyinSession.created = []
        let engine = PinyinEngine(runtime: .success(RimeRuntime()))
        let a = UUID()
        let b = UUID()

        manager.currentLease = a
        engine.switchClient(to: a)
        let sessionA = RimePinyinSession.created[0]
        sessionA.markedText = "client-a"
        sessionA.emitCommit("alpha")

        // A stale publication after B becomes current must write neither A's
        // marked text nor its pending commit into B.
        manager.currentLease = b
        engine.switchClient(to: a)
        CandidateWindowController.last?.simulatePick(0)
        precondition(manager.inserted.isEmpty)
        precondition(manager.marked.allSatisfy { $0.0 != b || $0.1 != "client-a" })
        precondition(sessionA.selections == 0, "a stale candidate action must not mutate another lease")

        // The commit was moved out of librime but remains queued by A's lease.
        manager.currentLease = a
        manager.acceptsInsert = false
        engine.switchClient(to: a)
        precondition(manager.inserted.isEmpty)
        manager.acceptsInsert = true
        engine.switchClient(to: a)
        precondition(manager.inserted.count == 1 && manager.inserted[0].0 == a && manager.inserted[0].1 == "alpha")
        engine.switchClient(to: a)
        precondition(manager.inserted.count == 1, "an acknowledged commit must not be inserted twice")

        // A key from a client whose activation the engine never saw (IMK attached
        // before the app finished launching) still gets a session of its own.
        let c = UUID()
        manager.currentLease = c
        let before = RimePinyinSession.created.count
        engine.ensureClient(c)
        precondition(RimePinyinSession.created.count == before + 1, "a key must create the missing session")
        engine.ensureClient(c)
        precondition(RimePinyinSession.created.count == before + 1, "an existing session is reused")
        engine.forgetClient(c)
        engine.ensureClient(c)
        precondition(RimePinyinSession.created.count == before + 2, "a forgotten client is recreated on its next key")
    }

    @MainActor
    static func preferenceSynchronization() {
        let manager = IMEManager.shared
        manager.reset()
        RimePinyinSession.created = []
        let engine = PinyinEngine(runtime: .success(RimeRuntime()))
        let a = UUID()
        let b = UUID()

        manager.currentLease = a
        engine.switchClient(to: a)
        let sessionA = RimePinyinSession.created[0]
        manager.currentLease = b
        engine.switchClient(to: b)
        let sessionB = RimePinyinSession.created[1]
        engine.applyPreferences(BridgePinyinPreferences(englishMode: true))
        precondition(sessionB.englishMode)
        precondition(!sessionA.englishMode)
        manager.currentLease = a
        engine.switchClient(to: a)
        precondition(sessionA.englishMode, "an inactive session must adopt the saved mode when it becomes current")

        // Only a Shift tap is reported as a switch; a mode pushed from the
        // settings is not sent back, so two quick taps cannot echo into the wrong mode.
        var reported: [Bool] = []
        engine.onEnglishModeChanged = { reported.append($0) }
        engine.applyPreferences(BridgePinyinPreferences(englishMode: false))
        precondition(!sessionA.englishMode && reported.isEmpty, "a pushed mode is not reported back (\(reported))")
        sessionA.tapShift()
        precondition(reported == [true] && engine.englishMode, "a Shift tap is reported (\(reported))")
        manager.currentLease = b
        engine.switchClient(to: b)
        precondition(sessionB.englishMode, "the other client follows the mode the tap chose")
        precondition(reported == [true], "following it is not another switch (\(reported))")
    }

    @MainActor
    static func composingSessionsAreNotEvicted() {
        let manager = IMEManager.shared
        manager.reset()
        RimePinyinSession.created = []
        let engine = PinyinEngine(runtime: .success(RimeRuntime()))
        var leases: [UUID] = []
        for _ in 0..<13 {
            let lease = UUID()
            leases.append(lease)
            manager.currentLease = lease
            engine.switchClient(to: lease)
            RimePinyinSession.created.last?.isComposing = true
        }
        let count = RimePinyinSession.created.count
        manager.currentLease = leases[0]
        engine.switchClient(to: leases[0])
        precondition(RimePinyinSession.created.count == count,
                     "evicting a composing client would lose its marked text")
    }
}
