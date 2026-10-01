import AppKit
import SwiftUI

@MainActor
final class SettingsController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var localMonitor: Any?

    var isVisible: Bool { window?.isVisible == true }
    var isFocused: Bool { NSApp.isActive && window?.isKeyWindow == true }
    var focusedResponderIdentity: ObjectIdentifier? {
        window?.firstResponder.map(ObjectIdentifier.init)
    }

    func show(model: AppModel) {
        // The main program has no Dock icon; its windows come and go like a panel's.
        NSApp.setActivationPolicy(.accessory)

        let hosting = NSHostingController(rootView: SettingsView().environment(model))
        if let window {
            window.contentViewController = hosting
            self.window = window
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Saylane"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 880, height: 700))
            window.minSize = NSSize(width: 780, height: 640)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor.windowBackgroundColor
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            self.window = window
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.removeMonitor()
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        installMonitor(model: model)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.setActivationPolicy(.accessory)
    }

    private func installMonitor(model: AppModel) {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak model] event in
            // Local monitors are delivered on the main thread.
            nonisolated(unsafe) let event = event
            guard let model else { return event }
            let consumed = MainActor.assumeIsolated { model.handleSettingsShortcut(event) == nil }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}
