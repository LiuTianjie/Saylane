import AppKit
import AuthenticationServices
import Foundation

/// AuthenticationServices ends a session on its own XPC reply queue and may ask
/// for the anchor off the main thread. Swift 6 traps when a main-actor isolated
/// closure is entered anywhere else, so both are called here from background
/// queues, the way the framework calls them. A regression ends this process
/// with SIGTRAP instead of printing "passed".

func expect(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

/// Runs the handler from a background queue and returns what the waiting sign-in got.
func finish(callback: URL?, error: Error?) async -> Result<URL, Error> {
    do {
        let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let handler = OAuthBrowser.completionHandler(resuming: continuation)
            DispatchQueue(label: "com.apple.NSXPCConnection.test-reply").async {
                expect(!Thread.isMainThread, "the handler runs off the main thread in this test")
                handler(callback, error)
            }
        }
        return .success(url)
    } catch {
        return .failure(error)
    }
}

@main
enum OAuthBrowserTests {
    static func main() async {
        let url = URL(string: "saylane://auth-callback?code=abc")!
        let returned = await finish(callback: url, error: nil)
        expect((try? returned.get()) == url, "a callback from a background queue reaches the sign-in")

        let cancelled = await finish(callback: nil, error: ASWebAuthenticationSessionError(.canceledLogin))
        if case .failure(let error) = cancelled { expect(error as? AccountError == .cancelled, "closing the sheet is a cancel") }
        else { expect(false, "closing the sheet is a cancel") }

        let failed = await finish(callback: nil, error: ASWebAuthenticationSessionError(.presentationContextInvalid))
        if case .failure(let error) = failed { expect(error as? AccountError == .invalidCallback, "another error fails the sign-in") }
        else { expect(false, "another error fails the sign-in") }

        // The anchor: chosen on the main actor, handed out from any thread.
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let anchor = OAuthAnchor(window: window)
        let fromBackground: ASPresentationAnchor = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let session = ASWebAuthenticationSession(url: URL(string: "https://example.com")!, callbackURLScheme: "saylane") { _, _ in }
                continuation.resume(returning: anchor.presentationAnchor(for: session))
            }
        }
        expect(fromBackground === window, "the anchor answers from a background thread")

        print("oauth browser tests passed")
    }
}
