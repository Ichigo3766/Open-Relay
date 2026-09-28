import Foundation

/// The server's estimated usage against its compaction threshold, not a model's context-window size.
nonisolated struct ChatContextUsage: Decodable, Hashable, Sendable {
    let tokens: Int
    let threshold: Int

    var fraction: Double { Double(tokens) / Double(threshold) }

    private enum CodingKeys: String, CodingKey { case tokens, estimated_tokens, threshold }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try values.decodeIfPresent(Int.self, forKey: .tokens)
            ?? values.decode(Int.self, forKey: .estimated_tokens)
        threshold = try values.decode(Int.self, forKey: .threshold)
        guard tokens >= 0, threshold > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid context usage"))
        }
    }

    static func parse(_ value: Any?) -> Self? {
        guard let value = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

nonisolated struct ChatCompactionResult: Decodable, Sendable {
    let ok: Bool
    let compacted: Bool
    let reason: String?

    var message: String {
        if compacted { return "Context compacted. Original messages are unchanged." }
        switch reason {
        case "disabled": return "Context compaction is disabled on this server."
        case "empty", "too_short": return "There isn't enough conversation history to compact."
        default: return "No context compaction was needed."
        }
    }
}
