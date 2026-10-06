import Foundation
import os.log

/// Manages knowledge base CRUD operations and caches the list for the workspace.
/// Registered in `AppDependencyContainer` and shared across all views.
@Observable
final class KnowledgeManager {
    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "Knowledge")

    // MARK: - State

    /// Flat list of all knowledge bases (used by the workspace list and the `#` picker).
    var knowledgeBases: [KnowledgeItem] = []
    /// All server users (used for the access-control user picker in the editor).
    var allUsers: [ChannelMember] = []
    var isLoading = false
    var error: String?

    // MARK: - Init

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch

    /// Loads all knowledge bases. Called on workspace open and after any mutation.
    /// File counts are fetched via the paginated `/files?page=1` endpoint in parallel,
    /// so they reflect files added from any client (app or web UI), not the stale
    /// list-endpoint value which often returns null or an empty array.
    func fetchAll() async {
        isLoading = true
        error = nil
        do {
            let raw = try await apiClient.getKnowledgeBases()

            // Build items without file counts first so the list appears immediately.
            let items: [KnowledgeItem] = raw.compactMap { entry -> KnowledgeItem? in
                guard let id = entry["id"] as? String,
                      let name = entry["name"] as? String else { return nil }
                var item = KnowledgeItem(
                    id: id,
                    name: name,
                    description: entry["description"] as? String,
                    type: .collection,
                    fileCount: nil
                )
                item.isExternal = (entry["meta"] as? [String: Any])?["source"] as? String == "external"
                return item
            }
            knowledgeBases = items

            // Fetch accurate file counts in parallel from the paginated files endpoint.
            // The list endpoint's `files` field is unreliable (often null or empty).
            let counts: [(String, Int)] = await withTaskGroup(of: (String, Int).self) { group in
                for item in items {
                    group.addTask { [weak self] in
                        guard let self else { return (item.id, 0) }
                        let count = (try? await self.apiClient.getKnowledgeFileCount(item.id)) ?? 0
                        return (item.id, count)
                    }
                }
                var results: [(String, Int)] = []
                for await result in group { results.append(result) }
                return results
            }

            // Merge counts back into the list by reconstructing each item with the fetched count.
            // (KnowledgeItem.fileCount is `let`, so we create a new value.)
            let countMap = Dictionary(uniqueKeysWithValues: counts)
            knowledgeBases = items.map { item in
                KnowledgeItem(
                    id: item.id,
                    name: item.name,
                    description: item.description,
                    type: item.type,
                    fileCount: countMap[item.id]
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Create

    @discardableResult
    func createKnowledge(from detail: KnowledgeDetail) async throws -> KnowledgeDetail {
        let payload = detail.toCreatePayload()
        let json = try await apiClient.createKnowledge(payload: payload)
        guard let created = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        await fetchAll()
        return created
    }

    // MARK: - Read

    func getDetail(id: String) async throws -> KnowledgeDetail {
        let json = try await apiClient.getKnowledgeById(id)
        guard let detail = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        return detail
    }

    // MARK: - Update

    @discardableResult
    func updateKnowledge(_ detail: KnowledgeDetail) async throws -> KnowledgeDetail {
        let payload = detail.toUpdatePayload()
        let json = try await apiClient.updateKnowledge(id: detail.id, payload: payload)
        guard let updated = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        // Sync list entry
        if let idx = knowledgeBases.firstIndex(where: { $0.id == detail.id }) {
            knowledgeBases[idx] = updated.toKnowledgeItem()
        }
        return updated
    }

    // MARK: - Delete

    func deleteKnowledge(id: String) async throws {
        try await apiClient.deleteKnowledge(id: id)
        knowledgeBases.removeAll { $0.id == id }
    }

    // MARK: - Reset

    /// Removes all files from a knowledge base and re-processes it.
    @discardableResult
    func resetKnowledge(id: String) async throws -> KnowledgeDetail {
        let json = try await apiClient.resetKnowledge(id: id)
        guard let updated = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        if let idx = knowledgeBases.firstIndex(where: { $0.id == id }) {
            knowledgeBases[idx] = updated.toKnowledgeItem()
        }
        return updated
    }

    // MARK: - File Management

    /// Fetches the files attached to a specific knowledge base.
    func getFiles(knowledgeId: String) async throws -> [KnowledgeFileEntry] {
        let raw = try await apiClient.getKnowledgeFilesForKB(knowledgeId)
        return raw.compactMap { KnowledgeFileEntry(json: $0) }
    }

    /// Uploads multiple files in parallel. Each upload is processed and linked to the
    /// knowledge base (into `directoryId`) by the server, like the web client.
    /// One failing file (e.g. "Duplicate content") does not stop the others; failures are
    /// collected and thrown together at the end.
    ///
    /// - Parameters:
    ///   - files: Array of (data, fileName) tuples to upload.
    ///   - knowledgeId: The knowledge base to add files to.
    ///   - directoryId: Target folder, or nil for the top level.
    ///   - onProgress: Called with a value 0…1 as uploads complete.
    func uploadAndAddFilesBatch(
        files: [(data: Data, fileName: String)],
        knowledgeId: String,
        directoryId: String? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        guard !files.isEmpty else { return }

        let total = Double(files.count)
        let counter = ProgressCounter()
        var failures: [String] = []

        await withTaskGroup(of: String?.self) { group in
            for file in files {
                group.addTask { [self] in
                    var failure: String? = nil
                    do {
                        _ = try await self.apiClient.uploadFile(
                            data: file.data, fileName: file.fileName,
                            knowledgeId: knowledgeId, directoryId: directoryId)
                    } catch {
                        failure = "\(file.fileName): \(error.localizedDescription)"
                    }
                    let completed = await counter.increment()
                    onProgress?(Double(completed) / total)
                    return failure
                }
            }
            for await failure in group { if let failure { failures.append(failure) } }
        }

        onProgress?(1.0)
        await refreshFileCount(knowledgeId)
        if !failures.isEmpty {
            throw KnowledgeUploadError(failures: failures, total: files.count)
        }
    }

    /// Re-reads the file count so the list row stays accurate after uploads.
    private func refreshFileCount(_ knowledgeId: String) async {
        guard let idx = knowledgeBases.firstIndex(where: { $0.id == knowledgeId }) else { return }
        let count = (try? await apiClient.getKnowledgeFileCount(knowledgeId)) ?? knowledgeBases[idx].fileCount ?? 0
        var item = KnowledgeItem(
            id: knowledgeBases[idx].id, name: knowledgeBases[idx].name,
            description: knowledgeBases[idx].description, type: knowledgeBases[idx].type, fileCount: count)
        item.isExternal = knowledgeBases[idx].isExternal
        knowledgeBases[idx] = item
    }

    /// Uploads one file. The server links it to the knowledge base (into `directoryId`)
    /// as part of the upload, exactly like the web client — no separate /file/add call.
    func uploadAndAddFile(
        fileData: Data,
        fileName: String,
        knowledgeId: String,
        directoryId: String? = nil,
        onUploaded: ((String) -> Void)? = nil
    ) async throws {
        _ = try await apiClient.uploadFile(
            data: fileData, fileName: fileName, knowledgeId: knowledgeId,
            directoryId: directoryId, onUploaded: onUploaded)
        await refreshFileCount(knowledgeId)
    }

    /// Scrapes a web page and stores its text as a file in the knowledge base.
    /// 1. POST /api/v1/retrieval/process/web?process=false → scraped text
    /// 2. Upload the text as a .txt (server links it via `knowledge_id` metadata)
    func addWebPage(url: String, knowledgeId: String, directoryId: String? = nil) async throws {
        let content = try await apiClient.processWebPage(url: url)
        let host = URL(string: url)?.host ?? "webpage"
        let fileName = "\(host.replacingOccurrences(of: "www.", with: "")).txt"
        guard let fileData = content.data(using: .utf8) else { throw KnowledgeManagerError.invalidResponse }
        _ = try await apiClient.uploadFile(
            data: fileData, fileName: fileName, knowledgeId: knowledgeId, directoryId: directoryId)
        await refreshFileCount(knowledgeId)
    }

    /// Stores typed text as a .txt file in the knowledge base.
    func addTextContent(text: String, title: String, knowledgeId: String, directoryId: String? = nil) async throws {
        guard let fileData = text.data(using: .utf8) else { throw KnowledgeManagerError.invalidResponse }
        let safe = title.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "_")
        let fileName = safe.isEmpty ? "content.txt" : "\(safe).txt"
        _ = try await apiClient.uploadFile(
            data: fileData, fileName: fileName, knowledgeId: knowledgeId, directoryId: directoryId)
        await refreshFileCount(knowledgeId)
    }

    // MARK: - Access Grants

    /// Updates the access grants for a knowledge base.
    /// - Parameters:
    ///   - knowledgeId: The knowledge base ID.
    ///   - grants: The per-user access grants to persist.
    ///   - isPublic: If `true`, appends a wildcard `*` grant so all users can read (Public mode).
    /// Write access = TWO entries (one "read" + one "write") matching the web UI format.
    @discardableResult
    func updateAccessGrants(knowledgeId: String, grants: [AccessGrant], isPublic: Bool = false) async throws -> [AccessGrant] {
        var payload: [[String: Any]] = []
        for grant in grants {
            if let userId = grant.userId {
                payload.append(["principal_type": "user", "principal_id": userId, "permission": "read"])
                if grant.write {
                    payload.append(["principal_type": "user", "principal_id": userId, "permission": "write"])
                }
            } else if let groupId = grant.groupId {
                payload.append(["principal_type": "group", "principal_id": groupId, "permission": "read"])
                if grant.write {
                    payload.append(["principal_type": "group", "principal_id": groupId, "permission": "write"])
                }
            }
        }
        // Public mode: add wildcard grant so all users can read
        if isPublic {
            payload.append(["principal_type": "user", "principal_id": "*", "permission": "read"])
        }
        let json = try await apiClient.updateKnowledgeAccessGrants(id: knowledgeId, grants: payload)
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            let merged = AccessGrant.mergedByUser(raw)
            // Strip the wildcard entry from the local state — it's implicit in isPrivate = false
            return merged.filter { $0.userId != "*" }
        }
        return grants
    }

    // MARK: - Users

    /// Fetches all server users for the access-control picker.
    func fetchAllUsers() async {
        do {
            allUsers = try await apiClient.searchAllUsers()
        } catch {
            // Non-critical — editor will show empty picker if this fails
        }
    }

    /// Removes a file from a knowledge base (does not delete the underlying file).
    @discardableResult
    func removeFile(fileId: String, from knowledgeId: String) async throws -> KnowledgeDetail {
        let json = try await apiClient.removeFileFromKnowledge(
            knowledgeId: knowledgeId,
            fileId: fileId
        )
        guard let updated = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        if let idx = knowledgeBases.firstIndex(where: { $0.id == knowledgeId }) {
            knowledgeBases[idx] = updated.toKnowledgeItem()
        }
        return updated
    }
}

// MARK: - ProgressCounter

/// A simple actor that provides async-safe increment for tracking parallel upload progress.
private actor ProgressCounter {
    private var value: Int = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

// MARK: - Errors

enum KnowledgeManagerError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an unexpected response."
        }
    }
}

/// One or more files in a batch failed to upload or process.
struct KnowledgeUploadError: LocalizedError {
    let failures: [String]
    let total: Int
    var errorDescription: String? {
        "\(failures.count) of \(total) file\(total == 1 ? "" : "s") failed:\n" + failures.prefix(4).joined(separator: "\n")
            + (failures.count > 4 ? "\n…" : "")
    }
}
