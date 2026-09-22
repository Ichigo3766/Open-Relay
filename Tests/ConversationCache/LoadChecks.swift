import Foundation

struct Logger { func error(_ message: String) {}; func info(_ message: String) {} }
@MainActor final class Client {
    var controlWrites = 0
    var historyWrites = 0
    func syncConversationHistory(id: String, history: History, model: String, systemPrompt: String?, chatParams: [String: String]?, title: String, chatFiles: [ChatMessageFile]) async throws { historyWrites += 1 }
    func updateChatControls(id: String, files: [ChatMessageFile]) async throws { controlWrites += 1 }
    var saved: (conversation: Conversation, isRecent: Bool, validatedAt: Date)?
    func cachedConversation(id: String) async -> (conversation: Conversation, isRecent: Bool, validatedAt: Date)? { saved }
}
@MainActor final class ConversationManager {
    let apiClient = Client()
    var count = 0
    func syncConversationMessages(id: String, messages: [Message], model: String, title: String?, chatParams: [String: String]?) async throws { apiClient.historyWrites += 1 }
    var gate: Gate?
    var failure: APIError?
    func fetchConversation(id: String) async throws -> Conversation {
        count += 1
        await gate?.wait()
        if let failure { throw failure }
        return Conversation(id: id, title: "Updated synthetic conversation")
    }
}
@MainActor final class ChatViewModel {
    var hasLoaded = false
    var isLoadingModels = false
    var modelGate: Gate?
    func loadModels() async { await modelGate?.wait(); isLoadingModels = false }
    func syncUIWithModelDefaults() {}
    // STARTUP_METHOD
    var conversationId: String? = "chat"
    var conversation: Conversation?
    var manager: ConversationManager?
    var isLoadingConversation = false
    var isRevalidatingConversation = false
    var isShowingCachedConversation = false
    var errorMessage: String?
    var lastSyncTime = Date.distantPast
    var deletedMessageIds: [String] = []
    var tasks: [String] = []
    var chatFiles: [ChatMessageFile] = []
    var removedContextIds = Set<String>()
    // REMOVE_FILE_METHOD
    // TREE_SYNC_METHOD
    var flatSyncs = 0
    func syncFlatMessagesToTreeNodes() { flatSyncs += 1 }
    func syncHistory() async { await syncToServerViaTree() }
    var selectedModelId: String?
    var availableModels: [Conversation] = []
    var userDisabledBuiltinFeatures: [String] = []
    let logger = Logger()
    var writes = 0
    var scans = 0
    func syncCurrentIdToServer() async { writes += 1 }
    func restoreToolApprovalMode() {}
    func scanForPendingToolActions() { scans += 1 }
    // PRODUCTION_METHODS
}
@main enum LoadChecks {
    @MainActor static func main() async throws {
        let manager = ConversationManager()
        var saved = Conversation(id: "chat", title: "Saved synthetic conversation")
        saved.history.isPopulated = true
        manager.apiClient.saved = (saved, false, Date().addingTimeInterval(-60))
        let model = ChatViewModel()
        model.manager = manager
        let gate = Gate()
        manager.gate = gate
        await model.loadConversation()
        await gate.waitUntilStarted()
        try check(model.conversation?.title == saved.title && model.isShowingCachedConversation, "stale content must appear immediately as read only")
        try check(model.writes == 0 && model.scans == 0, "preview must not synchronize history or run pending actions")
        let file = ChatMessageFile(url: "https://relay.example/synthetic-file")
        model.chatFiles = [file]
        model.removeFile(file)
        await model.syncHistory()
        try check(manager.apiClient.historyWrites == 0 && model.flatSyncs == 0, "stale preview must block every full-history write")
        for _ in 0..<100 { await Task.yield() }
        try check(manager.apiClient.controlWrites == 0 && model.chatFiles.count == 1, "preview must not overwrite server attachments through chat controls")
        await gate.release()
        try await drain(model)
        try check(model.conversation?.title == "Updated synthetic conversation" && !model.isShowingCachedConversation, "successful validation must replace and unlock the preview")

        await model.syncHistory()
        try check(manager.apiClient.historyWrites == 1, "verified conversation must still allow history writes")
        manager.gate = nil
        manager.failure = .networkError(underlying: URLError(.notConnectedToInternet))
        await model.loadConversation()
        for _ in 0..<100 { await Task.yield() }
        try await drain(model)
        try check(model.conversation?.title == saved.title && model.isShowingCachedConversation, "offline preview must remain read only")
        manager.failure = .httpError(statusCode: 404, message: nil, data: nil)
        await model.loadConversation(useCache: false)
        try check(model.conversation == nil, "deleted or denied conversation must lose its preview")

        manager.failure = nil
        manager.apiClient.saved = (saved, true, .now)
        let count = manager.count
        await model.loadConversation()
        for _ in 0..<100 { await Task.yield() }
        try check(manager.count == count && !model.isShowingCachedConversation, "recent validated response must not trigger another download")
        let startup = ChatViewModel()
        startup.manager = manager
        let modelGate = Gate()
        startup.modelGate = modelGate
        await startup.load()
        await modelGate.waitUntilStarted()
        try check(startup.conversation?.title == saved.title && startup.isLoadingModels,
                  "saved messages must be shown while model catalog loading is still pending")
        await modelGate.release()
        print("PASS: actual chat loading shows stale previews, blocks side effects, revalidates, preserves offline reads and removes deleted content")
    }
    @MainActor static func drain(_ model: ChatViewModel) async throws {
        for _ in 0..<1000 {
            if !model.isRevalidatingConversation { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Failure(message: "chat validation did not finish")
    }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
}
