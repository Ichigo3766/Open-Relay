import Foundation

// MARK: - Chat Task

/// A task item managed by the model's built-in task management tools
/// (`create_tasks` / `update_task`). Stored at the chat level by OpenWebUI.
struct ChatTask: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var content: String
    /// One of: "pending", "in_progress", "completed", "cancelled"
    var status: String

    var isCompleted: Bool { status == "completed" }
    var isInProgress: Bool { status == "in_progress" }
    var isCancelled: Bool { status == "cancelled" }
    var isPending: Bool { status == "pending" }
}

// MARK: - Conversation

/// Represents a chat conversation with its message history.
struct Conversation: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var model: String?
    var systemPrompt: String?

    /// The tree-based message history — **source of truth** for all messages.
    ///
    /// Populated from the server's `chat.history` JSON object. All operations
    /// (edit, regenerate, new message, version switch) mutate the tree, then
    /// re-derive the flat `messages` array via `rederiveMessages()`.
    var history: MessageHistory

    /// Flat ordered message list for the current branch — **derived from `history`**.
    ///
    /// The UI reads this directly. It is re-computed by calling `rederiveMessages()`
    /// after any tree mutation. During streaming, individual messages are updated
    /// in-place for efficiency; the full rederive happens on structural changes
    /// (new messages, branch switches, edits).
    var messages: [ChatMessage]

    var pinned: Bool
    var archived: Bool
    var shareId: String?
    var folderId: String?
    var tags: [String]
    /// Per-chat advanced params override. When non-nil, these values are merged
    /// on top of the selected model's params for every message sent in this chat.
    var chatParams: ChatAdvancedParams?
    /// Tasks created and managed by the model's built-in task management tools.
    var tasks: [ChatTask]

    init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        model: String? = nil,
        systemPrompt: String? = nil,
        history: MessageHistory = MessageHistory(),
        messages: [ChatMessage] = [],
        pinned: Bool = false,
        archived: Bool = false,
        shareId: String? = nil,
        folderId: String? = nil,
        tags: [String] = [],
        tasks: [ChatTask] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.systemPrompt = systemPrompt
        self.history = history
        self.messages = messages
        self.pinned = pinned
        self.archived = archived
        self.shareId = shareId
        self.folderId = folderId
        self.tags = tags
        self.tasks = tasks
    }

    /// Re-derives the flat `messages` array from the history tree.
    ///
    /// Call this after any structural mutation to the history tree
    /// (new nodes, branch switches, edits). Content-only updates
    /// during streaming can bypass this for performance.
    mutating func rederiveMessages() {
        messages = history.createMessagesList()
    }

    // MARK: - Tree Convenience

    /// Returns the sibling IDs for a given message in the history tree.
    func siblings(of messageId: String) -> [String] {
        history.siblings(of: messageId)
    }

    // Hashable: includes messages count and title so SwiftUI
    // detects structural changes during streaming.
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.messages == rhs.messages
            && lhs.tasks == rhs.tasks
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(messages.count)
        hasher.combine(tasks.count)
    }

    /// Whether this conversation is a temporary (incognito) chat that
    /// hasn't been persisted to the server. Matches the Open WebUI
    /// `local:` prefix convention used by the Conduit Flutter client.
    var isTemporary: Bool {
        id.hasPrefix("local:")
    }
}
