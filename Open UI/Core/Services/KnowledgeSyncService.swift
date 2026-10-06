import Foundation

/// The two folder-import operations (see `KnowledgeManifest` for the shared rules).
enum KnowledgeSyncService {

    /// Creates the folders the diff asks for (parents first) and returns `path → id`.
    private static func createMissingFolders(
        api: APIClient, knowledgeId: String, diff: KnowledgeSyncDiff
    ) async -> [String: String] {
        var ids = diff.directoryMap
        for path in diff.mkdir {
            let parts = path.split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            let parentPath = parts.dropLast().joined(separator: "/")
            let parentId = parentPath.isEmpty ? nil : ids[parentPath]
            if let d = try? await api.createKnowledgeDirectory(knowledgeId: knowledgeId, name: name, parentId: parentId) {
                ids[path] = d.id
            }
        }
        return ids
    }

    private static func upload(
        _ files: [KnowledgeLocalFile], api: APIClient, knowledgeId: String,
        folderIds: [String: String], fallbackFolderId: String?,
        status: @escaping (String) -> Void, result: inout KnowledgeSyncResult
    ) async {
        for (i, item) in files.enumerated() {
            status("Uploading \(i + 1)/\(files.count): \(item.entry.filename)")
            do {
                let data = try Data(contentsOf: item.url)
                // The server links the file to the knowledge base (into this folder) itself.
                let folder = item.entry.path.isEmpty ? fallbackFolderId : folderIds[item.entry.path]
                _ = try await api.uploadFile(
                    data: data, fileName: item.entry.filename, knowledgeId: knowledgeId,
                    directoryId: folder, fileHash: item.entry.checksum)
            } catch {
                result.failed += 1
                result.failures.append("\(item.entry.filename): \(error.localizedDescription)")
            }
        }
    }

    /// Upload directory: add every file beneath the current folder; never deletes.
    static func uploadDirectory(
        api: APIClient, knowledgeId: String, root: URL,
        currentFolderPath: String, currentFolderId: String?,
        status: @escaping (String) -> Void
    ) async throws -> KnowledgeSyncResult {
        status("Computing checksums…")
        let files = try KnowledgeManifest.build(root: root, pathPrefix: currentFolderPath)
        status("Comparing with knowledge base…")
        let diff = try await api.knowledgeSyncDiff(knowledgeId: knowledgeId, manifest: files.map(\.entry))
        var ids = await createMissingFolders(api: api, knowledgeId: knowledgeId, diff: diff)
        if !currentFolderPath.isEmpty, let currentFolderId { ids[currentFolderPath] = currentFolderId }
        var result = KnowledgeSyncResult(added: files.count)
        await upload(files, api: api, knowledgeId: knowledgeId, folderIds: ids,
                     fallbackFolderId: currentFolderId, status: status, result: &result)
        return result
    }

    /// Sync directory: mirror onto the whole knowledge base.
    static func sync(
        api: APIClient, knowledgeId: String, root: URL,
        status: @escaping (String) -> Void
    ) async throws -> KnowledgeSyncResult {
        status("Computing checksums…")
        let files = try KnowledgeManifest.build(root: root, pathPrefix: "")

        status("Comparing with knowledge base…")
        let diff = try await api.knowledgeSyncDiff(knowledgeId: knowledgeId, manifest: files.map(\.entry))

        let staleIds = diff.deleted.compactMap { $0["file_id"] as? String }
            + diff.modified.compactMap { $0["stale_file_id"] as? String }
        if !staleIds.isEmpty || !diff.rmdir.isEmpty {
            status("Removing \(staleIds.count) stale files…")
            try await api.knowledgeSyncCleanup(knowledgeId: knowledgeId, fileIds: staleIds, dirIds: diff.rmdir)
        }

        let ids = await createMissingFolders(api: api, knowledgeId: knowledgeId, diff: diff)
        func key(_ path: String, _ name: String) -> String { path + "\u{0}" + name }
        let wanted = Set((diff.added + diff.modified).map {
            key(($0["path"] as? String) ?? "", ($0["filename"] as? String) ?? "")
        })
        let changed = files.filter { wanted.contains(key($0.entry.path, $0.entry.filename)) }

        var result = KnowledgeSyncResult(added: diff.added.count, modified: diff.modified.count,
                                         deleted: diff.deleted.count, unmodified: diff.unmodifiedCount)
        await upload(changed, api: api, knowledgeId: knowledgeId, folderIds: ids,
                     fallbackFolderId: nil, status: status, result: &result)
        return result
    }
}
