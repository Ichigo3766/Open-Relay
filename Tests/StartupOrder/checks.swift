import Foundation

struct Conversation: Sendable { let id: String }
struct Summary: Sendable { let conversation: Conversation }
struct Index: Sendable {
    var conversations: [Summary]
    var pinned: [Summary] = []
    var reconciledAt = Date()
}
@MainActor final class Transport {
    var requests: [String] = []
    var completed = Set<String>()
    var sidebarDelay: UInt64 = 150_000_000
    var pageDelay: UInt64 = 30_000_000
    var fail = false
    func fetch(_ path: String, delay: UInt64) async {
        requests.append(path)
        try? await Task.sleep(nanoseconds: delay)
        completed.insert(path)
    }
}
@MainActor final class Network { var conversationCacheScope: String? = "account-a" }
@MainActor final class APIClient {
    let network = Network()
    func getCurrentUser() async throws -> User { User(id: "synthetic-user") }
}
struct User { let id: String }
@MainActor final class ConversationManager {
    let apiClient = APIClient()
    let transport: Transport
    init(_ transport: Transport) { self.transport = transport }
}
@MainActor final class ConversationCache {
    static let shared = ConversationCache()
    var saved: Index?
    var delay: UInt64 = 0
    func cachedIndex(scope: String?) async -> Index? {
        let result = scope == "account-a" ? saved : nil
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return result
    }
}
@MainActor final class Folders {
    let transport: Transport
    init(_ transport: Transport) { self.transport = transport }
    func configure(with: Folders) {}
    func loadFolders() async { await transport.fetch("folders", delay: transport.sidebarDelay) }
}
@MainActor final class Channels {
    let transport: Transport
    init(_ transport: Transport) { self.transport = transport }
    func configure(apiClient: APIClient, socket: Int?, currentUserId: String?) {}
    func loadChannels() async { await transport.fetch("channels", delay: transport.sidebarDelay) }
}
@MainActor final class ChatListViewModel {
    var manager: ConversationManager?
    var isLoading = false
    var isRefreshing = false
    var isFetchingAllPages = false
    var conversations: [Conversation] = []
    var pinnedConversations: [Conversation] = []
    var lastReconciledAt: Date?
    var refreshGeneration = UUID()
    var contentRevision = UUID()
    let folderViewModel: Folders
    init(_ transport: Transport) { folderViewModel = Folders(transport) }
    func configure(with manager: ConversationManager) { self.manager = manager }
    func refreshConversations() async {
        guard let manager else { return }
        let scope = manager.apiClient.network.conversationCacheScope
        let generation = refreshGeneration
        async let page: Void = manager.transport.fetch("page-one", delay: manager.transport.pageDelay)
        async let pins: Void = manager.transport.fetch("pinned", delay: manager.transport.pageDelay)
        _ = await (page, pins)
        guard generation == refreshGeneration, scope == self.manager?.apiClient.network.conversationCacheScope else { return }
        isLoading = false
        if !manager.transport.fail { conversations = [Conversation(id: "synthetic-chat")] }
    }
    // PRODUCTION_LOAD
}
@MainActor final class Auth { var currentUser: User? = User(id: "synthetic-user") }
@MainActor final class Dependencies {
    let conversationManager: ConversationManager?
    let folderManager: Folders?
    let apiClient: APIClient?
    let authViewModel = Auth()
    let socketService: Int? = nil
    var pendingChannelId: String?
    let transport: Transport
    init(_ transport: Transport) {
        self.transport = transport
        let manager = ConversationManager(transport)
        conversationManager = manager
        apiClient = manager.apiClient
        folderManager = Folders(transport)
    }
    func fetchTaskConfig() async { await transport.fetch("task-config", delay: transport.sidebarDelay) }
    func requestOpenChannel(_ id: String) {}
    func consumePendingChannel() -> String? { nil }
}
@MainActor final class SharedDataService {
    static let shared = SharedDataService()
    var lastActiveConversationId: String? = "synthetic-chat"
}
@MainActor final class NotificationService {
    static let shared = NotificationService()
    var onOpenChannel: ((String) -> Void)?
}
@MainActor final class Harness {
    let dependencies: Dependencies
    let listViewModel: ChatListViewModel
    let channelListVM: Channels
    let start = ContinuousClock.now
    var firstRestore: Duration?
    var sidebarPendingAtRestore = false
    var newChatGeneration = 0
    var activeChannelId: String?
    var activeFolderWorkspaceId: String?
    var activeConversationId: String? {
        didSet {
            if activeConversationId == "synthetic-chat", firstRestore == nil {
                firstRestore = start.duration(to: .now)
                sidebarPendingAtRestore = !dependencies.transport.completed.contains("folders")
            }
        }
    }
    init(_ transport: Transport) {
        dependencies = Dependencies(transport)
        listViewModel = ChatListViewModel(transport)
        channelListVM = Channels(transport)
    }
    func registerSocketReconnectHandler() {}
    func onSocketSetup() {}
    func openChannelFromLink(_ id: String) {}
    // PRODUCTION_VIEWS
}

@main struct Checks {
    @MainActor static func main() async {
        var failures = 0
        var count = 0
        func check(_ value: Bool, _ name: String) {
            count += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(name)")
        }
        for pad in [false, true] {
            let platform = pad ? "pad" : "phone"
            for scenario in ["cached", "uncached", "empty-cache", "offline", "uncached-failed", "missing", "no-last-chat", "selected", "selected-during-refresh", "new-chat", "channel", "folder", "pending-channel", "already-loading", "cancelled", "account-switch", "mutated-index"] {
                let transport = Transport()
                transport.fail = ["offline", "uncached-failed"].contains(scenario)
                let cache = ConversationCache.shared
                cache.saved = ["uncached", "uncached-failed", "selected-during-refresh"].contains(scenario) ? nil : Index(conversations: scenario == "empty-cache" ? [] : [Summary(conversation: Conversation(id: "synthetic-chat"))])
                cache.delay = ["cancelled", "account-switch", "mutated-index"].contains(scenario) ? 40_000_000 : 0
                SharedDataService.shared.lastActiveConversationId = scenario == "missing" ? "deleted-chat" : "synthetic-chat"
                if scenario == "no-last-chat" { SharedDataService.shared.lastActiveConversationId = nil }
                let harness = Harness(transport)
                if scenario == "pending-channel" { harness.dependencies.pendingChannelId = "synthetic-channel" }
                if scenario == "already-loading" {
                    harness.listViewModel.isRefreshing = true
                    harness.listViewModel.conversations = [Conversation(id: "synthetic-chat")]
                }
                if scenario == "selected" { harness.activeConversationId = "manually-selected" }
                let task = Task { if pad { await harness.runPad() } else { await harness.runPhone() } }
                if ["cancelled", "account-switch", "mutated-index", "selected-during-refresh", "new-chat", "channel", "folder"].contains(scenario) {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    if ["new-chat", "channel", "folder"].contains(scenario) {
                        harness.activeConversationId = nil
                        if scenario == "new-chat" { harness.newChatGeneration += 1 }
                        if scenario == "channel" { harness.activeChannelId = "synthetic-channel" }
                        if scenario == "folder" { harness.activeFolderWorkspaceId = "synthetic-folder" }
                    }
                    if scenario == "selected-during-refresh" { harness.activeConversationId = "manually-selected" }
                    if scenario == "cancelled" { task.cancel() }
                    if scenario == "account-switch" {
                        let replacement = ConversationManager(transport)
                        replacement.apiClient.network.conversationCacheScope = "account-b"
                        harness.listViewModel.configure(with: replacement)
                    }
                    if scenario == "mutated-index" {
                        harness.listViewModel.contentRevision = UUID()
                        harness.listViewModel.conversations = [Conversation(id: "newer-index-chat")]
                    }
                }
                await task.value
                if scenario == "account-switch" {
                    check(!harness.listViewModel.isLoading, "\(platform): account replacement releases the old loading state")
                }
                switch scenario {
                case "cached", "offline":
                    let ms = harness.firstRestore.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 } ?? .infinity
                    print("MEASURE \(platform) \(scenario) restore_ms=\(ms)")
                    check(harness.firstRestore != nil && harness.sidebarPendingAtRestore, "\(platform): saved chat opens before delayed sidebar (\(scenario))")
                case "uncached", "empty-cache":
                    check(harness.firstRestore != nil && harness.sidebarPendingAtRestore, "\(platform): first server page restores chat before folders")
                case "selected", "selected-during-refresh": check(harness.activeConversationId == "manually-selected", "\(platform): preserves existing navigation (\(scenario))")
                case "already-loading": check(harness.activeConversationId == "synthetic-chat", "\(platform): fallback preserves restore when another list load is active")
                case "new-chat", "channel", "folder": check(harness.activeConversationId == nil, "\(platform): later refresh preserves explicit navigation (\(scenario))")
                case "pending-channel": check(harness.firstRestore == nil, "\(platform): pending channel route is not preempted")
                default: check(harness.activeConversationId == nil, "\(platform): no stale restore (\(scenario))")
                }
                if !["cancelled", "account-switch", "mutated-index"].contains(scenario) {
                    var expected = Set(pad ? ["page-one", "pinned", "folders", "task-config"] : ["page-one", "pinned", "folders", "task-config", "channels"])
                    if scenario == "already-loading" { expected.subtract(["page-one", "pinned"]) }
                    check(Set(transport.requests) == expected && transport.requests.count == expected.count, "\(platform): all existing requests complete exactly once (\(scenario))")
                }
            }
        }
        print("\(count) checks; \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
