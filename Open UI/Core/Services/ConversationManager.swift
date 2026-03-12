import Foundation
import os.log

/// Manages conversation lifecycle operations against the OpenWebUI server.
///
/// Wraps ``APIClient`` calls and provides local caching of conversation
/// state. All methods are `async` and designed to be called from
/// `@Observable` view models on the main actor.
final class ConversationManager: @unchecked Sendable {
    let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "ConversationManager")

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch

    /// Fetches conversations from the server with optional pagination.
    func fetchConversations(limit: Int? = nil, skip: Int? = nil) async throws -> [Conversation] {
        try await apiClient.getConversations(limit: limit, skip: skip)
    }

    /// Fetches a single conversation with full message history.
    func fetchConversation(id: String) async throws -> Conversation {
        try await apiClient.getConversation(id: id)
    }

    /// Searches conversations by query string.
    func searchConversations(query: String) async throws -> [Conversation] {
        try await apiClient.searchConversations(query: query)
    }

    // MARK: - Create

    /// Creates a new conversation on the server.
    func createConversation(
        title: String,
        messages: [ChatMessage] = [],
        model: String? = nil,
        systemPrompt: String? = nil,
        folderId: String? = nil
    ) async throws -> Conversation {
        try await apiClient.createConversation(
            title: title,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt,
            folderId: folderId
        )
    }

    // MARK: - Update

    /// Renames a conversation.
    func renameConversation(id: String, title: String) async throws {
        try await apiClient.updateConversation(id: id, title: title)
    }

    /// Updates a conversation's system prompt.
    func updateSystemPrompt(id: String, systemPrompt: String) async throws {
        try await apiClient.updateConversation(id: id, systemPrompt: systemPrompt)
    }

    /// Saves conversation state (messages and metadata) after streaming.
    ///
    /// Syncs the full message history (including sources, files, follow-ups)
    /// to the server with the current title. This ensures nothing is lost.
    func saveConversation(_ conversation: Conversation) async throws {
        // Sync full messages with title to preserve everything
        try await apiClient.syncConversationMessages(
            id: conversation.id,
            messages: conversation.messages,
            model: conversation.model,
            systemPrompt: conversation.systemPrompt,
            title: conversation.title
        )
    }

    // MARK: - Delete

    /// Deletes a conversation.
    func deleteConversation(id: String) async throws {
        try await apiClient.deleteConversation(id: id)
    }

    /// Deletes all conversations for the current user.
    func deleteAllConversations() async throws {
        try await apiClient.deleteAllConversations()
    }

    // MARK: - Pin / Archive

    /// Pins or unpins a conversation.
    func pinConversation(id: String, pinned: Bool) async throws {
        try await apiClient.pinConversation(id: id, pinned: pinned)
    }

    /// Archives or unarchives a conversation.
    func archiveConversation(id: String, archived: Bool) async throws {
        try await apiClient.archiveConversation(id: id, archived: archived)
    }

    // MARK: - Share / Clone

    /// Shares a conversation and returns the share ID.
    func shareConversation(id: String) async throws -> String? {
        try await apiClient.shareConversation(id: id)
    }

    /// Clones a conversation.
    func cloneConversation(id: String) async throws -> Conversation {
        try await apiClient.cloneConversation(id: id)
    }

    // MARK: - Models

    /// Fetches available AI models.
    func fetchModels() async throws -> [AIModel] {
        try await apiClient.getModels()
    }

    /// Fetches the user's default model.
    func fetchDefaultModel() async -> String? {
        await apiClient.getDefaultModel()
    }

    // MARK: - Tools

    /// Fetches available tools from the server's `/api/v1/tools/` endpoint.
    /// Fetches available terminal servers for the current user.
    func fetchTerminalServers() async throws -> [TerminalServer] {
        try await apiClient.listTerminalServers()
    }

    func fetchTools() async throws -> [ToolItem] {
        let rawTools = try await apiClient.getTools()
        return rawTools.compactMap { raw -> ToolItem? in
            guard let id = raw["id"] as? String else { return nil }
            let name = raw["name"] as? String ?? id.replacingOccurrences(of: "_", with: " ").capitalized
            let meta = raw["meta"] as? [String: Any]
            let description = meta?["description"] as? String ?? raw["description"] as? String
            // Parse global enabled state: tools can be marked active via
            // `is_active` at the top level or `enabled` in meta.
            let isActive = raw["is_active"] as? Bool
                ?? meta?["enabled"] as? Bool
                ?? false
            return ToolItem(id: id, name: name, description: description, isEnabled: isActive)
        }
    }

    // MARK: - Chat Completion

    /// Sends a chat completion request and returns an SSE stream.
    func sendMessageStreaming(request: ChatCompletionRequest) async throws -> SSEStream {
        try await apiClient.sendMessageStreaming(request: request)
    }

    /// Sends a chat completion request via HTTP POST (for WebSocket streaming mode).
    /// Returns the JSON response (typically contains task_id).
    func sendMessageHTTP(request: ChatCompletionRequest) async throws -> [String: Any] {
        try await apiClient.sendMessageHTTP(request: request)
    }

    /// Syncs conversation messages to the server (builds full chat payload).
    func syncConversationMessages(
        id: String,
        messages: [ChatMessage],
        model: String?,
        systemPrompt: String? = nil,
        title: String? = nil
    ) async throws {
        try await apiClient.syncConversationMessages(
            id: id,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt,
            title: title
        )
    }

    /// Notifies the server that streaming is complete.
    func sendChatCompleted(
        chatId: String,
        messageId: String,
        model: String,
        sessionId: String
    ) async {
        await apiClient.sendChatCompleted(
            chatId: chatId,
            messageId: messageId,
            model: model,
            sessionId: sessionId
        )
    }

    // MARK: - Files

    /// Uploads a file and returns its server ID.
    func uploadFile(data: Data, fileName: String) async throws -> String {
        try await apiClient.uploadFile(data: data, fileName: fileName)
    }

    // MARK: - Knowledge

    /// Fetches knowledge bases as `KnowledgeItem` models for the `#` picker.
    func fetchKnowledgeItems() async throws -> [KnowledgeItem] {
        try await apiClient.getKnowledgeItems()
    }

    /// Fetches knowledge-associated files as `KnowledgeItem` models for the `#` picker.
    func fetchKnowledgeFileItems() async throws -> [KnowledgeItem] {
        try await apiClient.getKnowledgeFileItems()
    }

    /// Fetches chat folders as `KnowledgeItem` models for the `#` picker.
    func fetchFolderItems() async throws -> [KnowledgeItem] {
        try await apiClient.getFolderItems()
    }

    /// Returns the base URL for constructing file content URLs.
    var baseURL: String { apiClient.baseURL }
}
