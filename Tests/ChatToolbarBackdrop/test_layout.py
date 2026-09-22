"""Structural guardrails for the floating chat controls; no app or user data needed."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[2]
          / "Open UI/Features/Chat/Views/ChatDetailView.swift").read_text()
APPEARANCE = (Path(__file__).resolve().parents[2]
              / "Open UI/Features/Settings/Views/AppearanceSettingsView.swift").read_text()


class ChatToolbarBackdropTests(unittest.TestCase):
    def test_transparency_requires_ios26_and_opt_in(self):
        toolbar = SOURCE.split('.chatChromeBar(edge: .top) {', 1)[1].split(
            '// Read-aloud player', 1)[0]
        self.assertIn('if !navBarHidden', toolbar)
        self.assertIn('customTopBar', toolbar)
        self.assertIn('.transition(', toolbar)
        self.assertEqual(toolbar.count('.background {'), 1)
        background = toolbar.split('.background {', 1)[1].split('.transition(', 1)[0]
        self.assertIn('if showsToolbarBackdrop {', background)
        policy = SOURCE.partition('private var showsToolbarBackdrop: Bool {')[2].partition('// MARK:')[0]
        self.assertIn('if #available(iOS 26.0, *) { return !transparentChatToolbar }', policy)
        self.assertIn('return true', policy)

    def test_local_preference_defaults_to_off_in_both_views(self):
        declaration = '@AppStorage("transparentChatToolbar") private var transparentChatToolbar = false'
        self.assertTrue(declaration in SOURCE, 'Chat defaults to the original backdrop')
        self.assertTrue(declaration in APPEARANCE, 'Settings uses the same local default')

    def test_setting_is_only_visible_on_ios26(self):
        section = APPEARANCE.partition('// Chat toolbar')[2].partition('// iPad-only:')[0]
        self.assertIn('if #available(iOS 26.0, *) {', section)
        self.assertIn('header: "Chat Appearance"', section)
        self.assertIn('title: "Transparent Chat Toolbar"', section)
        self.assertIn('isOn: transparentChatToolbar', section)
        self.assertIn('onChange: { transparentChatToolbar = $0 }', section)

    def test_legacy_backdrop_keeps_its_original_material_and_tint(self):
        toolbar = SOURCE.split('.chatChromeBar(edge: .top) {', 1)[1].split(
            '// Read-aloud player', 1)[0]
        for original in ('Rectangle()', '.fill(.ultraThinMaterial)',
                         '.overlay(theme.background.opacity(theme.isDark ? 0.55 : 0.25))',
                         '.ignoresSafeArea(edges: .top)'):
            self.assertIn(original, toolbar)

    def test_status_blur_remains_confined_to_safe_area(self):
        status = SOURCE.split('// Status-bar safe-area backdrop', 1)[1].split(
            '.navigationBarHidden(true)', 1)[0]
        self.assertIn('.glassEffect(.clear', status)
        self.assertIn('.background(.ultraThinMaterial)', status)
        self.assertIn('.frame(height: geometry.safeAreaInsets.top)', status)
        self.assertIn('.offset(y: -geometry.safeAreaInsets.top)', status)
        self.assertIn('.allowsHitTesting(false)', status)
        self.assertNotIn('if !navBarHidden', status)

    def test_individual_controls_keep_their_glass(self):
        self.assertIn('.chatControlGlass(in: Circle()', SOURCE)
        self.assertIn('.chatControlGlass(in: RoundedRectangle(cornerRadius: 22', SOURCE)
        self.assertIn('.glassEffect(.regular.interactive(), in: shape)', SOURCE)
        self.assertIn('self.background(fallback, in: shape)', SOURCE)


if __name__ == '__main__':
    unittest.main()
