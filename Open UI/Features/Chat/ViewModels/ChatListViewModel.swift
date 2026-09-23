import Foundation
import os.log

/// Manages the conversation list — grouping, search, and CRUD operations.
///
/// ## Pagination Strategy
///
/// All conversations are fetched upfront on load, matching the Open WebUI web interface.
/// Page 1 loads immediately so the UI is interactive right away. Remaining pages are then
/// fetched in parallel batches of 5 in the background, merging progressively into the list.
/// This continues until the server returns an empty page, signalling no more data.
///
/// There is no scroll-based lazy pagination — it doesn't work well with time-grouped sections
/// because empty section headers don't render, leaving no items to scroll to.
@MainActor @Observable
final class ChatListViewModel {
    // MARK: - Published State

    /// Whether the initial page-1 load is in progress.
    var isLoading: Bool = false

    /// Whether a pull-to-refresh is in progress.
    var isRefreshing: Bool = false

    /// Whether background pages are still being fetched after page 1.
    var isFetchingAllPages: Bool = false

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

    /// Whether the "move to folder" sheet is showing (bulk selection).
    var showMoveToFolderSheet: Bool = false

    // MARK: - Folder Integration

    /// The folder view model — drives the Folders section.
    var folderViewModel = FolderListViewModel()

    // MARK: - Private

    private var manager: ConversationManager?
    private let logger = Logger(subsystem: "com.openui", category: "ChatListVM")

    /// Debounce task for search.
    private var searchTask: Task<Void, Never>?

    /// Background fetch task — cancelled on refresh so a new fetch can start clean.
    private var backgroundFetchTask: Task<Void, Never>?

    /// Timestamp of the last successful refresh to avoid excessive refreshes.
    private var lastRefreshDate: Date?

    /// Minimum interval between auto-refreshes (in seconds).
    private let autoRefreshInterval: TimeInterval = 5

    private var lastReconciledAt: Date?
    private var refreshGeneration = UUID()
    private var contentRevision = UUID()

    // MARK: - Cached Formatters

    /// Cached month-name formatter — allocated once, reused across all `groupedConversations` calls.
    /// `DateFormatter` is one of Foundation's most expensive objects; allocating it per-call
    /// during active drawer-open/close animations causes measurable frame drops.
    private static let monthNameFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL"  // Full month name e.g. "February"
        return fmt
    }()

    // MARK: - Computed Properties

    /// Pinned conversations fetched directly from `/api/v1/chats/pinned`.
    /// This is an independent list — NOT a filtered subset of `conversations` —
    /// so it correctly includes folder chats that are excluded from the main list.
    var conversations: [Conversation] = [] {
        didSet { contentRevision = UUID() }
    }

    var pinnedConversations: [Conversation] = [] {
        didSet {
            contentRevision = UUID()
            // Keep folderViewModel in sync so folder chat lists can exclude pinned IDs
            // and avoid showing a pinned folder chat both in Pinned and inside its folder.
            folderViewModel.pinnedChatIds = Set(pinnedConversations.map(\.id))
        }
    }

    /// Non-pinned, non-archived conversations for time grouping.
    private var unpinnedConversations: [Conversation] {
        filteredConversations.filter { !$0.pinned && !$0.archived }
    }

    /// Conversations that are NOT inside any folder (shown in the main list).
    ///
    /// Excludes any conversation whose ID appears in a folder's loaded chat list.
    /// Pinned chats are now in their own independent `pinnedConversations` array
    /// and do NOT need to be surfaced here.
    var unfolderedConversations: [Conversation] {
        let folderChatIds = Set(folderViewModel.folders.flatMap(\.chats).map(\.id))
        let pinnedIds = Set(pinnedConversations.map(\.id))
        return conversations.filter {
            ($0.folderId == nil || $0.folderId!.isEmpty)
                && !folderChatIds.contains($0.id)
                && !pinnedIds.contains($0.id)
        }
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

    /// Conversations grouped by recency, matching the Open WebUI web interface grouping:
    ///
    /// - **Today** — updated today
    /// - **Yesterday** — updated yesterday
    /// - **This Week** — updated in the last 7 days (not today/yesterday)
    /// - **This Month** — updated this calendar month (not this week)
    /// - **[Month name]** — e.g. "February", "January" — previous months in the current year
    /// - **[Year]** — e.g. "2025", "2024" — conversations from previous years
    ///
    /// Each group is sorted by `updatedAt` descending (most recent first).
    var groupedConversations: [(String, [Conversation])] {
        let calendar = Calendar.current
        let now = Date.now
        let currentYear = calendar.component(.year, from: now)

        let sortDesc = { (a: Conversation, b: Conversation) -> Bool in a.updatedAt > b.updatedAt }

        // Buckets for the fixed recent sections
        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var thisWeek: [Conversation] = []
        var thisMonth: [Conversation] = []

        // Dynamic buckets: keyed by "YYYY-MM" for previous months in current year,
        // and "YYYY" for entire previous years.
        var monthBuckets: [String: [Conversation]] = [:]  // e.g. "2026-01" → [...]
        var yearBuckets: [String: [Conversation]] = [:]   // e.g. "2025" → [...]

        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!

        // Compute the start of the current month for "this month" boundary
        let startOfMonth: Date = {
            var comps = calendar.dateComponents([.year, .month], from: now)
            comps.day = 1
            comps.hour = 0
            comps.minute = 0
            comps.second = 0
            return calendar.date(from: comps) ?? now
        }()

        for conv in unpinnedConversations {
            let date = conv.updatedAt
            if date >= todayStart && date < tomorrowStart {
                today.append(conv)
            } else if date >= yesterdayStart && date < todayStart {
                yesterday.append(conv)
            } else if date > weekAgo {
                thisWeek.append(conv)
            } else if date >= startOfMonth {
                // Within current month but older than 7 days
                thisMonth.append(conv)
            } else {
                // Older than current month
                let year = calendar.component(.year, from: date)
                let month = calendar.component(.month, from: date)

                if year == currentYear {
                    // Previous month within the same year → show month name
                    let key = String(format: "%04d-%02d", year, month)
                    monthBuckets[key, default: []].append(conv)
                } else {
                    // Previous year → group entire year together
                    let key = "\(year)"
                    yearBuckets[key, default: []].append(conv)
                }
            }
        }

        var groups: [(String, [Conversation])] = []

        // Fixed recent sections
        if !today.isEmpty {
            groups.append((String(localized: "Today"), today.sorted(by: sortDesc)))
        }
        if !yesterday.isEmpty {
            groups.append((String(localized: "Yesterday"), yesterday.sorted(by: sortDesc)))
        }
        if !thisWeek.isEmpty {
            groups.append((String(localized: "This Week"), thisWeek.sorted(by: sortDesc)))
        }
        if !thisMonth.isEmpty {
            groups.append((String(localized: "This Month"), thisMonth.sorted(by: sortDesc)))
        }

        // Previous months in the current year — sorted newest month first
        let sortedMonthKeys = monthBuckets.keys.sorted().reversed()
        let monthFormatter = ChatListViewModel.monthNameFormatter

        for key in sortedMonthKeys {
            guard let convs = monthBuckets[key], !convs.isEmpty else { continue }
            // Build a Date from the key to get the localized month name
            // key format: "YYYY-MM"
            let parts = key.split(separator: "-")
            if parts.count == 2,
               let year = Int(parts[0]),
               let month = Int(parts[1]) {
                var comps = DateComponents()
                comps.year = year
                comps.month = month
                comps.day = 1
                if let date = calendar.date(from: comps) {
                    let monthName = monthFormatter.string(from: date)
                    groups.append((monthName, convs.sorted(by: sortDesc)))
                }
            }
        }

        // Previous years — sorted newest year first
        let sortedYearKeys = yearBuckets.keys.sorted().reversed()
        for key in sortedYearKeys {
            guard let convs = yearBuckets[key], !convs.isEmpty else { continue }
            groups.append((key, convs.sorted(by: sortDesc)))
        }

        return groups
    }

    // MARK: - Setup

    /// Configures the view model with a conversation manager.
    func configure(with manager: ConversationManager) {
        self.manager = manager
    }

    // MARK: - Loading

    func loadConversations() async {
        guard let manager, !isLoading, !isRefreshing, !isFetchingAllPages else { return }
        let scope = manager.apiClient.network.conversationCacheScope
        let generation = refreshGeneration
        let savedContent = contentRevision
        isLoading = conversations.isEmpty
        if conversations.isEmpty, let saved = await ConversationCache.shared.cachedIndex(scope: scope) {
            guard generation == refreshGeneration, scope == manager.apiClient.network.conversationCacheScope else { return }
            guard savedContent == contentRevision else { isLoading = false; return }
            conversations = saved.conversations.map(\.conversation)
            pinnedConversations = saved.pinned.map(\.conversation)
            lastReconciledAt = saved.reconciledAt
            isLoading = false
        }
        await refreshConversations()
    }

    /// Keep the existing list visible; publish page one before fetching older pages.
    func refreshConversations(forceFull: Bool = false) async {
        guard let manager, !isRefreshing else { return }
        backgroundFetchTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        let scope = manager.apiClient.network.conversationCacheScope
        isRefreshing = true
        var revision = await ConversationCache.shared.currentRevision()
        guard generation == refreshGeneration else { return }
        let full = forceFull || (lastReconciledAt.map { Date().timeIntervalSince($0) >= 6 * 60 * 60 } ?? true)
        let known = Dictionary(conversations.map { ($0.id, ConversationIndex.Summary($0)) }, uniquingKeysWith: { _, last in last })
        var expectedContent = contentRevision
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard generation == self.refreshGeneration, expectedContent == self.contentRevision,
                  scope == manager.apiClient.network.conversationCacheScope else { throw CancellationError() }
        }
        do {
            async let page1Request = manager.fetchConversationsPage(page: 1)
            async let pinnedRequest = manager.apiClient.getPinnedConversations()
            let (page1, pinned) = try await (page1Request, pinnedRequest)
            try checkCurrent()
            revision = await invalidateChangedSummaries(page1, known: known, scope: scope, revision: revision)
            try checkCurrent()
            conversations = mergeFreshPage(page1, into: conversations)
            pinnedConversations = pinned
            expectedContent = contentRevision
            isLoading = false
            isRefreshing = false
            isFetchingAllPages = true
            errorMessage = nil
            // Save a partial snapshot immediately after page 1 so the cache is populated
            // even if the user goes offline before the background paginator finishes.
            // Without this, `ConversationCache.cachedIndex` returns nil until all pages
            // complete, causing the blocking overlay to show instead of the offline banner.
            let partialSnapshot = ConversationIndex(
                conversations: conversations.map(ConversationIndex.Summary.init),
                pinned: pinnedConversations.map(ConversationIndex.Summary.init),
                reconciledAt: lastReconciledAt ?? .distantPast)
            await ConversationCache.shared.saveIndex(partialSnapshot, scope: scope, revision: revision)
            backgroundFetchTask = Task {
                var fresh = page1
                var page = page1
                var number = 1
                var unchangedPages = ConversationIndex.unchanged(page, comparedTo: known) ? 1 : 0
                do {
                    while !page.isEmpty && (full || unchangedPages < 2) {
                        try checkCurrent()
                        let batch = try await withThrowingTaskGroup(of: (Int, [Conversation]).self) { group in
                            for next in (number + 1)...(number + (full ? 5 : 1)) {
                                group.addTask { (next, try await manager.fetchConversationsPage(page: next)) }
                            }
                            var results: [(Int, [Conversation])] = []
                            for try await result in group { results.append(result) }
                            return results.sorted { $0.0 < $1.0 }
                        }
                        for (next, fetched) in batch {
                            try checkCurrent()
                            number = next
                            page = fetched
                            revision = await self.invalidateChangedSummaries(page, known: known, scope: scope, revision: revision)
                            try checkCurrent()
                            unchangedPages = ConversationIndex.unchanged(page, comparedTo: known) ? unchangedPages + 1 : 0
                            fresh = self.mergeFreshPage(fresh, into: page)
                            self.conversations = self.mergeFreshPage(fresh, into: self.conversations)
                            expectedContent = self.contentRevision
                            if page.isEmpty { break }
                        }
                    }
                    if page.isEmpty {
                        let present = Set(fresh.map(\.id))
                        revision = await ConversationCache.shared.invalidate(scope: scope,
                            ids: known.keys.filter { !present.contains($0) }, since: revision)
                        try checkCurrent()
                        self.conversations = fresh
                        expectedContent = self.contentRevision
                        self.lastReconciledAt = .now
                    }
                    self.lastRefreshDate = .now
                    let snapshot = ConversationIndex(conversations: self.conversations.map(ConversationIndex.Summary.init),
                        pinned: self.pinnedConversations.map(ConversationIndex.Summary.init),
                        reconciledAt: self.lastReconciledAt ?? .distantPast)
                    await ConversationCache.shared.saveIndex(snapshot, scope: scope, revision: revision)
                } catch {
                    if generation == self.refreshGeneration, !Task.isCancelled, !(error is CancellationError) { self.errorMessage = self.errorDescription(for: error) }
                }
                if generation == self.refreshGeneration { self.isFetchingAllPages = false }
            }
        } catch {
            guard generation == refreshGeneration else { return }
            if APIError.from(error).requiresReauth { clearAll() }
            if !(error is CancellationError) { errorMessage = errorDescription(for: error) }
            isLoading = false
            isRefreshing = false
            isFetchingAllPages = false
        }
    }

    /// Drop account-specific state and prevent old asynchronous work from restoring it.
    func clearAll() {
        refreshGeneration = UUID()
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        conversations = []
        pinnedConversations = []
        lastRefreshDate = nil
        lastReconciledAt = nil
        isLoading = false
        isRefreshing = false
        isFetchingAllPages = false
        folderViewModel.folders = []
    }

    func refreshIfStale() async {
        guard !isLoading, !isRefreshing, !isFetchingAllPages else { return }
        if let lastRefreshDate, Date().timeIntervalSince(lastRefreshDate) < autoRefreshInterval { return }
        await refreshConversations()
    }

    private func invalidateChangedSummaries(_ page: [Conversation], known: [String: ConversationIndex.Summary],
                                            scope: String?, revision: UUID) async -> UUID {
        let changed = page.filter { known[$0.id] != nil && known[$0.id] != ConversationIndex.Summary($0) }.map(\.id)
        return await ConversationCache.shared.invalidate(scope: scope, ids: changed, since: revision)
    }

    // MARK: - Background Pagination

    /// Fetches all pages starting from `startingPage` in parallel batches.
    /// Merges each completed batch into `conversations` progressively.
    /// Stops when any page in a batch returns empty (no more data).
    private func fetchRemainingPagesInBackground(
        manager: ConversationManager,
        startingPage: Int
    ) async {
        var nextPage = startingPage
        var keepGoing = true

        while keepGoing {
            guard !Task.isCancelled else {
                logger.info("Background fetch cancelled at page \(nextPage)")
                break
            }

            // Build the batch of page numbers
            let batchPages = (nextPage..<(nextPage + 5)).map { $0 }

            // Fetch all pages in the batch concurrently
            var batchResults: [(page: Int, conversations: [Conversation])] = []

            await withTaskGroup(of: (Int, [Conversation]).self) { group in
                for page in batchPages {
                    group.addTask {
                        do {
                            let convs = try await manager.fetchConversationsPage(page: page)
                            return (page, convs)
                        } catch {
                            // On error, return empty so we stop at this page
                            return (page, [])
                        }
                    }
                }

                for await result in group {
                    batchResults.append((page: result.0, conversations: result.1))
                }
            }

            guard !Task.isCancelled else { break }

            // Sort results by page number so we merge in order
            batchResults.sort { $0.page < $1.page }

            // Accumulate all conversations from this batch
            var batchConversations: [Conversation] = []
            for result in batchResults {
                if result.conversations.isEmpty {
                    // This page was empty — no more data
                    keepGoing = false
                    break
                }
                batchConversations.append(contentsOf: result.conversations)
            }

            if !batchConversations.isEmpty {
                // Merge batch into main list (deduplicated)
                let newItems = batchConversations.filter { newConv in
                    !conversations.contains(where: { $0.id == newConv.id })
                }
                if !newItems.isEmpty {
                    conversations.append(contentsOf: newItems)
                    logger.info("Background fetch: appended \(newItems.count) conversations at page \(nextPage)")
                }
            }

            nextPage += 5
        }

        isFetchingAllPages = false
        logger.info("Background fetch complete. Total conversations: \(self.conversations.count)")
    }

    // MARK: - Private Helpers

    /// Merges a fresh page 1 into an existing full list.
    /// Fresh items are placed at the top; existing items not in the fresh page are kept.
    private func mergeFreshPage(_ fresh: [Conversation], into existing: [Conversation]) -> [Conversation] {
        var merged: [Conversation] = []
        var seen = Set<String>()

        // Fresh page first (newest items)
        for conv in fresh {
            merged.append(conv)
            seen.insert(conv.id)
        }
        // Existing items not in the fresh page (older paginated data)
        for conv in existing where !seen.contains(conv.id) {
            merged.append(conv)
        }
        return merged
    }

    // MARK: - Search

    /// Triggers a debounced search. Call from onChange.
    func triggerSearch() {
        searchTask?.cancel()
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
        pinnedConversations.removeAll { $0.id == id }

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
    ///
    /// Uses an optimistic update on `pinnedConversations` for instant UI feedback,
    /// then calls the server and re-fetches the authoritative pinned list to confirm.
    /// Reverts the optimistic update if the server call fails.
    func togglePin(conversation: Conversation) async {
        guard let manager else { return }

        let newPinned = !conversation.pinned

        // Optimistic update to pinnedConversations
        if newPinned {
            var pinned = conversation
            pinned.pinned = true
            pinnedConversations.insert(pinned, at: 0)
        } else {
            pinnedConversations.removeAll { $0.id == conversation.id }
        }

        do {
            try await manager.pinConversation(id: conversation.id, pinned: newPinned)
            // Re-fetch authoritative list from server
            pinnedConversations = (try? await manager.apiClient.getPinnedConversations()) ?? pinnedConversations

            // If we just unpinned a folder chat, reload that folder's chat list
            // so the chat reappears in the sidebar immediately.
            if !newPinned, let folderId = conversation.folderId, !folderId.isEmpty {
                await folderViewModel.refreshFolderChats(id: folderId)
            }
        } catch {
            logger.error("Failed to toggle pin: \(error.localizedDescription)")
            // Revert optimistic update
            if newPinned {
                pinnedConversations.removeAll { $0.id == conversation.id }
            } else {
                var restored = conversation
                restored.pinned = true
                pinnedConversations.insert(restored, at: 0)
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

        // If archiving, remove from pinned section immediately
        if newArchived {
            pinnedConversations.removeAll { $0.id == conversation.id }
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

    /// Shares a conversation, updates the local shareId, and returns it.
    func shareConversation(_ conversation: Conversation) async -> String? {
        guard let manager else { return nil }

        do {
            let shareId = try await manager.shareConversation(id: conversation.id)
            // Update shareId locally so the context menu immediately reflects shared state
            if let shareId, let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index].shareId = shareId
            }
            return shareId
        } catch {
            logger.error("Failed to share: \(error.localizedDescription)")
            return nil
        }
    }

    /// Updates the shareId for a conversation in the local list.
    /// Called by the ShareChatSheet when the share link is created, updated, or deleted.
    func updateShareId(for conversationId: String, shareId: String?) {
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].shareId = shareId
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
        pinnedConversations.removeAll { idsToDelete.contains($0.id) }
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
        pinnedConversations.removeAll()

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
        pinnedConversations.removeAll()
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
