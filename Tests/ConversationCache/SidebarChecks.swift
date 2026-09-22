import Foundation

@MainActor final class Network { var conversationCacheScope: String? = "synthetic-sidebar-scope" }
@MainActor final class Client {
    let network = Network()
    func getPinnedConversations() async throws -> [Conversation] { [] }
}
@MainActor final class ConversationManager {
    let apiClient = Client()
    var rows: [Conversation]
    var requests: [Int] = []
    var gate: Gate?
    var blockedPage = 0
    var failedPage = 0
    init(_ rows: [Conversation]) { self.rows = rows }
    func fetchConversationsPage(page: Int) async throws -> [Conversation] {
        requests.append(page)
        if page == blockedPage { await gate?.wait() }
        if page == failedPage { throw URLError(.notConnectedToInternet) }
        let start = min(rows.count, (page - 1) * 10)
        return Array(rows[start..<min(rows.count, start + 10)])
    }
}
@MainActor final class Folders { var folders: [String] = []; var pinnedChatIds = Set<String>() }

@MainActor final class ChatListViewModel {
    let testCache: ConversationCache
    var manager: ConversationManager?
    // CONVERSATIONS_PROPERTY
    // PINNED_PROPERTY
    var isLoading = false
    var isRefreshing = false
    var isFetchingAllPages = false
    var errorMessage: String?
    var lastRefreshDate: Date?
    var lastReconciledAt: Date?
    var refreshGeneration = UUID()
    var contentRevision = UUID()
    var backgroundFetchTask: Task<Void, Never>?
    let folderViewModel = Folders()
    let autoRefreshInterval: TimeInterval = 5
    init(_ manager: ConversationManager, cache: ConversationCache) {
        self.manager = manager
        testCache = cache
    }
    func errorDescription(for error: Error) -> String { error.localizedDescription }
    // PRODUCTION_METHODS
}

@main enum SidebarChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "relay-sidebar-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let cache = ConversationCache(directory: directory, defaults: defaults)
        let rows = (0..<100).map { Conversation(id: "chat-\($0)", title: "Synthetic \($0)") }
        let manager = ConversationManager(rows)
        let first = ChatListViewModel(manager, cache: cache)
        await first.loadConversations()
        try await drain(first)
        try check(first.conversations.count == 100 && manager.requests.count == 11, "cold load must fetch the entire list")
        try check(await cache.cachedIndex(scope: manager.apiClient.network.conversationCacheScope)?.conversations.count == 100, "complete sidebar must persist")

        let reopened = ChatListViewModel(manager, cache: cache)
        let gate = Gate()
        manager.requests = []
        manager.gate = gate
        manager.blockedPage = 1
        let load = Task { await reopened.loadConversations() }
        await gate.waitUntilStarted()
        try check(reopened.conversations.count == 100 && !reopened.isLoading, "saved sidebar must appear before a network response")
        await gate.release()
        await load.value
        try await drain(reopened)
        try check(manager.requests == [1, 2], "unchanged sidebar should stop after one overlap page")
        manager.blockedPage = 0

        let additions = (0..<25).map { Conversation(id: "new-\($0)", title: "New synthetic \($0)") }
        manager.rows = additions + rows
        manager.requests = []
        await reopened.refreshConversations()
        try await drain(reopened)
        try check(reopened.conversations.count == 125, "updates spanning several pages must not be skipped")
        try check(manager.requests == [1, 2, 3, 4, 5], "refresh should reach two unchanged pages after new rows")
        manager.rows[40].title = "Changed synthetic title"
        manager.requests = []
        // An older metadata change outside the overlap is picked up by full reconciliation.
        manager.rows.removeLast()
        await reopened.refreshConversations(forceFull: true)
        try await drain(reopened)
        try check(reopened.conversations.count == 124, "full reconciliation must remove absent chats")
        try check(reopened.conversations[40].title == "Changed synthetic title", "full reconciliation must find older changes")

        let changedID = manager.rows[0].id
        _ = try await cache.load(scope: manager.apiClient.network.conversationCacheScope, id: changedID) { _ in Server.response(id: changedID) }
        manager.rows[0].title = "Updated sidebar metadata"
        await reopened.refreshConversations()
        try await drain(reopened)
        try check(await cache.cached(scope: manager.apiClient.network.conversationCacheScope, id: changedID) == nil,
                  "changed summary metadata must invalidate the saved body")
        let savedIndex = await cache.cachedIndex(scope: manager.apiClient.network.conversationCacheScope)
        try check(savedIndex?.conversations.first?.title == "Updated sidebar metadata", "updated metadata must still persist after body invalidation")
        reopened.lastReconciledAt = Date().addingTimeInterval(-7 * 60 * 60)
        manager.requests = []
        await reopened.refreshConversations()
        try await drain(reopened)
        try check(manager.requests.count == 16, "an expired reconciliation checkpoint must trigger a full scan")

        let checkpoint = reopened.lastReconciledAt
        manager.failedPage = 2
        await reopened.refreshConversations(forceFull: true)
        try await drain(reopened)
        try check(reopened.lastReconciledAt == checkpoint, "failed page must not advance the full-scan checkpoint")
        try check(reopened.conversations.count == 124, "failed page must not truncate the saved list")
        manager.failedPage = 0

        // A page request already in flight must not undo an optimistic edit.
        let editGate = Gate()
        manager.gate = editGate
        manager.blockedPage = 2
        await reopened.refreshConversations(forceFull: true)
        await editGate.waitUntilStarted()
        let deletedID = reopened.conversations[0].id
        let renamedID = reopened.conversations[1].id
        reopened.conversations.removeAll { $0.id == deletedID }
        reopened.conversations[0].title = "Locally renamed synthetic chat"
        await editGate.release()
        try await drain(reopened)
        try check(!reopened.conversations.contains { $0.id == deletedID }, "late pagination must not restore a locally deleted chat")
        try check(reopened.conversations.first { $0.id == renamedID }?.title == "Locally renamed synthetic chat", "late pagination must not undo a rename")
        try check(reopened.errorMessage == nil, "abandoning obsolete pagination should not show an error")

        let switchGate = Gate()
        manager.gate = switchGate
        manager.blockedPage = 2
        await reopened.refreshConversations(forceFull: true)
        await switchGate.waitUntilStarted()
        reopened.clearAll()
        manager.apiClient.network.conversationCacheScope = "different-synthetic-session"
        await switchGate.release()
        for _ in 0..<100 { await Task.yield() }
        try check(reopened.conversations.isEmpty, "old-account pages must never reappear after switching")
        try check(await cache.cachedIndex(scope: "different-synthetic-session") == nil, "old-account pages must never be saved in the new scope")
        print("PASS: sidebar persistence, immediate restore, overlap checkpoint, multi-page updates, full reconciliation, failures and account-switch races")
    }
    @MainActor static func drain(_ model: ChatListViewModel) async throws {
        for _ in 0..<1000 {
            if !model.isFetchingAllPages { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Failure(message: "pagination did not finish")
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
