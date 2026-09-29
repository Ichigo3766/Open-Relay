import Foundation

enum Method { case get, post }
struct Conversation { let id: String; let title: String; let params: [String: Any] }
@MainActor final class NetworkManager {
    var authToken: String? = "synthetic-token"
    var requests: [(String, Method)] = []
    var fail = false
    var malformed = false
    var afterRequest: (() -> Void)?
    var delay = false
    func requestRaw(path: String, method: Method = .get, deduplicate: Bool) async throws -> (Data, Int) {
        precondition(!deduplicate)
        requests.append((path, method))
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        if fail { throw URLError(.timedOut) }
        afterRequest?()
        let result: Any
        if malformed { result = ["unexpected": true] }
        else if path.hasSuffix("/chats") { result = [["id": "older", "title": "Earlier note chat"]] }
        else {
            result = ["id": method == .post ? "new-linked-chat" : "linked-chat",
                      "chat": ["title": "Note discussion", "params": ["system": "Synthetic native note context", "temperature": 0.2]]]
        }
        return (try JSONSerialization.data(withJSONObject: result), 200)
    }
}
@MainActor final class APIClient {
    let network = NetworkManager()
    var note: [String: Any] = ["id": "paper", "title": "Paper Lanterns", "data": ["content": ["md": "Fold a square."]]]
    var reads = 0
    var afterRead: (() -> Void)?
    func getNoteById(_ id: String) async throws -> [String: Any] {
        precondition(id == "paper"); reads += 1; afterRead?(); return note
    }
    nonisolated func parseFullConversation(_ json: [String: Any]) -> Conversation {
        let chat = json["chat"] as! [String: Any]
        return Conversation(id: json["id"] as! String, title: chat["title"] as! String,
                            params: chat["params"] as! [String: Any])
    }
}

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1; print("PASS \(name)") }
        func rejects(_ name: String, _ operation: () async throws -> Void) async {
            do { try await operation(); preconditionFailure(name) } catch { check(true, name) }
        }
        let api = APIClient()
        var current = true
        let session = NoteChatSession(noteId: "paper", api: api) { current }
        check(api.reads == 0 && api.network.requests.isEmpty, "initialization makes no requests")
        await rejects("unsaved text blocks chat creation") { _ = try await session.open(title: "Paper Lanterns", content: "Unsaved text") }
        check(api.network.requests.isEmpty && !session.isBusy, "unsaved check never calls mutating GET")
        await rejects("unsaved title blocks chat creation") { _ = try await session.open(title: "New title", content: "Fold a square.") }
        let opened = try await session.open(title: "Paper Lanterns", content: "Fold a square.")
        check(opened.id == "linked-chat", "native get-or-create response used")
        check(opened.params["system"] as? String == "Synthetic native note context", "native params passed to conversation decoder")
        check(api.network.requests.count == 1 && api.network.requests[0].0 == "/api/v1/notes/paper/chat"
              && api.network.requests[0].1 == .get, "get-or-create uses authenticated transport without POST")
        check(session.chats.map(\.id) == ["linked-chat"], "initial chat remains usable before history request")
        api.network.fail = true
        await session.refresh()
        check(session.error != nil && session.chats.map(\.id) == ["linked-chat"], "history failure retains open chat")
        check(api.network.requests.count == 2, "history failure is not automatically retried")
        api.network.fail = false
        await session.refresh()
        check(session.error == nil && session.chats.map(\.id) == ["older"], "manual history retry replaces confirmed list")
        check(api.network.requests.last?.0 == "/api/v1/notes/paper/chats", "native list route")
        let created = try await session.create()
        check(created.id == "new-linked-chat" && api.network.requests.last?.1 == .post, "explicit create uses native POST")
        check(session.chats.map(\.id) == ["new-linked-chat", "older"], "created chat added to history")
        api.network.fail = true
        let before = api.network.requests.count
        await rejects("create failure surfaced") { _ = try await session.create() }
        check(api.network.requests.count == before + 1, "create is not retried automatically")
        check(session.chats.count == 2 && !session.isBusy, "create failure preserves confirmed state")
        api.network.fail = false
        current = false
        let stopped = api.network.requests.count
        await rejects("server switch blocks create") { _ = try await session.create() }
        await session.refresh()
        check(api.network.requests.count == stopped, "stale session never sends a request")
        current = true
        api.network.authToken = "other-synthetic-account"
        await rejects("account switch blocks get-or-create") { _ = try await session.open(title: "Paper Lanterns", content: "Fold a square.") }
        api.network.authToken = "synthetic-token"
        api.afterRead = { current = false }
        await rejects("session switch during note read blocks creation") { _ = try await session.open(title: "Paper Lanterns", content: "Fold a square.") }
        check(api.network.requests.count == stopped, "late note response cannot create chat")
        api.afterRead = nil; current = true
        api.network.afterRequest = { current = false }
        await rejects("late creation response rejected") { _ = try await session.create() }
        check(session.chats.count == 2, "late response not inserted")
        api.network.afterRequest = nil; current = true; api.network.malformed = true
        await rejects("malformed creation rejected") { _ = try await session.create() }
        await session.refresh()
        check(session.error != nil && session.chats.count == 2, "malformed history preserves previous state")
        api.network.malformed = false; api.network.delay = true
        let first = Task { try await session.create() }
        await Task.yield()
        await rejects("overlapping create blocked") { _ = try await session.create() }
        _ = try await first.value
        let cancelled = Task { try await session.create() }
        await Task.yield(); cancelled.cancel()
        await rejects("cancelled create rejected") { _ = try await cancelled.value }
        check(!session.isBusy, "cancellation releases operation guard")
        print("\(count) checks passed")
    }
}
