import Foundation

// MARK: - Supporting Types (imported from Channel.swift)
// AccessGrant is defined in Channel.swift and reused here.

/// Data stored on a folder that configures it as a project workspace.
/// Maps to the `data` field in the Open WebUI folder API.
struct FolderData: Sendable, Hashable {
    /// Default model IDs for chats created inside this folder.
    var modelIds: [String]
    /// System prompt prepended to all new chats created in this folder.
    var systemPrompt: String?
    /// Knowledge bases / files attached to this folder.
    var knowledgeItems: [FolderKnowledgeItem]

    init(
        modelIds: [String] = [],
        systemPrompt: String? = nil,
        knowledgeItems: [FolderKnowledgeItem] = []
    ) {
        self.modelIds = modelIds
        self.systemPrompt = systemPrompt
        self.knowledgeItems = knowledgeItems
    }

    init?(json: [String: Any]) {
        modelIds = json["model_ids"] as? [String] ?? []
        systemPrompt = json["system_prompt"] as? String
        if let rawItems = json["knowledge_items"] as? [[String: Any]] {
            knowledgeItems = rawItems.compactMap { FolderKnowledgeItem(json: $0) }
        } else {
            knowledgeItems = []
        }
    }

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = [
            "model_ids": modelIds
        ]
        if let systemPrompt {
            dict["system_prompt"] = systemPrompt
        }
        if !knowledgeItems.isEmpty {
            dict["knowledge_items"] = knowledgeItems.map { $0.toJSON() }
        }
        return dict
    }
}

/// A knowledge base or file attached to a folder.
struct FolderKnowledgeItem: Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    /// "collection" | "file" | "folder"
    var type: String

    init(id: String, name: String, type: String = "collection") {
        self.id = id
        self.name = name
        self.type = type
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.type = json["type"] as? String ?? "collection"
    }

    func toJSON() -> [String: Any] {
        ["id": id, "name": name, "type": type]
    }
}

/// Metadata stored on a folder (visual & UI state).
/// Maps to the `meta` field in the Open WebUI folder API.
struct FolderMeta: Sendable, Hashable {
    /// URL of a background image (set via Edit Folder → Upload).
    var backgroundImageUrl: String?

    init(backgroundImageUrl: String? = nil) {
        self.backgroundImageUrl = backgroundImageUrl
    }

    init?(json: [String: Any]) {
        backgroundImageUrl = json["background_image_url"] as? String
            ?? json["backgroundImageUrl"] as? String
    }

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let url = backgroundImageUrl {
            dict["background_image_url"] = url
        }
        return dict
    }
}

// MARK: - ChatFolder

/// Represents a folder for organising chat conversations.
///
/// Folders live on the Open WebUI server and are synced on every
/// load/refresh. Expand/collapse state is persisted to the server
/// with a short debounce so local UI remains snappy.
///
/// Folders also act as **project workspaces**: they can hold a system
/// prompt, default model IDs, and attached knowledge bases that apply
/// to every new chat created inside them.
struct ChatFolder: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var parentId: String?
    var isExpanded: Bool
    var createdAt: Date
    var updatedAt: Date

    /// Project workspace configuration (system prompt, models, knowledge).
    var data: FolderData?

    /// Visual metadata (background image URL).
    var meta: FolderMeta?

    /// Conversations loaded inside this folder (populated lazily).
    var chats: [Conversation]

    /// Child folders (populated when building the tree from a flat list).
    var childFolders: [ChatFolder]

    // MARK: - Sharing

    /// User ID of the folder owner (nil if server doesn't return it).
    var userId: String?

    /// Whether this folder is publicly accessible (access_grants contains principal_id == "*").
    var isPublic: Bool

    /// Access grants — the list of users/groups who can access this folder.
    var accessGrants: [AccessGrant]

    /// When true, this folder was shared *with* the current user (not owned by them)
    /// and they only have read permission — chats inside are view-only.
    var readonly: Bool

    init(
        id: String,
        name: String,
        parentId: String? = nil,
        isExpanded: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        data: FolderData? = nil,
        meta: FolderMeta? = nil,
        chats: [Conversation] = [],
        childFolders: [ChatFolder] = [],
        userId: String? = nil,
        isPublic: Bool = false,
        accessGrants: [AccessGrant] = [],
        readonly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.isExpanded = isExpanded
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.data = data
        self.meta = meta
        self.chats = chats
        self.childFolders = childFolders
        self.userId = userId
        self.isPublic = isPublic
        self.accessGrants = accessGrants
        self.readonly = readonly
    }

    // MARK: - Convenience computed properties

    /// System prompt from the folder's data, or nil if not set.
    var systemPrompt: String? { data?.systemPrompt }

    /// Default model IDs from the folder's data.
    var modelIds: [String] { data?.modelIds ?? [] }

    /// Background image URL from the folder's meta.
    var backgroundImageUrl: String? { meta?.backgroundImageUrl }

    /// Whether this folder has any project-level configuration.
    var hasProjectConfig: Bool {
        guard let data else { return false }
        return !(data.systemPrompt ?? "").isEmpty
            || !data.modelIds.isEmpty
            || !data.knowledgeItems.isEmpty
            || meta?.backgroundImageUrl != nil
    }

    // MARK: - Equatable

    // Include chats count, IDs, titles, pin state, data and meta so SwiftUI
    // re-renders when folder contents or configuration changes.
    static func == (lhs: ChatFolder, rhs: ChatFolder) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isExpanded == rhs.isExpanded
            && lhs.parentId == rhs.parentId
            && lhs.data == rhs.data
            && lhs.meta == rhs.meta
            && lhs.chats.count == rhs.chats.count
            && lhs.chats.map(\.id) == rhs.chats.map(\.id)
            && lhs.chats.map(\.title) == rhs.chats.map(\.title)
            && lhs.chats.map(\.pinned) == rhs.chats.map(\.pinned)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(data)
        hasher.combine(chats.count)
        for chat in chats {
            hasher.combine(chat.id)
            hasher.combine(chat.title)
        }
    }
}

// MARK: - Parsing

extension ChatFolder {
    /// Initialises from a raw JSON dictionary returned by the server.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String
        else { return nil }

        self.id = id
        self.name = name
        self.parentId = json["parent_id"] as? String

        // The server stores expanded state in the meta object or at root level
        if let meta = json["meta"] as? [String: Any] {
            self.isExpanded = meta["is_expanded"] as? Bool ?? false
        } else {
            self.isExpanded = json["is_expanded"] as? Bool ?? false
        }

        var createdAt = Date()
        var updatedAt = Date()
        if let ts = json["created_at"] as? Double { createdAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["created_at"] as? Int { createdAt = Date(timeIntervalSince1970: Double(ts)) }
        if let ts = json["updated_at"] as? Double { updatedAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["updated_at"] as? Int { updatedAt = Date(timeIntervalSince1970: Double(ts)) }

        self.createdAt = createdAt
        self.updatedAt = updatedAt

        // Parse project data (system prompt, models, knowledge)
        if let rawData = json["data"] as? [String: Any] {
            self.data = FolderData(json: rawData)
        } else {
            self.data = nil
        }

        // Parse visual meta (background image)
        if let rawMeta = json["meta"] as? [String: Any] {
            self.meta = FolderMeta(json: rawMeta)
        } else {
            self.meta = nil
        }

        self.chats = []
        self.childFolders = []

        // Parse owner
        self.userId = json["user_id"] as? String

        // Parse access_grants and detect public access
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            self.accessGrants = AccessGrant.mergedByPrincipal(raw)
            self.isPublic = grantsArray.contains { $0["principal_id"] as? String == "*" }
        } else {
            self.accessGrants = []
            self.isPublic = false
        }

        // readonly flag — set by server on /shared/chats response; false for owned folders
        self.readonly = json["readonly"] as? Bool ?? false
    }
}

// MARK: - Sharing Helpers

extension ChatFolder {
    /// Returns true if the current user owns this folder.
    func isOwnedBy(_ currentUserId: String) -> Bool {
        guard let userId else { return true } // assume owner if server doesn't return userId
        return userId == currentUserId
    }

    /// Returns true if this folder has been shared with at least one person or group.
    var isShared: Bool {
        isPublic || !accessGrants.isEmpty
    }

    /// Builds the access_grants payload for POST /folders/{id}/access/update.
    /// Write access = TWO entries (read + write), read-only = ONE entry (read).
    func buildGrantsPayload() -> [[String: Any]] {
        var result: [[String: Any]] = []
        if isPublic {
            result.append(["principal_type": "user", "principal_id": "*", "permission": "read"])
        }
        for grant in accessGrants {
            if let userId = grant.userId, userId != "*" {
                result.append(["principal_type": "user", "principal_id": userId, "permission": "read"])
                if grant.write {
                    result.append(["principal_type": "user", "principal_id": userId, "permission": "write"])
                }
            } else if let groupId = grant.groupId {
                result.append(["principal_type": "group", "principal_id": groupId, "permission": "read"])
                if grant.write {
                    result.append(["principal_type": "group", "principal_id": groupId, "permission": "write"])
                }
            }
        }
        return result
    }
}
