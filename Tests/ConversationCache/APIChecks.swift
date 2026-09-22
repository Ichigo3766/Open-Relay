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
    init(_ cache: ConversationCache) { testCache = cache }
    nonisolated func parseFullConversation(_ json: [String: Any]) -> Conversation {
        Conversation(id: json["id"] as! String, title: (json["chat"] as! [String: Any])["title"] as! String)
    }
    func parseConversationSummary(_ json: [String: Any]) -> Conversation? { nil }
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
        client.network.overrideData = Data("{}".utf8)
        do {
            _ = try await client.getConversationsPage(page: 2)
            throw Failure(message: "malformed page treated as a completed list")
        } catch is APIError {}
        print("PASS: actual APIClient navigation reuses the saved response")
    }
}
