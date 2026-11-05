import Foundation
import Observation

/// The calls the controller makes to the account service; `AccountClient` in
/// the product, a script in the tests.
protocol MembershipService: Sendable {
    func refresh(_ session: AccountSession) async -> RefreshOutcome
    func entitlement(_ session: AccountSession) async -> EntitlementResponse
    func signOut(_ session: AccountSession) async
}

protocol MembershipStoring: AnyObject, Sendable {
    func loadSession() -> AccountSession?
    func saveSession(_ session: AccountSession?)
    func loadRecord() -> EntitlementRecord?
    func saveRecord(_ record: EntitlementRecord?)
    func loadHighWater() -> Date?
    func saveHighWater(_ date: Date)
}

/// For tests and previews.
final class MemoryMembershipStore: MembershipStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AccountSession?
    private var record: EntitlementRecord?
    private var highWater: Date?
    init(session: AccountSession? = nil, record: EntitlementRecord? = nil, highWater: Date? = nil) {
        self.session = session; self.record = record; self.highWater = highWater
    }
    func loadSession() -> AccountSession? { lock.withLock { session } }
    func saveSession(_ session: AccountSession?) { lock.withLock { self.session = session } }
    func loadRecord() -> EntitlementRecord? { lock.withLock { record } }
    func saveRecord(_ record: EntitlementRecord?) { lock.withLock { self.record = record } }
    func loadHighWater() -> Date? { lock.withLock { highWater } }
    func saveHighWater(_ date: Date) { lock.withLock { highWater = date } }
}

/// The signed-in account and whether it includes Saylane's membership
/// features. Lives in the main program, the process that runs 所见即译 and AI
/// editing; the input method never needs it (docs/ARCHITECTURE.md §6b).
@MainActor @Observable
final class MembershipController {
    private(set) var session: AccountSession?
    private(set) var record: EntitlementRecord?
    private(set) var isChecking = false
    private(set) var isSigningIn = false
    /// The last thing that went wrong, said to the user in the account section.
    var message: String?
    /// Bumped whenever the clock is read, so views that show the access re-evaluate.
    private(set) var evaluatedAt: Date

    @ObservationIgnored private let store: any MembershipStoring
    @ObservationIgnored private let service: any MembershipService
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var highWater: Date?
    @ObservationIgnored private var lastForcedCheck: Date?

    init(store: any MembershipStoring, service: any MembershipService, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.service = service
        self.now = now
        session = store.loadSession()
        record = store.loadRecord()
        highWater = store.loadHighWater()
        evaluatedAt = now()
        if session == nil, record != nil { store.saveRecord(nil); record = nil }
    }

    /// For views: reads the clock, changes nothing.
    var access: MembershipAccess {
        _ = evaluatedAt
        return MembershipPolicy.access(session: session, record: record, now: now(), highWater: highWater)
    }

    /// For the place a feature starts. Free features never even read the account.
    func gate(_ feature: MembershipFeature) -> Bool {
        guard feature.requiresMembership else { return true }
        tick()
        return MembershipPolicy.allows(feature, access)
    }

    var isSignedIn: Bool { session != nil }
    var tier: MembershipTier { record?.userID == session?.userID ? record?.tier ?? .free : .free }

    // MARK: Checking

    /// Ask the server again. Without `force` only when the stored answer is a day old.
    func revalidate(force: Bool = false) async {
        guard var current = session, !isChecking else { return }
        let time = now()
        tick()
        if !force, !MembershipPolicy.needsRevalidation(record: record, now: time), access.allowsMembershipFeatures { return }
        // Activation of the app re-checks forcibly; not more than twice a minute.
        if force, let last = lastForcedCheck, time.timeIntervalSince(last) < 30, last <= time { return }
        if force { lastForcedCheck = time }
        isChecking = true
        defer { isChecking = false; tick() }

        var refreshed = false
        if current.isExpired(at: time) {
            switch await service.refresh(current) {
            case .refreshed(let next): current = next; adopt(next); refreshed = true
            case .signedOut: endSession(); return
            case .unavailable: break
            }
        }
        var response = await service.entitlement(current)
        if response == .loginRequired, !refreshed {
            switch await service.refresh(current) {
            case .refreshed(let next):
                current = next; adopt(next)
                response = await service.entitlement(current)
            case .signedOut:
                endSession(); return
            case .unavailable:
                // The token could not be renewed for now: keep what is known.
                message = String(localized: "暂时无法确认会员状态，稍后会自动重试。")
                return
            }
        }
        guard session?.userID == current.userID else { return }
        switch response {
        case .verdict(let verdict):
            record = verdict
            store.saveRecord(verdict)
            // The server has just confirmed the time: the high-water mark starts again from here.
            highWater = now()
            store.saveHighWater(highWater!)
            message = nil
        case .loginRequired:
            endSession()
            message = String(localized: "登录已失效，请重新登录。")
        case .unavailable:
            message = String(localized: "暂时无法确认会员状态，稍后会自动重试。")
        }
    }

    // MARK: Signing in and out

    func signIn(_ perform: () async throws -> AccountSession) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        message = nil
        defer { isSigningIn = false }
        do {
            let next = try await perform()
            if session?.userID != next.userID { record = nil; store.saveRecord(nil) }
            adopt(next)
            lastForcedCheck = nil
            await revalidate(force: true)
        } catch AccountError.cancelled {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    func signOut() async {
        guard let session else { return }
        endSession()
        await service.signOut(session)
    }

    private func adopt(_ next: AccountSession) {
        session = next
        store.saveSession(next)
    }

    private func endSession() {
        session = nil
        record = nil
        store.saveSession(nil)
        store.saveRecord(nil)
        lastForcedCheck = nil
    }

    private func tick() {
        let time = now()
        evaluatedAt = time
        let next = MembershipPolicy.advance(highWater: highWater, to: time)
        if next != highWater {
            highWater = next
            store.saveHighWater(next)
        }
    }
}
