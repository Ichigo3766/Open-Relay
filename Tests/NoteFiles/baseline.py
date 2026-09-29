"""Reproduce the native note attachment omission without a server or user data."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
baseline = "4151a735512d5d6dbc9fd1962fa806517a0d4ea7"
def original(path):
    return subprocess.check_output(["git", "show", f"{baseline}:{path}"], cwd=root, text=True)
with tempfile.TemporaryDirectory(prefix="note-files-baseline-") as directory:
    source = Path(directory) / "Note.swift"
    source.write_text(original("Open UI/Core/Models/Note.swift"))
    main = Path(directory) / "main.swift"
    main.write_text('''import Foundation
let json: [String: Any] = ["id": "paper", "data": ["content": ["md": "Synthetic craft plan"],
    "files": [["id": "guide", "type": "file", "name": "guide.txt", "size": 80]]]]
let note = Note.fromServerJSON(json)!
precondition(note.fileAttachments.isEmpty)
print("REPRODUCED: native data.files is ignored by the baseline note parser")
''')
    binary = Path(directory) / "repro"
    subprocess.run(["swiftc", str(source), str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
api = original("Open UI/Core/Networking/APIClient.swift")
update = api.split("    func updateNote(", 1)[1].split("    func deleteNote(", 1)[0]
assert '"files"' not in update
print("REPRODUCED: existing note saves never write the uploaded file references")
