import Foundation

@main struct OverlayNoticeTests {
    @MainActor static func wait(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    @MainActor static func main() async {
        let primary = OverlayScreenDescriptor(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850),
            isMain: true
        )
        let secondary = OverlayScreenDescriptor(
            displayID: 2,
            frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1055),
            isMain: false
        )
        let screens = [primary, secondary]
        let caret = CGRect(x: 1700, y: 420, width: 0, height: 24)
        let primaryWindow = CGRect(x: 100, y: 100, width: 900, height: 700)
        let secondaryWindow = CGRect(x: 1600, y: 20, width: 1000, height: 760)
        precondition(OverlayScreenSelector.choose(
            from: screens, caretRect: caret, frontmostWindowRect: primaryWindow,
            mouseLocation: CGPoint(x: 200, y: 200)
        )?.displayID == secondary.displayID, "Caret screen must win over window and mouse")
        precondition(OverlayScreenSelector.choose(
            from: screens, caretRect: nil, frontmostWindowRect: secondaryWindow,
            mouseLocation: CGPoint(x: 200, y: 200)
        )?.displayID == secondary.displayID, "Frontmost window must win when no caret is available")
        precondition(OverlayScreenSelector.choose(
            from: screens, caretRect: .zero, frontmostWindowRect: nil,
            mouseLocation: CGPoint(x: 1700, y: 200)
        )?.displayID == secondary.displayID, "Pointer is the final interaction fallback")
        precondition(OverlayScreenSelector.choose(
            from: screens, caretRect: nil, frontmostWindowRect: nil,
            mouseLocation: CGPoint(x: -9000, y: -9000)
        )?.displayID == primary.displayID, "Missing interaction geometry must fall back to main")
        precondition(OverlayScreenSelector.choose(
            from: [], caretRect: caret, frontmostWindowRect: secondaryWindow,
            mouseLocation: CGPoint(x: 1700, y: 200)
        ) == nil)
        var target = OverlayScreenTarget()
        target.begin(screens: screens, caretRect: caret, frontmostWindowRect: primaryWindow,
                     mouseLocation: CGPoint(x: 200, y: 200))
        precondition(target.displayID == secondary.displayID)
        precondition(target.resolve(in: screens)?.displayID == secondary.displayID,
                     "A presentation must keep its initial screen while content changes")
        precondition(target.resolve(in: [primary])?.displayID == primary.displayID,
                     "A disconnected display must fall back to the current main screen")
        target.end()
        precondition(target.displayID == nil)

        let overlay = OverlayController(displaysPanel: false)
        overlay.showLanguageSwitch(from: "English", to: "简体中文", duration: 0.025)
        precondition(overlay.model.languageSwitch?.from == "English" && overlay.model.languageSwitch?.to == "简体中文")
        await wait(60)
        precondition(overlay.model.languageSwitch == nil)
        overlay.showLanguageSwitch(from: "English", to: "中文", duration: 0.025)
        await wait(10)
        overlay.showLanguageSwitch(from: "中文", to: "日本語", duration: 0.10)
        await wait(45)
        precondition(overlay.model.languageSwitch?.to == "日本語", "Old timeout must not hide new switch")
        await wait(90)
        precondition(overlay.model.languageSwitch == nil)
        overlay.showLanguageSwitch(from: "中文", to: "English", duration: 0.025)
        overlay.show(source: "中文", target: "EN", liveInject: true, hotkeyLabel: "右⌘")
        overlay.setPhase(.listening)
        await wait(60)
        precondition(overlay.model.languageSwitch == nil && overlay.model.phase == .listening)
        overlay.showLanguageSwitch(from: "中文", to: "日本語", duration: 0.025)
        precondition(overlay.model.languageSwitch == nil, "Notice must not cover recording")
        overlay.hide()
        overlay.showLanguageSwitch(from: "中文", to: "English", duration: 0.025)
        overlay.hide(); await wait(50)
        precondition(overlay.model.languageSwitch == nil && overlay.model.phase == .hidden)
        overlay.showCompletion(.polishFailed, duration: 0.025)
        precondition(overlay.model.completion == .polishFailed)
        await wait(60)
        precondition(overlay.model.completion == nil)
        overlay.showCompletion(.polishTimedOut, duration: 0.025)
        overlay.show(source: "中文", target: "EN", liveInject: true, hotkeyLabel: "右⌘")
        overlay.setPhase(.polishing)
        await wait(60)
        precondition(overlay.model.phase == .polishing && overlay.model.completion == nil)
        overlay.showCompletion(.unchanged)
        precondition(overlay.model.completion == nil, "Completion cannot cover an active session")
        overlay.hide()
        for feedback in [CompletionFeedback.ordinary, .polished, .unchanged] {
            overlay.showCompletion(feedback)
            precondition(overlay.model.completion == nil && overlay.model.phase == .hidden)
        }
        overlay.showConversionFailure(duration: 0.025)
        precondition(overlay.model.phase == .error)
        await wait(60)
        precondition(overlay.model.phase == .hidden)
        overlay.showCompletion(.polishFailed, duration: 0.025)
        overlay.showConversionFailure()
        precondition(overlay.model.completion == .polishFailed && overlay.model.phase == .hidden)
        overlay.hide()
        overlay.showConversionFailure(duration: 0.025)
        overlay.show(source: "中文", target: "EN", liveInject: true, hotkeyLabel: "右⌘")
        overlay.setPhase(.listening)
        await wait(60)
        precondition(overlay.model.phase == .listening)
        overlay.hide()
        print("PASS: locked HUD screen selection, notice expiry, recording priority and explicit hide")
    }
}
