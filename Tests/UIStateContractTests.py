"""Static contracts for permission capability wording and onboarding accessibility."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class UIStateContractTests(unittest.TestCase):
    def source(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_permission_ui_distinguishes_listening_from_filtering(self) -> None:
        source = self.source("Sources/Views/PermissionsSettingsView.swift")
        self.assertIn("model.router.isGlobalTapListening", source)
        self.assertIn("model.router.isGlobalTapFiltering", source)
        self.assertIn("globalTriggerUsable", source)
        self.assertIn("if globalTriggerUsable", source)
        self.assertIn("请先手动选中 Saylane", source)
        self.assertIn("可监听并拦截全局按键", source)
        self.assertIn("当前功能键需要这项权限", source)
        self.assertIn("已允许；全局按键拦截尚未接入", source)

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
