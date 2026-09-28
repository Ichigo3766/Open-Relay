import Foundation

@MainActor final class APIClient {
    var calls = 0
    func updateNote(id: String, title: String?, markdownContent: String?) async throws -> [String: Any] {
        calls += 1
        return [:]
    }
}
struct Logger { func warning(_ message: String) {} }
@MainActor final class NotesManager {
    var apiClient: APIClient? = APIClient()
    var isServerEnabled = true
    var localWrites = 0
    let logger = Logger()
    func updateLocalNote(_ note: Note) { localWrites += 1 }
    // SAVE METHOD
}

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); count += 1
        }
        let readOnly = Note.fromServerJSON(["id": "paper", "write_access": false])!
        let writer = Note.fromServerJSON(["id": "paper", "write_access": true])!
        let legacy = Note.fromServerJSON(["id": "legacy"])!
        check(readOnly.writeAccess == false && !readOnly.canEdit, "native read-only access")
        check(writer.writeAccess == true && writer.canEdit, "native write access including group grants")
        check(legacy.writeAccess == nil && legacy.canEdit, "legacy response compatibility; server still authorizes writes")
        check(Note(isLocalOnly: true).canEdit, "offline local-only editing unchanged")
        let roundTrip = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(readOnly))
        check(roundTrip.writeAccess == false && !roundTrip.canEdit, "cache round-trip preserves access")
        var oldCache = try JSONSerialization.jsonObject(with: JSONEncoder().encode(writer)) as! [String: Any]
        oldCache.removeValue(forKey: "writeAccess")
        let oldNote = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: oldCache))
        check(oldNote.writeAccess == nil && oldNote.canEdit, "existing cached notes still decode")
        var changed = readOnly
        changed.writeAccess = true
        check(changed != readOnly, "permission change invalidates equal note rows")
        check(changed == changed, "note equality remains reflexive")
        let manager = NotesManager()
        await manager.updateNote(readOnly)
        check(manager.localWrites == 0, "rejected local write cannot mask shared content")
        check(manager.apiClient!.calls == 0, "no unauthorized update request")
        await manager.updateNote(writer)
        check(manager.localWrites == 1 && manager.apiClient!.calls == 1, "authorized editing still saves")
        await manager.updateNote(legacy)
        check(manager.localWrites == 2 && manager.apiClient!.calls == 2, "legacy saves still reach server permission checks")
        manager.apiClient = nil
        await manager.updateNote(readOnly)
        check(manager.localWrites == 2, "cached read-only note remains read-only offline")
        await manager.updateNote(Note(isLocalOnly: true))
        check(manager.localWrites == 3, "local-only notes still save offline")
        print("\(count) note-access checks passed")
    }
}
