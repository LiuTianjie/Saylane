import Foundation
import AppKit
import InputMethodKit
#if DEBUG
import SwiftUI
#endif

@main
enum SaylaneMain {
    private static var inputServer: IMKServer?

    static func main() {
        if CommandLine.arguments.contains("--pinyin-self-test") {
            exit(RimeDiagnostics.run())
        }
        if CommandLine.arguments.contains("--register-input-source") {
            exit(InputSourceInstall.registerBundle() == noErr ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.contains("--install") {
            let ok = InputSourceInstall.enableAndSelect()
            fputs(ok ? "Saylane input source enabled and selected\n" : "\(InputSourceInstall.lastFailure ?? "Input source not found")\n", stderr)
            exit(ok ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.contains(where: { ["--diagnose", "--recognize-file", "--translation-check", "--download-speech-model", "--asr-memory-check", "--qwen-worker"].contains($0) }) {
            Task { @MainActor in exit(await Diagnostics.run(CommandLine.arguments)) }
            RunLoop.main.run()
            return
        }
        #if DEBUG
        // Preview the real settings without registering a second IMK server or global hotkeys.
        if CommandLine.arguments.contains("--preview-models")
            || Bundle.main.object(forInfoDictionaryKey: "SaylaneUIPreview") as? Bool == true {
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                let model = AppModel.shared
                let arguments = CommandLine.arguments
                // "--preview-tab N" picks the page; "--preview-shot dir" writes every page as settings-N.png and exits.
                model.settingsTab = arguments.firstIndex(of: "--preview-tab").flatMap { Int(arguments[safe: $0 + 1] ?? "") } ?? 1
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Saylane"
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.minSize = NSSize(width: 780, height: 640)
                window.toolbarStyle = .unified
                let previewStep = Bundle.main.object(forInfoDictionaryKey: "SaylaneUIPreviewSetupStep") as? Int
                model.isShowingSetup = previewStep != nil
                window.contentView = NSHostingView(rootView: SettingsView(initialSetupStep: previewStep ?? 0).environment(model)
                    .preferredColorScheme(Bundle.main.object(forInfoDictionaryKey: "SaylaneUIPreviewDark") as? Bool == true ? .dark : nil))
                window.center()
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                if let index = arguments.firstIndex(of: "--preview-shot"), let directory = arguments[safe: index + 1] {
                    // Vibrancy does not render into a cached bitmap, so hand the window number to
                    // `screencapture -l` for a faithful composite of each page.
                    Task { @MainActor in
                        for tab in [0] + Array(0...5) {
                            model.settingsTab = tab
                            try? await Task.sleep(for: .milliseconds(1200))
                            let process = Process()
                            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(directory)/settings-\(tab).png"]
                            try? process.run()
                            process.waitUntilExit()
                        }
                        app.terminate(nil)
                    }
                }
                withExtendedLifetime(window) { app.run() }
            }
            return
        }
        #endif
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

#if DEBUG
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
