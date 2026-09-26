"""Small source guards; behavioral coverage lives in XCUITest."""
from pathlib import Path
import sys
import unittest

ROOT = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CHAT = (ROOT / "Open UI/Features/Chat/Views/ChatDetailView.swift").read_text()
SETTINGS = (ROOT / "Open UI/Features/Settings/Views/SettingsView.swift").read_text()


class SuggestionsTests(unittest.TestCase):
    def test_shared_persisted_default(self):
        for source in (CHAT, SETTINGS):
            self.assertTrue('@AppStorage("showNewChatSuggestions") private var showNewChatSuggestions = true' in source)

    def test_grid_guard(self):
        self.assertTrue("if showNewChatSuggestions && !randomPrompts.isEmpty {" in CHAT)

    def test_setting_is_explicitly_local(self):
        self.assertTrue('Toggle("Show New Chat Suggestions", isOn: $showNewChatSuggestions)' in SETTINGS)
        self.assertTrue("Applies only to Open Relay on this device" in SETTINGS)

    def test_followups_remain_independent(self):
        self.assertTrue('let displayFollowUps: [String] = suggestionsEnabled ? message.followUps : []' in CHAT)


if __name__ == "__main__":
    unittest.main()
