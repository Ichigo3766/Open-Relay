enum BackendConfig { struct PromptSuggestion: Codable, Hashable, Sendable {} }
enum APIError: Error { case cancelled }
struct Chat { var id = "craft-chat"; var chatVariables: [String: Any] = [:] }
final class Network { var conversationCacheScope: String? = "synthetic-scope" }
final class Client {
    let network = Network()
    var saved: [String: Any] = [:]
    var writes = 0
    var fail = false
    var onSave: (() -> Void)?
    func updateChatVariables(id: String, values: [String: Any]) async throws {
        writes += 1
        if fail { throw APIError.cancelled }
        saved = values
        onSave?()
    }
}
final class Manager {
    let apiClient = Client()
    var stored = Chat(chatVariables: ["other-model": ["keep": [1, 2]]])
    var onFetch: (() -> Void)?
    var fetches = 0
    func fetchConversation(id: String) async throws -> Chat {
        fetches += 1; onFetch?(); return stored
    }
}
