import AppKit

struct Preferences {
    var pinyinEnglishMode = false
    var pinyinBarPreeditEnabled = false
    var pinyinFuzzyEnabled = true
}

enum PushToTalkHotkey { case leftShift, rightShift, other }
struct PinyinKeyEvent { init(_ event: NSEvent) {} }
struct PinyinCandidate: Equatable { let word: String }

final class RimeRuntime: @unchecked Sendable {
    static let shared: Result<RimeRuntime, Error> = .success(RimeRuntime())
}

@MainActor
final class RimePinyinSession {
    static var created: [RimePinyinSession] = []

    var englishMode: Bool
    var fuzzyEnabled: Bool
    var isComposing = false
    var markedText = ""
    var markedCaret = 0
    var markedHighlight = NSRange(location: 0, length: 0)
    var candidates: [PinyinCandidate] = []
    var highlighted = 0
    var showsCandidates: Bool { !candidates.isEmpty }
    var preeditDisplay: String { markedText }
    var onModeChange: ((Bool) -> Void)?
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
    func setEnglishMode(_ enabled: Bool) { englishMode = enabled; onModeChange?(enabled) }
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
        leaseIdentity()
        pendingCommitAndClientIsolation()
        preferenceSynchronization()
        composingSessionsAreNotEvicted()
        print("PASS: IME client leases, pending commit acknowledgement, client isolation, preference sync")
    }

    static func leaseIdentity() {
        let a = NSObject()
        let b = NSObject()
        var state = IMEClientLeaseState()

        let first = state.bind(a)
        precondition(first.changed && state.lease(matching: a) == first.id)
        let same = state.bind(a)
        precondition(!same.changed && same.id == first.id)
        let renewed = state.bind(a, renew: true)
        precondition(renewed.changed && renewed.id != first.id)
        let second = state.bind(b)
        precondition(second.changed && state.lease(matching: a) == renewed.id)
        precondition(state.lease(matching: b) == second.id)
        let returned = state.bind(a)
        precondition(returned.changed && returned.id == renewed.id,
                     "returning to a live client must resume its own session")
        _ = state.bind(b)
        precondition(state.invalidate(renewed.id), "the stale client's own lease should close")
        precondition(state.id == second.id && state.lease(matching: b) == second.id,
                     "closing stale A must not invalidate current B")
        let resumed = state.bind(a)
        precondition(resumed.changed && resumed.id != renewed.id,
                     "a client invalidated by deactivation must receive a fresh lease")
        _ = state.bind(b)
        precondition(state.invalidate(second.id) && state.id == nil)
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
        engine.applyPreferences(Preferences(pinyinEnglishMode: true))
        precondition(sessionB.englishMode)
        precondition(!sessionA.englishMode)
        manager.currentLease = a
        engine.switchClient(to: a)
        precondition(sessionA.englishMode, "an inactive session must adopt the saved mode when it becomes current")
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
