import Foundation
import os.log

// No real account, server, Open WebUI module, or app runtime is used.
enum InlineImageStore { static func extractAndReplace(content: String) -> String { content } }
extension Notification.Name { static let conversationListNeedsRefresh = Notification.Name("synthetic-refresh") }
struct ChatAttachment {
    enum Kind { case audio, file, image }
    enum Status { case pending, uploaded, error }
    var type: Kind; var name: String; var thumbnail: Data?; var data: Data?
    var uploadStatus: Status = .uploaded
    var uploadedFileId: String?; var uploadedFileObject: [String: Any]?
    var transcribedText: String?; var useFullContext = false; var uploadContext: String?
    var isUploading: Bool { false }
}
struct Reference { var context: String?; func toChatFileRef() -> [String: Any] { [:] } }
struct Note { var id: String; var title: String; var content: String }
struct QueuedMessage { var id: UUID; var text: String }
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
}
struct Defaults { var defaultUploadContext = "focused" }
struct ChatCompletionRequest {
    var model: String; var messages: [[String: Any]]; var stream: Bool
    var chatId: String?; var sessionId: String; var messageId: String; var parentId: String
    var files: [[String: Any]] = []; var userMessage: [String: Any]?; var skillIds: [String] = []
}
@MainActor final class NotificationService {
    static let shared = NotificationService(); var activeConversationId: String?
}
@MainActor final class ActiveChatStore {
    var cachedUserDefaultParams: Defaults?
    func retain(_ vm: ChatViewModel, for id: String) {}
}
@MainActor final class NoteSession {
    func checkSession() throws {}
    func create() async throws -> Conversation { fatalError("Notes are outside this typed-send fixture") }
}
@MainActor final class Socket {
    var isConnected = true; var isUserJoined = true; var sid: String? = "synthetic-socket"
    func ensureConnected(timeout: TimeInterval) async -> Bool { isConnected && isUserJoined }
}
@MainActor final class StreamingStore {
    var streamingMessageId: String?; var isActive = false
    func beginStreaming(messageId: String, modelId: String) { streamingMessageId = messageId; isActive = true }
    struct Result {
        var content = ""; var sources: [ChatSourceReference] = []; var statusHistory: [ChatStatusUpdate] = []
    }
    @discardableResult func abortStreaming() -> Result { isActive = false; return Result() }
}
@MainActor final class ToolPrompts { func cancelAll() {} }
@MainActor final class Subscription { func dispose() {} }
@MainActor final class Network { var conversationCacheScope: String? = "synthetic-session" }
struct AIModel { var id: String }
enum APIError: Error {
    case connectivity
    var isConnectivityError: Bool { true }
    static func from(_ error: Error) -> APIError { .connectivity }
}
struct CachedConversation { var conversation: Conversation }
@MainActor final class APIClient {
    let network = Network()
    var server: Conversation
    var historyError: URLError.Code?
    var completionError: URLError.Code?
    var createError: URLError.Code?
    var syncAttempts = 0; var completionAttempts = 0
    var afterSyncAttempt: (() async -> Void)?
    init(server: Conversation) { self.server = server }
    func cachedConversation(id: String) async -> CachedConversation? { nil }
    func syncConversationHistory(id: String, history: MessageHistory, model: String?, systemPrompt: String?, chatParams: ChatAdvancedParams?, title: String?, chatFiles: [ChatMessageFile]) async throws {
        syncAttempts += 1
        await afterSyncAttempt?()
        if let historyError { throw URLError(historyError) }
        server.history = history; server.rederiveMessages(); server.files = chatFiles
    }
}
@MainActor final class Manager {
    let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }
    func fetchConversation(id: String) async throws -> Conversation { apiClient.server }
    func createConversation(title: String, model: String?, folderId: String?, variables: [String: Any]) async throws -> Conversation {
        if let createError = apiClient.createError { throw URLError(createError) }
        var chat = Conversation(id: "synthetic-new-chat", title: title, model: model)
        chat.chatVariables = variables; apiClient.server = chat; return chat
    }
    func syncConversationMessages(id: String, messages: [ChatMessage], model: String?, title: String?, chatParams: ChatAdvancedParams?, chatFiles: [ChatMessageFile]) async throws {
        fatalError("Fixture always uses the actual history tree")
    }
    func uploadFile(data: Data, fileName: String) async throws -> (String, [String: Any]) { ("synthetic-file", [:]) }
    func sendMessageHTTP(request: ChatCompletionRequest) async throws -> [String: Any] {
        apiClient.completionAttempts += 1
        if let completionError = apiClient.completionError { throw URLError(completionError) }
        return ["task_id": "synthetic-task"]
    }
    func sendChatCompleted(chatId: String, messageId: String, model: String, sessionId: String, messages: [[String: Any]]) async {}
}

// Full sendMessage, tree-sync, reconciliation and reload bodies are appended verbatim.
// UI, socket readiness, upload and model configuration boundaries are inert stubs.
@MainActor final class ChatViewModel {
    let logger = Logger(subsystem: "synthetic-client", category: "Reproduction")
    var manager: Manager?; var conversation: Conversation?; var conversationId: String?
    var inputText = ""; var attachments: [ChatAttachment] = []; var errorMessage: String?
    var isCompactingContext = false; var contextNeedsRefresh = false; var isSavingChatVariables = false
    var isCreatingConversation = false; var isCreatingNoteChat = false; var isVoiceMode = false
    var isStreaming = false; var isExternallyStreaming = false; var isSavingContext = false
    var enableMessageQueue = false; var messageQueue: [QueuedMessage] = []; var pendingTextAfterUpload: String?
    var mentionedModelId: String?; var selectedModelId: String? = "synthetic-model"
    var toolConnectionRequested: String?; var noteChatSession: NoteSession?; var isTemporaryChat = false
    var chatVariablesDraftGeneration = 0; var pendingChatVariables: [String: Any] = [:]
    var folderContextId: String?; var pendingChatParams: ChatAdvancedParams?
    var selectedKnowledgeItems: [Reference] = []; var selectedReferenceChats: [Reference] = []
    var selectedNotes: [Note] = []; var selectedSkillIds: [String] = []
    var activeChatStore: ActiveChatStore?; var chatFiles: [ChatMessageFile] = []
    var userDefaultParamsTask: Task<Void, Never>?; var contextSaveTask: Task<Void, Never>?
    var completionTask: Task<Void, Never>?; var streamingTask: Task<Void, Never>?
    var sessionId = ""; var hasFinishedStreaming = false; var selfInitiatedStream = false
    var streamingSessionId = 0; var lastCompletedSelfInitiatedMessageId: String?
    var wasBackgroundedDuringThisStream = false; let streamingStore = StreamingStore()
    var socketService: Socket? = Socket(); var activeTaskId: String?
    var deletedMessageIds: Set<String> = []; var tasks: [ChatTask] = []
    var lastSyncTime = Date.distantPast; let syncDebounceInterval = 3.0
    var lastSendBlockReason: SendBlockReason?
    var availableModels: [AIModel] = []; var isLoadingConversation = false
    var userDisabledBuiltinFeatures: Set<String> = []
    let toolEventPrompts = ToolPrompts()
    var chatSubscription: Subscription?; var channelSubscription: Subscription?; var recoveryTimer: Timer?
    var emptyPollCount = 0; var lastRecoveryPollContentLength = 0; var recoveryTaskCheckFailures = 0
    var recoveryTimerStartDate = Date.distantPast
    init(manager: Manager, conversation: Conversation?) { self.manager = manager; self.conversation = conversation; conversationId = conversation?.id }
    func authorizeWebSearch() async -> Bool { true }
    func checkToolConnections(ignoreDraftAndBranch: Bool = false) async -> Bool { true }
    func needsChatVariables(modelID: String) -> Bool { false }
    func stopStreaming(stopAllChatTasks: Bool) { cleanupStreaming() }
    func mimeType(for name: String) -> String { "text/plain" }
    func buildAPIMessagesAsync() async -> [[String: Any]] { [] }
    func buildSimpleAPIMessages() -> [[String: Any]] { [] }
    func startSwitchStatusPolling() {}
    func appendStatusUpdate(id: String, status: ChatStatusUpdate) {}
    func registerSocketHandlers(socket: Socket, assistantMessageId: String, modelId: String, socketSessionId: String, effectiveChatId: String?) {}
    func contextFileRefs(currentFiles: [ChatMessageFile]) async -> [[String: Any]] { [] }
    func populateCommonRequestFields(_ request: inout ChatCompletionRequest) async {}
    func startRecoveryTimer(assistantMessageId: String, chatId: String?) {}
    func refreshConversationMetadata(chatId: String, assistantMessageId: String) async throws {}
    func sendCompletionNotificationIfNeeded(content: String) async {}
    func applyContextMetadata(_ conversation: Conversation) {}
    func backfillLegacyChatContextIfNeeded() {}
    func restoreToolApprovalMode() {}
    func scanForPendingToolActions() {}
    func syncCurrentIdToServer() async {}
    func updateAssistantMessage(id: String, content: String, isStreaming: Bool, error: ChatMessageError? = nil) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }
        conversation?.messages[index].content = content
        conversation?.messages[index].isStreaming = isStreaming
        conversation?.messages[index].error = error
        conversation?.history.updateNode(id: id) { $0.error = error; $0.done = !isStreaming }
    }
    func cancelLiveAskUser() {}
    func stopSwitchStatusPolling() {}
    func startPassiveSocketListener() {}
