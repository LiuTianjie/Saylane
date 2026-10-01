import AppKit
import InputMethodKit

@main
enum SaylaneIMEMain {
    /// Retained for the process lifetime; only ever touched from `main` on the main thread.
    nonisolated(unsafe) private static var inputServer: IMKServer?

    static func main() {
        if CommandLine.arguments.contains("--pinyin-self-test") {
            exit(RimeDiagnostics.run())
        }
        // Establish the IMK connection before entering the AppKit lifecycle, as a
        // dedicated input-method host. Retain it for the entire process lifetime.
        let name = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String
        inputServer = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier!)
        let application = NSApplication.shared
        let delegate = IMEAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class IMEAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        IMEHost.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SLRimeFinalize()
    }
}
