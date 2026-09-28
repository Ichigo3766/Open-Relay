import Foundation

enum Method { case post }
@MainActor final class Network {
    var calls: [String] = []
    var reply: [String: Any] = ["is_pinned": true]
    var fail = false
    var suspend = false
    var pending: CheckedContinuation<Void, Never>?
    func requestJSON(path: String, method: Method) async throws -> [String: Any] {
        calls.append(path)
        if suspend { await withCheckedContinuation { pending = $0 } }
        if fail { throw NSError(domain: "Synthetic", code: 503) }
        return reply
    }
}
@MainActor final class APIClient {
    let network = Network()
    // API
}
@MainActor final class NotesManager {
    var apiClient: APIClient? = APIClient()
    var isServerEnabled = true
    var cache: [Note] = []
    func fetchLocalNotes() -> [Note] { cache }
    func saveLocalNotes(_ notes: [Note]) { cache = notes }
    // MANAGER
}
@MainActor final class NotesListViewModel {
    var notes: [Note] = []
    var searchResults: [Note]?
    var manager: NotesManager?
    var pinningNoteIDs: Set<String> = []
    var errorMessage: String?
    // VIEWMODEL
}

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            count += 1
        }
        let note = Note.fromServerJSON(["id": "demo-note", "title": "Paper stars", "is_pinned": true])!
        check(note.isPinned, "server pin is decoded")
        check(!Note.fromServerJSON(["id": "legacy"])!.isPinned, "older responses remain compatible")
        let manager = NotesManager()
        let api = manager.apiClient!
        manager.cache = [Note(id: note.id, content: "Unsaved draft"), Note(id: "unrelated")]
        let pinned = try await manager.togglePin(note)
        check(pinned, "use returned server state, not inversion of stale UI state")
        check(api.network.calls == ["/api/v1/notes/demo-note/pin"], "native authenticated API route")
        check(manager.cache[0].content == "Unsaved draft" && manager.cache.count == 2, "pin update preserves local content and unrelated notes")
        check(manager.cache[0].isPinned, "cache adopts confirmed state")
        api.network.reply = ["is_pinned": false]
        check(try await manager.togglePin(note) == false, "server unpin works")
        api.network.reply = [:]
        do { _ = try await manager.togglePin(note); fatalError("Malformed response accepted") }
        catch { check(!manager.cache[0].isPinned, "malformed response leaves state unchanged") }
        api.network.fail = true
        do { _ = try await manager.togglePin(note); fatalError("Failed pin accepted") }
        catch { check(!manager.cache[0].isPinned, "network error leaves state unchanged") }
        let calls = api.network.calls.count
        let local = Note(id: "local", isLocalOnly: true)
        manager.cache.append(local)
        check(try await manager.togglePin(local), "local-only pin still works")
        check(api.network.calls.count == calls, "local-only note does not contact server")
        manager.apiClient = nil
        do { _ = try await manager.togglePin(note); fatalError("Remote pin silently changed locally") }
        catch { check(!manager.cache[0].isPinned, "missing connection cannot silently change a remote pin") }
        check(try await manager.togglePin(local), "explicit local note works without a connection")
        manager.apiClient = api
        let vm = NotesListViewModel()
        vm.manager = manager
        vm.notes = [note, Note(id: "not-in-cache")]
        vm.searchResults = [note]
        api.network.fail = false
        api.network.reply = ["is_pinned": false]
        api.network.suspend = true
        let task = Task { await vm.togglePin(note) }
        while api.network.pending == nil { await Task.yield() }
        check(vm.pinningNoteIDs.contains(note.id), "pending state disables pin control")
        await vm.togglePin(note)
        check(api.network.calls.count == calls + 1, "duplicate tap cannot toggle twice")
        api.network.pending?.resume(); api.network.pending = nil
        await task.value
        check(vm.pinningNoteIDs.isEmpty, "pending state clears")
        check(vm.notes.count == 2 && vm.notes[1].id == "not-in-cache", "pinning does not replace full list with partial cache")
        check(!vm.notes[0].isPinned && vm.searchResults?[0].isPinned == false, "main and search rows both update")
        api.network.suspend = false
        api.network.fail = true
        await vm.togglePin(note)
        check(vm.errorMessage != nil && !vm.notes[0].isPinned, "UI reports failure without optimistic false success")
        print("\(count) note-pin checks passed")
    }
}
