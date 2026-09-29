import Foundation

enum HTTPMethod: String { case get = "GET", post = "POST" }
@MainActor final class FakeSession {
    var requests: [URLRequest] = []
    var remote = Note(id: "folding", title: "Paper Shapes", content: "Fold a square.")
    var status = 200
    var malformed = false
    var fail = false
    var afterRequest: (() async -> Void)?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        await afterRequest?()
        if fail { throw URLError(.notConnectedToInternet) }
        if request.httpMethod == "POST", status == 200, !malformed {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if let title = body["title"] as? String { remote.title = title }
            if let data = body["data"] as? [String: Any], let content = data["content"] as? [String: Any] {
                remote.content = content["md"] as! String
            }
        }
        let json: [String: Any] = malformed ? ["invalid": true] : ["id": remote.id, "title": remote.title,
            "data": ["content": ["md": remote.content, "html": "<p>Fold a square.</p>"]]]
        return (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class NetworkManager {
    let session = FakeSession()
    var authToken: String? = "synthetic-token"
    func buildRequest(path: String, method: HTTPMethod, body: Data?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://notes.example.test" + path)!)
        request.httpMethod = method.rawValue; request.httpBody = body
        request.setValue(authToken.map { "Bearer " + $0 }, forHTTPHeaderField: "Authorization")
        return request
    }
}
@MainActor final class APIClient { let network = NetworkManager() }
@MainActor final class NotesManager {
    var notes: [Note] = []
    var isServerEnabled = true
    var deletions = 0
    var afterFetch: (() async -> Void)?
    func fetchNotes() async -> [Note] { await afterFetch?(); return notes }
    func createNote(title: String) async -> Note { Note(title: title) }
    func deleteNote(id: String) async { deletions += 1 }
    func searchNotes(query: String) async -> [Note] { notes.filter { $0.content.contains(query) } }
    func togglePin(id: String) {
        if let index = notes.firstIndex(where: { $0.id == id }) { notes[index].isPinned.toggle() }
    }
    func fetchLocalNotes() -> [Note] { notes }
}

@main struct Checks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let identity = NoteDraftStore.Identity(server: "https://notes.example.test", account: "demo-user")
        var count = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1; print("PASS \(label)") }
        let store = NoteDraftStore(identity: identity, root: root)
        let original = Note(id: "folding", title: "Paper Shapes", content: "Fold a square.")
        var edited = original; edited.content = "Fold a square, then add a paper handle."
        try store.stage(original: original, edited: edited)
        let first = try store.load(original.id)!
        check(first.original.content == original.content && first.edited.content == edited.content, "durable edit includes its server baseline")
        try store.stage(original: original, edited: edited)
        check(try store.load(original.id)?.revision == first.revision, "unchanged text does not rewrite its revision")
        let reopened = NoteDraftStore(identity: identity, root: root)
        check(try reopened.load(original.id)?.edited.content == edited.content, "reopening restores the unsynced edit")
        check(try reopened.pendingNotes().map(\.id) == [original.id], "pending notes remain discoverable independently of server list")
        check(try NoteDraftStore(identity: .init(server: identity.server, account: "other-user"), root: root).pendingNotes().isEmpty, "account isolation")
        check(try NoteDraftStore(identity: .init(server: "https://other.example.test", account: identity.account), root: root).pendingNotes().isEmpty, "server isolation")
        let api = APIClient()
        let transport = api.network.session
        var current = true
        let session = try NoteDraftSession(noteID: original.id, api: api, store: store) { current }
        check(session.requiresRetry && transport.requests.isEmpty, "recovery waits for explicit retry")
        transport.status = 503
        check(await session.save() == nil && session.error == .server, "failed server request is recoverable")
        check(try store.load(original.id)?.edited.content == edited.content, "failure retains exact edited text")
        check(transport.requests.count == 1, "failure is not automatically retried")
        _ = session.stage(original: original, title: original.title, content: edited.content)
        check(session.requiresRetry && session.error == .server, "typing does not silently dismiss a failed save")
        transport.status = 200
        check(await session.save()?.content == edited.content, "manual retry succeeds")
        check(try store.load(original.id) == nil, "confirmed success removes pending metadata")
        check(transport.requests.map(\.httpMethod) == ["GET", "GET", "POST"], "recovered draft checks server before native update")
        check(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token" }, "all requests preserve authentication")
        let sent = try JSONSerialization.jsonObject(with: transport.requests.last!.httpBody!) as! [String: Any]
        check(sent["title"] == nil, "body-only edit does not overwrite title")
        let content = (sent["data"] as! [String: Any])["content"] as! [String: Any]
        check(content["html"] as? String == "" && content["json"] is NSNull && content["HTML"] == nil, "native content keys")

        transport.remote = original
        var renamed = original; renamed.title = "Paper Lanterns"
        try store.stage(original: original, edited: renamed)
        let renameSession = try NoteDraftSession(noteID: original.id, api: api, store: store) { current }
        check(await renameSession.save()?.title == renamed.title, "rename retry succeeds")
        let renameBody = try JSONSerialization.jsonObject(with: transport.requests.last!.httpBody!) as! [String: Any]
        check(renameBody["data"] == nil, "rename preserves rich server content")

        transport.remote = original
        try store.stage(original: original, edited: edited)
        let conflictSession = try NoteDraftSession(noteID: original.id, api: api, store: store) { current }
        transport.remote.content = "Use a paper strip instead."
        let beforeConflict = transport.requests.count
        check(await conflictSession.save() == nil && conflictSession.error == .conflict, "conflicting remote edit is not overwritten")
        check(transport.requests.count == beforeConflict + 1 && transport.requests.last!.httpMethod == "GET", "conflict makes no write")
        check(try store.load(original.id)?.edited.content == edited.content, "conflict retains recovery text")
        transport.remote = edited
        let beforeAlreadySaved = transport.requests.count
        check(await conflictSession.save()?.content == edited.content, "lost success response reconciles with server")
        check(try transport.requests.count == beforeAlreadySaved + 1 && store.load(original.id) == nil, "already-saved edit is not submitted twice")

        transport.remote = original
        let active = try NoteDraftSession(noteID: original.id, api: api, store: store) { current }
        check(active.stage(original: original, title: original.title, content: edited.content), "typing persists before upload")
        var later = edited; later.content += " Decorate the handle."
        transport.afterRequest = {
            try! store.stage(original: original, edited: later)
            transport.afterRequest = nil
        }
        check(await active.save()?.content == edited.content, "first in-flight version can finish")
        check(try store.load(original.id)?.edited.content == later.content, "late success retains newer typing")
        check(try store.load(original.id)?.original.content == edited.content, "newer edit advances its saved baseline")
        check(await active.save()?.content == later.content, "next edit saves serially")
        check(try store.pendingNotes().isEmpty, "last version clears recovery data")

        transport.remote = original
        let firstPost = try NoteDraftSession(noteID: original.id, api: api, store: store) { current }
        _ = firstPost.stage(original: original, title: original.title, content: edited.content)
        transport.status = 503
        let beforeFailedPost = transport.requests.count
        check(await firstPost.save() == nil && firstPost.requiresRetry, "initial upload failure requires retry")
        check(transport.requests.count == beforeFailedPost + 1 && transport.requests.last?.httpMethod == "POST", "initial upload is a single write")
        check(try store.load(original.id)?.edited.content == edited.content, "initial upload failure preserves exact text")
        transport.status = 200
        transport.remote.title = "Server title"
        check(await firstPost.save()?.title == "Server title", "body retry preserves independently changed server title")

        try store.stage(original: original, edited: edited)
        let manager = NotesManager()
        manager.notes = [original]
        let list = NotesListViewModel()
        list.configure(with: manager, drafts: store)
        await list.loadNotes()
        check(list.notes.first?.content == edited.content, "server list cannot replace unsynced text")
        manager.notes = []
        await list.refreshNotes()
        check(list.notes.first?.content == edited.content, "draft remains discoverable when absent from server page")
        list.searchText = "handle"
        list.triggerSearch()
        try await Task.sleep(for: .milliseconds(350))
        check(list.filteredNotes.first?.content == edited.content, "search finds text in pending draft")
        list.searchText = "absent phrase"
        list.triggerSearch()
        try await Task.sleep(for: .milliseconds(350))
        check(list.filteredNotes.isEmpty, "search excludes nonmatching pending drafts")
        list.searchText = ""
        list.clearSearch()
        manager.notes = [original]
        list.togglePin(edited)
        check(list.notes.first?.content == edited.content, "pin refresh cannot hide recovery draft")
        check(list.notes.first?.isPinned == true, "recovery overlay preserves current pin state")
        manager.notes = []
        await list.deleteNote(edited)
        check(manager.deletions == 0 && list.errorMessage != nil, "delete protects unresolved draft")
        let otherStore = NoteDraftStore(identity: .init(server: identity.server, account: "other-user"), root: root)
        list.configure(with: manager, drafts: otherStore)
        check(list.notes.isEmpty, "changing account clears previously displayed drafts")
        await list.loadNotes()
        check(list.notes.isEmpty, "new account cannot list old account draft")
        list.configure(with: manager, drafts: store)
        manager.afterFetch = { list.configure(with: manager, drafts: otherStore) }
        await list.loadNotes()
        check(list.notes.isEmpty, "late list response cannot reveal old account draft")
        manager.afterFetch = nil
        try store.discard(original.id)

        transport.remote = original
        try store.stage(original: original, edited: edited)
        let identitySession = try NoteDraftSession(noteID: original.id, api: api, store: store) { current }
        current = false
        let beforeSwitch = transport.requests.count
        check(await identitySession.save() == nil && transport.requests.count == beforeSwitch, "server switch prevents request")
        current = true; api.network.authToken = "other-synthetic-token"
        check(await identitySession.save() == nil && transport.requests.count == beforeSwitch, "account token switch prevents request")
        api.network.authToken = "synthetic-token"
        transport.afterRequest = { current = false }
        check(await identitySession.save() == nil, "identity change during response is rejected")
        check(try store.load(original.id) != nil, "stale response cannot clear the saved edit")
        transport.afterRequest = nil; current = true
        transport.malformed = true
        check(try await identitySession.save() == nil && store.load(original.id) != nil, "malformed response preserves draft")
        transport.malformed = false
        transport.status = 403
        check(try await identitySession.save() == nil && store.load(original.id) != nil, "permission failure preserves draft")
        transport.status = 200
        transport.afterRequest = { try? await Task.sleep(for: .milliseconds(150)) }
        let firstSave = Task { await identitySession.save() }
        while !identitySession.isSaving { await Task.yield() }
        let beforeDuplicate = transport.requests.count
        check(await identitySession.save() == nil && transport.requests.count == beforeDuplicate, "duplicate save cannot overlap")
        firstSave.cancel()
        _ = await firstSave.value
        check(try store.load(original.id) != nil && !identitySession.isSaving, "cancelled save retains draft and releases guard")
        transport.afterRequest = nil
        try store.discard(original.id)
        check(try store.load(original.id) == nil, "explicit discard removes pending file")
        transport.remote = original
        let inFlight = try NoteDraftSession(noteID: original.id, api: api, store: store) { true }
        _ = inFlight.stage(original: original, title: original.title, content: edited.content)
        transport.afterRequest = { try? await Task.sleep(for: .milliseconds(150)) }
        let started = Task { await inFlight.save() }
        while !inFlight.isSaving { await Task.yield() }
        let replacement = try NoteDraftSession(noteID: original.id, api: api, store: reopened) { true }
        let alreadyStarted = transport.requests.count
        check(await replacement.save() == nil && transport.requests.count == alreadyStarted,
              "reopening editor cannot overlap an active save")
        do { try reopened.discard(original.id); preconditionFailure("discard overlapped active save") }
        catch { check(try store.load(original.id) != nil, "discard waits for active save to finish") }
        _ = await started.value
        transport.afterRequest = nil
        check(try store.load(original.id) == nil, "active save still finishes after editor replacement")
        list.configure(with: manager, drafts: store)
        await list.deleteNote(edited)
        check(manager.deletions == 1, "delete proceeds after explicit draft discard")

        let corruptRoot = root.appendingPathComponent("corrupt")
        let corruptStore = NoteDraftStore(identity: identity, root: corruptRoot)
        try corruptStore.stage(original: original, edited: edited)
        let corruptFile = (FileManager.default.enumerator(at: corruptRoot, includingPropertiesForKeys: nil)!.allObjects as! [URL]).first { $0.pathExtension == "json" }!
        let unreadable = Data("not-valid-json".utf8)
        try unreadable.write(to: corruptFile)
        do { _ = try corruptStore.load(original.id); preconditionFailure("corrupt draft accepted") }
        catch { check(try Data(contentsOf: corruptFile) == unreadable, "unreadable draft is not erased") }
        do { try corruptStore.stage(original: original, edited: edited); preconditionFailure("corrupt draft replaced") }
        catch { check(try Data(contentsOf: corruptFile) == unreadable, "staging cannot overwrite unreadable recovery data") }

        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("synthetic".utf8).write(to: blocked)
        let blockedStore = NoteDraftStore(identity: identity, root: blocked)
        let blockedSession = try NoteDraftSession(noteID: original.id, api: api, store: blockedStore) { true }
        check(!blockedSession.stage(original: original, title: original.title, content: edited.content)
              && blockedSession.error == .storage, "disk failure is shown rather than claiming a saved copy")
        print("\(count) checks passed")
    }
}
