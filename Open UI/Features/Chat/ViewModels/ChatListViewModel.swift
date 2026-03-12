import Foundation
import os.log

/// Manages the conversation list — grouping, search, pagination, and CRUD operations.
@MainActor @Observable
final class ChatListViewModel {
    // MARK: - Published State

    /// All conversations fetched from the server.
    var conversations: [Conversation] = []

    /// Whether conversations are being loaded.
    var isLoading: Bool = false

    /// Whether a refresh is in progress (pull-to-refresh).
    var isRefreshing: Bool = false

    /// Whether more pages are available.
    var hasMorePages: Bool = true

    /// Whether a next-page load is in progress.
    var isLoadingMore: Bool = false

    /// Search text for filtering conversations.
    var searchText: String = ""

    /// Error message to display.
    var errorMessage: String?

    /// Conversation being renamed (shown in alert).
    var renamingConversation: Conversation?

    /// Text for the rename alert field.
    var renameText: String = ""

    /// Conversation pending deletion (shown in confirmation).
    var deletingConversation: Conversation?

    /// Whether the user is in multi-select mode.
    var isSelectionMode: Bool = false

    /// IDs of conversations currently selected for bulk actions.
    var selectedConversationIds: Set<String> = []

    /// Whether the "delete all" confirmation is showing.
    var showDeleteAllConfirmation: Bool = false

    /// Whether the "delete selected" confirmation is showing.
    var showDeleteSelectedConfirmation: Bool = false

    /// Whether a bulk delete operation is in progress.
    var isDeletingBulk: Bool = false

    /// Whether the "archive all" confirmation is showing.
    var showArchiveAllConfirmation: Bool = false

    // MARK: - Pagination Config

    /// Number of conversations to fetch per page.
    let pageSize = 30

    /// Current page offset for pagination.
    private var currentPage = 0

    // MARK: - Folder Integration

    /// The folder view model — drives the Folders section.
    var folderViewModel = FolderListViewModel()

    // MARK: - Private

    private var manager: ConversationManager?
    private let logger = Logger(subsystem: "com.openui", category: "ChatListVM")

    /// Debounce task for search.
    private var searchTask: Task<Void, Never>?

    /// Timestamp of the last successful refresh to avoid excessive refreshes.
    private var lastRefreshDate: Date?

    /// Minimum interval between auto-refreshes (in seconds).
    private let autoRefreshInterval: TimeInterval = 5

    // MARK: - Computed Properties

    /// Pinned conversations, shown in a dedicated section.
    var pinnedConversations: [Conversation] {
        filteredConversations.filter(\.pinned)
    }

    /// Non-pinned, non-archived conversations for time grouping.
    private var unpinnedConversations: [Conversation] {
        filteredConversations.filter { !$0.pinned && !$0.archived }
    }

    /// Conversations that are NOT inside any folder (shown in the main list).
    var unfolderedConversations: [Conversation] {
        conversations.filter { $0.folderId == nil || $0.folderId?.isEmpty == true }
    }

    /// Filtered conversations based on search text.
    /// When searching, shows all conversations regardless of folder membership.
    var filteredConversations: [Conversation] {
        let source = searchText.isEmpty ? unfolderedConversations : conversations
        guard !searchText.isEmpty else { return source }
        return source.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Conversations grouped by recency for section headers.
    /// Each group is sorted by updatedAt descending (most recent first).
    var groupedConversations: [(String, [Conversation])] {
        let calendar = Calendar.current
        let sortDesc = { (a: Conversation, b: Conversation) -> Bool in a.updatedAt > b.updatedAt }
        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var thisWeek: [Conversation] = []
        var thisMonth: [Conversation] = []
        var older: [Conversation] = []

        for conversation in unpinnedConversations {
            if calendar.isDateInToday(conversation.updatedAt) {
                today.append(conversation)
            } else if calendar.isDateInYesterday(conversation.updatedAt) {
                yesterday.append(conversation)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now),
                      conversation.updatedAt > weekAgo {
                thisWeek.append(conversation)
            } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: .now),
                      conversation.updatedAt > monthAgo {
                thisMonth.append(conversation)
            } else {
                older.append(conversation)
            }
        }

        var groups: [(String, [Conversation])] = []
        if !today.isEmpty { groups.append((String(localized: "Today"), today.sorted(by: sortDesc))) }
        if !yesterday.isEmpty { groups.append((String(localized: "Yesterday"), yesterday.sorted(by: sortDesc))) }
        if !thisWeek.isEmpty { groups.append((String(localized: "This Week"), thisWeek.sorted(by: sortDesc))) }
        if !thisMonth.isEmpty { groups.append((String(localized: "This Month"), thisMonth.sorted(by: sortDesc))) }
        if !older.isEmpty { groups.append((String(localized: "Older"), older.sorted(by: sortDesc))) }
        return groups
    }

    // MARK: - Setup

    /// Configures the view model with a conversation manager.
    func configure(with manager: ConversationManager) {
        self.manager = manager
    }

    // MARK: - Loading

    /// Loads conversations from the server (first page).
    func loadConversations() async {
        guard let manager else { return }

        isLoading = true
        errorMessage = nil
        currentPage = 0
        hasMorePages = true

        do {
            let fetched = try await manager.fetchConversations(
                limit: pageSize,
                skip: 0
            )
            conversations = fetched
            hasMorePages = fetched.count >= pageSize
        } catch {
            logger.error("Failed to load conversations: \(error.localizedDescription)")
            errorMessage = errorDescription(for: error)
        }

        isLoading = false
    }

    /// Refreshes conversations (pull-to-refresh).
    func refreshConversations() async {
        guard let manager else { return }

        isRefreshing = true
        currentPage = 0

        do {
            let fetched = try await manager.fetchConversations(
                limit: pageSize,
                skip: 0
            )
            conversations = fetched
            hasMorePages = fetched.count >= pageSize
            errorMessage = nil
            lastRefreshDate = Date()
        } catch {
            logger.error("Failed to refresh conversations: \(error.localizedDescription)")
        }

        isRefreshing = false
    }

    /// Silently refreshes conversations if enough time has passed since the last refresh.
    /// Used for automatic foreground/reconnect refreshes to avoid hammering the server.
    func refreshIfStale() async {
        guard let manager else { return }

        // Skip if we refreshed recently
        if let lastRefresh = lastRefreshDate,
           Date().timeIntervalSince(lastRefresh) < autoRefreshInterval {
            return
        }

        // Skip if already loading
        guard !isLoading, !isRefreshing else { return }

        currentPage = 0

        do {
            let fetched = try await manager.fetchConversations(
                limit: pageSize,
                skip: 0
            )
            // Only update if the data actually changed (compare IDs + count)
            let fetchedIds = Set(fetched.map(\.id))
            let currentIds = Set(conversations.map(\.id))
            let titlesChanged = fetched.contains { newConv in
                conversations.first(where: { $0.id == newConv.id })?.title != newConv.title
            }
            let pinnedChanged = fetched.contains { newConv in
                conversations.first(where: { $0.id == newConv.id })?.pinned != newConv.pinned
            }

            if fetchedIds != currentIds || fetched.count != conversations.count || titlesChanged || pinnedChanged {
                conversations = fetched
                hasMorePages = fetched.count >= pageSize
                logger.info("Silent refresh: updated \(fetched.count) conversations")
            }
            errorMessage = nil
            lastRefreshDate = Date()
        } catch {
            logger.error("Silent refresh failed: \(error.localizedDescription)")
        }
    }

    /// Loads the next page of conversations when scrolling near the bottom.
    ///
    /// Call this from `onAppear` of the last few visible items.
    ///
    /// - Parameter currentItem: The conversation that just appeared.
    func loadMoreIfNeeded(currentItem: Conversation) async {
        // Only trigger when we're near the end of the list
        guard let lastItem = conversations.last,
              currentItem.id == lastItem.id,
              hasMorePages,
              !isLoadingMore,
              let manager
        else { return }

        isLoadingMore = true
        currentPage += 1

        do {
            let nextBatch = try await manager.fetchConversations(
                limit: pageSize,
                skip: currentPage * pageSize
            )

            // Deduplicate by ID before appending
            let existingIds = Set(conversations.map(\.id))
            let newItems = nextBatch.filter { !existingIds.contains($0.id) }
            conversations.append(contentsOf: newItems)

            hasMorePages = nextBatch.count >= pageSize
        } catch {
            logger.error("Failed to load more conversations: \(error.localizedDescription)")
            currentPage -= 1 // Revert page on failure
        }

        isLoadingMore = false
    }

    /// Triggers a debounced search. Call from onChange — does NOT await,
    /// so multiple onChange calls don't pile up outer Tasks.
    func triggerSearch() {
        searchTask?.cancel()
        // Skip creating a Task if the query is too short — avoids unnecessary
        // Task churn on every keystroke for single-character inputs.
        guard searchText.count >= 2 else { return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearchNow()
        }
    }

    /// Performs a server-side search with debouncing.
    func performSearch() async {
        guard searchText.count >= 2 else { return }
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearchNow()
        }
        await searchTask?.value
    }

    /// Immediately performs the search (no debounce). Internal use only.
    private func performSearchNow() async {
        guard let manager else { return }
        guard searchText.count >= 2 else { return }

        do {
            let results = try await manager.searchConversations(query: searchText)
            guard !Task.isCancelled else { return }

            // Merge search results with existing conversations
            let existingIds = Set(conversations.map(\.id))
            for result in results where !existingIds.contains(result.id) {
                conversations.append(result)
            }
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Search failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Create

    /// Creates a new empty conversation and returns it.
    func createNewConversation() -> Conversation {
        let conversation = Conversation(title: String(localized: "New Chat"))
        conversations.insert(conversation, at: 0)
        return conversation
    }

    // MARK: - Rename

    /// Begins the rename flow for a conversation.
    func beginRename(conversation: Conversation) {
        renamingConversation = conversation
        renameText = conversation.title
    }

    /// Commits the rename to the server.
    func commitRename() async {
        guard let manager,
              let conversation = renamingConversation,
              !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            renamingConversation = nil
            return
        }

        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Update locally first for responsiveness
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].title = newTitle
        }

        renamingConversation = nil

        do {
            try await manager.renameConversation(id: conversation.id, title: newTitle)
        } catch {
            logger.error("Failed to rename: \(error.localizedDescription)")
            // Revert on failure
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].title = conversation.title
            }
        }
    }

    // MARK: - Delete

    /// Deletes a conversation by ID.
    func deleteConversation(id: String) async {
        guard let manager else { return }

        // Remove locally first
        let removed = conversations.first { $0.id == id }
        conversations.removeAll(where: { $0.id == id })

        do {
            try await manager.deleteConversation(id: id)
        } catch {
            logger.error("Failed to delete: \(error.localizedDescription)")
            // Revert on failure
            if let removed {
                conversations.insert(removed, at: 0)
            }
        }
    }

    // MARK: - Pin / Unpin

    /// Toggles the pinned state of a conversation.
    func togglePin(conversation: Conversation) async {
        guard let manager else { return }

        let newPinned = !conversation.pinned

        // Update locally first
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].pinned = newPinned
        }

        do {
            try await manager.pinConversation(id: conversation.id, pinned: newPinned)
        } catch {
            logger.error("Failed to toggle pin: \(error.localizedDescription)")
            // Revert on failure
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].pinned = !newPinned
            }
        }
    }

    // MARK: - Archive / Unarchive

    /// Toggles the archived state of a conversation.
    func toggleArchive(conversation: Conversation) async {
        guard let manager else { return }

        let newArchived = !conversation.archived

        // Update locally first
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index].archived = newArchived
        }

        do {
            try await manager.archiveConversation(
                id: conversation.id,
                archived: newArchived
            )
        } catch {
            logger.error("Failed to toggle archive: \(error.localizedDescription)")
            // Revert on failure
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].archived = !newArchived
            }
        }
    }

    // MARK: - Share

    /// Shares a conversation and returns the share ID.
    func shareConversation(_ conversation: Conversation) async -> String? {
        guard let manager else { return nil }

        do {
            return try await manager.shareConversation(id: conversation.id)
        } catch {
            logger.error("Failed to share: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Title Updates

    /// Updates the title of a conversation in the local list.
    /// Called when a chat's title is generated by the server.
    func updateTitle(for conversationId: String, title: String) {
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].title = title
        }
    }

    // MARK: - Selection Mode

    /// Toggles selection mode on/off, clearing selections when exiting.
    func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode {
            selectedConversationIds.removeAll()
        }
    }

    /// Exits selection mode and clears all selections.
    func exitSelectionMode() {
        isSelectionMode = false
        selectedConversationIds.removeAll()
    }

    /// Toggles selection state of a single conversation.
    func toggleSelection(for conversationId: String) {
        if selectedConversationIds.contains(conversationId) {
            selectedConversationIds.remove(conversationId)
        } else {
            selectedConversationIds.insert(conversationId)
        }
    }

    /// Selects all visible conversations.
    func selectAll() {
        selectedConversationIds = Set(filteredConversations.map(\.id))
    }

    /// Whether a conversation is currently selected.
    func isSelected(_ conversationId: String) -> Bool {
        selectedConversationIds.contains(conversationId)
    }

    /// The number of currently selected conversations.
    var selectedCount: Int {
        selectedConversationIds.count
    }

    // MARK: - Bulk Delete

    /// Deletes all selected conversations.
    func deleteSelectedConversations() async {
        guard let manager else { return }

        isDeletingBulk = true
        let idsToDelete = selectedConversationIds

        // Remove locally first for responsiveness
        let removedConversations = conversations.filter { idsToDelete.contains($0.id) }
        conversations.removeAll { idsToDelete.contains($0.id) }
        selectedConversationIds.removeAll()
        isSelectionMode = false

        // Delete each conversation on the server
        var failedIds: [String] = []
        for id in idsToDelete {
            do {
                try await manager.deleteConversation(id: id)
            } catch {
                logger.error("Failed to delete conversation \(id): \(error.localizedDescription)")
                failedIds.append(id)
            }
        }

        // Revert any failed deletions
        if !failedIds.isEmpty {
            let failedConversations = removedConversations.filter { failedIds.contains($0.id) }
            conversations.insert(contentsOf: failedConversations, at: 0)
        }

        isDeletingBulk = false
    }

    /// Archives all conversations for the current user.
    func archiveAllConversations() async {
        guard let apiClient = manager?.apiClient else { return }

        isDeletingBulk = true // Reuse the loading overlay

        let previousConversations = conversations
        conversations.removeAll()

        do {
            try await apiClient.archiveAllConversations()
        } catch {
            logger.error("Failed to archive all: \(error.localizedDescription)")
            conversations = previousConversations
        }

        isDeletingBulk = false
    }

    /// Unshares a conversation (revokes its share link).
    func unshareConversation(_ conversation: Conversation) async {
        guard let apiClient = manager?.apiClient else { return }

        do {
            try await apiClient.unshareConversation(id: conversation.id)
            // Clear shareId locally
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].shareId = nil
            }
        } catch {
            logger.error("Failed to unshare: \(error.localizedDescription)")
        }
    }

    /// Deletes all conversations for the current user.
    func deleteAllConversations() async {
        guard let manager else { return }

        isDeletingBulk = true

        // Store for potential revert
        let previousConversations = conversations

        // Clear locally first for responsiveness
        conversations.removeAll()
        selectedConversationIds.removeAll()
        isSelectionMode = false

        do {
            try await manager.deleteAllConversations()
        } catch {
            logger.error("Failed to delete all conversations: \(error.localizedDescription)")
            // Revert on failure
            conversations = previousConversations
        }

        isDeletingBulk = false
    }

    // MARK: - Error Helpers

    /// Generates a user-friendly error description.
    private func errorDescription(for error: Error) -> String {
        let apiError = APIError.from(error)

        switch apiError {
        case .networkError:
            return String(localized: "Unable to connect. Check your internet connection and try again.")
        case .unauthorized, .tokenExpired:
            return String(localized: "Your session has expired. Please sign in again.")
        case .httpError(let code, _, _) where code >= 500:
            return String(localized: "The server is experiencing issues. Please try again later.")
        case .httpError(let code, let msg, _):
            return msg ?? String(localized: "Server error (\(code)). Please try again.")
        default:
            return String(localized: "Failed to load conversations. Please try again.")
        }
    }
}
