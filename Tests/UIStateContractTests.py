"""Static contracts for permission capability wording and onboarding accessibility."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class UIStateContractTests(unittest.TestCase):
    def source(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_permission_ui_reports_what_the_talk_key_can_reach(self) -> None:
        source = self.source("Sources/Views/SetupChecklistView.swift")
        # Accessibility decides whether the talk key works everywhere. Allowed
        # but with the listener not attached is said so, with the control that attaches it.
        self.assertIn("model.router.isGlobalTapFiltering", source)
        self.assertIn("model.reconnectGlobalKeys()", source)
        self.assertIn("任何应用、任何输入法下都能按键说话", source)
        self.assertIn("已允许；按键监听还没有接上", source)
        self.assertIn("当前的说话键是功能键，必须开启这一项才能用", source)
        # The input method counts as settled when it is current, or when the
        # talk key arrives under any input method.
        readiness = self.source("Sources/Core/Readiness.swift")
        self.assertIn("inputSource.enabled && (inputSource.selected || globalInvokeAvailable)", readiness)
        # Input Monitoring is no longer asked for: Accessibility covers it.
        self.assertNotIn("输入监控", source)
        self.assertNotIn("requestInputMonitoring", source)

    def test_talk_key_wording_matches_the_gesture(self) -> None:
        source = self.source("Sources/Views/SettingsView.swift")
        self.assertIn("单独按住约 0.3 秒开始说话", source)
        self.assertIn("和其它键一起按", source)
        self.assertNotIn("按下的那一刻就已经在录音", source)
        gesture = self.source("Sources/Input/VoiceGesture.swift")
        self.assertIn("static let holdDelay: TimeInterval = 0.28", gesture)
        self.assertIn("static let prewarmDelay: TimeInterval = 0.12", gesture)

    def test_function_key_warning_is_inline_and_actionable(self) -> None:
        source = self.source("Sources/Views/SettingsView.swift")
        self.assertIn("functionKeyNeedsFiltering", source)
        self.assertIn("!p.pushToTalk.isModifier && !model.router.isGlobalTapFiltering", source)
        self.assertIn("当前功能键需要辅助功能权限才能可靠使用", source)
        self.assertIn("model.requestAccessibility()", source)

    def test_guide_is_one_page_that_turns_everything_on(self) -> None:
        welcome = self.source("Sources/Views/WelcomeView.swift")
        # One page, not a wizard of pages: the list of four, one button that
        # settles whatever is next, a way out, and the trial once all are on.
        self.assertIn("SetupChecklistView(guide: true)", welcome)
        self.assertIn("model.performNextSetupStep()", welcome)
        self.assertIn("model.deferSetup()", welcome)
        self.assertIn("DictationTrialView(", welcome)
        self.assertIn("model.ensureInputSource()", welcome)
        self.assertNotIn("TabView", welcome)
        self.assertFalse((ROOT / "Sources/Views/OnboardingView.swift").exists())
        self.assertFalse((ROOT / "Sources/Views/PermissionsSettingsView.swift").exists())
        # Everything Saylane needs is on the list: nothing is left to be asked for at first use.
        flow = self.source("Sources/Models/SetupFlow.swift")
        for step in ("case inputMethod", "case microphone", "case accessibility", "case screenRecording"):
            self.assertIn(step, flow)
        # macOS reopens the program when Screen Recording is allowed: the guide comes back.
        delegate = self.source("Sources/App/AppDelegate.swift")
        self.assertIn("AppModel.shared.guideWasInterrupted", delegate)
        # The input method is added and switched to in place. System Settings
        # is opened for it only after the system has had its chance.
        rows = self.source("Sources/Views/SetupChecklistView.swift")
        self.assertIn('String(localized: "添加")', rows)
        self.assertIn('String(localized: "切换到 Saylane")', rows)
        self.assertNotIn("openSystemInputSourceSettings", rows)
        controller = self.source("Sources/Services/PermissionsController.swift")
        self.assertLess(controller.index("ContinuousClock.now - start > Self.addInPlaceLimit"),
                        controller.index("InputSourceInstall.openSystemInputSourceSettings()"))
        self.assertEqual(controller.count("openSystemInputSourceSettings()"), 1)
        # After an installation the input source is added before anything is shown.
        delegate = self.source("Sources/App/AppDelegate.swift")
        self.assertLess(delegate.index("AppModel.shared.ensureInputSource()"), delegate.index("Self.showWelcomeIfNew { _ in }"))

    def test_microphone_is_still_asked_for_at_first_use_if_the_guide_was_left(self) -> None:
        voice = self.source("Sources/Voice/VoiceSessionController.swift")
        self.assertIn("if blocker == .microphoneNotRequested {", voice)
        self.assertIn("host.requestMicrophoneForDictation()", voice)
        readiness = self.source("Sources/Models/SetupReadiness.swift")
        self.assertNotIn("inputMethodNotSelected", readiness)

    def test_trial_meter_reports_its_state(self) -> None:
        source = self.source("Sources/Views/DictationTrialView.swift")
        self.assertIn(".accessibilityValue(accessibilityValue)", source)
        for state in ("未启用", "无输入", "较弱", "正常", "较强"):
            self.assertIn(state, source)

    def test_input_source_is_never_changed_from_a_test_home(self) -> None:
        source = self.source("Sources/Services/InputSourceInstall.swift")
        for function in ("registerBundle", "requestModeEnable", "selectEnabledMode", "disableForUninstall",
                         "selectASCIILayout", "select(inputSourceID"):
            body = source[source.index("static func " + function):]
            self.assertIn("mayChangeSystem", body[:body.index("\n    }")], function)


if __name__ == "__main__":
    unittest.main()
