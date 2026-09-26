"""Structural regression checks; UI tests cover actual navigation and persistence."""
from pathlib import Path
import sys
import unittest

ROOT = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
SETTINGS = (ROOT / "Open UI/Features/Settings/Views/SettingsView.swift").read_text()
LANGUAGE = (ROOT / "Open UI/Features/Settings/Views/LanguagePickerView.swift").read_text()
MODEL = SETTINGS.split("struct DefaultModelPickerView:")[1].split("// MARK: - Chat Settings View")[0]


class SettingsNavigationTests(unittest.TestCase):
    maxDiff = 200
    def test_preference_destinations_share_navigation(self):
        for name in ("defaultModel", "language"):
            self.assertIn(f"navigationPath.append(SettingsDestination.{name})", SETTINGS)
            self.assertIn(f"case .{name}:", SETTINGS)
        self.assertNotIn("showDefaultModelPicker", SETTINGS)
        self.assertNotIn("showLanguagePicker", SETTINGS)

    def test_no_nested_stack_or_cancel_button(self):
        for page in (MODEL, LANGUAGE):
            self.assertNotIn("NavigationStack", page)
            self.assertNotIn('Button("Cancel")', page)

    def test_neutral_grouped_rows_and_accessible_confirmation(self):
        for page in (MODEL, LANGUAGE):
            self.assertIn(".listStyle(.insetGrouped)", page)
            self.assertNotIn(".listRowBackground", page)
            self.assertIn(".accessibilityAddTraits", page)
        self.assertIn('Button("Save", systemImage: "checkmark")', MODEL)
        self.assertIn(".labelStyle(.iconOnly)", MODEL)
        self.assertIn(".foregroundStyle(theme.textPrimary)", MODEL)

    def test_language_uses_exact_app_override(self):
        self.assertIn("persistentDomain(forName: domain)", LANGUAGE)
        self.assertIn("Self.selectedLanguageCode == lang.code", LANGUAGE)
        self.assertIn("Self.selectedLanguageCode == nil", LANGUAGE)
        self.assertNotIn("hasPrefix", LANGUAGE)
        subtitle = SETTINGS.split("private var currentLanguageDisplayName:")[1].split("private var notificationStatusSubtitle:")[0]
        self.assertIn("LanguagePickerView.selectedLanguageCode", subtitle)
        self.assertNotIn("hasPrefix", subtitle)


if __name__ == "__main__":
    unittest.main()
