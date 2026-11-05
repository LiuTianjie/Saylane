import Foundation

// Google / GitHub sign-in opens a tab in the person's browser and waits on a loopback listener
// (Sources/Membership/LoopbackOAuth.swift). A URLSession request stands in for the browser;
// nothing here opens one.

func check(_ condition: Bool, _ name: String) {
    if !condition { print("FAILED: \(name)"); exit(1) }
}

final class OpenedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ url: URL) { lock.withLock { self.url = url } }
    func wait() async throws -> URL {
        for _ in 0..<200 {
            if let url = lock.withLock({ self.url }) { return url }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("FAILED: the browser was never opened"); exit(1)
    }
}

func visit(_ suffix: String) async throws -> (URL, String) {
    let opened = OpenedURL()
    let flow = Task {
        try await LoopbackOAuth.run(productName: "Saylane", timeout: 10, open: { opened.set($0) }) { redirect in
            URL(string: "https://example.test/authorize?redirect_to=\(redirect.absoluteString)")!
        }
    }
    let authorize = try await opened.wait()
    let redirect = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_to" }!.value!
    check(redirect.hasPrefix("http://127.0.0.1:") && redirect.hasSuffix("/linkshell/callback"), "listener on loopback")
    let (_, notFound) = try await URLSession.shared.data(from: URL(string: redirect.replacingOccurrences(of: "/linkshell/callback", with: "/other"))!)
    check((notFound as? HTTPURLResponse)?.statusCode == 404, "other paths 404")
    let (body, response) = try await URLSession.shared.data(from: URL(string: redirect + suffix)!)
    check((response as? HTTPURLResponse)?.statusCode == 200, "callback page served")
    return (try await flow.value, String(decoding: body, as: UTF8.self))
}

@main
enum LoopbackOAuthTests {
    static func main() async throws {
        let config = MembershipConfiguration(
            supabaseURL: URL(string: "https://example.supabase.co")!, publishableKey: "sb_publishable_x",
            itoolURL: URL(string: "https://itool.tech")!
        )
        let client = AccountClient(configuration: config)
        let built = try client.authorizeURL(provider: "github", codeChallenge: "abc", redirect: URL(string: "http://127.0.0.1:5555/linkshell/callback")!)
        let query = URLComponents(url: built, resolvingAgainstBaseURL: false)!.queryItems!
        let value = { (name: String) in query.first { $0.name == name }?.value }
        check(built.path == "/auth/v1/authorize", "authorize path")
        check(value("redirect_to") == "http://127.0.0.1:5555/linkshell/callback", "loopback redirect")
        check(value("code_challenge") == "abc" && value("code_challenge_method") == "s256", "PKCE challenge")
        check(value("scopes") == "read:user user:email", "GitHub email scope")

        let (ok, okPage) = try await visit("?code=one-time")
        check(try AccountClient.authCode(from: ok) == "one-time", "code delivered")
        check(okPage.contains("已完成授权"), "success page")

        let (denied, _) = try await visit("?error=access_denied")
        do { _ = try AccountClient.authCode(from: denied); check(false, "denial must throw") }
        catch AccountError.cancelled {}

        let (failed, _) = try await visit("?error_code=bad_oauth_state&error_description=State%20expired")
        do { _ = try AccountClient.authCode(from: failed); check(false, "error_code must throw") }
        catch let AccountError.rejected(message) { check(message == "State expired", "provider message kept") }

        do {
            _ = try await LoopbackOAuth.run(productName: "Saylane", timeout: 0.3, open: { _ in }) { $0 }
            check(false, "must time out")
        } catch LoopbackOAuthError.timedOut {}

        let waiting = Task { try await LoopbackOAuth.run(productName: "Saylane", timeout: 10, open: { _ in }) { $0 } }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        do { _ = try await waiting.value; check(false, "must cancel") }
        catch LoopbackOAuthError.cancelled {}

        print("loopback oauth: ok")
    }
}
