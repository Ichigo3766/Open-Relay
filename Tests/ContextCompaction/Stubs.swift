import Foundation

enum APIError: Error { case cancelled, responseDecoding(underlying: Error, data: Data?) }
enum Method { case post }
@MainActor final class Network {
    var conversationCacheScope: String? = "synthetic-account"
    var requests: [(String, [String: String], Double)] = []
    var response = #"{"ok":true,"compacted":true}"#
    var fail = false
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?
    func requestRaw(path: String, method: Method, body: Data, timeout: Double) async throws -> (Data, Int) {
        requests.append((path, try JSONSerialization.jsonObject(with: body) as! [String: String], timeout))
        if suspend { await withCheckedContinuation { continuation = $0 } }
        if fail { throw NSError(domain: "Synthetic", code: 503) }
        return (Data(response.utf8), 200)
    }
}
@MainActor final class APIClient { let network = Network() }
struct Chat {
    var id = "demo"
    var history = MessageHistory()
    var contextUsage: ChatContextUsage?
}
typealias Conversation = Chat
@MainActor final class Manager {
    let apiClient = APIClient()
    var failFetch = false
    var fetches = 0
    func fetchConversation(id: String) async throws -> Chat {
        fetches += 1
        if failFetch { throw NSError(domain: "Synthetic", code: 503) }
        var chat = Chat(id: id)
        chat.contextUsage = ChatContextUsage.parse(["tokens": 2000, "threshold": 8000])
        chat.history.nodes["answer"] = MessageHistory.parseNode(id: "answer", from: ["role": "assistant", "content": "Five paper stars.", "contextSummary": "Five sheets were used."])
        return chat
    }
}
actor ConversationCache {
    static let shared = ConversationCache()
    var invalidations = 0
    func invalidate(scope: String, id: String) { invalidations += 1 }
}
