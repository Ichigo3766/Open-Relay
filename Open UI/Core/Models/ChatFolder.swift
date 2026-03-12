import Foundation

/// Represents a folder for organising chat conversations.
///
/// Folders live on the Open WebUI server and are synced on every
/// load/refresh. Expand/collapse state is persisted to the server
/// with a short debounce so local UI remains snappy.
struct ChatFolder: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var parentId: String?
    var isExpanded: Bool
    var createdAt: Date
    var updatedAt: Date

    /// Conversations loaded inside this folder (populated lazily).
    var chats: [Conversation]

    init(
        id: String,
        name: String,
        parentId: String? = nil,
        isExpanded: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        chats: [Conversation] = []
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.isExpanded = isExpanded
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.chats = chats
    }

    // Include chats count, IDs, titles, and pin state so SwiftUI re-renders
    // when folder contents change (e.g. title updates, pin toggles).
    static func == (lhs: ChatFolder, rhs: ChatFolder) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isExpanded == rhs.isExpanded
            && lhs.parentId == rhs.parentId
            && lhs.chats.count == rhs.chats.count
            && lhs.chats.map(\.id) == rhs.chats.map(\.id)
            && lhs.chats.map(\.title) == rhs.chats.map(\.title)
            && lhs.chats.map(\.pinned) == rhs.chats.map(\.pinned)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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

        // The server stores expanded state in the meta object
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
        self.chats = []
    }
}
