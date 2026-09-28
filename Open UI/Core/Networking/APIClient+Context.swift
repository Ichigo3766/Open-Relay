import Foundation

extension APIClient {
    func compactChat(id: String, model: String?) async throws -> ChatCompactionResult {
        let scope = network.conversationCacheScope
        let body = model.map { ["model": $0] } ?? [:]
        // A deliberate server-side summarization may take time. Never automatically resubmit it.
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/\(id)/compact", method: .post,
                                                    body: JSONSerialization.data(withJSONObject: body), timeout: 300)
        guard scope == network.conversationCacheScope else { throw APIError.cancelled }
        let result = try JSONDecoder().decode(ChatCompactionResult.self, from: data)
        guard result.ok else { throw APIError.responseDecoding(underlying: CocoaError(.coderReadCorrupt), data: nil) }
        return result
    }
}
