import Foundation

/// Version history for workspace resources.
///
/// Every save of a model, tool, function or skill keeps a version that can be
/// listed, compared with another, made live again, or deleted. Prompts have their
/// own richer history (see `PromptVersion`).
enum VersionedResource: Sendable, Equatable {
    case model(id: String)
    case tool(id: String)
    case function(id: String)
    case skill(id: String)

    /// Base path + extra query items for each resource's history routes.
    var base: (path: String, query: [URLQueryItem]) {
        switch self {
        case .model(let id):
            // Model ids may contain "/", so they travel as `?id=`.
            return ("/api/v1/models/model", [URLQueryItem(name: "id", value: id)])
        case .tool(let id): return ("/api/v1/tools/id/\(id.encodedPathSegment)", [])
        case .function(let id): return ("/api/v1/functions/id/\(id.encodedPathSegment)", [])
        case .skill(let id): return ("/api/v1/skills/id/\(id.encodedPathSegment)", [])
        }
    }

    var isSkill: Bool { if case .skill = self { return true }; return false }
}

/// One saved version (`*HistoryResponse`).
struct ResourceVersion: Identifiable, Sendable, Hashable {
    let id: String
    let parentId: String?
    let userId: String
    let authorName: String?
    let commitMessage: String?
    let createdAt: Date

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        parentId = json["parent_id"] as? String
        userId = json["user_id"] as? String ?? ""
        authorName = (json["user"] as? [String: Any])?["name"] as? String
        commitMessage = (json["commit_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let ts = (json["created_at"] as? Double) ?? (json["created_at"] as? Int).map(Double.init) ?? 0
        // Some tables store nanoseconds — normalise to seconds.
        createdAt = Date(timeIntervalSince1970: ts > 1_000_000_000_000 ? ts / 1_000_000_000 : ts)
    }

    var shortId: String { String(id.prefix(7)) }
    var title: String { commitMessage ?? shortId }
}

/// Result of comparing two versions.
struct ResourceVersionDiff: Sendable {
    struct FieldChange: Sendable, Hashable {
        let key: String
        let before: String
        let after: String
    }
    struct FileChange: Sendable, Hashable {
        let path: String
        let status: String
        let binary: Bool
    }
    var metadata: [FieldChange] = []
    var contentDiff: [String] = []
    var files: [FileChange] = []
    var lineEndingsOnly = false

    init(json: [String: Any]) {
        if let meta = json["metadata"] as? [String: Any] {
            metadata = meta.keys.sorted().map { key in
                let entry = meta[key] as? [String: Any] ?? [:]
                return FieldChange(key: key, before: Self.describe(entry["before"]), after: Self.describe(entry["after"]))
            }
        }
        if let patch = json["content_diff"] as? String, !patch.isEmpty {
            contentDiff = patch.components(separatedBy: "\n")
        } else if let lines = json["content_diff"] as? [String] {
            contentDiff = lines
        }
        files = (json["files"] as? [[String: Any]] ?? []).compactMap { f in
            guard let path = f["path"] as? String else { return nil }
            return FileChange(path: path, status: f["status"] as? String ?? "modified", binary: f["binary"] as? Bool ?? false)
        }
        lineEndingsOnly = json["line_endings_only"] as? Bool ?? false
    }

    private static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "—" }
        if let s = value as? String { return s.isEmpty ? "—" : s }
        if let n = value as? NSNumber { return n.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
           let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }
}
