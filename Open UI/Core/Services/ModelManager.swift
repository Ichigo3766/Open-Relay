import Foundation
import os.log

/// Manages Models CRUD operations for the workspace.
@Observable
final class ModelManager {
    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "Models")

    // MARK: - State

    var models: [ModelItem] = []
    var allUsers: [ChannelMember] = []
    var isLoading = false
    var error: String?

    // MARK: - Init

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch All

    // MARK: - Server-side list filters (mirror Models.svelte)

    /// "" (all) | "created" | "shared" — the server's `view_option`.
    var viewOption = ""
    /// Selected tag filter ("" = none).
    var selectedTag = ""
    /// name | created_at | updated_at — empty uses the server default.
    var sortKey = ""
    /// asc | desc.
    var sortDirection = ""
    /// Search text (sent to the server, which also matches owner name/email).
    var query = ""
    var tags: [String] = []

    func fetchAll() async {
        isLoading = true
        error = nil
        do {
            models = try await apiClient.listAllWorkspaceModels(
                query: query, viewOption: viewOption, tag: selectedTag,
                orderBy: sortKey, direction: sortDirection)
            tags = (try? await apiClient.getWorkspaceModelTags()) ?? tags
            // Evict all model avatar URLs from the cache so that any avatar
            // changed on the server is re-fetched on the next render instead
            // of serving the stale cached image indefinitely.
            let baseURL = apiClient.baseURL
            let avatarURLs = models.compactMap { $0.resolveAvatarURL(baseURL: baseURL) }
            Task {
                for url in avatarURLs {
                    await ImageCacheService.shared.evict(for: url)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Get Detail

    func getDetail(id: String) async throws -> ModelDetail {
        try await apiClient.getWorkspaceModelDetail(id: id)
    }

    // MARK: - Create

    @discardableResult
    func create(from detail: ModelDetail) async throws -> ModelDetail {
        let json = try await apiClient.createWorkspaceModel(payload: detail.toCreatePayload())
        guard let created = ModelDetail(json: json) else {
            throw ModelManagerError.invalidResponse
        }
        models.append(created.toModelItem())
        return created
    }

    // MARK: - Update

    @discardableResult
    func update(_ detail: ModelDetail) async throws -> ModelDetail {
        let json = try await apiClient.updateWorkspaceModel(payload: detail.toUpdatePayload())
        guard let updated = ModelDetail(json: json) else {
            throw ModelManagerError.invalidResponse
        }
        if let idx = models.firstIndex(where: { $0.id == detail.id }) {
            models[idx] = updated.toModelItem()
        }
        // Evict this model's avatar from the cache so the updated image
        // is re-fetched immediately on next display.
        if let url = updated.toModelItem().resolveAvatarURL(baseURL: apiClient.baseURL) {
            Task { await ImageCacheService.shared.evict(for: url) }
        }
        return updated
    }

    // MARK: - Delete

    func delete(id: String) async throws {
        try await apiClient.deleteWorkspaceModel(id: id)
        models.removeAll { $0.id == id }
    }

    // MARK: - Toggle Active

    @discardableResult
    func toggle(id: String) async throws -> ModelItem {
        let json = try await apiClient.toggleWorkspaceModel(id: id)
        guard let updated = ModelDetail(json: json) else {
            throw ModelManagerError.invalidResponse
        }
        let item = updated.toModelItem()
        if let idx = models.firstIndex(where: { $0.id == id }) {
            models[idx] = item
        }
        return item
    }

    // MARK: - Clone

    @discardableResult
    func clone(id: String) async throws -> ModelDetail {
        let source = try await getDetail(id: id)
        // Generate new ID and name
        let cloneId = source.id + "-clone"
        let cloneName = source.name + " (Clone)"
        // Build the payload from the source model
        var payload = source.toCreatePayload()
        payload["id"] = cloneId
        payload["name"] = cloneName
        payload["access_grants"] = [] as [[String: Any]]
        let json = try await apiClient.createWorkspaceModel(payload: payload)
        guard let created = ModelDetail(json: json) else {
            throw ModelManagerError.invalidResponse
        }
        models.append(created.toModelItem())
        return created
    }

    // MARK: - Export All

    func exportAll() async throws -> Data {
        let items = try await apiClient.exportWorkspaceModels()
        return try JSONSerialization.data(withJSONObject: items, options: .prettyPrinted)
    }

    // MARK: - Access Grants

    @discardableResult
    func updateAccessGrants(modelId: String, modelName: String, grants: [AccessGrant], isPublic: Bool = false) async throws -> [AccessGrant] {
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
        if isPublic {
            payload.append(["principal_type": "user", "principal_id": "*", "permission": "read"])
        }
        let json = try await apiClient.updateModelAccessGrants(id: modelId, name: modelName, grants: payload)
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            let merged = AccessGrant.mergedByUser(raw)
            return merged.filter { $0.userId != "*" }
        }
        return grants
    }

    // MARK: - Hide / Show (meta.hidden)

    /// Flips `meta.hidden` by re-sending the stored record (web `hideModelHandler`).
    @discardableResult
    func setHidden(_ hidden: Bool, id: String) async throws -> ModelItem? {
        guard var record = try await apiClient.getWorkspaceModelRecord(id: id) else { return nil }
        var meta = decodeOriginalMeta(record.originalMetaJSON)
        meta["hidden"] = hidden
        record.originalMetaJSON = try? JSONSerialization.data(withJSONObject: meta)
        var payload = record.toRawUpdatePayload()
        payload["meta"] = meta
        let json = try await apiClient.updateWorkspaceModel(payload: payload)
        guard let updated = ModelDetail(json: json) else { throw ModelManagerError.invalidResponse }
        let item = updated.toModelItem()
        var merged = item
        merged.isHidden = hidden
        if let idx = models.firstIndex(where: { $0.id == id }) { models[idx] = merged }
        return merged
    }

    // MARK: - Pinned ("Keep in Sidebar") — ui.pinnedModels

    func loadPinnedModelIds() async -> [String] {
        let settings = (try? await apiClient.getUserSettings()) ?? [:]
        let ui = settings["ui"] as? [String: Any] ?? [:]
        return ui["pinnedModels"] as? [String] ?? []
    }

    /// Toggles a model in `ui.pinnedModels`, keeping every other `ui` key.
    func togglePinned(id: String, current: [String]) async throws -> [String] {
        var next = current
        if let i = next.firstIndex(of: id) { next.remove(at: i) } else { next.append(id) }
        try await apiClient.mergeUserUISettings(["pinnedModels": next])
        return next
    }

    // MARK: - Bulk actions (apply to the current filtered set, across all pages)

    /// Enables/disables every model whose state differs. Uses `/toggle`, which flips is_active.
    func setActiveForAll(_ active: Bool) async throws {
        let all = try await apiClient.listAllWorkspaceModels(
            query: query, viewOption: viewOption, tag: selectedTag)
        for m in all where m.writeAccess && m.isActive != active {
            _ = try await apiClient.toggleWorkspaceModel(id: m.id)
        }
        await fetchAll()
    }

    /// Hides/shows every model whose state differs.
    func setHiddenForAll(_ hidden: Bool) async throws {
        let all = try await apiClient.listAllWorkspaceModels(
            query: query, viewOption: viewOption, tag: selectedTag)
        for m in all where m.writeAccess && m.isHidden != hidden {
            _ = try await setHidden(hidden, id: m.id)
        }
        await fetchAll()
    }

    // MARK: - Users

    func fetchAllUsers() async {
        do {
            allUsers = try await apiClient.searchAllUsers()
        } catch {
            logger.warning("Failed to fetch users: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum ModelManagerError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "The server returned an unexpected response."
    }
}
