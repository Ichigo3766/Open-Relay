import Foundation

// MARK: - Group 1: small gaps found by the API diff

extension APIClient {

    /// POST /api/v1/knowledge/{id}/file/update — rebuild one file's search index.
    /// (Web: KnowledgeBase.svelte `updateFileFromKnowledgeById`.)
    func reprocessKnowledgeFile(knowledgeId: String, fileId: String) async throws {
        _ = try await network.requestJSON(
            path: "/api/v1/knowledge/\(knowledgeId)/file/update", method: .post,
            body: ["file_id": fileId], timeout: 600)
    }

    /// POST /api/v1/prompts/id/{id}/update/meta — name, command and tags only; no new version.
    @discardableResult
    func updatePromptMetadata(id: String, name: String, command: String, tags: [String]) async throws -> [String: Any] {
        try await network.requestJSON(
            path: "/api/v1/prompts/id/\(id)/update/meta", method: .post,
            body: ["name": name, "command": command, "tags": tags])
    }

    /// GET /api/v1/auths/admin/details → `{ name, email }` (400 when the admin hides their details).
    func getAdminDetails() async throws -> (name: String?, email: String?) {
        let json = try await network.requestJSON(path: "/api/v1/auths/admin/details")
        return (json["name"] as? String, json["email"] as? String)
    }

    // MARK: Danger zone (Admin → Documents)

    /// POST /api/v1/knowledge/reindex — rebuild every knowledge file's vectors (admin).
    func reindexKnowledgeFiles() async throws {
        _ = try await network.requestRaw(path: "/api/v1/knowledge/reindex", method: .post, timeout: 3600)
    }

    /// POST /api/v1/knowledge/metadata/reindex — rebuild knowledge-base search embeddings (admin).
    func reindexKnowledgeMetadata() async throws {
        _ = try await network.requestRaw(path: "/api/v1/knowledge/metadata/reindex", method: .post, timeout: 3600)
    }

    /// POST /api/v1/memories/reindex — rebuild every user's memory vectors (admin).
    func reindexMemoryVectors() async throws {
        _ = try await network.requestRaw(path: "/api/v1/memories/reindex", method: .post, timeout: 3600)
    }

    /// POST /api/v1/retrieval/reset/uploads — empty the upload directory (admin).
    func resetUploadDirectory() async throws {
        _ = try await network.requestRaw(path: "/api/v1/retrieval/reset/uploads", method: .post)
    }

    /// POST /api/v1/retrieval/reset/db — wipe the vector database (admin).
    func resetVectorDatabase() async throws {
        _ = try await network.requestRaw(path: "/api/v1/retrieval/reset/db", method: .post)
    }

    /// DELETE /api/v1/files/all — delete every uploaded file (admin).
    func deleteAllFiles() async throws {
        _ = try await network.requestRaw(path: "/api/v1/files/all", method: .delete)
    }
}
