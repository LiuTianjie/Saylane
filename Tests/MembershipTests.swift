import Foundation

/// The membership gate and its offline rule: what is free stays free, what
/// needs the yearly membership follows the last answer the server gave.
final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class ScriptedService: MembershipService, @unchecked Sendable {
    var entitlements: [EntitlementResponse] = []
    var refreshes: [RefreshOutcome] = []
    var entitlementCalls: [String] = []
    var refreshCalls = 0
    var signOuts = 0

    func refresh(_ session: AccountSession) async -> RefreshOutcome {
        refreshCalls += 1
        return refreshes.isEmpty ? .unavailable : refreshes.removeFirst()
    }
    func entitlement(_ session: AccountSession) async -> EntitlementResponse {
        entitlementCalls.append(session.accessToken)
        return entitlements.isEmpty ? .unavailable : entitlements.removeFirst()
    }
    func signOut(_ session: AccountSession) async { signOuts += 1 }
}

let day: TimeInterval = 24 * 3600
let start = Date(timeIntervalSince1970: 1_800_000_000)
let userID = "4a6f2d1e-0000-4000-8000-000000000001"

func session(_ token: String = "t1", expiresIn: TimeInterval = 3600, at time: Date = start, user: String = userID) -> AccountSession {
    AccountSession(userID: user, accessToken: token, refreshToken: "r-\(token)", expiresAt: time.addingTimeInterval(expiresIn),
                   email: "a@example.com", provider: "email")
}

func record(active: Bool, tier: MembershipTier = .yearly, validFor: TimeInterval? = 300 * day, at time: Date = start, user: String = userID) -> EntitlementRecord {
    EntitlementRecord(userID: user, active: active, tier: tier, validUntil: validFor.map { time.addingTimeInterval($0) },
                      memberUntil: nil, yearlyUntil: nil, serverTime: time, checkedAt: time)
}

func check(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@MainActor func policyTests() {
    let free: [MembershipFeature] = [.dictation, .pinyin, .voiceTranslation]
    let gated: [MembershipFeature] = [.translateAnywhere, .aiPolish]
    let every: [MembershipAccess] = [.signedOut, .notIncluded(.free), .notIncluded(.monthly), .unverified(.neverChecked),
                                     .unverified(.offlineTooLong), .unverified(.clockChanged), .unverified(.expired),
                                     .active(validUntil: nil, checkedAt: start)]
    for access in every {
        for feature in free { check(MembershipPolicy.allows(feature, access), "\(feature) is free in \(access)") }
        for feature in gated {
            check(MembershipPolicy.allows(feature, access) == access.allowsMembershipFeatures, "\(feature) follows \(access)")
        }
    }
    check(Set(MembershipFeature.allCases.filter(\.requiresMembership)) == Set(gated), "exactly the two features need the membership")

    let s = session()
    check(MembershipPolicy.access(session: nil, record: record(active: true), now: start, highWater: nil) == .signedOut, "no session is signed out")
    check(MembershipPolicy.access(session: s, record: nil, now: start, highWater: nil) == .unverified(.neverChecked), "never checked")
    check(MembershipPolicy.access(session: s, record: record(active: true, user: "other"), now: start, highWater: nil) == .unverified(.neverChecked),
          "another account's answer does not count")
    check(MembershipPolicy.access(session: s, record: record(active: false, tier: .monthly), now: start, highWater: nil) == .notIncluded(.monthly),
          "explicit no")
    // Offline: up to seven days after the last good answer.
    let yes = record(active: true)
    check(MembershipPolicy.access(session: s, record: yes, now: start + 6.9 * day, highWater: nil).allowsMembershipFeatures, "within 7 days")
    check(MembershipPolicy.access(session: s, record: yes, now: start + 7.1 * day, highWater: nil) == .unverified(.offlineTooLong), "after 7 days")
    // Never past valid_until, counted on the server's clock.
    let short = record(active: true, validFor: 2 * day)
    check(MembershipPolicy.access(session: s, record: short, now: start + 1.9 * day, highWater: nil).allowsMembershipFeatures, "before valid_until")
    check(MembershipPolicy.access(session: s, record: short, now: start + 2.1 * day, highWater: nil) == .unverified(.expired), "past valid_until")
    var skewed = short
    skewed.serverTime = start + 1.5 * day   // this Mac runs a day and a half behind the server
    check(MembershipPolicy.access(session: s, record: skewed, now: start + 0.6 * day, highWater: nil) == .unverified(.expired),
          "valid_until is judged on the server's clock")
    let open = record(active: true, validFor: nil)
    check(MembershipPolicy.access(session: s, record: open, now: start + 3 * day, highWater: nil).allowsMembershipFeatures, "no end date")
    // Clock rollback.
    check(MembershipPolicy.access(session: s, record: yes, now: start - 3600, highWater: nil) == .unverified(.clockChanged),
          "the clock set back before the check")
    check(MembershipPolicy.access(session: s, record: yes, now: start + 2 * day, highWater: start + 5 * day) == .unverified(.clockChanged),
          "the clock set back after having been later")
    check(MembershipPolicy.access(session: s, record: yes, now: start + 2 * day, highWater: start + 2 * day + 60).allowsMembershipFeatures,
          "a minute of drift is not a rollback")
    check(MembershipPolicy.advance(highWater: start + 10, to: start) == start + 10, "the high-water mark never goes back")
    check(MembershipPolicy.needsRevalidation(record: yes, now: start + 23 * 3600) == false, "a fresh answer is kept")
    check(MembershipPolicy.needsRevalidation(record: yes, now: start + 25 * 3600), "asked again after a day")
}

func wireTests() {
    let body = #"{"ok":true,"product":"saylane","required_tier":"yearly","active":true,"valid_until":"2027-11-05T10:00:00.123456+00:00","tier":"yearly","member_until":"2027-11-05T10:00:00+00:00","yearly_until":"2027-11-05T10:00:00+00:00","server_time":"2026-11-05T10:37:32.495123+00:00"}"#
    guard case .verdict(let verdict) = MembershipWire.parseEntitlement(status: 200, data: Data(body.utf8), userID: userID, now: start) else {
        check(false, "a 200 is a verdict"); return
    }
    check(verdict.active && verdict.tier == .yearly && verdict.userID == userID && verdict.checkedAt == start, "fields read")
    check(verdict.validUntil == MembershipWire.date("2027-11-05T10:00:00.123Z"), "microseconds are read")
    check(abs(verdict.serverTime.timeIntervalSince1970 - 1_793_875_052.495) < 0.01, "server time read")
    let monthly = #"{"ok":true,"active":false,"tier":"monthly","valid_until":null,"server_time":"2026-11-05T10:37:32Z"}"#
    if case .verdict(let no) = MembershipWire.parseEntitlement(status: 200, data: Data(monthly.utf8), userID: userID, now: start) {
        check(!no.active && no.tier == .monthly && no.validUntil == nil, "monthly is not active for Saylane")
    } else { check(false, "inactive is still a verdict") }
    check(MembershipWire.parseEntitlement(status: 401, data: Data(#"{"ok":false,"code":"login_required"}"#.utf8), userID: userID, now: start) == .loginRequired, "401")
    for status in [404, 500, 502, 503, 0] {
        check(MembershipWire.parseEntitlement(status: status, data: Data(), userID: userID, now: start) == .unavailable, "\(status) is not an answer")
    }
    check(MembershipWire.parseEntitlement(status: 200, data: Data("<html>".utf8), userID: userID, now: start) == .unavailable, "garbage")

    let previous = session()
    let refreshed = #"{"access_token":"t2","refresh_token":"r2","expires_in":3600,"user":{"id":"4A6F2D1E-0000-4000-8000-000000000001","email":"a@example.com"}}"#
    if case .refreshed(let next) = MembershipWire.parseRefresh(status: 200, data: Data(refreshed.utf8), previous: previous, now: start) {
        check(next.accessToken == "t2" && next.refreshToken == "r2" && next.userID == userID && next.provider == "email", "refresh read")
    } else { check(false, "refresh 200") }
    check(MembershipWire.parseRefresh(status: 400, data: Data(#"{"code":"invalid_grant"}"#.utf8), previous: previous, now: start) == .signedOut, "400 signs out")
    check(MembershipWire.parseRefresh(status: 401, data: Data(), previous: previous, now: start) == .signedOut, "401 signs out")
    check(MembershipWire.parseRefresh(status: 503, data: Data(), previous: previous, now: start) == .unavailable, "5xx keeps the token")
    let other = #"{"access_token":"t2","refresh_token":"r2","user":{"id":"4a6f2d1e-0000-4000-8000-000000000002"}}"#
    check(MembershipWire.parseRefresh(status: 200, data: Data(other.utf8), previous: previous, now: start) == .signedOut, "never another account")
    check(MembershipConfiguration.purchaseURL(preferredLanguages: ["zh-Hans"]).absoluteString == "https://itool.tech/zh/pro?from=saylane", "zh purchase")
    check(MembershipConfiguration.purchaseURL(preferredLanguages: ["en"]).absoluteString == "https://itool.tech/en/pro?from=saylane", "en purchase")
}

@MainActor func controllerTests() async {
    // Signed in, checked: both features open; dictation never asks.
    var clock = Clock(start)
    var service = ScriptedService()
    service.entitlements = [.verdict(record(active: true))]
    var store = MemoryMembershipStore(session: session())
    var c = MembershipController(store: store, service: service, now: { clock.now })
    check(!c.gate(.translateAnywhere) && c.gate(.dictation), "before the first check only free features")
    await c.revalidate(force: true)
    check(c.gate(.translateAnywhere) && c.gate(.aiPolish), "active after the check")
    check(store.loadRecord()?.active == true, "the answer is kept in the store")

    // Offline: the stored answer carries over a relaunch for seven days, not longer.
    clock.now = start + 3 * day
    c = MembershipController(store: store, service: service, now: { clock.now })
    await c.revalidate()
    check(c.gate(.translateAnywhere), "offline on day 3 after a relaunch")
    check(c.message != nil, "the failed check is said")
    clock.now = start + 7.5 * day
    check(!c.gate(.translateAnywhere) && c.gate(.dictation) && c.gate(.voiceTranslation), "offline on day 8: gated off, dictation untouched")

    // Back online: a new yes opens it again; an explicit no closes it at once.
    service.entitlements = [.verdict(record(active: true, at: clock.now))]
    await c.revalidate(force: true)
    check(c.gate(.aiPolish), "a new answer opens it again")
    clock.now += 60
    service.entitlements = [.verdict(record(active: false, tier: .free, validFor: nil, at: clock.now))]
    await c.revalidate(force: true)
    check(!c.gate(.aiPolish) && c.access == .notIncluded(.free), "an explicit no revokes immediately")
    check(c.gate(.dictation) && c.gate(.pinyin), "free features stay")

    // Clock set back after a check.
    clock = Clock(start)
    service = ScriptedService()
    service.entitlements = [.verdict(record(active: true))]
    store = MemoryMembershipStore(session: session())
    c = MembershipController(store: store, service: service, now: { clock.now })
    await c.revalidate(force: true)
    clock.now = start + 2 * day
    check(c.gate(.translateAnywhere), "two days later")
    clock.now = start + 1 * day
    check(!c.gate(.translateAnywhere) && c.access == .unverified(.clockChanged), "setting the clock back a day locks the features")
    c = MembershipController(store: store, service: service, now: { clock.now })
    check(!c.gate(.translateAnywhere), "and a relaunch does not forget it")

    // 401: refresh once and retry with the new token.
    clock = Clock(start)
    service = ScriptedService()
    service.entitlements = [.loginRequired, .verdict(record(active: true))]
    service.refreshes = [.refreshed(session("t2"))]
    store = MemoryMembershipStore(session: session("t1"))
    c = MembershipController(store: store, service: service, now: { clock.now })
    await c.revalidate(force: true)
    check(service.entitlementCalls == ["t1", "t2"] && service.refreshCalls == 1, "refreshed once and retried")
    check(c.gate(.translateAnywhere) && store.loadSession()?.accessToken == "t2", "the new token is stored")

    // 401 again after the refresh: signed out.
    service = ScriptedService()
    service.entitlements = [.loginRequired, .loginRequired]
    service.refreshes = [.refreshed(session("t3"))]
    c = MembershipController(store: store, service: service, now: { clock.now })
    clock.now += 60
    await c.revalidate(force: true)
    check(!c.isSignedIn && store.loadSession() == nil && store.loadRecord() == nil, "a second 401 signs out")

    // Refresh says invalid_grant: signed out. Refresh unavailable: the old state stays.
    service = ScriptedService()
    service.entitlements = [.loginRequired]
    service.refreshes = [.signedOut]
    store = MemoryMembershipStore(session: session(), record: record(active: true))
    c = MembershipController(store: store, service: service, now: { clock.now })
    await c.revalidate(force: true)
    check(!c.isSignedIn, "invalid_grant signs out")
    service = ScriptedService()
    service.entitlements = [.loginRequired]
    service.refreshes = [.unavailable]
    store = MemoryMembershipStore(session: session(), record: record(active: true))
    c = MembershipController(store: store, service: service, now: { clock.now })
    await c.revalidate(force: true)
    check(c.isSignedIn && c.gate(.translateAnywhere), "a refresh that cannot reach the server keeps the cached state")

    // An expired access token is refreshed before the check.
    clock = Clock(start)
    service = ScriptedService()
    service.refreshes = [.refreshed(session("fresh"))]
    service.entitlements = [.verdict(record(active: true))]
    store = MemoryMembershipStore(session: session("old", expiresIn: -10))
    c = MembershipController(store: store, service: service, now: { clock.now })
    await c.revalidate(force: true)
    check(service.entitlementCalls == ["fresh"], "expired token refreshed first")

    // Sign-out clears the cached answer; signing in as someone else does not inherit it.
    await c.signOut()
    check(!c.isSignedIn && store.loadRecord() == nil && service.signOuts == 1 && !c.gate(.aiPolish) && c.gate(.dictation), "sign-out clears")
    service.entitlements = [.verdict(record(active: false, tier: .monthly, validFor: nil, user: "4a6f2d1e-0000-4000-8000-000000000002"))]
    await c.signIn { session("b", user: "4a6f2d1e-0000-4000-8000-000000000002") }
    check(c.isSignedIn && c.access == .notIncluded(.monthly) && c.tier == .monthly, "a monthly member is not included")

    // A stored answer without a session (a sign-out that was interrupted) is dropped.
    store = MemoryMembershipStore(session: nil, record: record(active: true))
    c = MembershipController(store: store, service: ScriptedService(), now: { clock.now })
    check(store.loadRecord() == nil && !c.gate(.translateAnywhere), "orphaned answer dropped")

    // Without force, a day-old check is not repeated.
    clock = Clock(start)
    service = ScriptedService()
    service.entitlements = [.verdict(record(active: true))]
    store = MemoryMembershipStore(session: session())
    c = MembershipController(store: store, service: service, now: { clock.now })
    await c.revalidate(force: true)
    clock.now = start + 3600
    await c.revalidate()
    check(service.entitlementCalls.count == 1, "no second request within the day")
    clock.now = start + 25 * 3600
    await c.revalidate()
    check(service.entitlementCalls.count == 2, "asked again after 24 hours")
}

@main struct MembershipTests {
    static func main() async {
        await MainActor.run { policyTests() }
        wireTests()
        await controllerTests()
        print("membership tests passed")
    }
}
