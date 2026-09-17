import AppKit
import SwiftUI

@MainActor
final class SettingsController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(model: AppModel) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let hosting = NSHostingController(rootView: SettingsView().environment(model))
        if let window {
            window.contentViewController = hosting
            self.window = window
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Saylane"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 780, height: 640))
            window.minSize = NSSize(width: 720, height: 520)
            window.titlebarAppearsTransparent = false
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}
