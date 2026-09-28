"""Test exact Notes search API/manager methods and the production list view-model."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
def read(path):
    return subprocess.check_output(["git", "show", "origin/main:" + path], cwd=root, text=True) if baseline else (root / path).read_text()
api = read("Open UI/Core/Networking/APIClient.swift")
method = api[api.index("    func searchNotes("):api.index("    // MARK: - Profile & Account")]
manager = read("Open UI/Core/Services/NotesManager.swift")
search = manager[manager.index("    func searchNotes("):manager.index("    /// Pins or unpins")]
vm = read("Open UI/Features/Notes/ViewModels/NotesListViewModel.swift")
with tempfile.TemporaryDirectory(prefix="relay-notes-search-", dir=os.environ.get("TMPDIR")) as directory:
    directory = Path(directory)
    generated = directory / "Methods.swift"
    generated.write_text("import Foundation\nimport os.log\nextension APIClient {\n" + method + "\n}\nextension NotesManager {\n" + search + "\n}\n" + vm)
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", *( ["-D", "BASELINE"] if baseline else []), str(generated), str(root / "Open UI/Core/Models/Note.swift"), str(root / "Tests/NotesSearch/Checks.swift"), "-o", str(directory / "checks")], check=True)
    subprocess.run([str(directory / "checks")], check=True)
