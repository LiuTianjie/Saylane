"""Static contracts for permission capability wording and onboarding accessibility."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class UIStateContractTests(unittest.TestCase):
    def source(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_permission_ui_reports_what_the_talk_key_can_reach(self) -> None:
        source = self.source("Sources/Views/PermissionsSettingsView.swift")
        self.assertIn("model.router.isGlobalTapListening", source)
        self.assertIn("model.router.isGlobalTapFiltering", source)
        self.assertIn("if globalTriggerUsable", source)
        # Accessibility decides whether the talk key works everywhere; it is
        # shown as granted only when the listener really runs.
        self.assertIn("ready: accessibilityReady && globalEventFiltering", source)
        self.assertIn("recommended: true", source)
        self.assertIn("任何应用、任何输入法下都能用", source)
        self.assertIn("只有 Saylane 是当前输入法时才能说话", source)
        self.assertIn("已允许；全局按键监听尚未接入", source)
        self.assertIn("当前功能键需要这项权限", source)
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

    def test_welcome_is_one_page_with_nothing_to_do_elsewhere(self) -> None:
        welcome = self.source("Sources/Views/WelcomeView.swift")
        # One page: the trial, the short permission list, one button. No steps.
        self.assertIn("DictationTrialView(", welcome)
        self.assertIn("PermissionsSettingsView(welcome: true)", welcome)
        self.assertIn("model.ensureInputSource()", welcome)
        self.assertNotIn("step", welcome)
        self.assertFalse((ROOT / "Sources/Views/OnboardingView.swift").exists())
        # The input method is added and switched to in place. System Settings
        # is opened for it only after the system has had its chance.
        rows = self.source("Sources/Views/PermissionsSettingsView.swift")
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

    def test_microphone_is_asked_for_where_it_is_first_needed(self) -> None:
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
