"""Source-level guards for native navigation toolbar actions (no server needed)."""
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = "4151a735512d5d6dbc9fd1962fa806517a0d4ea7"
# These screens already have equivalent changes in independently ported PRs.
DEFERRED = {"ChatContextPanel.swift", "PromptVariableSheet.swift",
            "CreateCalendarEventSheet.swift", "CalendarEventDetailView.swift"}
LABELS = "Cancel|Close|Done|Save|Apply|Create|Add"
EXPRESSION = (r'"(?:' + LABELS + r')"|String\(localized: "(?:' + LABELS + r')"\)'
              r'|isEditMode \? "Update" : "Create"'
              r'|viewModel.editingItemId != nil \? "Save" : "Create"')
BUTTON = re.compile(r'Button\((' + EXPRESSION + r')(?:, systemImage: "([^"]+)")?\)\s*\{')


def masked(source):
    # Keep offsets stable while ignoring braces inside comments and strings.
    return re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"',
                  lambda m: " " * len(m[0]), source)


def closing(code, start):
    depth = 0
    for i in range(start, len(code)):
        depth += (code[i] == "{") - (code[i] == "}")
        if depth == 0:
            return i
    raise AssertionError("Unbalanced block")


def controls(source):
    code = masked(source)
    items = []
    item_matches = list(re.finditer(r'ToolbarItem(?:Group)?\(placement:\s*\.([A-Za-z]+)\)\s*\{', code))
    # GroupEditSheet factors its confirmation toolbar button into a view property.
    item_matches += list(re.finditer(r'private var (saveButton): some View\s*\{', code))
    for item in item_matches:
        if item[1] in ("keyboard", "bottomBar"):
            continue
        end = closing(code, item.end() - 1)
        for button in BUTTON.finditer(source, item.end(), end):
            action_end = closing(code, button.end() - 1)
            # The chain ends at the first line outside the button's modifiers.
            tail = source[action_end + 1:end]
            modifiers = re.match(r'(?:\s*\.[^\n]+)*', tail)[0]
            items.append(dict(start=button.start(), end=action_end + 1,
                              label=button[1], symbol=button[2], placement=item[1],
                              action=source[button.end():action_end], modifiers=modifiers))
    return items


def sources():
    return sorted(p for p in (ROOT / "Open UI").rglob("*.swift") if p.name not in DEFERRED)


class ToolbarTests(unittest.TestCase):
    def test_no_legacy_text_navigation_actions(self):
        legacy = []
        for path in sources():
            for c in controls(path.read_text()):
                if not c["symbol"] or ".labelStyle(.iconOnly)" not in c["modifiers"]:
                    legacy.append(f'{path.relative_to(ROOT)}: {c["label"]}')
        self.assertEqual([], legacy)

    def test_existing_actions_labels_and_placements_are_preserved(self):
        count = 0
        for path in sources():
            relative = str(path.relative_to(ROOT))
            before = subprocess.check_output(["git", "show", f"{BASE}:{relative}"], cwd=ROOT, text=True)
            after = path.read_text()
            if before == after:
                continue
            old, new = controls(before), controls(after)
            self.assertEqual(len(old), len(new), relative)
            for a, b in zip(old, new):
                self.assertEqual((a["label"], a["action"], a["placement"]),
                                 (b["label"], b["action"], b["placement"]), relative)
                count += 1
        self.assertGreater(count, 0)

    def test_scope_excludes_alerts_inline_and_keyboard_actions(self):
        source = '''Button("Cancel") { inline() }
        .alert("Demo") { Button("Save") { alert() } }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { Button("Done") { keyboard() } }
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }'''
        self.assertEqual([" dismiss() "], [c["action"] for c in controls(source)])

    def test_navigation_close_symbols_are_not_precircled(self):
        for path in sources():
            source = path.read_text()
            code = masked(source)
            for item in re.finditer(r'ToolbarItem(?:Group)?\([^\n]*\)\s*\{', code):
                end = closing(code, item.end() - 1)
                self.assertNotIn('"xmark.circle', source[item.start():end], str(path.relative_to(ROOT)))

    def test_only_presentation_changes(self):
        def normalize(source):
            source = re.sub(r', systemImage: "(?:xmark|checkmark)"', '', source)
            source = re.sub(r'\.(?:labelStyle\(\.iconOnly\)|tint\(\.secondary\)|'
                            r'scaledFont\([^\n]*?\)|fontWeight\([^\n]*?\)|'
                            r'foregroundStyle\([^\n]*?\))', '', source)
            source = source.replace('Label("Cancel")', 'Text("Cancel")')
            return re.sub(r'\s+', '', source)
        changed = subprocess.check_output(["git", "diff", BASE, "--name-only", "--", "Open UI"], cwd=ROOT, text=True)
        for relative in changed.splitlines():
            before = subprocess.check_output(["git", "show", f"{BASE}:{relative}"], cwd=ROOT, text=True)
            self.assertEqual(normalize(before), normalize((ROOT / relative).read_text()), relative)


if __name__ == "__main__":
    import sys
    if "--inventory" in sys.argv:
        for path in sources():
            source = path.read_text()
            for c in controls(source):
                if not c["symbol"]:
                    line = source.count("\n", 0, c["start"]) + 1
                    print(f'{path.relative_to(ROOT)}:{line}: {c["placement"]} {c["label"]} => {c["action"].strip()}')
    else:
        unittest.main()
