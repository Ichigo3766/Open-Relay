import Foundation

@MainActor final class Network: @unchecked Sendable {
    var conversationCacheScope: String? { "synthetic-api-session" }
    var count = 0
    var bytes = 0
    var overrideData: Data?
    func requestRaw(path: String, queryItems: [URLQueryItem]? = nil, ifNoneMatch: String? = nil, deduplicate: Bool = true) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let data = overrideData ?? Server.payload(id: "chat", size: 3_000_000)
        bytes += data.count
        return (data, HTTPURLResponse(url: URL(string: "https://relay.example/api/v1/chats/chat")!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}
@MainActor final class APIClient: @unchecked Sendable {
    let network = Network()
    let testCache: ConversationCache
    nonisolated let decodeGate = DecodeGate()
    init(_ cache: ConversationCache) { testCache = cache }
    nonisolated func parseFullConversation(_ json: [String: Any]) -> Conversation {
        decodeGate.pauseIfArmed()
        return Conversation(id: json["id"] as! String, title: (json["chat"] as! [String: Any])["title"] as! String)
    }
    // SUMMARY_METHOD
    // PAGE_METHOD
    // PRODUCTION_METHODS
}
@main enum APIChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "relay-api-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let cache = ConversationCache(directory: directory, defaults: defaults)
        let client = APIClient(cache)
        let first = try await client.getConversation(id: "chat"/* NAVIGATION */)
        let second = try await client.getConversation(id: "chat"/* NAVIGATION */)
        guard first.title == second.title else { throw Failure(message: "changed response") }
        print("Synthetic repeated navigation: \(client.network.count) requests, \(client.network.bytes) response bytes")
        guard client.network.count == 1 else {
            print("FAIL: reopening a recent conversation downloads the full body again")
            exit(1)
        }
        #if !BASELINE
        client.decodeGate.arm()
        let decoding = Task { await client.cachedConversation(id: "chat") }
        await client.decodeGate.waitUntilStarted()
        await cache.invalidate(scope: client.network.conversationCacheScope!, id: "chat")
        client.decodeGate.release()
        guard await decoding.value == nil else { throw Failure(message: "invalidated cached response escaped while decoding") }
        #endif
        for malformed in ["{}", "[{\"title\":\"Synthetic malformed row\"}]", "[{\"id\":\"\"}]"] {
            client.network.overrideData = Data(malformed.utf8)
            do {
                _ = try await client.getConversationsPage(page: 2)
                throw Failure(message: "malformed page treated as a completed list")
            } catch is APIError {}
        }
        client.network.overrideData = Data(#"[{"id":"chat","title":"Synthetic summary","updated_at":5,"created_at":1}]"#.utf8)
        guard try await client.getConversationsPage(page: 1).first?.title == "Synthetic summary",
              try await client.getPinnedConversations().first?.pinned == true else { throw Failure(message: "summary endpoints lost metadata") }
        print("PASS: actual APIClient navigation reuses the saved response")
    }
}

final class DecodeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var started = false
    func arm() { condition.lock(); armed = true; started = false; condition.unlock() }
    func pauseIfArmed() {
        condition.lock()
        defer { condition.unlock() }
        guard armed else { return }
        started = true
        condition.broadcast()
        while armed { condition.wait() }
    }
    func waitUntilStarted() async {
        await Task.detached { self.waitForStart() }.value
    }
    private func waitForStart() {
        condition.lock()
        defer { condition.unlock() }
        while !started { condition.wait() }
    }
    func release() { condition.lock(); armed = false; condition.broadcast(); condition.unlock() }
}
