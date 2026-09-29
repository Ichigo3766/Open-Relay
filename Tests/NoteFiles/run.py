"""Compile actual attachment model and write API with mocked transport/upload."""
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[1]
with tempfile.TemporaryDirectory(prefix="note-files-") as directory:
    binary = Path(directory) / "checks"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library",
                    str(root / "Open UI/Core/Services/NoteFilesModel.swift"),
                    str(here / "Checks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
