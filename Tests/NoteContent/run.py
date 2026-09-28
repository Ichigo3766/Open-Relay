"""Compile production note parsing/update paths with a synthetic shallow-merge server."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[2]
baseline = "--baseline" in sys.argv
def source(path):
    return subprocess.check_output(["git", "show", "origin/main:" + path], cwd=root, text=True) if baseline else (root / path).read_text()

model = source("Open UI/Core/Models/Note.swift")
api = source("Open UI/Core/Networking/APIClient.swift")
methods = api[api.index("    func createNote("):api.index("    func deleteNote(")]
manager = source("Open UI/Core/Services/NotesManager.swift")
update = manager[manager.index("    func updateNote("):manager.index("    /// Deletes a note on the server.")]
if not baseline:
    editor = source("Open UI/Features/Notes/Views/NoteEditorView.swift")
    assert "contentChanged: contentText != note?.content" in editor
    assert "if saved { note = updatedNote }" in editor
    assert "hasChanges = !saved || titleText != updatedNote.title || contentText != updatedNote.content" in editor
stubs = '''
enum Method { case post }
final class Network {
    var writes: [[String: Any]] = []
    var fail = false
    var data: [String: Any] = ["content": ["md": "Paper stars", "html": "<p><b>Paper stars</b></p>", "json": ["type": "doc", "custom": true]], "files": [["id": "synthetic-file"]], "versions": [["id": "synthetic-version"]]]
    func requestJSON(path: String, method: Method, body: [String: Any]) async throws -> [String: Any] {
        writes.append(body)
        if fail { throw NSError(domain: "Synthetic", code: 503) }
        if let patch = body["data"] as? [String: Any] { data.merge(patch) { _, new in new } }
        return ["id": "demo-note", "title": body["title"] ?? "", "data": data]
    }
}
final class APIClient {
    let network = Network()
'''
logger = '''
struct Logger { func warning(_ text: String) {} }
final class NotesManager {
    var apiClient: APIClient? = APIClient()
    var isServerEnabled = true
    var cached: Note?
    let logger = Logger()
    func updateLocalNote(_ note: Note) { cached = note }
'''
with tempfile.TemporaryDirectory(prefix="relay-note-content-") as directory:
    work = Path(directory)
    production = work / "Production.swift"
    production.write_text(model + stubs + methods + "}\n" + logger + update + "}\n")
    binary = work / "checks"
    subprocess.run(["swiftc", "-swift-version", "5", *(["-D", "BASELINE"] if baseline else []), str(production), str(root / "Tests/NoteContent/Checks.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
