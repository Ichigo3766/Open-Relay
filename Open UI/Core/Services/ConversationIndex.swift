import Foundation

/// Only sidebar metadata is persisted here; message bodies belong to the individual chat cache.
nonisolated struct ConversationIndex: Codable, Sendable {
    var conversations: [Summary]
    var pinned: [Summary]
    var reconciledAt: Date

    nonisolated struct Summary: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var model: String?
        var pinned: Bool
        var archived: Bool
        var folderId: String?
        var tags: [String]

        init(_ conversation: Conversation) {
            id = conversation.id
            title = conversation.title
            createdAt = conversation.createdAt
            updatedAt = conversation.updatedAt
            model = conversation.model
            pinned = conversation.pinned
            archived = conversation.archived
            folderId = conversation.folderId
            tags = conversation.tags
        }

        var conversation: Conversation {
            Conversation(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                model: model, pinned: pinned, archived: archived, folderId: folderId, tags: tags)
        }
    }

    /// Require a whole unchanged page, and continue through one more unchanged page as overlap.
    static func unchanged(_ page: [Conversation], comparedTo known: [String: Summary]) -> Bool {
        !page.isEmpty && page.allSatisfy { known[$0.id] == Summary($0) }
    }
}
