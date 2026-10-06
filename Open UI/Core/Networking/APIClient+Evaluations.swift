import Foundation

// MARK: - Evaluations: leaderboard, model history, arena config, feedback export

struct LeaderboardEntryItem: Identifiable, Sendable {
    let modelId: String
    let rating: Int
    let won: Int
    let lost: Int
    let count: Int
    let topTags: [(tag: String, count: Int)]
    var id: String { modelId }

    init?(json: [String: Any]) {
        guard let id = json["model_id"] as? String else { return nil }
        modelId = id
        rating = json["rating"] as? Int ?? 0
        won = json["won"] as? Int ?? 0
        lost = json["lost"] as? Int ?? 0
        count = json["count"] as? Int ?? (won + lost)
        topTags = (json["top_tags"] as? [[String: Any]] ?? []).compactMap {
            guard let t = $0["tag"] as? String else { return nil }
            return (t, $0["count"] as? Int ?? 0)
        }
    }
}

struct ModelHistoryPoint: Identifiable, Sendable {
    let date: String
    let won: Int
    let lost: Int
    var id: String { date }
}

extension APIClient {

    /// GET /api/v1/evaluations/leaderboard?query= (admin). `query` re-weights by tag similarity.
    func getLeaderboard(query: String? = nil) async throws -> [LeaderboardEntryItem] {
        var q: [URLQueryItem] = []
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            q.append(URLQueryItem(name: "query", value: query))
        }
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/evaluations/leaderboard", queryItems: q.isEmpty ? nil : q, timeout: 120)
        let dict = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (dict["entries"] as? [[String: Any]] ?? []).compactMap { LeaderboardEntryItem(json: $0) }
    }

    /// GET /api/v1/evaluations/leaderboard/{model}/history?days=
    func getModelHistory(modelId: String, days: Int = 30) async throws -> [ModelHistoryPoint] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/evaluations/leaderboard/\(modelId.encodedPathSegment)/history",
            queryItems: [URLQueryItem(name: "days", value: "\(days)")],
            pathIsEncoded: true)
        let dict = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (dict["history"] as? [[String: Any]] ?? []).compactMap {
            guard let d = $0["date"] as? String else { return nil }
            return ModelHistoryPoint(date: d, won: $0["won"] as? Int ?? 0, lost: $0["lost"] as? Int ?? 0)
        }
    }

    /// GET /api/v1/evaluations/config → `{ ENABLE_EVALUATION_ARENA_MODELS, EVALUATION_ARENA_MODELS }`
    func getEvaluationConfig() async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/evaluations/config")
    }

    /// POST /api/v1/evaluations/config — sends only what is provided (both fields are optional server-side).
    func updateEvaluationConfig(enabled: Bool?, arenaModels: [[String: Any]]?) async throws {
        var body: [String: Any] = [:]
        if let enabled { body["ENABLE_EVALUATION_ARENA_MODELS"] = enabled }
        if let arenaModels { body["EVALUATION_ARENA_MODELS"] = arenaModels }
        _ = try await network.requestJSON(path: "/api/v1/evaluations/config", method: .post, body: body)
    }

    /// GET /api/v1/evaluations/feedbacks/models — model ids that have feedback.
    func getFeedbackModelIds() async throws -> [String] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/evaluations/feedbacks/models")
        return (try JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    }

    /// GET /api/v1/evaluations/feedbacks/all/export?model_id= — raw JSON array.
    func exportAllFeedbacks(modelId: String? = nil) async throws -> Data {
        var q: [URLQueryItem]? = nil
        if let modelId, !modelId.isEmpty { q = [URLQueryItem(name: "model_id", value: modelId)] }
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/evaluations/feedbacks/all/export", queryItems: q, timeout: 300)
        return data
    }

    /// DELETE /api/v1/evaluations/feedbacks/all (admin)
    func deleteAllFeedbacks() async throws {
        try await network.requestVoidJSON(path: "/api/v1/evaluations/feedbacks/all", method: .delete)
    }
}
