"""Compile the native event draft against synthetic event inputs only."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
models = (root / "Open UI/Core/Models/CalendarModels.swift").read_text().replace("import SwiftUI", "")
color = "struct Color { static let blue = Color(); init() {}; init?(hex: String) {} }\n"
with tempfile.TemporaryDirectory(prefix="relay-calendar-editing-") as directory:
    work = Path(directory)
    (work / "Models.swift").write_text(models + color)
    subprocess.run(["swiftc", "-swift-version", "5", str(work / "Models.swift"),
        str(root / "Open UI/Core/Models/CalendarEventDraft.swift"),
        str(root / "Tests/CalendarEditing/Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
