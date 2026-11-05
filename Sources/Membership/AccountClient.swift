import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security

protocol MembershipTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionMembershipTransport: MembershipTransport {
    func data(for request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Talks to the iTool account service: sign-in through Supabase Auth, token
/// refresh and the entitlement check through itool.tech first (it is reachable
/// where supabase.co is not), Supabase directly as the fallback.
struct AccountClient: Sendable {
    var configuration: MembershipConfiguration
    var transport: any MembershipTransport = URLSessionMembershipTransport()
    var now: @Sendable () -> Date = { Date() }

    // MARK: Sign-in

    func authorizeURL(provider: String, codeChallenge: String, redirect: URL) throws -> URL {
        guard let authBase = configuration.authBase, configuration.isConfigured else { throw AccountError.notConfigured }
        var components = URLComponents(url: authBase.appending(path: "authorize"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: redirect.absoluteString),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        // Without user:email a GitHub account with a private address has none.
        if provider == "github" { items.append(URLQueryItem(name: "scopes", value: "read:user user:email")) }
        components?.queryItems = items
        guard let url = components?.url else { throw AccountError.notConfigured }
        return url
    }

    /// Google / GitHub: the authorize page opens as a tab in the default browser, which comes
    /// back to a 127.0.0.1 listener (LoopbackOAuth.swift), as in LinkShell.
    func signIn(provider: String) async throws -> AccountSession {
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(verifier)
        _ = try authorizeURL(provider: provider, codeChallenge: challenge, redirect: URL(string: "http://127.0.0.1/")!)
        let client = self
        let callback: URL
        do {
            callback = try await LoopbackOAuth.run(productName: "Saylane") { redirect in
                (try? client.authorizeURL(provider: provider, codeChallenge: challenge, redirect: redirect)) ?? redirect
            }
        } catch LoopbackOAuthError.cancelled {
            throw AccountError.cancelled
        } catch LoopbackOAuthError.timedOut {
            throw AccountError.rejected(String(localized: "登录超时，请再试一次。"))
        } catch {
            throw AccountError.invalidCallback
        }
        await MainActor.run { NSApplication.shared.activate() }
        let code = try Self.authCode(from: callback)
        return try await token(grant: "pkce", body: ["auth_code": code, "code_verifier": verifier], fallbackProvider: provider)
    }

    func signIn(email: String, password: String) async throws -> AccountSession {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else { throw AccountError.rejected(String(localized: "请输入邮箱和密码。")) }
        return try await token(grant: "password", body: ["email": email, "password": password], fallbackProvider: "email")
    }

    private func token(grant: String, body: [String: String], fallbackProvider: String?) async throws -> AccountSession {
        guard let authBase = configuration.authBase, configuration.isConfigured else { throw AccountError.notConfigured }
        var components = URLComponents(url: authBase.appending(path: "token"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var request = URLRequest(url: components?.url ?? authBase)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, status: Int
        do { (data, status) = try await transport.data(for: request) } catch { throw AccountError.network }
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["error_code"] as? String ?? json?["error"] as? String
            if code == "invalid_credentials" || code == "invalid_grant" {
                throw AccountError.rejected(String(localized: "邮箱或密码不对。"))
            }
            if code == "email_not_confirmed" {
                throw AccountError.rejected(String(localized: "这个邮箱还没有验证，请先打开验证邮件。"))
            }
            let message = json?["error_description"] as? String ?? json?["msg"] as? String ?? String(localized: "登录没有完成，请再试一次。")
            throw AccountError.rejected(message)
        }
        do { return try MembershipWire.parseSession(data: data, now: now(), fallbackProvider: fallbackProvider) } catch { throw AccountError.invalidCallback }
    }

    func signOut(_ session: AccountSession) async {
        guard let authBase = configuration.authBase, configuration.isConfigured else { return }
        // Only this sign-in: without the scope Supabase ends every session of the
        // account, on itool.tech and in the other iTool apps too.
        var components = URLComponents(url: authBase.appending(path: "logout"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "scope", value: "local")]
        var request = URLRequest(url: components?.url ?? authBase.appending(path: "logout"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await transport.data(for: request)
    }

    // MARK: Refresh

    func refresh(_ session: AccountSession) async -> RefreshOutcome {
        var request = URLRequest(url: configuration.itoolURL.appending(path: "api/linkshell/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])
        if let (data, status) = try? await transport.data(for: request) {
            let outcome = MembershipWire.parseRefresh(status: status, data: data, previous: session, now: now())
            if outcome != .unavailable { return outcome }
        }
        // itool.tech did not answer: Supabase directly.
        guard let authBase = configuration.authBase, configuration.isConfigured else { return .unavailable }
        var components = URLComponents(url: authBase.appending(path: "token"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var direct = URLRequest(url: components?.url ?? authBase)
        direct.httpMethod = "POST"
        direct.timeoutInterval = 12
        direct.setValue("application/json", forHTTPHeaderField: "Content-Type")
        direct.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        direct.httpBody = request.httpBody
        guard let (data, status) = try? await transport.data(for: direct) else { return .unavailable }
        return MembershipWire.parseRefresh(status: status, data: data, previous: session, now: now())
    }

    // MARK: Entitlement

    func entitlement(_ session: AccountSession) async -> EntitlementResponse {
        var components = URLComponents(url: configuration.itoolURL.appending(path: "api/membership/entitlement"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "product", value: MembershipConfiguration.product)]
        var request = URLRequest(url: components?.url ?? configuration.itoolURL)
        request.timeoutInterval = 12
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if let (data, status) = try? await transport.data(for: request) {
            let response = MembershipWire.parseEntitlement(status: status, data: data, userID: session.userID, now: now())
            if response != .unavailable { return response }
        }
        // itool.tech did not answer: the same function through Supabase directly.
        guard let base = configuration.supabaseURL, configuration.isConfigured else { return .unavailable }
        var rpc = URLRequest(url: base.appending(path: "rest/v1/rpc/itool_entitlement"))
        rpc.httpMethod = "POST"
        rpc.timeoutInterval = 12
        rpc.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rpc.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        rpc.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        rpc.httpBody = try? JSONSerialization.data(withJSONObject: ["p_product": MembershipConfiguration.product])
        guard let (data, status) = try? await transport.data(for: rpc) else { return .unavailable }
        return MembershipWire.parseEntitlement(status: status, data: data, userID: session.userID, now: now())
    }

    // MARK: PKCE

    static func authCode(from url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value ?? items.first(where: { $0.name == "error_code" })?.value {
            if error == "access_denied" || error == "no_code" { throw AccountError.cancelled }
            throw AccountError.rejected(items.first(where: { $0.name == "error_description" })?.value ?? error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw AccountError.invalidCallback }
        return code
    }

    static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func codeChallenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension AccountClient: MembershipService {}

// MARK: - Storage

/// The session, the last good answer and the clock high-water mark, each its
/// own Keychain item. Reads never show a Keychain dialog.
final class KeychainMembershipStore: MembershipStoring, @unchecked Sendable {
    let service: String
    init(service: String = "com.saylane.membership" + TestHome.suffix) { self.service = service }

    func loadSession() -> AccountSession? { load("session") }
    func saveSession(_ session: AccountSession?) { save(session, "session") }
    func loadRecord() -> EntitlementRecord? { load("entitlement") }
    func saveRecord(_ record: EntitlementRecord?) { save(record, "entitlement") }
    func loadHighWater() -> Date? { load("clock") }
    func saveHighWater(_ date: Date) { save(date, "clock") }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func load<T: Decodable>(_ account: String) -> T? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T?, _ account: String) {
        guard let value else { SecItemDelete(query(account) as CFDictionary); return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(account)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}
