"""Small source guards; interactive behavior is covered by XCUITest."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
reference = sys.argv.pop(1) if len(sys.argv) > 1 else None


def source(name):
    if reference:
        return subprocess.check_output(["git", "show", f"{reference}:{name}"], cwd=ROOT).decode()
    return (ROOT / name).read_text()


CHAT = source("Open UI/Features/Chat/Views/ChatDetailView.swift")
SETTINGS = source("Open UI/Features/Settings/Views/SettingsView.swift")
COMPOSER = source("Open UI/Shared/Components/ChatInputField.swift")


class VoiceButtonTests(unittest.TestCase):
    def test_enabled_by_default_in_both_views(self):
        for text in (CHAT, SETTINGS):
            self.assertIn('@AppStorage("showVoiceModeButton") private var showVoiceModeButton = true', text)

    def test_visibility_preserves_server_permissions(self):
        self.assertIn("onVoiceInput: showVoiceModeButton && dependencies.authViewModel.chatPermissions.call ? { toggleVoiceInput() } : nil", CHAT)

    def test_dictation_is_independent(self):
        self.assertIn("onDictationStart: dependencies.authViewModel.chatPermissions.stt ? { startDictation() } : nil", CHAT)

    def test_both_voice_positions_depend_on_callback(self):
        self.assertIn("onVoiceInput != nil && isEnabled && !canSend && hasQuickPills", COMPOSER)
        self.assertIn("else if !hasQuickPills, let onVoiceInput", COMPOSER)

    def test_send_fallback_remains_disabled_without_sendable_content(self):
        self.assertIn("} else if canSend || onVoiceInput == nil {", COMPOSER)
        send = COMPOSER.split("} else if canSend || onVoiceInput == nil {", 1)[1].split("} else if !hasQuickPills", 1)[0]
        self.assertIn(".disabled(!canSend)", send)
        self.assertIn("canSend ? theme.brandPrimary : theme.textTertiary.opacity(0.15)", send)
        self.assertIn("canSend ? theme.brandOnPrimary : theme.textTertiary", send)


if __name__ == "__main__":
    unittest.main()
