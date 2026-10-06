import Foundation

// MARK: - Knowledge directories and file ops (server contract: routers/knowledge.py)

private func knowledgeDecodeError() -> APIError {
    .responseDecoding(underlying: NSError(domain: "Knowledge", code: -1), data: nil)
}

extension APIClient {

    /// How a directory's parent changes on update.
    enum DirectoryParent { case keep, root, folder(String) }

    /// GET /api/v1/knowledge/{id}/files — one page (30 items) of files + folders.
    /// - Parameter directoryId: nil = no folder filter (all files), "" = root, else that folder.
    func getKnowledgeFolderPage(
        knowledgeId: String, directoryId: String?, page: Int = 1,
        query: String? = nil, sort: KnowledgeFileSort? = nil
    ) async throws -> KnowledgeFolderPage {
        var q = [URLQueryItem(name: "page", value: "\(page)")]
        if let directoryId { q.append(URLQueryItem(name: "directory_id", value: directoryId)) }
        if let query, !query.isEmpty { q.append(URLQueryItem(name: "query", value: query)) }
        if let sort {
            q.append(URLQueryItem(name: "order_by", value: sort.query.orderBy))
            q.append(URLQueryItem(name: "direction", value: sort.query.direction))
        }
        let (data, _) = try await network.requestRaw(path: "/api/v1/knowledge/\(knowledgeId)/files", queryItems: q)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return KnowledgeFolderPage(files: [], directories: [], breadcrumbs: [], total: 0)
        }
        let files = (dict["items"] as? [[String: Any]] ?? []).compactMap { KnowledgeFileEntry(json: $0) }
        let dirs = (dict["directories"] as? [[String: Any]] ?? []).compactMap { KnowledgeDirectory(json: $0) }
        let crumbs = (dict["breadcrumbs"] as? [[String: Any]] ?? []).compactMap { KnowledgeDirectory(json: $0) }
        return KnowledgeFolderPage(files: files, directories: dirs, breadcrumbs: crumbs,
                                   total: dict["total"] as? Int ?? files.count)
    }

    /// POST /api/v1/knowledge/{id}/dirs/create
    func createKnowledgeDirectory(knowledgeId: String, name: String, parentId: String?) async throws -> KnowledgeDirectory {
        var body: [String: Any] = ["name": name]
        if let parentId { body["parent_id"] = parentId }
        let json = try await network.requestJSON(
            path: "/api/v1/knowledge/\(knowledgeId)/dirs/create", method: .post, body: body)
        guard let dir = KnowledgeDirectory(json: json) else { throw knowledgeDecodeError() }
        return dir
    }

    /// POST /api/v1/knowledge/{id}/dirs/{dir}/update — rename and/or move.
    @discardableResult
    func updateKnowledgeDirectory(knowledgeId: String, directoryId: String, name: String? = nil,
                                  parent: DirectoryParent = .keep) async throws -> KnowledgeDirectory {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        switch parent {
        case .keep: body["parent_id"] = "__unset__"
        case .root: body["parent_id"] = NSNull()
        case .folder(let id): body["parent_id"] = id
        }
        let json = try await network.requestJSON(
            path: "/api/v1/knowledge/\(knowledgeId)/dirs/\(directoryId)/update", method: .post, body: body)
        guard let dir = KnowledgeDirectory(json: json) else { throw knowledgeDecodeError() }
        return dir
    }

    /// DELETE /api/v1/knowledge/{id}/dirs/{dir}/delete?move_files=
    /// `moveFiles == true` moves contents to the parent; `false` deletes them.
    func deleteKnowledgeDirectory(knowledgeId: String, directoryId: String, moveFiles: Bool) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/knowledge/\(knowledgeId)/dirs/\(directoryId)/delete",
            method: .delete,
            queryItems: [URLQueryItem(name: "move_files", value: moveFiles ? "true" : "false")])
    }

    /// POST /api/v1/knowledge/{id}/file/add with an optional target folder.
    func addFileToKnowledge(knowledgeId: String, fileId: String, directoryId: String?) async throws -> [String: Any] {
        var body: [String: Any] = ["file_id": fileId]
        if let directoryId { body["directory_id"] = directoryId }
        return try await network.requestJSON(
            path: "/api/v1/knowledge/\(knowledgeId)/file/add", method: .post, body: body)
    }

    /// POST /api/v1/knowledge/{id}/file/move — `directoryId == nil` moves to the root.
    func moveKnowledgeFile(knowledgeId: String, fileId: String, directoryId: String?) async throws {
        var body: [String: Any] = ["file_id": fileId]
        body["directory_id"] = directoryId.map { $0 as Any } ?? NSNull()
        _ = try await network.requestJSON(
            path: "/api/v1/knowledge/\(knowledgeId)/file/move", method: .post, body: body)
    }

    /// POST /api/v1/files/{id}/rename
    func renameFile(id: String, filename: String) async throws {
        _ = try await network.requestJSON(
            path: "/api/v1/files/\(id)/rename", method: .post, body: ["filename": filename])
    }

    /// POST /api/v1/files/{id}/data/content/update — re-extracts and re-indexes the file text.
    func updateFileTextContent(id: String, content: String) async throws {
        _ = try await network.requestJSON(
            path: "/api/v1/files/\(id)/data/content/update", method: .post,
            body: ["content": content], timeout: 300)
    }
}
