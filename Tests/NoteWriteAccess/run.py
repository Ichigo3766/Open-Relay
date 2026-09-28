"""Exercise the actual note decoder and save method with synthetic data only."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
def read(path):
    if baseline:
        return subprocess.check_output(["git", "show", "4151a735:" + path], cwd=root, text=True)
    return (root / path).read_text()

model = read("Open UI/Core/Models/Note.swift")
manager = read("Open UI/Core/Services/NotesManager.swift")
method = manager[manager.index("    func updateNote("):manager.index("    /// Deletes a note")]
checks = (root / "Tests/NoteWriteAccess/Checks.swift").read_text().replace("// SAVE METHOD", method)
if baseline:
    checks = '''
import Foundation
@main struct Checks {
    static func main() throws {
        let note = Note.fromServerJSON(["id": "paper", "write_access": false])!
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        precondition(encoded["writeAccess"] as? Bool == false, "Read-only access was lost")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="note-access-") as directory:
    work = Path(directory)
    (work / "Note.swift").write_text(model)
    (work / "Checks.swift").write_text(checks)
    subprocess.run(["swiftc", "-swift-version", "5", str(work / "Note.swift"), str(work / "Checks.swift"), "-o", str(work / "checks")], check=True)
    subprocess.run([str(work / "checks")], check=True)
