import Foundation

@main enum Checks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "relay-cache-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let cache = ConversationCache(directory: directory, defaults: defaults)
        let scope = ConversationCache.scope(server: "https://relay.example", token: "synthetic-session")!
        let server = Server()
        let fetch: @Sendable (String?) async throws -> (Data, HTTPURLResponse) = { try await server.fetch($0) }

        func check(_ result: Bool, _ message: String) throws {
            if !result { throw Failure(message: message) }
        }
        let first = try await cache.load(scope: scope, id: "chat", preferRecent: true, fetch: fetch)
        _ = try await cache.load(scope: scope, id: "chat", preferRecent: true, fetch: fetch)
        try check(await server.count == 1, "recent navigation should avoid a second request")
        let reopened = ConversationCache(directory: directory, defaults: defaults)
        _ = try await reopened.load(scope: scope, id: "chat", preferRecent: true, fetch: fetch)
        try check(await server.count == 1, "cache should survive recreation")
        let validated = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        let lastTag = await server.lastTag
        try check(validated == first && lastTag == "\"v1\"", "304 must reuse the exact full response")
        try check(await server.count == 2, "forced reads must check even a recent entry")
        await server.configure(version: 2)
        let updated = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(updated != first, "changed ETag should replace old content")
        await server.configure(headers: [:])
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(await server.lastTag == nil, "server without validators must use full GET")

        let otherAccount = ConversationCache.scope(server: "https://relay.example", token: "synthetic-other")!
        let otherServer = ConversationCache.scope(server: "https://second.example", token: "synthetic-session")!
        let otherTenant = ConversationCache.scope(server: "https://relay.example", token: "synthetic-session", headers: ["X-Tenant": "second"])!
        for other in [otherAccount, otherServer, otherTenant] {
            try check(await cache.cached(scope: other, id: "chat") == nil, "sessions, servers and headers must be isolated")
        }
        await server.fail(.networkError(underlying: URLError(.notConnectedToInternet)))
        do { _ = try await cache.load(scope: scope, id: "chat", fetch: fetch); throw Failure(message: "offline validation must throw") }
        catch is APIError {}
        try check(await cache.cached(scope: scope, id: "chat") != nil, "offline failure should preserve the saved preview")
        for code in [401, 403, 404, 410] {
            await server.configure(headers: [:])
            _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
            await server.fail(.httpError(statusCode: code, message: nil, data: nil))
            do { _ = try await cache.load(scope: scope, id: "chat", fetch: fetch); throw Failure(message: "access failure must throw") }
            catch is APIError {}
            try check(await cache.cached(scope: scope, id: "chat") == nil, "denied/deleted chats must be evicted")
        }
        await server.configure(headers: ["Cache-Control": "no-store"])
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(await cache.size() == 0, "no-store must not persist")
        await server.configure(headers: ["Cache-Control": "no-cache", "ETag": "\"v2\""])
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(await cache.cached(scope: scope, id: "chat")?.isRecent() == false, "no-cache must always revalidate")
        await server.configure(headers: ["ETag": "\"v2\""])
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(await cache.cached(scope: scope, id: "chat")?.isRecent() == false, "304 must preserve prior freshness restrictions")
        await server.configure(headers: ["Cache-Control": "max-age=5", "Age": "10"])
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(await cache.cached(scope: scope, id: "chat")?.isRecent() == false, "Age must reduce freshness")

        await server.configure(headers: [:])
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try Data("corrupt".utf8).write(to: files[0])
        try check(await cache.cached(scope: scope, id: "chat") == nil, "corruption should become a cache miss")
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        var request = URLRequest(url: URL(string: "https://relay.example/api/v1/chats/chat/messages/message")!)
        request.httpMethod = "POST"
        await cache.invalidateMutation(request, scope: scope)
        try check(await cache.cached(scope: scope, id: "chat") == nil, "message mutations must invalidate the chat")
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        request = URLRequest(url: URL(string: "https://relay.example/api/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"chat_id":"chat"}"#.utf8)
        await cache.invalidateMutation(request, scope: scope)
        try check(await cache.cached(scope: scope, id: "chat") == nil, "sending must invalidate the chat")

        let gate = Gate()
        let pending = Task {
            try await cache.load(scope: scope, id: "chat") { _ in
                await gate.wait()
                return Server.response(id: "chat")
            }
        }
        await gate.waitUntilStarted()
        await cache.clear()
        await gate.release()
        _ = try await pending.value
        try check(await cache.size() == 0, "in-flight request must not repopulate a cleared cache")

        // Coalescing must reserve the task before suspension.
        let counter = Counter()
        let coalescingGate = Gate()
        let blockedFetch: @Sendable (String?) async throws -> (Data, HTTPURLResponse) = { _ in
            await counter.increment()
            await coalescingGate.wait()
            return Server.response(id: "chat")
        }
        let reader1 = Task { try await cache.load(scope: scope, id: "chat", fetch: blockedFetch) }
        await coalescingGate.waitUntilStarted()
        let reader2 = Task { try await cache.load(scope: scope, id: "chat", fetch: blockedFetch) }
        for _ in 0..<100 { await Task.yield() }
        try check(await counter.value == 1, "simultaneous reads must share one request")
        await coalescingGate.release()
        _ = try await (reader1.value, reader2.value)

        let conditional = ConditionalServer()
        await server.configure(headers: ["ETag": "\"v2\""])
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        let validation = Task { try await cache.load(scope: scope, id: "chat") { try await conditional.fetch($0) } }
        await conditional.gate.waitUntilStarted()
        await cache.invalidate(scope: scope, id: "chat")
        await conditional.gate.release()
        _ = try await validation.value
        try check(await conditional.calls == 2, "invalidated 304 must retry unconditionally")
        try check(await cache.size() == 0, "invalidated in-flight request must not repopulate disk")

        for id in ["chat", "local:temporary"] {
            _ = try await cache.load(scope: id == "chat" ? nil : scope, id: id) { _ in Server.response(id: id) }
        }
        try check(await cache.size() == 0, "unauthenticated and temporary conversations must not persist")
        for shape in ["history", "flat"] {
            let chat: [String: Any] = shape == "history"
                ? ["history": ["messages": ["answer": ["done": false]]]]
                : ["messages": [["done": false]]]
            let data = try JSONSerialization.data(withJSONObject: ["id": "chat", "chat": chat])
            _ = try await cache.load(scope: scope, id: "chat") { _ in (data, Server.response(id: "chat").1) }
            try check(await cache.size() == 0, "unfinished responses must not persist")
        }
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        do {
            _ = try await cache.load(scope: scope, id: "chat") { _ in Server.response(id: "wrong-chat") }
            throw Failure(message: "mismatched response must be rejected")
        } catch is APIError {}
        try check(await cache.cached(scope: scope, id: "chat") == nil, "invalid response must evict the previous body")
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(await cache.cached(scope: scope, id: "chat", now: Date().addingTimeInterval(ConversationCache.retention + 1)) == nil,
                  "old saved responses must expire")
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-ConversationCache.retention - 1)], ofItemAtPath: url.path)
        }
        await cache.prune()
        try check(await cache.size() == 0, "recent access must not extend the disk retention limit")
        let revision = await cache.currentRevision()
        await cache.clear()
        let staleRevision = await cache.invalidate(scope: scope, ids: ["chat"], since: revision)
        let index = ConversationIndex(conversations: [], pinned: [], reconciledAt: .now)
        await cache.saveIndex(index, scope: scope, revision: staleRevision)
        try check(await cache.size() == 0, "metadata invalidation must not undo an intervening clear")

        defaults.set(1, forKey: ConversationCache.limitKey)
        for id in ["one", "two"] {
            _ = try await cache.load(scope: scope, id: id) { _ in Server.response(id: id, size: 400_000) }
        }
        // Give the first entry a deterministic, more recent LRU timestamp.
        _ = await cache.cached(scope: scope, id: "one", now: Date().addingTimeInterval(1))
        _ = try await cache.load(scope: otherAccount, id: "three") { _ in Server.response(id: "three", size: 400_000) }
        try check(await cache.size() <= 1024 * 1024, "budget must cover all accounts together")
        try check(await cache.cached(scope: scope, id: "one") != nil, "recently accessed entry should survive eviction")
        try check(await cache.cached(scope: scope, id: "two") == nil, "least recently used entry should be evicted")
        _ = try await cache.load(scope: scope, id: "one") { _ in Server.response(id: "one", size: 2_000_000) }
        try check(await cache.cached(scope: scope, id: "one") == nil, "oversized replacement must remove the old response")
        defaults.set(0, forKey: ConversationCache.limitKey)
        await cache.prune()
        try check(await cache.size() == 0, "disabling must remove saved copies")
        _ = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(await cache.size() == 0, "disabled cache must not write")
        print("PASS: persistence, recent reuse, 200/304, validator fallback, identity isolation, offline/auth errors, directives, corruption, mutations, clear races, LRU, limits and Off")
    }
}

struct Failure: Error { let message: String }
actor Server {
    var count = 0
    var lastTag: String?
    var version = 1
    var headers = ["ETag": "\"v1\""]
    var failure: APIError?
    func configure(version: Int? = nil, headers: [String: String]? = nil) {
        failure = nil
        if let version { self.version = version; self.headers = ["ETag": "\"v\(version)\""] }
        if let headers { self.headers = headers }
    }
    func fail(_ error: APIError) { failure = error }
    func fetch(_ etag: String?) throws -> (Data, HTTPURLResponse) {
        count += 1
        lastTag = etag
        if let failure { throw failure }
        let status = etag != nil && etag == headers["ETag"] ? 304 : 200
        return (status == 304 ? Data() : Self.payload(id: "chat", version: version),
            HTTPURLResponse(url: URL(string: "https://relay.example/api/v1/chats/chat")!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    static func payload(id: String, version: Int = 1, size: Int = 0) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": id, "chat": ["title": "Synthetic \(version)",
            "history": ["currentId": "answer", "messages": ["answer": ["id": "answer", "done": true, "content": String(repeating: "x", count: size), "files": [["id": "synthetic-file"]]], "alternate": ["id": "alternate", "done": true]]]]])
    }
    static func response(id: String, size: Int = 0) -> (Data, HTTPURLResponse) {
        (payload(id: id, size: size), HTTPURLResponse(url: URL(string: "https://relay.example")!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}
actor Gate {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    var startWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func release() { waiter?.resume(); waiter = nil }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}
actor ConditionalServer {
    let gate = Gate()
    var calls = 0
    func fetch(_ tag: String?) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        if tag != nil {
            await gate.wait()
            return (Data(), HTTPURLResponse(url: URL(string: "https://relay.example")!, statusCode: 304, httpVersion: nil, headerFields: [:])!)
        }
        return Server.response(id: "chat")
    }
}
