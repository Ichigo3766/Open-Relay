"""Compile actual note parsing and pin routes against a synthetic transport/cache."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
def read(path):
    return subprocess.check_output(["git", "show", "origin/main:" + path], cwd=root, text=True) if baseline else (root / path).read_text()

model = read("Open UI/Core/Models/Note.swift")
checks = '''
import Foundation
@main struct Checks {
    static func main() async throws {
        let note = Note.fromServerJSON(["id": "demo-note", "is_pinned": true])!
        precondition(note.isPinned, "Native server pin is lost")
        print("Native pin decoded")
    }
}
'''
if not baseline:
    api = read("Open UI/Core/Networking/APIClient.swift")
    manager = read("Open UI/Core/Services/NotesManager.swift")
    vm = read("Open UI/Features/Notes/ViewModels/NotesListViewModel.swift")
    api_method = api[api.index("    func toggleNotePin("):api.index("    func createNote(")]
    manager_method = manager[manager.index("    func togglePin("):manager.index("    // MARK: - File Operations")]
    vm_method = vm[vm.index("    func togglePin("):vm.rindex("}")]
    errors = manager[manager.index("enum NotesError:"):]
    checks = (root / "Tests/NotePins/Checks.swift").read_text().replace("// API", api_method).replace("// MANAGER", manager_method).replace("// VIEWMODEL", vm_method)
    model += errors
    assert "isLocalOnly: true" in manager
with tempfile.TemporaryDirectory(prefix="relay-note-pins-") as directory:
    work = Path(directory)
    (work / "Production.swift").write_text(model)
    (work / "Checks.swift").write_text(checks)
    subprocess.run(["swiftc", "-swift-version", "5", str(work / "Production.swift"), str(work / "Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
