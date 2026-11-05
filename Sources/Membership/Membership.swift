import Foundation

/// What needs an iTool membership and what never does. Dictation, pinyin and
/// translating while speaking work without an account; 所见即译 and AI editing
/// are part of the iTool yearly membership.
enum MembershipFeature: String, CaseIterable, Sendable {
    case dictation
    case pinyin
    case voiceTranslation
    case translateAnywhere
    case aiPolish

    var requiresMembership: Bool {
        switch self {
        case .dictation, .pinyin, .voiceTranslation: return false
        case .translateAnywhere, .aiPolish: return true
        }
    }
}

enum MembershipTier: String, Codable, Equatable, Sendable {
    case free, monthly, yearly
    init(wire: String?) { self = MembershipTier(rawValue: wire ?? "") ?? .free }
}

/// A signed-in iTool (Supabase) account. Stored in the Keychain, never in preferences.
struct AccountSession: Codable, Equatable, Sendable {
    var userID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
    var provider: String?

    func isExpired(at now: Date) -> Bool { expiresAt.timeIntervalSince(now) < 60 }
}

/// The last answer the server gave about Saylane, with the two clocks it was read against.
struct EntitlementRecord: Codable, Equatable, Sendable {
    var userID: String
    var active: Bool
    var tier: MembershipTier
    var validUntil: Date?
    var memberUntil: Date?
    var yearlyUntil: Date?
    /// The server's clock at the check.
    var serverTime: Date
    /// This Mac's clock at the check.
    var checkedAt: Date
}

enum MembershipAccess: Equatable, Sendable {
    case signedOut
    /// The membership features may be used.
    case active(validUntil: Date?, checkedAt: Date)
    /// Signed in, and the server said this account does not include Saylane.
    case notIncluded(MembershipTier)
    /// Signed in, with no answer that can be relied on right now.
    case unverified(UnverifiedReason)

    enum UnverifiedReason: Equatable, Sendable {
        case neverChecked
        case offlineTooLong
        case expired
        case clockChanged
    }

    var allowsMembershipFeatures: Bool {
        if case .active = self { return true }
        return false
    }
}

/// The offline rule, as pure functions of the stored state and the clock.
enum MembershipPolicy {
    /// After a successful check the features keep working offline for at most this long.
    static let offlineGrace: TimeInterval = 7 * 24 * 3600
    static let revalidateInterval: TimeInterval = 24 * 3600
    /// Clocks drift; only a step back larger than this counts as the clock being set back.
    static let clockTolerance: TimeInterval = 5 * 60

    static func access(session: AccountSession?, record: EntitlementRecord?, now: Date, highWater: Date?) -> MembershipAccess {
        guard let session else { return .signedOut }
        guard let record, record.userID == session.userID else { return .unverified(.neverChecked) }
        // An explicit "no" holds offline too: it is never extended by a grace period.
        guard record.active else { return .notIncluded(record.tier) }
        let elapsed = now.timeIntervalSince(record.checkedAt)
        if elapsed < -clockTolerance { return .unverified(.clockChanged) }
        if let highWater, now.timeIntervalSince(highWater) < -clockTolerance { return .unverified(.clockChanged) }
        if elapsed > offlineGrace { return .unverified(.offlineTooLong) }
        if let validUntil = record.validUntil,
           record.serverTime.addingTimeInterval(max(elapsed, 0)) >= validUntil {
            return .unverified(.expired)
        }
        return .active(validUntil: record.validUntil, checkedAt: record.checkedAt)
    }

    static func allows(_ feature: MembershipFeature, _ access: MembershipAccess) -> Bool {
        !feature.requiresMembership || access.allowsMembershipFeatures
    }

    /// Whether the stored answer is old enough (or the clock odd enough) to ask again.
    static func needsRevalidation(record: EntitlementRecord?, now: Date) -> Bool {
        guard let record else { return true }
        let elapsed = now.timeIntervalSince(record.checkedAt)
        return elapsed >= revalidateInterval || elapsed < -clockTolerance
    }

    /// The latest time this Mac's clock has shown. It only moves forward.
    static func advance(highWater: Date?, to now: Date) -> Date {
        guard let highWater else { return now }
        return max(highWater, now)
    }
}

/// Where the iTool account lives. The publishable key is public; it identifies
/// the project, it does not grant anything.
struct MembershipConfiguration: Sendable {
    var supabaseURL: URL?
    var publishableKey: String
    var itoolURL: URL
    static let product = "saylane"

    static func from(bundle: Bundle) -> MembershipConfiguration {
        let url = (bundle.object(forInfoDictionaryKey: "SaylaneSupabaseURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (bundle.object(forInfoDictionaryKey: "SaylaneSupabasePublishableKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return MembershipConfiguration(supabaseURL: URL(string: url), publishableKey: key, itoolURL: URL(string: "https://itool.tech")!)
    }

    var isConfigured: Bool { supabaseURL != nil && !publishableKey.isEmpty }
    var authBase: URL? { supabaseURL?.appending(path: "auth/v1") }

    /// The membership page in the user's language; it says where the visitor came from.
    static func purchaseURL(preferredLanguages: [String] = Locale.preferredLanguages) -> URL {
        let locale = preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
        return URL(string: "https://itool.tech/\(locale)/pro?from=saylane")!
    }
}

enum AccountError: LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case invalidCallback
    case rejected(String)
    case network

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "这个版本没有配置登录。")
        case .cancelled: return String(localized: "已取消登录。")
        case .invalidCallback: return String(localized: "登录没有完成，请再试一次。")
        case .rejected(let message): return message
        case .network: return String(localized: "连不上 iTool，请检查网络后再试。")
        }
    }
}

// MARK: - Wire formats

enum EntitlementResponse: Equatable, Sendable {
    case verdict(EntitlementRecord)
    case loginRequired
    /// Not an answer: the network, a 5xx, or a route that is not there.
    case unavailable
}

enum RefreshOutcome: Equatable, Sendable {
    case refreshed(AccountSession)
    /// The refresh token is no longer valid: sign out.
    case signedOut
    /// Keep the old token and try later.
    case unavailable
}

enum MembershipWire {
    static func parseEntitlement(status: Int, data: Data, userID: String, now: Date) -> EntitlementResponse {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 401 || (json?["code"] as? String) == "login_required" { return .loginRequired }
        guard status == 200, let json, json["ok"] as? Bool == true, let active = json["active"] as? Bool else {
            return .unavailable
        }
        let record = EntitlementRecord(
            userID: userID,
            active: active,
            tier: MembershipTier(wire: json["tier"] as? String),
            validUntil: date(json["valid_until"]),
            memberUntil: date(json["member_until"]),
            yearlyUntil: date(json["yearly_until"]),
            serverTime: date(json["server_time"]) ?? now,
            checkedAt: now)
        return .verdict(record)
    }

    static func parseRefresh(status: Int, data: Data, previous: AccountSession, now: Date) -> RefreshOutcome {
        if status == 400 || status == 401 { return .signedOut }
        guard (200..<300).contains(status) else { return .unavailable }
        guard let session = try? parseSession(data: data, now: now, fallbackProvider: previous.provider) else { return .unavailable }
        // A refresh never turns one account into another.
        guard session.userID == previous.userID else { return .signedOut }
        var result = session
        if result.email == nil { result.email = previous.email }
        return .refreshed(result)
    }

    struct MalformedSession: Error {}

    static func parseSession(data: Data, now: Date, fallbackProvider: String?) throws -> AccountSession {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty,
              let refresh = json["refresh_token"] as? String, !refresh.isEmpty,
              let user = json["user"] as? [String: Any],
              let id = user["id"] as? String, UUID(uuidString: id) != nil else { throw MalformedSession() }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let identities = user["identities"] as? [[String: Any]]
        let provider = (identities?.first?["provider"] as? String)
            ?? ((user["app_metadata"] as? [String: Any])?["provider"] as? String) ?? fallbackProvider
        return AccountSession(userID: id.lowercased(), accessToken: access, refreshToken: refresh,
                              expiresAt: now.addingTimeInterval(expiresIn), email: user["email"] as? String, provider: provider)
    }

    /// Postgres writes timestamps with up to six fractional digits and an offset.
    static func date(_ value: Any?) -> Date? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        if text.hasSuffix("Z") { text = String(text.dropLast()) + "+00:00" }
        // Keep at most three fractional digits, which the formatter reads.
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let digits = text[text.index(after: dot)..<end]
            text = String(text[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + String(text[end...])
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
