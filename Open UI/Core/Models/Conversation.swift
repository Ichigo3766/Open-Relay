import Foundation

/// Represents a chat conversation with its message history.
struct Conversation: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var model: String?
    var systemPrompt: String?
    var messages: [ChatMessage]
    var pinned: Bool
    var archived: Bool
    var shareId: String?
    var folderId: String?
    var tags: [String]

    init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        model: String? = nil,
        systemPrompt: String? = nil,
        messages: [ChatMessage] = [],
        pinned: Bool = false,
        archived: Bool = false,
        shareId: String? = nil,
        folderId: String? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.pinned = pinned
        self.archived = archived
        self.shareId = shareId
        self.folderId = folderId
        self.tags = tags
    }

    // Hashable: includes messages count and title so SwiftUI
    // detects structural changes during streaming.
    // FIX: Removed redundant `messages.count` comparison — already checked by `messages ==`.
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.messages == rhs.messages
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(messages.count)
    }

    /// Whether this conversation is a temporary (incognito) chat that
    /// hasn't been persisted to the server. Matches the Open WebUI
    /// `local:` prefix convention used by the Conduit Flutter client.
    var isTemporary: Bool {
        id.hasPrefix("local:")
    }
}
