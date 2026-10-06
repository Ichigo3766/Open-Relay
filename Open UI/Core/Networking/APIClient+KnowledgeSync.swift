import Foundation

// MARK: - Knowledge sync, pending files and export

extension APIClient {

    /// GET /api/v1/knowledge/{id}/files/pending — files still being processed.
    func getPendingKnowledgeFiles(knowledgeId: String) async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/knowledge/\(knowledgeId)/files/pending")
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// POST /api/v1/knowledge/{id}/sync/diff
    func knowledgeSyncDiff(knowledgeId: String, manifest: [KnowledgeSyncEntry]) async throws -> KnowledgeSyncDiff {
        let body: [String: Any] = ["manifest": manifest.map {
            ["filename": $0.filename, "path": $0.path, "checksum": $0.checksum, "size": $0.size] as [String: Any]
        }]
        let json = try await network.requestJSON(
            path: "/api/v1/knowledge/\(knowledgeId)/sync/diff", method: .post, body: body, timeout: 120)
        var diff = KnowledgeSyncDiff()
        diff.added = json["added"] as? [[String: Any]] ?? []
        diff.modified = json["modified"] as? [[String: Any]] ?? []
        diff.deleted = json["deleted"] as? [[String: Any]] ?? []
        diff.mkdir = json["mkdir"] as? [String] ?? []
        diff.rmdir = json["rmdir"] as? [String] ?? []
        diff.unmodifiedCount = json["unmodified_count"] as? Int ?? 0
        diff.directoryMap = json["directory_map"] as? [String: String] ?? [:]
        return diff
    }

    /// POST /api/v1/knowledge/{id}/sync/cleanup — remove stale files and orphaned folders.
    func knowledgeSyncCleanup(knowledgeId: String, fileIds: [String], dirIds: [String]) async throws {
        _ = try await network.requestJSON(
            path: "/api/v1/knowledge/\(knowledgeId)/sync/cleanup", method: .post,
            body: ["file_ids": fileIds, "dir_ids": dirIds])
    }

    /// GET /api/v1/knowledge/{id}/export — ZIP of the knowledge base's files.
    func exportKnowledgeZip(knowledgeId: String) async throws -> Data {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/knowledge/\(knowledgeId)/export", timeout: 600)
        return data
    }
}
