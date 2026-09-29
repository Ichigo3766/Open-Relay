import Foundation

final class APIClient {
    var note: [String: Any] = ["id": "folding", "title": "Paper Shapes", "data": ["content": ["md": "Fold a square."]]]
    func getNotes() async throws -> ([[String: Any]], Bool) { ([note], true) }
    func getNoteById(_ id: String) async throws -> [String: Any] { note }
    func createNote(title: String, markdownContent: String) async throws -> [String: Any] { note }
    func updateNote(id: String, title: String, markdownContent: String?) async throws -> [String: Any] { throw URLError(.notConnectedToInternet) }
    func deleteNote(id: String) async throws -> Bool { true }
    func searchNotes(query: String) async throws -> [[String: Any]] { [] }
    func uploadFile(data: Data, fileName: String) async throws -> (String, String) { ("file", "file") }
}
final class SharedDataService {
    static let shared = SharedDataService()
    struct RecentNote { let id: String; let title: String; let preview: String; let updatedAt: Date }
    func saveRecentNotes(_ notes: [RecentNote]) {}
}

@main struct Baseline {
    static func main() async {
        // This standalone executable uses its own defaults domain, never the app's.
        let manager = NotesManager(apiClient: APIClient())
        let notes = await manager.fetchNotes()
        var edited = notes[0]
        edited.content = "Fold a square, then add a paper handle."
        await manager.updateNote(edited)
        precondition(manager.fetchLocalNote(id: edited.id)?.content == edited.content)
        _ = await manager.fetchNotes()
        precondition(manager.fetchLocalNote(id: edited.id)?.content == "Fold a square.")
        print("REPRODUCED: refreshing after a failed save replaces the unsynced cached edit")
        UserDefaults.standard.removeObject(forKey: "com.openui.notes")
    }
}
