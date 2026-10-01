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

    def test_onboarding_exposes_progress_and_meter_state(self) -> None:
        source = self.source("Sources/Views/OnboardingView.swift")
        self.assertIn("progressAccessibilityValue(for: index)", source)
        self.assertIn(".accessibilityAddTraits(index == step ? .isSelected : [])", source)
        self.assertIn("第 \\(index + 1) 步，共 4 步", source)
        self.assertIn(".accessibilityValue(accessibilityValue)", source)
        for state in ("未启用", "无输入", "较弱", "正常", "较强"):
            self.assertIn(state, source)


if __name__ == "__main__":
    unittest.main()
