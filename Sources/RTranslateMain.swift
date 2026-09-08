import Foundation
import AppKit
import InputMethodKit

@main
enum RTranslateMain {
    private static var inputServer: IMKServer?

    static func main() {
        if CommandLine.arguments.contains("--register-input-source") {
            exit(InputSourceInstall.registerBundle() == noErr ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.contains("--install") {
            let ok = InputSourceInstall.enableAndSelect()
            fputs(ok ? "RTranslate input source enabled and selected\n" : "\(InputSourceInstall.lastFailure ?? "Input source not found")\n", stderr)
            exit(ok ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.contains(where: { ["--diagnose", "--recognize-file", "--translation-check"].contains($0) }) {
            Task { @MainActor in exit(await Diagnostics.run(CommandLine.arguments)) }
            RunLoop.main.run()
            return
        }
        // Establish the IMK connection before entering the AppKit lifecycle, as a
        // dedicated input-method host. Retain it for the entire process lifetime.
        let name = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String
        inputServer = IMKServer(name: name, bundleIdentifier: Bundle.main.bundleIdentifier!)
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
