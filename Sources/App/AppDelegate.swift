import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The main program has no Dock icon and no menu bar of its own, but its
        // settings window still needs the standard editing commands.
        let menu = NSMenu()
        let appItem = menu.addItem(withTitle: "Saylane", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Saylane")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: String(localized: "设置…"), action: #selector(openPreferences(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        // ⌘Q closes the window. The program keeps running: the talk key and
        // screen translation live here.
        appMenu.addItem(withTitle: String(localized: "关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
        appMenu.addItem(withTitle: String(localized: "关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = menu.addItem(withTitle: String(localized: "编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: String(localized: "编辑"))
        editItem.submenu = editMenu
        for (title, action, key) in [(String(localized: "撤销"), "undo:", "z"), (String(localized: "剪切"), "cut:", "x"), (String(localized: "复制"), "copy:", "c"), (String(localized: "粘贴"), "paste:", "v"), (String(localized: "全选"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        AppModel.shared.bootstrap()
        
        #if DEBUG
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"), idx + 1 < CommandLine.arguments.count {
            // "--snapshot out.png" renders the voice tab; "--snapshot out.png all" renders every tab as out-N.png.
            let path = CommandLine.arguments[idx + 1]
            let model = AppModel.shared
            if CommandLine.arguments.count > idx + 2, CommandLine.arguments[idx + 2] == "all" {
                let base = (path as NSString).deletingPathExtension
                for tab in 0...5 {
                    model.settingsTab = tab
                    PreviewSnapshot.takeSnapshot(model: model, path: "\(base)-\(tab).png")
                }
            } else {
                model.settingsTab = 1
                PreviewSnapshot.takeSnapshot(model: model, path: path)
            }
            NSApp.terminate(nil)
            return
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--waveform-snapshot"), idx + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[idx + 1]
            PreviewSnapshot.takeWaveformSnapshot(path: path)
            NSApp.terminate(nil)
            return
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--pin-snapshot"), idx + 5 < CommandLine.arguments.count {
            // "--pin-snapshot in.png scale source target out.png": a picture through the screen-translation path, as the pin shows it.
            let a = CommandLine.arguments
            guard let loaded = NSImage(contentsOfFile: a[idx + 1]), let scale = Double(a[idx + 2]),
                  let cg = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let source = AppLanguage(rawValue: a[idx + 3]), let target = AppLanguage(rawValue: a[idx + 4]) else { exit(2) }
            let image = NSImage(cgImage: cg, size: CGSize(width: Double(cg.width) / scale, height: Double(cg.height) / scale))
            Task { @MainActor in
                let controller = ScreenTranslateController()
                let result = await controller.preview(image, direction: TranslationDirection(source: source, target: target))
                try? result.pin?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[idx + 5]))
                print("pin snapshot written; status: \(result.status.isEmpty ? "done" : result.status)")
                exit(result.pin == nil ? 1 : 0)
            }
            return
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--setup-snapshot"), idx + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[idx + 1]
            PreviewSnapshot.takeSetupSnapshot(model: AppModel.shared, path: path)
            NSApp.terminate(nil)
            return
        }
        #endif

        let arguments = CommandLine.arguments
        if arguments.contains("--ui-self-test") {
            Task { @MainActor in exit(await UISelfTest.run(model: AppModel.shared)) }
            return
        }
        if arguments.contains("--setup") {
            AppModel.shared.beginSetup()
        } else if arguments.contains("--installed") {
            // Just installed or upgraded: the input source is added and made
            // current here, as other input methods do when they install. The
            // welcome page appears once; an upgrade is silent.
            AppModel.shared.ensureInputSource()
            Self.showWelcomeIfNew { _ in }
        } else if arguments.contains("--settings") {
            AppModel.shared.openSettings()
        } else if !arguments.contains("--background"), !Self.launchedAsLoginItem {
            // Opened by hand: show something.
            Self.showWelcomeIfNew { $0.openSettings() }
        }
    }

    /// The welcome page until it has been finished once; `otherwise` after that.
    /// Permissions are not a reason to show it again: each is asked for where
    /// it is first needed.
    @MainActor static func showWelcomeIfNew(otherwise: (AppModel) -> Void) {
        let model = AppModel.shared
        if model.setupCompleted { otherwise(model) } else { model.beginSetup() }
    }

    /// Started by the system at login: stay out of the way.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    @objc private func openPreferences(_ sender: Any?) {
        MainActor.assumeIsolated { AppModel.shared.openSettings() }
    }

    /// Opened again while running. The installer's `open` arrives here when the
    /// input method has already started the program in the background.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showWelcomeIfNew { $0.openSettings() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
