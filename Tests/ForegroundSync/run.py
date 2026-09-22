#!/usr/bin/env python3
"""Exercise production lifecycle callbacks with synthetic cached chats."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "Open UI/Features/Chat/ViewModels/ChatViewModel.swift").read_text()
view = (root / "Open UI/Features/Chat/Views/ChatDetailView.swift").read_text()


def method(name):
    start = source.index(f"    private func {name}(")
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end].replace("private func", "func", 1)


# Keep the baseline runnable before the visibility property is introduced.
visibility = re.search(r"var visibleViewIDs[^\n]+", source)
view_id = re.search(r"var visibilityID[^\n]+", view)
appearance_end = view.index("            viewModel.syncOnEntry()")
appearance_start = view.rindex(".onAppear {", 0, appearance_end) + len(".onAppear {")
disappearance_start = view.index("private func handleDisappear() {") + len("private func handleDisappear() {")
disappearance_end = view.index("        keyboard.stop()", disappearance_start)
harness = (Path(__file__).parent / "Checks.swift").read_text()
for marker, code in {
    "VISIBILITY": visibility.group() if visibility else "var visibleViewIDs: Set<UUID> = []",
    "VIEW_ID": view_id.group() if view_id else "var visibilityID = UUID()",
    "LISTENERS": method("startForegroundSyncListener"),
    "APPEAR": view[appearance_start:appearance_end],
    "DISAPPEAR": view[disappearance_start:disappearance_end],
}.items():
    harness = harness.replace(f"// {marker}", code)
with tempfile.TemporaryDirectory(prefix="relay-foreground-tests-") as directory:
    swift = Path(directory) / "Checks.swift"
    binary = Path(directory) / "checks"
    swift.write_text(harness)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
