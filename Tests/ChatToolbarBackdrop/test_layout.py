"""Structural guardrails for the floating chat controls; no app or user data needed."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[2]
          / "Open UI/Features/Chat/Views/ChatDetailView.swift").read_text()


class ChatToolbarBackdropTests(unittest.TestCase):
    def test_full_width_backdrop_is_only_for_legacy_ios(self):
        toolbar = SOURCE.split('.chatChromeBar(edge: .top) {', 1)[1].split(
            '// Read-aloud player', 1)[0]
        self.assertIn('if !navBarHidden', toolbar)
        self.assertIn('customTopBar', toolbar)
        self.assertIn('.transition(', toolbar)
        self.assertEqual(toolbar.count('.background {'), 1)
        background = toolbar.split('.background {', 1)[1].split('.transition(', 1)[0]
        code = '\n'.join(line.split('//', 1)[0] for line in background.splitlines()).strip()
        self.assertTrue(code.startswith('if #unavailable(iOS 26.0) {'))
        self.assertNotIn('else', code)

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
