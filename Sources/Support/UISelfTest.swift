import AppKit
import SwiftUI

/// `--ui-self-test`: drive the real windows of this build with real mouse and
/// key events posted to this process, and report what the interface did. It
/// only runs in a test home (`SAYLANE_TEST_HOME`), next to — never instead of —
/// the installed product. This is the check that an event monitor, a window
/// level or a focus rule has not made the interface deaf.
@MainActor
enum UISelfTest {
    private static var failures: [String] = []

    static func run(model: AppModel) async -> Int32 {
        guard TestHome.isActive else {
            print("ui-self-test needs SAYLANE_TEST_HOME")
            return 2
        }
        func check(_ condition: Bool, _ message: String) {
            print((condition ? "ok   " : "FAIL ") + message)
            if !condition { failures.append(message) }
        }

        // 1. The guide opens in a key window and lists the four items. What is
        //    on and what is not is said here: a test binary's own permissions
        //    are whatever the Mac happens to grant it.
        model.testChecklist = SetupChecklist(inputMethod: true, microphone: false, accessibility: false, screenRecording: false)
        model.beginSetup()
        await settle()
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Saylane" }) else {
            print("FAIL no settings window")
            return 1
        }
        check(window.isKeyWindow, "the welcome window is key")
        check(model.isShowingSetup && UISelfTestAnchors.frames["welcome"] != nil, "the welcome page is showing")
        check((0...3).allSatisfy { UISelfTestAnchors.frames["setup-row-\($0)"] != nil }, "the guide lists its four items")
        // "Later" leaves without claiming the guide is done; opened again, it is back.
        let later = click("welcome-later", in: window)
        await settle()
        check(later && !model.isShowingSetup && !model.setupCompleted, "“later” leaves the guide unfinished")
        AppDelegate.showWelcomeIfNew { $0.openSettings() }
        await settle()
        check(model.isShowingSetup, "opened again, the guide comes back")

        // 2. With all four on, the page offers the trial field: an ordinary text
        //    view a dictation can be written into, and what is written reaches the model.
        model.testChecklist = .complete
        await settle()
        model.testText = ""
        let field = firstTextView(in: window.contentView)
        check(field != nil, "the welcome page has the trial field")
        if let field {
            window.makeFirstResponder(field)
            check(LocalTextInserter.insert("听写"), "text can be written into the focused field of this process")
            await settle()
            check(model.testText.contains("听写"), "the written text reaches the model (\"\(model.testText)\")")
        }
        let done = click("welcome-done", in: window)
        await settle()
        check(done && !model.isShowingSetup && model.setupCompleted, "a click on “get started” leaves the welcome page for good")

        // 3. Settings: a click on a sidebar row changes the page, and the guide
        //    button brings the welcome page back.
        model.openSettings(tab: 1)
        await settle()
        let moved = click("tab-0", in: window)
        await settle()
        check(moved && model.settingsTab == 0, "a click on a sidebar row changes the page (1 → \(model.settingsTab))")
        let guide = click("setup-guide", in: window)
        await settle()
        check(guide && model.isShowingSetup, "a click on the guide button opens the welcome page again")
        model.deferSetup()
        await settle()

        // Opened again later (by hand, or by an installer over a running
        // program): the settings, not the welcome page — whatever permission
        // may be missing is asked for where it is needed.
        AppDelegate.showWelcomeIfNew { $0.openSettings() }
        await settle()
        check(!model.isShowingSetup, "once finished, the welcome page does not come back by itself")

        // 4. The talk-key gesture reaches the model from this window's own key
        //    monitor: hold alone starts, a chord does not.
        var actions: [String] = []
        let original = model.router.onAction
        model.router.onAction = { actions.append(String(describing: $0)) }
        let trigger = model.prefs.pushToTalk
        if trigger.isModifier {
            post(flagsChanged: trigger, down: true, window: window)
            post(key: "w", code: 13, flags: trigger.nsModifierFlag, window: window)
            try? await Task.sleep(for: .milliseconds(450))
            post(flagsChanged: trigger, down: false, window: window)
            await settle()
            check(!actions.contains { $0.contains("start") }, "a chord with the talk key starts nothing: \(actions)")
            actions = []
            post(flagsChanged: trigger, down: true, window: window)
            try? await Task.sleep(for: .milliseconds(450))
            post(flagsChanged: trigger, down: false, window: window)
            await settle()
            check(actions.contains { $0.contains("start") } && actions.contains { $0.contains("stop") },
                  "holding the talk key alone starts and its release stops: \(actions)")
        }
        model.router.onAction = original

        print(failures.isEmpty ? "PASS: interface self-test" : "FAILED: \(failures.count) check(s)")
        return failures.isEmpty ? 0 : 1
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(350)) }

    // MARK: - Finding and clicking

    /// Click the middle of a control that carries `.selfTestAnchor(name)`.
    private static func click(_ name: String, in window: NSWindow) -> Bool {
        guard let view = window.contentView, let frame = UISelfTestAnchors.frames[name],
              frame.width > 1, frame.height > 1 else { return false }
        // SwiftUI's global space is the window's, with the origin at its top left
        // (title bar included); AppKit's has it at the bottom left.
        let location = NSPoint(x: frame.midX, y: window.frame.height - frame.midY)
        if CommandLine.arguments.contains("--verbose") {
            let inView = view.convert(location, from: nil)
            print("     \(name): frame=\(frame) window=\(location) inside=\(view.bounds.contains(inView))")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }

    private static func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.isEditable { return text }
        for child in view.subviews {
            if let found = firstTextView(in: child) { return found }
        }
        return nil
    }

    private static func post(flagsChanged trigger: PushToTalkHotkey, down: Bool, window: NSWindow) {
        let flags = down ? trigger.nsModifierFlag : []
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                        keyCode: UInt16(trigger.keyCode)) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func post(key: String, code: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                                        keyCode: code) {
            NSApp.postEvent(event, atStart: false)
        }
    }
}

/// Where the controls that the self-test clicks are, in the hosting view.
@MainActor
enum UISelfTestAnchors {
    static var frames: [String: CGRect] = [:]
}

extension View {
    /// Lets `--ui-self-test` find this control. Does nothing outside a test home.
    @ViewBuilder func selfTestAnchor(_ name: String) -> some View {
        if TestHome.isActive {
            background(GeometryReader { proxy in
                Color.clear
                    .onAppear { UISelfTestAnchors.frames[name] = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in UISelfTestAnchors.frames[name] = frame }
            })
        } else {
            self
        }
    }
}
