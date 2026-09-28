"""Regression checks for custom picker headers; synthetic, no network."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPONENTS = ROOT / "Open UI/Shared/Components"


class PickerCloseTests(unittest.TestCase):
    def test_models_use_system_close_control(self):
        source = (COMPONENTS / "ModelSelectorSheet.swift").read_text()
        header = source.split("private var sheetHeader:")[1].split("// MARK: - Search Bar")[0]
        self.assertIn("SheetCloseButton { dismiss() }", header)
        self.assertNotIn('Button("Done")', header)
        self.assertNotIn("RoundedRectangle", header)
        self.assertIn(".presentationDragIndicator(.visible)", source)

    def test_attachments_keep_the_dismiss_callback(self):
        source = (COMPONENTS / "UnifiedAttachmentPicker.swift").read_text()
        header = source.split("// Title")[1].split("// Recent Photos Section")[0]
        self.assertIn("SheetCloseButton {\n                    onDismiss()", header)
        self.assertNotIn("xmark.circle", header)

    def test_native_style_with_older_os_fallback(self):
        source = (COMPONENTS / "SheetCloseButton.swift").read_text()
        for expected in ['if #available(iOS 26, *)', '.buttonStyle(.glass)',
                         '.buttonStyle(.bordered)', '.buttonBorderShape(.circle)',
                         '.controlSize(.large)', '.labelStyle(.iconOnly)',
                         'Button("Close", systemImage: "xmark", action: action)']:
            self.assertIn(expected, source)
        for custom_effect in ["glassEffect(", "Circle()", ".background("]:
            self.assertNotIn(custom_effect, source)

    def test_old_headers_expose_the_regression(self):
        base = "4151a735512d5d6dbc9fd1962fa806517a0d4ea7"
        def old(file):
            return subprocess.check_output(["git", "show", f"{base}:Open UI/Shared/Components/{file}"], cwd=ROOT, text=True)
        self.assertIn('Button("Done")', old("ModelSelectorSheet.swift"))
        self.assertIn('Image(systemName: "xmark.circle.fill")', old("UnifiedAttachmentPicker.swift"))


if __name__ == "__main__": unittest.main()
