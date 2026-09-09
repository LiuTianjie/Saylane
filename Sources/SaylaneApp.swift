import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSHostingController settings still need standard edit/menu commands,
        // but no NSStatusItem/MenuBarExtra is created by this input-method host.
        let menu = NSMenu()
        let appItem = menu.addItem(withTitle: "Saylane", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Saylane")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "设置…", action: #selector(openPreferences(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Saylane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = menu.addItem(withTitle: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        AppModel.shared.bootstrap()
        
        #if DEBUG
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"), idx + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[idx + 1]
            let model = AppModel.shared
            model.settingsTab = 1
            PreviewSnapshot.takeSnapshot(model: model, path: path)
            NSApp.terminate(nil)
            return
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--waveform-snapshot"), idx + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[idx + 1]
            PreviewSnapshot.takeWaveformSnapshot(path: path)
            NSApp.terminate(nil)
            return
        }
        #endif

        if CommandLine.arguments.contains("--setup") {
            AppModel.shared.beginSetup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SLRimeFinalize()
    }

    @objc private func openPreferences(_ sender: Any?) {
        MainActor.assumeIsolated { AppModel.shared.openSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.openSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
