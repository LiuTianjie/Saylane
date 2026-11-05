import AppKit
import AuthenticationServices

/// Google and GitHub sign-in in the system's web authentication sheet.
///
/// AuthenticationServices calls the completion handler on one of its own XPC
/// reply queues, and may ask for the presentation anchor off the main thread.
/// Neither may be isolated to the main actor: a closure written inside a
/// main-actor context is inferred main-actor isolated, and Swift 6 checks that
/// on entry and traps when it is called anywhere else. So the handler is made
/// in a nonisolated function, only resumes the continuation and hops to the
/// main actor for its own bookkeeping, and the anchor is chosen on the main
/// actor before the session starts.
@MainActor
enum OAuthBrowser {
    private static var current: ASWebAuthenticationSession?
    /// The session holds its presentation context provider weakly.
    private static var anchor: OAuthAnchor?

    static func open(_ url: URL, callbackScheme: String) async throws -> URL {
        let anchor = OAuthAnchor(window: presentationWindow())
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme,
                                                     completionHandler: completionHandler(resuming: continuation))
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            current = session
            self.anchor = anchor
            if !session.start() {
                current = nil
                self.anchor = nil
                continuation.resume(throwing: AccountError.invalidCallback)
            }
        }
    }

    /// The handler given to the session. Safe to call on any thread or queue.
    nonisolated static func completionHandler(resuming continuation: CheckedContinuation<URL, Error>) -> @Sendable (URL?, Error?) -> Void {
        { callback, error in
            Task { @MainActor in
                current = nil
                anchor = nil
            }
            continuation.resume(with: outcome(callback: callback, error: error))
        }
    }

    nonisolated static func outcome(callback: URL?, error: Error?) -> Result<URL, Error> {
        if let callback { return .success(callback) }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            return .failure(AccountError.cancelled)
        }
        return .failure(AccountError.invalidCallback)
    }

    private static func presentationWindow() -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: \.isVisible)
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }
}

/// Hands the session the window chosen on the main actor, from whatever thread asks.
final class OAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding, Sendable {
    private let window: ASPresentationAnchor

    @MainActor init(window: ASPresentationAnchor) { self.window = window }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}
