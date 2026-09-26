"""Regression check for custom circles inside native toolbar close buttons."""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def masked(source):
    # Preserve offsets while ignoring braces in Swift strings and comments.
    return re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"',
                  lambda match: " " * len(match[0]), source)


def closing_brace(source, start):
    clean = masked(source)
    depth = 0
    for index in range(start, len(clean)):
        depth += (clean[index] == "{") - (clean[index] == "}")
        if depth == 0:
            return index + 1
    raise ValueError("Unbalanced Swift block")


def close_toolbars(source):
    clean = masked(source)
    for match in re.finditer(r'\bToolbarItem(?:Group)?\s*\([^\n]*\)\s*\{', clean):
        end = closing_brace(source, clean.index("{", match.start()))
        block = source[match.start():end]
        if re.search(r'"xmark(?:\.circle(?:\.fill)?)?"', block):
            yield source.count("\n", 0, match.start()) + 1, block


def decorated(block):
    return ('"xmark.circle' in block
            or re.search(r'\.(?:background|overlay|clipShape)\s*\(', block) is not None)


class ToolbarCloseTests(unittest.TestCase):
    def test_no_nested_toolbar_decoration(self):
        failures = []
        for path in (ROOT / "Open UI").rglob("*.swift"):
            for line, block in close_toolbars(path.read_text()):
                if decorated(block):
                    failures.append(f"{path.relative_to(ROOT)}:{line}")
        self.assertFalse(failures, "Custom toolbar close decoration:\n" + "\n".join(failures))

    def test_scan_handles_nested_actions_and_quoted_braces(self):
        source = '''ToolbarItem(placement: .cancellationAction) {
            Button { if ready { close("}") } } label: {
                Image(systemName: "xmark").background(Color.gray)
            }
        }'''
        blocks = list(close_toolbars(source))
        self.assertEqual(len(blocks), 1)
        self.assertTrue(decorated(blocks[0][1]))

    def test_inline_clear_buttons_are_out_of_scope(self):
        self.assertEqual(list(close_toolbars('Button { clear() } label: { Image(systemName: "xmark.circle.fill") }')), [])

    def test_native_close_button_is_allowed(self):
        block = 'ToolbarItem(placement: .topBarLeading) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).tint(.secondary) }'
        self.assertFalse(decorated(next(close_toolbars(block))[1]))


if __name__ == "__main__":
    unittest.main(argv=sys.argv)
