import Foundation
import os.log
import SwiftUI

extension Notification.Name {
    static let conversationTitleUpdated = Notification.Name("conversationTitleUpdated")
    static let navigateToChannel = Notification.Name("navigateToChannel")
    static let conversationListNeedsRefresh = Notification.Name("conversationListNeedsRefresh")
    /// Posted by MemoriesView when the user toggles the Enable Memory switch.
    /// `object` is the new Bool value so ChatViewModel updates immediately.
    static let memorySettingChanged = Notification.Name("memorySettingChanged")
    /// Posted by ChatSettingsView when the user toggles the Enable Message Queue switch.
    /// `object` is the new Bool value so ChatViewModel updates immediately.
    static let messageQueueSettingChanged = Notification.Name("messageQueueSettingChanged")
    /// Posted by AdminConsoleView when a user's chat is cloned.
    static let adminClonedChat = Notification.Name("adminClonedChat")
    /// Posted by the audio attachment thumbnail's retry button.
    /// `object` is the `UUID` of the attachment to retry uploading.
    static let retryAttachmentUpload = Notification.Name("retryAttachmentUpload")
    /// Posted when function config changes (toggle active/global in Admin, or model editor save).
    /// ChatViewModel observes this to re-resolve actions/filters for the current model immediately.
    static let functionsConfigChanged = Notification.Name("functionsConfigChanged")
}

/// A message waiting in the queue to be sent after the current stream completes.
struct QueuedMessage: Identifiable {
    let id: UUID
    let text: String
}

/// Manages state and logic for a single chat conversation.
/// Handles sending/streaming messages via Socket.IO, loading history, and model selection.
/// Instances are held by `ActiveChatStore` so they survive navigation transitions.
@MainActor @Observable
final class ChatViewModel {
    // MARK: - Published State

    /// Isolated store for streaming content. Only the actively streaming
    /// message view observes this — all other message views read from
    /// `conversation.messages` which stays frozen during streaming.
    /// This breaks the observation chain that was causing ALL messages
    /// to re-evaluate on every token.
    let streamingStore = StreamingContentStore()

    var conversation: Conversation?
    var availableModels: [AIModel] = []

    // MARK: - Folder Context

    /// When set, new chats will be created inside this folder and use this system prompt.
    var folderContextId: String?
    var folderContextSystemPrompt: String?
    var folderContextModelIds: [String] = []

    /// Sets or clears the folder workspace context.
    /// Called when the user taps a folder name in the drawer.
    func setFolderContext(folderId: String?, systemPrompt: String?, modelIds: [String] = []) {
        folderContextId = folderId
        folderContextSystemPrompt = systemPrompt
        folderContextModelIds = modelIds
        // If the folder has default model IDs and we have no model selected, pick the first
        if let firstModel = modelIds.first, !firstModel.isEmpty {
            let available = availableModels.map(\.id)
            if available.contains(firstModel) {
                selectModel(firstModel)
            }
        }
    }
    var selectedModelId: String?
    var isStreaming: Bool = false {
        didSet {
            // Signal any awaiter (e.g. VoiceCallViewModel) that streaming has started.
            // Fires exactly once when isStreaming transitions false → true.
            if isStreaming && !oldValue {
                streamingStartedContinuation?.resume()
                streamingStartedContinuation = nil
            }
        }
    }
    /// True while a fork (clone) request is in-flight. Drives the spinner in the action bar.
    var isForkingChat = false
    /// Continuation fulfilled the first time `isStreaming` becomes `true` after
    /// `waitForStreamingToStart()` is called. Cleared immediately after signalling
    /// to avoid retaining a stale continuation across calls.
    private var streamingStartedContinuation: CheckedContinuation<Void, Never>?

    /// Suspends until `isStreaming` becomes `true` (i.e. the server has accepted the
    /// request and the first token is flowing). Returns immediately if already streaming.
    ///
    /// This is used by `VoiceCallViewModel` to avoid the race where the
    /// content-polling loop in `waitForResponseAndSpeak()` would see `isStreaming == false`
    /// (because the server hasn't responded yet) and skip TTS entirely for the first message.
    func waitForStreamingToStart() async {
        guard !isStreaming else { return }
        await withCheckedContinuation { continuation in
            streamingStartedContinuation = continuation
        }
    }

    /// When `true`, every `sendMessage()` call includes `features.voice = true`
    /// in the request body so the server injects the admin-configured voice mode
    /// system prompt (OpenWebUI `VOICE_MODE_PROMPT_TEMPLATE`).
    /// Set by `VoiceCallViewModel.configure()` and reset in `endCall()`.
    var isVoiceMode: Bool = false
    var isLoadingConversation: Bool = false
    var isLoadingModels: Bool = false
    /// Tasks managed by the model's built-in task tools (create_tasks / update_task).
    /// Populated from the server on load and updated in real-time during streaming.
    var tasks: [ChatTask] = []
    var errorMessage: String?
    /// Bumped each time a regenerate begins. Observed by ChatDetailView to trigger scroll-to-bottom.
    var regenerateScrollToken: UUID = UUID()
    var inputText: String = ""
    /// Toggled to `true` by the Ask text-selection action to request keyboard focus.
    /// `ChatDetailView` observes this via `.onChange` and sets `isEditFieldFocused`.
    /// Reset to `false` immediately after focus is granted.
    var shouldFocusInput: Bool = false
    var attachments: [ChatAttachment] = []
    var webSearchEnabled: Bool = false {
        didSet {
            guard !suppressBuiltinFeatureTracking else { return }
            if webSearchEnabled {
                userDisabledBuiltinFeatures.remove("web_search")
            } else {
                userDisabledBuiltinFeatures.insert("web_search")
            }
        }
    }
    var imageGenerationEnabled: Bool = false {
        didSet {
            guard !suppressBuiltinFeatureTracking else { return }
            if imageGenerationEnabled {
                userDisabledBuiltinFeatures.remove("image_generation")
            } else {
                userDisabledBuiltinFeatures.insert("image_generation")
            }
        }
    }
    var codeInterpreterEnabled: Bool = false {
        didSet {
            guard !suppressBuiltinFeatureTracking else { return }
            if codeInterpreterEnabled {
                userDisabledBuiltinFeatures.remove("code_interpreter")
            } else {
                userDisabledBuiltinFeatures.insert("code_interpreter")
            }
        }
    }
    /// Whether memory is enabled for this chat session.
    /// Persisted to server user settings (`ui.memory`) so the web UI stays in sync.
    var memoryEnabled: Bool = false

    /// Whether the message queue feature is enabled.
    /// Persisted to server user settings (`ui.enableMessageQueue`).
    var enableMessageQueue: Bool = false

    /// Whether message rating (thumbs up/down) is enabled on this server.
    /// Populated from BackendFeatures.enableMessageRating via ActiveChatStore.
    var messageRatingEnabled: Bool = false

    /// Messages queued to send after the current stream completes.
    var messageQueue: [QueuedMessage] = []
    /// Pinned model IDs synced with server `ui.pinnedModels`.
    var pinnedModelIds: [String] = []
    var isTemporaryChat: Bool = false
    /// Chat params set before the conversation is created (new-chat flow).
    /// Applied to `conversation.chatParams` as soon as the conversation is created.
    var pendingChatParams: ChatAdvancedParams?
    var availableTools: [ToolItem] = []
    /// All functions (filter/action/pipe) with user valves, used by the Valves section
    /// in the Controls panel. Populated lazily in loadTools() alongside availableTools.
    var availableFunctions: [FunctionItem] = []
    var selectedToolIds: Set<String> = [] {
        didSet {
            // Track tools the user explicitly disabled (were in old set but not new)
            let removed = oldValue.subtracting(selectedToolIds)
            let added = selectedToolIds.subtracting(oldValue)
            userDisabledToolIds.formUnion(removed)
            userDisabledToolIds.subtract(added)
        }
    }
    /// Tools the user has explicitly toggled OFF during this chat session.
    /// Prevents `syncToolSelectionWithDefaults()` from re-enabling them.
    private var userDisabledToolIds: Set<String> = []
    /// Built-in features (web_search, image_generation, code_interpreter) the user
    /// has explicitly toggled OFF during this session. Prevents
    /// `applyIncrementalModelDefaults()` from re-enabling them before each send.
    private var userDisabledBuiltinFeatures: Set<String> = []
    /// When `true`, mutations to `webSearchEnabled`, `imageGenerationEnabled`, and
    /// `codeInterpreterEnabled` do NOT update `userDisabledBuiltinFeatures`.
    /// Set during `syncUIWithModelDefaults()` and `restoreBuiltinFeatureState()`
    /// so those internal resets aren't misinterpreted as explicit user overrides.
    private var suppressBuiltinFeatureTracking: Bool = false
    var selectedKnowledgeItems: [KnowledgeItem] = []
    var knowledgeItems: [KnowledgeItem] = []
    /// Reference chat conversations selected for context in the next message.
    var selectedReferenceChats: [ReferenceChatItem] = []
    /// Notes selected as context for the next message (injected as inline text, not file refs).
    var selectedNotes: [Note] = []
    /// IDs of context items that the user has explicitly removed via the Controls panel.
    /// `collectHistoryFileRefs` skips any stored file whose ID is in this set so the item
    /// is not re-injected into future RAG requests even though it still lives in history.
    var removedContextIds: Set<String> = []
    /// Top-level files attached to this conversation (mirrors OWUI `chat.files`).
    /// Loaded from `conversation.files` on open; persisted back via `syncConversationHistory`.
    var chatFiles: [ChatMessageFile] = []
    var isLoadingTools: Bool = false
    /// True once loadTools() has completed at least one fetch.
    /// Distinguishes "never fetched yet" (false) from "fetched and tool is gone" (true).
    var toolsHaveLoaded: Bool = false
    /// Available terminal servers fetched from the backend.
    var availableTerminalServers: [TerminalServer] = []
    /// Whether the user has enabled terminal for this chat session.
    var terminalEnabled: Bool = false
    /// The currently selected terminal server (auto-selects first if only one).
    var selectedTerminalServer: TerminalServer?
    /// True if the currently selected model has the terminal capability enabled.
    var isTerminalCapableForSelectedModel: Bool {
        selectedModel?.supportsTerminal ?? false
    }
    var isLoadingKnowledge: Bool = false
    var isShowingKnowledgePicker: Bool = false
    var knowledgeSearchQuery: String = ""

    // Prompt slash command state
    /// Cached prompts from the server. Fetched lazily on first `/` trigger.
    var availablePrompts: [PromptItem] = []
    /// Whether the prompt picker overlay is visible.
    var isShowingPromptPicker: Bool = false
    /// The current filter query (text typed after `/`).
    var promptSearchQuery: String = ""
    /// Whether prompts are currently being loaded from the server.
    var isLoadingPrompts: Bool = false
    // Skill $ trigger state
    /// Cached skills from the server. Fetched lazily on first `$` trigger.
    var availableSkills: [SkillItem] = []
    /// Whether the skill picker overlay is visible.
    var isShowingSkillPicker: Bool = false
    /// The current filter query (text typed after `$`).
    var skillSearchQuery: String = ""
    /// Whether skills are currently being loaded from the server.
    var isLoadingSkills: Bool = false
    /// Skills selected via the `$` picker for the current message.
    /// Sent as `skill_ids` in the API request and cleared after each send.
    var selectedSkillIds: [String] = []

    /// The prompt selected by the user that has variables requiring input.
    /// When set, the variable input sheet is presented.
    var pendingPromptForVariables: PromptItem?
    /// The parsed variables for the pending prompt.
    var pendingPromptVariables: [PromptVariable] = []
    /// The model ID selected via `@` mention in the chat input.
    /// Persists across messages until the user explicitly clears it.
    var mentionedModelId: String?
    /// Suggested emoji for the last assistant message (generated by server).
    private(set) var hasLoaded: Bool = false

    /// Whether an external client (website, another app tab) is currently
    /// streaming a response to this chat. When `true`, the app is passively
    /// observing socket events it did not initiate.
    private(set) var isExternallyStreaming: Bool = false

    /// Set to `true` after the initial load completes so that new messages
    /// arriving during a session get an appear animation, while the full
    /// history loaded on first launch does not.
    private(set) var shouldAnimateNewMessages: Bool = false

    // MARK: - Private State

    let conversationId: String?
    private var manager: ConversationManager?
    private var socketService: SocketIOService?
    /// Weak reference to the shared ASR service, set via configure().
    private weak var asrService: OnDeviceASRService?
    private weak var notesManager: NotesManager?
    private var streamingTask: Task<Void, Never>?
    /// Active transcription tasks keyed by attachment ID.
    /// Stored here so they survive navigation — the VM lives in ActiveChatStore
    /// and is never destroyed when the user switches chats.
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    /// The post-streaming completion task (chatCompleted + file polling + metadata refresh).
    /// Cancelled when a new message is sent so it doesn't overwrite newer messages.
    private var completionTask: Task<Void, Never>?
    /// In-flight model config fetch from selectModel(). Stored so
    /// sendMessage/regenerateResponse can await it before reading
    /// functionCallingMode — prevents the race where the user selects
    /// a model and immediately sends before the config fetch completes.
    private var modelConfigTask: Task<Void, Never>?
    /// Tracks the most recent user-default-params fetch so `populateCommonRequestFields`
    /// can await it before building a request — prevents the race where params are read
    /// before the async fetch completes (which caused the system prompt to be ignored).
    private var userDefaultParamsTask: Task<Void, Never>?
    private var chatSubscription: SocketSubscription?
    private var channelSubscription: SocketSubscription?
    /// Persistent passive socket listener that observes events for this chat
    /// regardless of who initiated the generation. Mirrors the website's
    /// `Chat.svelte` `socket.on("events", chatEventHandler)` pattern.
    private var passiveSubscription: SocketSubscription?
    /// True when this VM initiated the current streaming session (sendMessage/regenerate).
    /// The passive listener skips processing when this is true to avoid conflicts.
    private var selfInitiatedStream: Bool = false
    /// The message ID of the most recently completed self-initiated stream.
    /// Used by handlePassiveEvent to block replayed socket events (from the server
    /// re-delivering events to a freshly re-subscribed passive listener) for a message
    /// this VM just finished streaming. Cleared when a new self-initiated stream begins.
    private var lastCompletedSelfInitiatedMessageId: String?
    /// Guards against flooding syncForExternalStream with duplicate fetch tasks
    /// when many socket tokens arrive before the first fetch completes.
    private var isSyncingExternalStream: Bool = false
    /// Tracks the accumulated content for the currently externally-streaming message.
    /// Delta events are incremental, so we accumulate them here and feed the full
    /// cumulative string into streamingStore.updateContent() on each token — matching
    /// exactly what the self-initiated ContentAccumulator does.
    private var externalStreamAccumulatedContent: String = ""
    private(set) var sessionId: String = UUID().uuidString
    private let logger = Logger(subsystem: "com.openui", category: "ChatViewModel")
    private var hasFinishedStreaming = false
    /// IDs of nodes explicitly deleted by the user this session.
    /// Prevents `adoptServerMessages` from re-adding them if the server
    /// still returns them (e.g. in chatCompleted after a delete+regenerate).
    private var deletedMessageIds: Set<String> = []
    /// Monotonically incrementing counter identifying the current streaming session.
    /// Incremented every time a new stream starts. Captured by the `onDrained` callback
    /// so it can detect when a new stream has started (e.g., via queue drain) and
    /// skip cleanup that would otherwise tear down the new stream.
    private var streamingSessionId: Int = 0
    /// Tracks the content length at the last `extractAndApplyTasksFromContent` call.
    /// Prevents the O(n) task-extraction scan from running on every single token;
    /// it only fires when the content has grown by ≥ 100 chars since the last scan.
    private var lastTaskExtractionLength: Int = 0
    private var activeTaskId: String?
    private var recoveryTimer: Timer?
    /// Cancellable delay task for the initial recovery timer delay.
    /// Replaces `DispatchQueue.main.asyncAfter` so it can be cancelled
    /// when the user navigates away or sends a new message.
    private var recoveryDelayTask: Task<Void, Never>?
    private var emptyPollCount = 0
    /// Tracks consecutive failures when querying `/api/tasks/chat/{id}` during
    /// the static-content phase of the recovery timer.  After 5 consecutive
    /// network failures we fall back to the legacy stale-content give-up logic
    /// so the timer still terminates if the task API becomes permanently unreachable.
    private var recoveryTaskCheckFailures = 0
    /// Wall-clock time at which the recovery timer was started.  Used as a
    /// hard backstop: if the chat has been nominally streaming for more than 10
    /// minutes we give up regardless of what the task API reports.
    private var recoveryTimerStartDate: Date = .distantPast
    /// The server content length observed on the previous recovery poll.
    /// When the server content grows between polls the model is still generating,
    /// so `emptyPollCount` is reset to 0 — preventing premature give-up for slow
    /// models (large reasoning models, long MCP tool chains, local models, etc.).
    private var lastRecoveryPollContentLength: Int = 0
    /// Tracks whether the socket has received at least one content token.
    /// Used by the recovery timer to avoid overwriting an active stream.
    private var socketHasReceivedContent = false
    private(set) var serverBaseURL: String = ""
    @ObservationIgnored nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// Separate background task assertion for on-device ASR transcription.
    /// Independent from backgroundTaskId (which covers streaming completion).
    @ObservationIgnored nonisolated(unsafe) private var transcriptionBackgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Pending transcriptions that were interrupted when the app moved to the background
    /// (iOS < 26 only — no GPU access in background). Keyed by attachment ID.
    /// Re-started automatically when the app returns to foreground.
    private var pendingResumeTranscriptions: [UUID: (audioData: Data, fileName: String)] = [:]

    /// Timestamp of the last successful server sync. Used to debounce
    /// redundant syncs when the app rapidly transitions foreground ↔ background.
    private var lastSyncTime: Date = .distantPast

    /// Minimum interval (seconds) between server syncs to avoid redundant fetches.
    private let syncDebounceInterval: TimeInterval = 3.0

    /// Timestamp of the last time the chat view appeared (navigation entry).
    /// Used by syncOnEntry() to debounce SwiftUI's double-appear during transitions.
    private var lastEntryTime: Date = .distantPast

    /// Timestamp when the app entered the background. Used to skip
    /// sync when the background duration was trivially short.
    @ObservationIgnored nonisolated(unsafe) private var backgroundEnteredAt: Date?

    /// The current auth token for authenticated image requests (model avatars).
    var serverAuthToken: String? {
        manager?.apiClient.network.authToken
    }

    var messages: [ChatMessage] {
        conversation?.messages ?? []
    }

    // MARK: - Tree Sync Helpers

    /// Syncs the conversation to the server using the tree-based history.
    /// The history tree is always kept in sync by all tree-mutating operations,
    /// so this just serializes the current tree state to the server.
    /// Copies content and metadata from the flat `conversation.messages` list back into
    /// their corresponding tree nodes.
    ///
    /// The history tree nodes are created with empty content (e.g. assistant nodes are
    /// created at send/edit time before streaming begins). Streaming content flows into
    /// `conversation.messages` but the tree nodes are never updated in-place.
    /// Calling this before any `syncToServerViaTree()` ensures we never overwrite the
    /// server's good data with stale/empty tree nodes.
    private func syncFlatMessagesToTreeNodes() {
        guard conversation?.history.isPopulated == true else { return }
        for msg in conversation?.messages ?? [] {
            // Only update if this node actually exists in the tree
            guard conversation?.history.nodes[msg.id] != nil else { continue }
            conversation?.history.updateNode(id: msg.id) { node in
                // Don't overwrite non-empty tree node content with an empty flat message
                // (this protects nodes on inactive branches that are absent from flat messages)
                if !msg.content.isEmpty {
                    node.content = msg.content
                }
                node.done = !msg.isStreaming
                if !msg.sources.isEmpty { node.sources = msg.sources }
                if !msg.statusHistory.isEmpty { node.statusHistory = msg.statusHistory }
                if let error = msg.error { node.error = error }
                if !msg.files.isEmpty { node.files = msg.files }
                if let usage = msg.usage { node.usage = usage }
                // Sync follow-ups so they survive rederiveMessages() calls
                if !msg.followUps.isEmpty { node.followUps = msg.followUps }
            }
        }
    }

    private func syncToServerViaTree() async {
        // Ensure tree nodes have up-to-date content from the flat messages list before
        // syncing to the server. Tree nodes are created with empty content at send/edit time
        // and streaming content only flows into conversation.messages — without this step,
        // syncToServerViaTree() would overwrite the server's good data with empty strings.
        syncFlatMessagesToTreeNodes()

        guard let chatId = conversationId ?? conversation?.id, let manager else { return }
        let modelId = selectedModelId ?? conversation?.model ?? ""

        guard let conv = conversation, conv.history.isPopulated else {
            // Tree not populated — fall back to flat-list sync
            try? await manager.syncConversationMessages(
                id: chatId, messages: conversation?.messages ?? [], model: modelId,
                title: conversation?.title, chatParams: conversation?.chatParams)
            return
        }

        try? await manager.apiClient.syncConversationHistory(
            id: chatId,
            history: conv.history,
            model: modelId,
            systemPrompt: conv.systemPrompt,
            chatParams: conv.chatParams,
            title: conv.title,
            chatFiles: chatFiles
        )
    }

    var selectedModel: AIModel? {
        guard let id = selectedModelId else { return nil }
        return availableModels.first { $0.id == id }
    }

    var canSend: Bool {
        // When message queue is enabled and we're streaming, allow sending (will enqueue).
        // Uploading attachments always block sending since we need the upload to complete first.
        let notBlocked = (enableMessageQueue && isStreaming)
            || (!isStreaming
                && !attachments.contains(where: { $0.type == .audio && $0.isTranscribing }))
        return notBlocked
            && !attachments.contains(where: { $0.isUploading })
            && (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    /// True if any transcription Task is currently running.
    /// Used by ActiveChatStore to prevent evicting a VM that is still working.
    var hasActiveTranscriptions: Bool {
        !transcriptionTasks.isEmpty
    }

    /// Whether any attachment is still uploading or being processed.
    var hasUploadingAttachments: Bool {
        attachments.contains { $0.isUploading }
    }

    var isNewConversation: Bool {
        conversationId == nil && conversation == nil
    }

    // MARK: - Immediate File Upload

    /// Uploads an attachment to the server immediately after it's added.
    /// Call this right after appending an attachment to `self.attachments`.
    /// The attachment's `uploadStatus` will progress: uploading → completed/error.
    /// The send button is blocked while any attachment has `isUploading == true`.
    /// Scrapes a webpage URL, converts the extracted text to a `.txt` file,
    /// and uploads it through the standard files API so it appears as a file
    /// attachment pill — identical to attaching a document from the file picker.
    func processWebURL(urlString: String) {
        var normalised = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalised.isEmpty else { return }
        if !normalised.hasPrefix("http://") && !normalised.hasPrefix("https://") {
            normalised = "https://\(normalised)"
        }

        // Derive a short filename from the domain
        let host = URL(string: normalised)?.host ?? "webpage"
        let fileName = "\(host).txt"

        // Add a placeholder attachment immediately so the user sees the pill
        var attachment = ChatAttachment(
            type: .file,
            name: fileName,
            thumbnail: nil,
            data: nil
        )
        attachment.uploadStatus = .uploading
        attachments.append(attachment)
        let attachmentId = attachment.id

        Task {
            guard let apiClient = manager?.apiClient else {
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .error
                    attachments[idx].uploadError = "Not connected to server"
                }
                return
            }

            do {
                // Phase 1: Scrape the webpage content
                let content = try await apiClient.processWebPage(url: normalised)

                guard let textData = content.data(using: .utf8), !textData.isEmpty else {
                    if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                        attachments[idx].uploadStatus = .error
                        attachments[idx].uploadError = "No content extracted from webpage"
                    }
                    return
                }

                // Store data on the attachment for the upload
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].data = textData
                }

                // Phase 2: Upload the text file through the normal files pipeline
                guard let mgr = manager else { return }
                let (fileId, fileObject) = try await mgr.uploadFile(
                    data: textData,
                    fileName: fileName,
                    onUploaded: { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                                self.attachments[idx].uploadStatus = .processing
                            }
                        }
                    }
                )

                // Phase 3: Mark completed
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .completed
                    attachments[idx].uploadedFileId = fileId
                    attachments[idx].uploadedFileObject = fileObject
                    attachments[idx].data = nil
                }
                logger.info("Web page \(normalised) scraped + uploaded: \(fileId)")
            } catch {
                let errorMessage: String
                if let apiError = error as? APIError,
                   case .httpError(_, let msg, _) = apiError,
                   let msg, !msg.isEmpty {
                    errorMessage = msg
                } else {
                    errorMessage = error.localizedDescription
                }
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .error
                    attachments[idx].uploadError = errorMessage
                }
                logger.error("Web page attachment failed: \(errorMessage)")
            }
        }
    }

    func uploadAttachmentImmediately(attachmentId: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == attachmentId }) else { return }
        // Skip audio only when in on-device transcription mode — server mode uploads audio like any file
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        guard !(attachments[index].type == .audio && audioFileMode == "device") else { return }

        attachments[index].uploadStatus = .uploading

        Task {
            guard let manager else {
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .error
                    attachments[idx].uploadError = "Not connected to server"
                }
                return
            }

            guard let idx = attachments.firstIndex(where: { $0.id == attachmentId }),
                  let data = attachments[idx].data else { return }

            let fileName = attachments[idx].name

            do {
                // APIClient.uploadFile handles ?process=true + SSE polling.
                // onUploaded fires after the file is stored on the server but BEFORE
                // SSE processing completes — we switch the chip from "uploading" to
                // "processing" so the user sees the two-phase status.
                let (fileId, fileObject) = try await manager.uploadFile(
                    data: data,
                    fileName: fileName,
                    onUploaded: { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                                self.attachments[idx].uploadStatus = .processing
                            }
                        }
                    }
                )
                // Update on success
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .completed
                    attachments[idx].uploadedFileId = fileId
                    attachments[idx].uploadedFileObject = fileObject
                    // STORAGE FIX: Release raw file data after successful upload.
                    // The file ID is sufficient for referencing the file going forward.
                    // Holding multi-MB image data in memory indefinitely causes bloat.
                    attachments[idx].data = nil
                }

                logger.info("Attachment \(fileName) uploaded + processed: \(fileId)")
            } catch {
                // Extract the clean server error message when available.
                // APIClient.waitForFileProcessing throws APIError.httpError with
                // the stripped server error text (e.g. "Error transcribing chunk…"
                // cleaned to just the relevant message).
                let errorMessage: String
                if let apiError = error as? APIError,
                   case .httpError(_, let msg, _) = apiError,
                   let msg, !msg.isEmpty {
                    errorMessage = msg
                } else {
                    errorMessage = error.localizedDescription
                }
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .error
                    attachments[idx].uploadError = errorMessage
                }
                logger.error("Attachment upload failed for \(fileName): \(errorMessage)")
            }
        }
    }

    // MARK: - Initialisation

    init(conversationId: String) {
        self.conversationId = conversationId
    }

    init() {
        self.conversationId = nil
    }

    // MARK: - Setup

    /// Weak reference to the shared store — used to write back model cache.
    private weak var activeChatStore: ActiveChatStore?

    /// `true` after `configure()` has been called at least once.
    ///
    /// Used by `ActiveChatStore.prewarm()` and `ChatDetailView.onAppear` to
    /// avoid redundant re-configuration when the view model has already been
    /// wired up (e.g. pre-warmed before navigation).
    private(set) var isConfigured: Bool = false

    func configure(with manager: ConversationManager, socket: SocketIOService? = nil, store: ActiveChatStore? = nil, asr: OnDeviceASRService? = nil, notes: NotesManager? = nil) {
        self.manager = manager
        self.notesManager = notes
        self.socketService = socket
        self.serverBaseURL = manager.baseURL
        self.activeChatStore = store
        self.asrService = asr
        isConfigured = true
        setupRetryAttachmentObserver()
        setupMemorySettingObserver()
        setupMessageQueueSettingObserver()
        setupFunctionsConfigObserver()
    }

    /// Registers the observer that handles retry requests posted by the
    /// audio attachment thumbnail's retry button.
    ///
    /// When the user taps the retry button on a failed audio upload chip,
    /// `ChatInputField` posts `.retryAttachmentUpload` with the attachment
    /// UUID as the `object`. This observer picks it up and re-runs
    /// `uploadAttachmentImmediately` so the status cycles back through
    /// uploading → processing → completed/error without requiring a new configure().
    private func setupRetryAttachmentObserver() {
        NotificationCenter.default.addObserver(
            forName: .retryAttachmentUpload,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let attachmentId = notification.object as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Reset to pending so the thumbnail immediately shows a spinner
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    self.attachments[idx].uploadStatus = .pending
                    self.attachments[idx].uploadError = nil
                }
                self.uploadAttachmentImmediately(attachmentId: attachmentId)
            }
        }
    }

    /// Registers an observer for `.memorySettingChanged` so that when the user
    /// toggles memory in Settings → Personalization → Memories, all active
    /// ChatViewModels update `memoryEnabled` immediately without a server refetch.
    ///
    /// IMPORTANT: Also updates `activeChatStore?.cachedMemorySetting` so that new
    /// ChatViewModel instances created AFTER the toggle (e.g. opening a new chat)
    /// pick up the correct value from the session cache instead of the stale `false`
    /// that was set when the session started with memory disabled.
    private func setupMemorySettingObserver() {
        NotificationCenter.default.addObserver(
            forName: .memorySettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let newValue = notification.object as? Bool else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memoryEnabled = newValue
                // Keep the session-level cache in sync so new VMs (opened after
                // this toggle) read the correct value from the cache rather than
                // the stale value set at session start.
                self.activeChatStore?.cachedMemorySetting = newValue
            }
        }
    }

    /// Observes `.functionsConfigChanged` to re-resolve actions/filters for the
    /// current model immediately when function config changes (admin toggles
    /// active/global, or model editor saves). This ensures action buttons and
    /// filter IDs update in the chat UI without requiring a model picker open
    /// or app restart.
    private func setupFunctionsConfigObserver() {
        NotificationCenter.default.addObserver(
            forName: .functionsConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshSelectedModelConfig()
                self.logger.info("Functions config changed — re-resolved actions/filters for current model")
            }
        }
    }

    private func setupMessageQueueSettingObserver() {
        NotificationCenter.default.addObserver(
            forName: .messageQueueSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let newValue = notification.object as? Bool
                ?? notification.userInfo?["enabled"] as? Bool
            guard let self, let newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enableMessageQueue = newValue
                self.activeChatStore?.cachedMessageQueueSetting = newValue
            }
        }
    }

    // MARK: - Audio Transcription (Navigation-Persistent)

    /// Starts transcription for an audio attachment and stores the Task on the VM.
    ///
    /// Because the VM lives in `ActiveChatStore` and survives navigation, the Task
    /// stored here will NOT be cancelled when the user navigates to another chat,
    /// the welcome screen, or anywhere else in the app. When the user returns to
    /// this chat, the attachment's `isTranscribing` state reflects the live status
    /// and `transcribedText` is populated as soon as the model finishes.
    ///
    /// - Parameters:
    ///   - attachmentId: The UUID of the `ChatAttachment` to transcribe.
    ///   - audioData: Raw audio file bytes.
    ///   - fileName: Original filename (used for the temp file extension).
    func transcribeAudioAttachment(attachmentId: UUID, audioData: Data, fileName: String) {
        guard let asr = asrService, asr.isAvailable, asr.autoTranscribeEnabled else { return }

        // Cancel any existing task for this attachment (e.g., user re-added the same file)
        transcriptionTasks[attachmentId]?.cancel()

        // Begin a background task the first time transcription starts (if not already running).
        // This requests ~30 seconds of extra CPU time from iOS when the app moves to the
        // background. If transcription finishes before the time expires, we end it early.
        // If it takes longer (e.g. large file), iOS will suspend (NOT terminate) the process
        // after the grant expires, and the Task resumes naturally when the user returns.
        if transcriptionBackgroundTaskId == .invalid {
            transcriptionBackgroundTaskId = UIApplication.shared.beginBackgroundTask(
                withName: "OnDeviceASRTranscription"
            ) { [weak self] in
                // Expiry handler — iOS is about to suspend us; end the assertion gracefully.
                // The Task itself is NOT cancelled — it will resume when the app foregrounds.
                guard let self else { return }
                Task { @MainActor in self.endTranscriptionBackgroundTask() }
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            // Mark as transcribing
            if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                self.attachments[idx].isTranscribing = true
            }

            do {
                let transcript = try await asr.transcribe(audioData: audioData, fileName: fileName)

                // Only update if attachment still exists (user may have removed it)
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    self.attachments[idx].transcribedText = transcript
                    self.attachments[idx].isTranscribing = false
                }
                // Clear any pending resume record — transcription succeeded
                self.pendingResumeTranscriptions.removeValue(forKey: attachmentId)
                self.logger.info("Transcription complete for \(fileName): \(transcript.count) chars")
            } catch ASRError.backgroundInterrupted {
                // iOS < 26: The app moved to the background and Metal GPU access
                // was revoked. The task was cancelled gracefully (no crash).
                // Keep the attachment in "transcribing" state and store the audio
                // data so we can restart automatically when the app foregrounds.
                self.logger.info("Transcription paused for background: \(fileName) — will auto-resume on foreground")
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    // Keep isTranscribing = true so the chip still shows a spinner
                    // (transcription resumes; user doesn't need to do anything).
                    self.attachments[idx].isTranscribing = true
                }
                // Store audio data + filename so foreground sync can restart it
                self.pendingResumeTranscriptions[attachmentId] = (audioData: audioData, fileName: fileName)
                // Remove from active tasks — the task has ended; a new one will be started on resume
                self.transcriptionTasks.removeValue(forKey: attachmentId)
                self.endTranscriptionBackgroundTask()
                return
            } catch {
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    self.attachments[idx].isTranscribing = false
                }
                // Only surface the error if the task wasn't explicitly cancelled
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                    self.logger.error("Transcription failed for \(fileName): \(error.localizedDescription)")
                }
            }

            // Clean up the task reference once complete
            self.transcriptionTasks.removeValue(forKey: attachmentId)

            // If all transcriptions are done, unload the model to free ~400-600 MB of RAM.
            // The model will reload automatically on the next transcription request.
            // Also end the iOS background task assertion (no more CPU work needed).
            if self.transcriptionTasks.isEmpty {
                asr.unloadModel()
                self.logger.info("All transcriptions complete — ASR model unloaded to free memory")
                self.endTranscriptionBackgroundTask()
            }
        }

        transcriptionTasks[attachmentId] = task
    }

    /// Ends the iOS background task assertion for on-device transcription.
    private func endTranscriptionBackgroundTask() {
        guard transcriptionBackgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(transcriptionBackgroundTaskId)
        transcriptionBackgroundTaskId = .invalid
    }

    func resolvedImageURL(for model: AIModel?) -> URL? {
        guard let model else { return nil }
        return model.resolveAvatarURL(baseURL: serverBaseURL)
    }

    // MARK: - Loading

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        let isNew = conversationId == nil

        // Models & tools are NOT fetched here — they load lazily:
        //  • Models: pre-populated from ActiveChatStore cache. Refreshed
        //    when user opens model picker or before each send.
        //  • Tools: fetched fresh every time user opens the tools section.
        //
        // If this is the very first VM and the cache is empty, do an initial
        // model fetch so the user has something to select.
        let needsModelFetch = availableModels.isEmpty

        if isNew {
            // ── New chat fast path ──
            // Skip conversation fetch, passive listener, and external stream
            // check — they are all no-ops when there is no conversation ID.
            if needsModelFetch {
                await loadModels()
            } else {
                syncUIWithModelDefaults()
            }
        } else {
            // ── Existing chat path ──
            // Run model fetch (if needed) and conversation fetch in parallel.
            if needsModelFetch {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.loadModels() }
                    group.addTask { await self.loadConversation() }
                }
            } else {
                syncUIWithModelDefaults()
                await loadConversation()
            }
        }

        // Ensure socket is connected — fire-and-forget so it never blocks
        // the UI. The socket will be ready by the time the user sends a
        // message; if not, sendMessage() can await it at that point.
        if let socket = socketService, !socket.isConnected {
            Task {
                let connected = await socket.ensureConnected(timeout: 5.0)
                self.logger.info("Socket connect on load: \(connected)")
                // Start passive listener once socket is actually connected
                // (only meaningful for existing conversations).
                if connected && !isNew {
                    self.startPassiveSocketListener()
                }
            }
        } else if !isNew {
            // Socket already connected — start passive listener immediately
            startPassiveSocketListener()
        }

        // Start listening for app foreground events to sync with server
        startForegroundSyncListener()

        // Fetch terminal servers in the background (fire-and-forget).
        // This is lightweight and determines whether to show the terminal pill.
        Task { await loadTerminalServers() }

        // Now that all initial data is loaded, enable message appear animations.
        // New messages sent/received during this session will animate in smoothly.
        shouldAnimateNewMessages = true
    }

    /// Re-fetches the conversation from the server and updates the local state.
    /// Called after an action button invocation to pick up content changes
    /// made by the action's server-side event emitters.
    func reloadConversation() async {
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }
        do {
            let refreshed = try await manager.fetchConversation(id: chatId)
            adoptServerMessages(serverConversation: refreshed)
        } catch {
            logger.warning("reloadConversation failed: \(error.localizedDescription)")
        }
    }

    func loadConversation() async {
        guard let conversationId, let manager else { return }
        isLoadingConversation = true
        errorMessage = nil
        do {
            let fetched = try await manager.fetchConversation(id: conversationId)
            // Always use server data as the source of truth.
            // Versions are now stored as sibling messages on the server,
            // so server-fetched data already contains them.
            conversation = fetched
            // Clear the deleted-node blacklist — fresh load from server is the source of truth
            deletedMessageIds = []
            // Populate tasks from the server conversation
            tasks = fetched.tasks
            // Populate top-level chat files (mirrors OWUI `chatFiles = chat?.files ?? []`)
            chatFiles = fetched.files
            // Always adopt the last-used model for existing chats.
            // Priority: last assistant message's model (the actual model used
            // most recently) > conversation-level model > fallback.
            // This ensures returning to a chat uses the model from the most
            // recent response, even if it was changed mid-conversation from
            // the web UI or another client.
            if let lastAssistantModel = fetched.messages.last(where: { $0.role == .assistant })?.model,
               !lastAssistantModel.isEmpty {
                selectedModelId = lastAssistantModel
            } else if let conversationModel = fetched.model, !conversationModel.isEmpty {
                selectedModelId = conversationModel
            } else if selectedModelId == nil {
                selectedModelId = availableModels.first?.id
            }
        } catch {
            logger.error("Failed to load conversation: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        // Re-derive flat messages from the history tree when the tree has more nodes
        // than the flat messages array. This handles background sub-agent messages which
        // the server appends only to the history tree — `chat.messages` stays at 2 entries
        // while the tree has 4. After re-deriving, push the updated currentId to the
        // server so WebUI also navigates to the full branch.
        if conversation?.history.isPopulated == true {
            let treeMessages = conversation!.history.createMessagesList()
            if treeMessages.count > (conversation?.messages.count ?? 0) {
                conversation!.rederiveMessages()
                logger.info("loadConversation: re-derived \(treeMessages.count) messages from tree (was \(self.conversation?.messages.count ?? 0) from flat array)")
                Task { await self.syncCurrentIdToServer() }
            }
        }
        // Clear stale override tracking so the model's server defaults apply cleanly
        // when the user opens an existing chat. We don't persist per-chat feature state,
        // so starting fresh here is the correct behaviour (Bug 2 fix).
        userDisabledBuiltinFeatures = []
        isLoadingConversation = false
    }

    /// Syncs local conversation state with the server.
    ///
    /// This is the key mechanism for detecting external changes (e.g., when
    /// a response is regenerated from the website). Matches the Flutter app's
    /// `_syncRemoteTaskStatus` and `activeConversationProvider` listener pattern.
    ///
    /// It compares local messages with server messages and adopts server data
    /// when:
    /// - Server has more messages than local
    /// - Server's last assistant message has different/more content
    /// - Server's last assistant message has different files (regenerated images)
    ///
    /// Uses debouncing to avoid redundant syncs when the app rapidly transitions
    /// between foreground and background states.
    func syncWithServer() async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }

        // Debounce: skip if we synced very recently (e.g., foreground observer
        // + .task both firing within the same second)
        let now = Date()
        guard now.timeIntervalSince(lastSyncTime) >= syncDebounceInterval else {
            logger.debug("Server sync debounced (last sync \(self.lastSyncTime.formatted()))")
            return
        }

        do {
            let serverConversation = try await manager.fetchConversation(id: chatId)
            lastSyncTime = Date()

            let serverMessages = serverConversation.messages
            let localMessages = conversation?.messages ?? []

            // Skip if no server messages
            guard !serverMessages.isEmpty else { return }

            // Fast path: if message IDs, counts, and content fingerprints match,
            // nothing changed — only update lightweight metadata (title/tags).
            if localMessages.count == serverMessages.count && !localMessages.isEmpty {
                let allMatch = zip(localMessages, serverMessages).allSatisfy { local, server in
                    local.id == server.id
                    && local.content.utf8.count == server.content.utf8.count // Fast O(1) reject
                    && local.content == server.content // Full compare only if lengths match
                    && local.files.count == server.files.count
                    && local.sources.count == server.sources.count
                    && local.followUps.count == server.followUps.count
                }
                if allMatch {
                    // Only update title if changed — no structural changes to messages
                    if !serverConversation.title.isEmpty
                        && serverConversation.title != "New Chat"
                        && serverConversation.title != conversation?.title {
                        conversation?.title = serverConversation.title
                    }
                    logger.debug("Server sync: no changes detected, skipping")
                    return
                }
            }

            // Case 1: Server has more messages than local — adopt surgically
            if serverMessages.count > localMessages.count {
                logger.info("Server sync: server has \(serverMessages.count) msgs vs local \(localMessages.count)")
                adoptServerMessages(serverConversation: serverConversation)
                return
            }

            // Case 2: Same message count — check if last assistant changed
            if !localMessages.isEmpty && !serverMessages.isEmpty {
                let localLast = localMessages.last!
                let serverLast = serverMessages.last!

                // Find matching message by ID
                if localLast.id == serverLast.id && localLast.role == .assistant {
                    let localContent = localLast.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let serverContent = serverLast.content.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Server has different content (regenerated from website)
                    let contentChanged = !serverContent.isEmpty && serverContent != localContent

                    // Server has different files (e.g., regenerated images from tool)
                    let filesChanged = serverLast.files != localLast.files

                    // Server has different sources
                    let sourcesChanged = serverLast.sources.count != localLast.sources.count

                    if contentChanged || filesChanged || sourcesChanged {
                        logger.info("Server sync: detected external change (content:\(contentChanged) files:\(filesChanged) sources:\(sourcesChanged))")

                        // Save current local state as a version before adopting server state
                        // (only if the content actually differs and has meaningful content)
                        if contentChanged && !localContent.isEmpty {
                            if let idx = conversation?.messages.lastIndex(where: { $0.id == localLast.id }) {
                                let version = ChatMessageVersion(
                                    content: localLast.content,
                                    timestamp: localLast.timestamp,
                                    model: localLast.model,
                                    error: localLast.error,
                                    files: localLast.files,
                                    sources: localLast.sources,
                                    followUps: localLast.followUps
                                )
                                // Only add if we don't already have this version
                                let isDuplicate = conversation?.messages[idx].versions.contains(where: {
                                    $0.content == version.content && $0.timestamp == version.timestamp
                                }) ?? false
                                if !isDuplicate {
                                    conversation?.messages[idx].versions.append(version)
                                }
                            }
                        }

                        adoptServerMessages(serverConversation: serverConversation)
                        return
                    }
                }

                // Case 3: Last messages have different IDs — server has a different
                // message chain (e.g., regeneration created a new message ID)
                if localLast.id != serverLast.id && serverLast.role == .assistant {
                    logger.info("Server sync: different last message IDs (local:\(localLast.id) server:\(serverLast.id))")
                    adoptServerMessages(serverConversation: serverConversation)
                    return
                }
            }

            // Update title if changed
            if !serverConversation.title.isEmpty && serverConversation.title != "New Chat" {
                conversation?.title = serverConversation.title
            }

        } catch {
            logger.warning("Server sync failed: \(error.localizedDescription)")
        }
    }

    /// Adopts server messages using **surgical in-place updates** to preserve
    /// SwiftUI identity tracking and scroll position in the inverted ScrollView.
    ///
    /// Instead of replacing the entire `conversation` object (which causes
    /// SwiftUI to rebuild the full LazyVStack and lose scroll position), this
    /// method:
    /// 1. Updates existing messages in-place by matching on ID
    /// 2. Appends only truly new messages
    /// 3. Removes only messages deleted server-side
    /// 4. Merges local-only versions that haven't been synced
    ///
    /// This eliminates the flicker/jump and scroll-stuck issues that occurred
    /// when returning from background, because SwiftUI's identity tracking
    /// (via `.id(message.id)`) remains stable throughout the update.
    private func adoptServerMessages(serverConversation: Conversation) {
        guard conversation != nil else {
            // No local conversation yet — just assign directly
            conversation = serverConversation
            if let serverModel = serverConversation.model, selectedModelId != serverModel {
                selectedModelId = serverModel
            }
            return
        }

        // Merge the server's history tree into our local history.
        // The server tree is authoritative for all non-streaming nodes.
        if serverConversation.history.isPopulated {
            for (id, serverNode) in serverConversation.history.nodes {
                if let localNode = conversation?.history.nodes[id] {
                    // Node exists locally — update content fields but keep local
                    // content if we're actively streaming this message.
                    let isActivelyStreaming = streamingStore.streamingMessageId == id && streamingStore.isActive
                    if !isActivelyStreaming {
                        var updated = serverNode
                        // Preserve local childrenIds if they have more entries
                        // (local may have new branches not yet on server)
                        if localNode.childrenIds.count > serverNode.childrenIds.count {
                            updated.childrenIds = localNode.childrenIds
                        }
                        // CRITICAL: Never overwrite a non-empty local tree node content
                        // with empty server content. This prevents adoptServerMessages()
                        // from undoing the content we wrote to the tree node in
                        // updateAssistantMessage(isStreaming:false).
                        //
                        // How this bug occurs:
                        // 1. editMessage() syncs tree to server with empty assistant node
                        // 2. Streaming completes → updateAssistantMessage writes content to local tree node
                        // 3. refreshConversationMetadata() → adoptServerMessages() runs
                        // 4. Server still has the empty assistant node from step 1
                        // 5. WITHOUT this guard: server's empty node overwrites our good local node
                        // 6. Now the tree node is empty again; any future sync sends empty to server
                        if !localNode.content.isEmpty && updated.content.isEmpty {
                            updated.content = localNode.content
                            updated.done = true
                        }
                        conversation?.history.nodes[id] = updated
                    }
                } else {
                    // New node from server — add only if not explicitly deleted this session
                    if !deletedMessageIds.contains(id) {
                        conversation?.history.nodes[id] = serverNode
                    }
                }
            }
            // Update currentId from server unless we're actively streaming.
            // Walk to the deepest leaf — the server's currentId may be stale
            // (e.g. when a background sub-agent appends new nodes after the
            // original assistant response). deepestLeaf() follows the last-child
            // chain to the tip of the active branch, matching WebUI's loadChat().
            if !isStreaming, let serverCurrentId = serverConversation.history.currentId {
                let leaf = serverConversation.history.deepestLeaf(from: serverCurrentId)
                conversation?.history.currentId = leaf
            }
        }

        let serverMessages = serverConversation.messages

        // Build a set of server message IDs for removal detection
        let serverMessageIds = Set(serverMessages.map(\.id))

        // Phase 1: Remove local messages that no longer exist on server
        // Iterate in reverse to preserve indices during removal
        for i in (0..<(conversation!.messages.count)).reversed() {
            let localId = conversation!.messages[i].id
            if !serverMessageIds.contains(localId) {
                conversation!.messages.remove(at: i)
            }
        }

        // Phase 2: Update existing messages in-place and insert new ones
        for (serverIdx, serverMsg) in serverMessages.enumerated() {
            if let localIdx = conversation!.messages.firstIndex(where: { $0.id == serverMsg.id }) {
                // Message exists locally — update only changed fields in-place
                let local = conversation!.messages[localIdx]

                // GUARD: Skip ALL display-relevant field updates for the message
                // currently live in the StreamingPipeline. StreamingContentStore
                // is the single authoritative source for content/isStreaming/statusHistory
                // during active streaming. Letting adoptServerMessages() overwrite these
                // fields would cause the "navigate away and back" bug where a second
                // stale display path activates via message.isStreaming == true.
                let isCurrentlyInPipeline = streamingStore.streamingMessageId == serverMsg.id
                    && streamingStore.isActive
                if isCurrentlyInPipeline { continue }

                // GUARD: During active streaming, do NOT overwrite content of
                // already-completed (non-streaming) assistant messages. The server
                // may return stale/corrupted data during streaming that would
                // replace the first message's content with the second message's
                // streaming content — causing the "duplicate stream" bug.
                let isLocallyComplete = !local.isStreaming && local.role == .assistant
                    && !local.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let skipContentUpdate = isLocallyComplete && isStreaming

                if !skipContentUpdate && local.content != serverMsg.content {
                    conversation!.messages[localIdx].content = serverMsg.content
                }
                if local.files != serverMsg.files {
                    conversation!.messages[localIdx].files = serverMsg.files
                }
                if local.sources.count != serverMsg.sources.count || local.sources != serverMsg.sources {
                    conversation!.messages[localIdx].sources = serverMsg.sources
                }
                if local.followUps != serverMsg.followUps {
                    // Never overwrite non-empty local follow-ups with an empty server array.
                    // The server may not have persisted the follow-ups yet when the post-
                    // completion metadata refresh runs (they arrive via socket event and may
                    // be written to the server after the metadata fetch completes).
                    if !serverMsg.followUps.isEmpty || local.followUps.isEmpty {
                        conversation!.messages[localIdx].followUps = serverMsg.followUps
                    }
                }
                if local.error != serverMsg.error {
                    conversation!.messages[localIdx].error = serverMsg.error
                }
                if local.isStreaming != serverMsg.isStreaming {
                    conversation!.messages[localIdx].isStreaming = serverMsg.isStreaming
                }
                // CRITICAL: Sync parentId from server. Locally-created messages
                // always have parentId = nil (it's not set in the UI layer when
                // the user sends a message). The server's tree has the correct
                // parentId for every node. Without this, downstream messages
                // captured by regenerateResponse/restoreAssistantVersion retain
                // nil parentId, causing editMessage's fallback to pick the wrong
                // parent (the currently-displayed message instead of the real
                // tree parent).
                if local.parentId == nil, let serverParentId = serverMsg.parentId {
                    conversation!.messages[localIdx].parentId = serverParentId
                }

                // Merge versions: keep local-only versions + server versions.
                // The tree is the source of truth — versions are just sibling nodes
                // for the UI version counter. Server content wins; local-only versions
                // (not yet synced) are appended.
                var mergedVersions: [ChatMessageVersion] = []
                let serverVersionIds = Set(serverMsg.versions.map(\.id))
                // Start with server versions (authoritative)
                mergedVersions = serverMsg.versions
                // Append any local-only versions (not yet on server)
                for localVersion in local.versions {
                    if !serverVersionIds.contains(localVersion.id) {
                        mergedVersions.append(localVersion)
                    }
                }
                if mergedVersions.count != local.versions.count || mergedVersions != local.versions {
                    conversation!.messages[localIdx].versions = mergedVersions
                }

                // Preserve usage data from server — never overwrite with nil
                if local.usage == nil,
                   let serverUsage = serverMsg.usage, !serverUsage.isEmpty {
                    conversation!.messages[localIdx].usage = serverUsage
                }
                // Preserve embeds from server — never overwrite non-empty embeds with empty
                if local.embeds.isEmpty && !serverMsg.embeds.isEmpty {
                    conversation!.messages[localIdx].embeds = serverMsg.embeds
                }
            } else {
                // New message from server — insert at correct position
                let insertIdx = min(serverIdx, conversation!.messages.count)
                conversation!.messages.insert(serverMsg, at: insertIdx)
            }
        }

        // Phase 3: Ensure message order matches server order
        // (only reorder if the IDs don't match sequence — avoids unnecessary mutation)
        let currentIds = conversation!.messages.map(\.id)
        let serverIds = serverMessages.map(\.id)
        if currentIds != serverIds {
            // Reorder by building a new array in server order, preserving local mutations
            let localMap = Dictionary(conversation!.messages.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            var reordered: [ChatMessage] = []
            for serverId in serverIds {
                if let msg = localMap[serverId] {
                    reordered.append(msg)
                }
            }
            // Append any remaining local messages not in server (shouldn't happen, but safety)
            for msg in conversation!.messages where !serverMessageIds.contains(msg.id) {
                reordered.append(msg)
            }
            conversation!.messages = reordered
        }

        // Phase 4: Update conversation metadata (non-message fields)
        if !serverConversation.title.isEmpty && serverConversation.title != "New Chat" {
            conversation?.title = serverConversation.title
        }
        // NOTE: Do NOT override selectedModelId here. The user's model picker
        // selection is authoritative once the conversation is loaded. Overwriting
        // it from the server would revert a deliberate model change the user made
        // (e.g., picking a different model before regenerating). The initial load
        // case at the top of this method already sets selectedModelId when
        // conversation is nil.
        if serverConversation.tags != conversation?.tags {
            conversation?.tags = serverConversation.tags
        }
        // Sync tasks from server — ensures task list stays current after
        // syncWithServer() / reloadConversation() calls.
        if !serverConversation.tasks.isEmpty || !tasks.isEmpty {
            tasks = serverConversation.tasks
            conversation?.tasks = serverConversation.tasks
        }

        // Phase 5: Re-derive flat messages from the history tree when the tree
        // has more nodes on the active branch than the flat messages list reflects.
        //
        // This handles the background sub-agent case: the server appends new nodes
        // (an internal user message + final assistant message) to the history TREE
        // only — the server's `chat.messages` flat array is NOT updated. After Phase
        // 1-3 sync the flat array from server's messages (missing the new nodes),
        // the tree already has all 4 nodes and currentId is at the deepest leaf.
        // Calling rederiveMessages() here rebuilds the flat list from the tree,
        // making the sub-agent response visible without requiring a full reload.
        //
        // After rederiving, push the updated currentId back to the server so WebUI
        // also navigates to the full branch (WebUI uses currentId to walk the tree).
        //
        // Guard: only when not actively streaming (never interrupt a live stream).
        if !isStreaming, conversation?.history.isPopulated == true {
            let treeMessages = conversation!.history.createMessagesList()
            if treeMessages.count > (conversation?.messages.count ?? 0) {
                conversation!.rederiveMessages()
                logger.info("adoptServerMessages: re-derived \(treeMessages.count) messages from tree (was \(self.conversation?.messages.count ?? 0) from flat array)")
                // Push the updated currentId to server so WebUI also shows the full branch.
                Task { await self.syncCurrentIdToServer() }
            }
        }
    }

    // MARK: - Entry Sync (navigation re-entry)

    /// Syncs with the server every time the user navigates INTO this chat.
    ///
    /// Unlike `syncWithServer()` (which has a 3-second debounce designed to
    /// guard against rapid foreground/background transitions), this method uses
    /// a much shorter 1.5-second guard — just enough to absorb SwiftUI's
    /// double-appear during push/pop navigation transitions.
    ///
    /// Called from `ChatDetailView.onAppear` so that even when the view model
    /// is cached (`hasLoaded == true`) and no foreground transition occurs,
    /// we still pick up any messages changed externally (e.g. a response
    /// regenerated from the web while this chat was in the background pane).
    func syncOnEntry() {
        guard hasLoaded else { return } // load() handles the first appearance
        guard !isStreaming else { return } // never interrupt an active stream
        let now = Date()
        guard now.timeIntervalSince(lastEntryTime) >= 1.5 else { return }
        lastEntryTime = now
        // Reset lastSyncTime so syncWithServer() is not blocked by its own debounce
        lastSyncTime = .distantPast
        Task { await syncWithServer() }
    }

    // MARK: - Foreground Sync

    /// Listens for app becoming active to trigger a server sync,
    /// and for app entering background to start completion monitoring.
    /// This catches changes made externally (e.g., regeneration from website)
    /// and ensures tool-generated files/images are picked up after backgrounding.
    private func startForegroundSyncListener() {
        // Remove any existing observers to prevent duplicates
        if let existing = foregroundObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        if let existing = backgroundObserver {
            NotificationCenter.default.removeObserver(existing)
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Skip sync if the app was only backgrounded for a trivially
                // short period (< 2s). This prevents unnecessary flicker when
                // the user accidentally swipes to the app switcher and back.
                let bgDuration: TimeInterval
                if let bgStart = self.backgroundEnteredAt {
                    bgDuration = Date().timeIntervalSince(bgStart)
                } else {
                    bgDuration = .infinity // Unknown — assume long
                }
                self.backgroundEnteredAt = nil

                if self.isStreaming {
                    // App was backgrounded during streaming — socket events may
                    // have been missed. Check server for actual completion state.
                    await self.recoverFromBackgroundStreaming()
                } else if bgDuration >= 10.0 {
                    // Only sync if we were backgrounded long enough for
                    // something to have changed on the server (10s threshold
                    // avoids triggering on quick app-switcher glances which
                    // would cause scroll position loss and a flicker).
                    await self.syncWithServer()
                    // Re-fetch user default params so any system prompt or inference
                    // param changes made on another device or the web UI are picked
                    // up immediately for the next chat request.
                    await self.fetchUserDefaultParamsFromServer()
                } else {
                    self.logger.debug("Foreground sync skipped — background duration \(bgDuration)s < 10s")
                }

                // Auto-resume any transcriptions that were paused when the app
                // went to background on iOS < 26 (where GPU access is forbidden
                // in the background). The audio data was saved in
                // pendingResumeTranscriptions at pause time; restart them now.
                if !self.pendingResumeTranscriptions.isEmpty {
                    let pending = self.pendingResumeTranscriptions
                    self.pendingResumeTranscriptions = [:]
                    self.logger.info("Resuming \(pending.count) paused transcription(s) after foreground return")
                    for (attachmentId, info) in pending {
                        self.transcribeAudioAttachment(
                            attachmentId: attachmentId,
                            audioData: info.audioData,
                            fileName: info.fileName
                        )
                    }
                }
            }
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.backgroundEnteredAt = Date()
                guard self.isStreaming else { return }
                self.startBackgroundCompletionPolling()
            }
        }
    }

    /// Removes the foreground/background sync listeners.
    func removeForegroundSyncListener() {
        if let existing = foregroundObserver {
            NotificationCenter.default.removeObserver(existing)
            foregroundObserver = nil
        }
        if let existing = backgroundObserver {
            NotificationCenter.default.removeObserver(existing)
            backgroundObserver = nil
        }
    }

    deinit {
        let fgObserver = foregroundObserver
        let bgObserver = backgroundObserver
        if let fgObserver {
            NotificationCenter.default.removeObserver(fgObserver)
        }
        if let bgObserver {
            NotificationCenter.default.removeObserver(bgObserver)
        }
    }

    // MARK: - Background Completion Polling

    /// Starts a background task that polls the server for streaming completion.
    /// iOS grants ~30s of background execution. If the generation completes within
    /// that window, we fire a local notification and adopt the server state.
    private func startBackgroundCompletionPolling() {
        guard backgroundTaskId == .invalid else { return }

        let chatId = conversationId ?? conversation?.id

        backgroundTaskId = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            // Bug 1 fix: expiration handler — do one final check and fire a
            // notification before iOS kills us, rather than silently giving up.
            Task { @MainActor [weak self] in
                guard let self, let chatId, let manager = self.manager else {
                    self?.endBackgroundTask()
                    return
                }
                if self.isStreaming {
                    do {
                        let refreshed = try await manager.fetchConversation(id: chatId)
                        if let serverAssistant = refreshed.messages.last(where: { $0.role == .assistant }),
                           !serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.logger.info("Background expiry: server completed, firing notification")
                            self.adoptServerMessages(serverConversation: refreshed)
                            await self.sendCompletionNotificationIfNeeded(content: serverAssistant.content)
                            self.cleanupStreaming()
                            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                        } else {
                            // Still running — fire a "still processing" style notification
                            // so the user at least knows the response is in-flight.
                            self.logger.info("Background expiry: response still in progress, notifying user")
                            let partialContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
                            await self.sendCompletionNotificationIfNeeded(content: partialContent)
                        }
                    } catch {
                        self.logger.warning("Background expiry check failed: \(error.localizedDescription)")
                    }
                }
                self.endBackgroundTask()
            }
        }

        Task { @MainActor [weak self] in
            guard let self, let chatId, let manager = self.manager else {
                self?.endBackgroundTask()
                return
            }

            // Fix 4: Poll every 1.5s (was 3s), up to 20 times (~30s — near iOS limit)
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.isStreaming else {
                    self.endBackgroundTask()
                    return
                }

                do {
                    let refreshed = try await manager.fetchConversation(id: chatId)
                    if let serverAssistant = refreshed.messages.last(where: { $0.role == .assistant }),
                       !serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.logger.info("Background poll: server completed (\(serverAssistant.content.count) chars)")
                        self.adoptServerMessages(serverConversation: refreshed)
                        await self.sendCompletionNotificationIfNeeded(content: serverAssistant.content)
                        self.cleanupStreaming()
                        self.endBackgroundTask()
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                        return
                    }
                } catch {
                    self.logger.warning("Background poll failed: \(error.localizedDescription)")
                }
            }

            self.endBackgroundTask()
        }
    }

    /// Ends the iOS background task.
    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    /// Recovers streaming state when the app returns to foreground.
    /// Socket events may have been missed while backgrounded, so we check
    /// the server for the actual completion state and adopt it.
    private func recoverFromBackgroundStreaming() async {
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }

        do {
            let serverConversation = try await manager.fetchConversation(id: chatId)
            guard let serverAssistant = serverConversation.messages.last(where: { $0.role == .assistant }) else { return }

            let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)

            // If server has content, the generation completed while we were backgrounded
            if !serverContent.isEmpty {
                logger.info("Foreground recovery: server has completed content (\(serverContent.count) chars, \(serverAssistant.files.count) files)")

                // Adopt server state fully (includes files from tool calls)
                adoptServerMessages(serverConversation: serverConversation)

                // Safety net: if server didn't populate files but tool results
                // contain file references, extract them from the message content.
                // This is the primary fix for the "backgrounded during image gen" scenario.
                if let lastAssistantId = conversation?.messages.last(where: { $0.role == .assistant })?.id {
                    populateFilesFromToolResults(messageId: lastAssistantId)
                }

                // Fix 3: Set bypass flag so the notification shows even if the
                // user has already returned to this chat. The response completed
                // while they were away — they deserve to know it's ready.
                NotificationService.shared.bypassActiveConversationSuppression = true
                // Send notification — generation completed while we were away
                await sendCompletionNotificationIfNeeded(content: serverContent)

                // Cleanup streaming state
                cleanupStreaming()

                // Notify conversation list
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

                // Schedule a delayed re-sync to pick up title, follow-ups, and tags.
                // These background tasks run asynchronously on the server and may not
                // be ready when we first recover. A 3s + 8s poll catches most cases.
                Task {
                    for delay: UInt64 in [3, 8] {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        await self.syncWithServer()
                    }
                }
            }
            // If server content is still empty, streaming may still be in progress.
            // The existing socket handlers / recovery timer will handle it when
            // the socket reconnects.
        } catch {
            logger.warning("Foreground recovery failed: \(error.localizedDescription)")
        }
    }

    func loadModels() async {
        guard let manager else { return }
        isLoadingModels = true
        do {
            availableModels = try await manager.fetchModels()
            // Always fetch the server default model and cache it.
            // This ensures new chats always use the server-configured default,
            // not whatever model the user last switched to in a different chat.
            let serverDefault = await manager.fetchDefaultModel()
            if let store = activeChatStore {
                store.cachedDefaultModelId = serverDefault
            }
            if selectedModelId == nil {
                selectedModelId = serverDefault ?? availableModels.first?.id
            }
            // Write back to shared cache so subsequent VMs are pre-populated
            activeChatStore?.updateModelCache(models: availableModels, selectedId: selectedModelId)

            // Evict model avatar cache entries so admin-changed avatars are
            // picked up on the next render. Runs in the background — does not
            // block the model load or the UI. Uses prefetchWithAuth so images
            // are re-downloaded with the Bearer token immediately after eviction.
            let avatarURLs = availableModels.compactMap { $0.resolveAvatarURL(baseURL: serverBaseURL) }
            let authToken = manager.apiClient.network.authToken
            Task {
                for url in avatarURLs {
                    await ImageCacheService.shared.evict(for: url)
                }
                await ImageCacheService.shared.prefetchWithAuth(urls: avatarURLs, authToken: authToken)
            }
        } catch {
            logger.error("Failed to load models: \(error.localizedDescription)")
        }
        isLoadingModels = false
        // Sync UI toggles with model defaults after models are loaded
        syncUIWithModelDefaults()
    }

    /// Silently refreshes the model list from the server in the background.
    /// Called when the user opens the model picker to pick up admin-added models.
    func refreshModelsInBackground() {
        guard !isLoadingModels else { return }
        Task { await loadModels() }
    }

    /// Fetches terminal servers available to the user.
    ///
    /// Called once at chat load time. If any terminals are available, the
    /// user can toggle them on via the terminal pill in the input field.
    func loadTerminalServers() async {
        guard let manager else { return }
        do {
            availableTerminalServers = try await manager.fetchTerminalServers()
            // Auto-select first terminal if only one is available and nothing is selected yet.
            if selectedTerminalServer == nil, let first = availableTerminalServers.first {
                selectedTerminalServer = first
            }
            // If the previously selected server was removed or disabled server-side,
            // clear the selection so the user isn't silently routed to a dead server.
            if let current = selectedTerminalServer,
               !availableTerminalServers.contains(current) {
                selectedTerminalServer = availableTerminalServers.first
                // If terminal was enabled and we had to change/clear the server, disable
                // terminal so the user makes an explicit choice rather than silently
                // switching servers mid-session.
                if terminalEnabled && selectedTerminalServer == nil {
                    terminalEnabled = false
                }
            }
        } catch {
            logger.debug("Terminal servers fetch failed: \(error.localizedDescription)")
        }
    }

    /// Toggles the terminal on/off. When turning on, auto-selects the first
    /// server if none is selected. When multiple servers are available,
    /// the caller should set `selectedTerminalServer` before enabling.
    func toggleTerminal() {
        if terminalEnabled {
            terminalEnabled = false
            // Always clear the selected server when disabling so terminal_id
            // is never leaked into subsequent chat completion payloads.
            // Re-selection happens automatically in loadTerminalServers() /
            // the else-branch below when the user re-enables.
            selectedTerminalServer = nil
        } else {
            if selectedTerminalServer == nil, let first = availableTerminalServers.first {
                selectedTerminalServer = first
            }
            terminalEnabled = true
        }
    }

    func loadTools() async {
        guard let manager else { return }
        isLoadingTools = true
        do {
            var allItems = try await manager.fetchTools()

            // Also fetch toggle-filter functions (meta.toggle: true) from /api/v1/functions/
            // These are filter functions that can be toggled per-message, like
            // "OpenRouter Search" or "Direct Uploads". They show as toggleable
            // tools in the ToolsMenuSheet alongside regular tools.
            do {
                let functions = try await manager.apiClient.getFunctions()
                let toggleFilters = functions.filter { $0.type == "filter" && $0.isActive && $0.hasToggle }
                // Resolve defaultFilterIds from rawModelItem["info"]["meta"]["defaultFilterIds"].
                // This is where the web UI stores the per-chat toggle default for filter functions.
                let modelDefaultFilterIds: [String] = {
                    guard let raw = selectedModel?.rawModelItem,
                          let info = raw["info"] as? [String: Any],
                          let meta = info["meta"] as? [String: Any],
                          let ids = meta["defaultFilterIds"] as? [String] else { return [] }
                    return ids
                }()

                for fn in toggleFilters {
                    // Avoid duplicates (a filter could theoretically have the same ID as a tool)
                    if !allItems.contains(where: { $0.id == fn.id }) {
                        // Default ON state: use the model's defaultFilterIds list.
                        // An empty list means the admin left the default as OFF — respect that.
                        // isGlobal only controls whether the filter pipeline runs for all models;
                        // it is NOT the chat-UI toggle default and must NOT be used here.
                        let isDefaultOn = modelDefaultFilterIds.contains(fn.id)
                        allItems.append(ToolItem(
                            id: fn.id,
                            name: fn.name,
                            description: fn.description.isEmpty ? nil : fn.description,
                            isEnabled: isDefaultOn,
                            hasUserValves: true,
                            isFunctionTool: true
                        ))
                    }
                }
            }

                // Also populate availableFunctions for the Controls panel Valves section.
            // Fetch ALL active functions (not just toggle-filters) so the Valves section
            // can show any tool/function that has user-configurable valve settings.
            do {
                let allFunctions = try await manager.apiClient.getFunctions()
                availableFunctions = allFunctions.filter { $0.isActive && $0.hasUserValves }
            } catch {
                logger.debug("Failed to fetch functions for valves: \(error.localizedDescription)")
            }

            if !allItems.isEmpty {
                availableTools = allItems
                syncToolSelectionWithDefaults()
                // Prune selectedToolIds of orphaned IDs (tools that no longer exist on server).
                // Mirrors IntegrationsMenu.svelte line 108:
                //   selectedToolIds = selectedToolIds.filter(id => Object.keys(tools).includes(id))
                let knownIds = Set(allItems.map { $0.id })
                selectedToolIds = selectedToolIds.filter { knownIds.contains($0) }
                isLoadingTools = false
                toolsHaveLoaded = true
                return
            }
        } catch {
            logger.warning("Failed to fetch tools: \(error.localizedDescription)")
        }
        var seen = Set<String>()
        var items: [ToolItem] = []
        for model in availableModels {
            for toolId in model.toolIds where !seen.contains(toolId) {
                seen.insert(toolId)
                items.append(ToolItem(
                    id: toolId,
                    name: toolId.replacingOccurrences(of: "_", with: " ").capitalized,
                    description: nil
                ))
            }
        }
        availableTools = items
        syncToolSelectionWithDefaults()
        let knownFallbackIds = Set(items.map { $0.id })
        selectedToolIds = selectedToolIds.filter { knownFallbackIds.contains($0) }
        isLoadingTools = false
        toolsHaveLoaded = true
    }

    /// Adds globally-enabled tools (server `is_active`) and model-assigned
    /// tools to `selectedToolIds` so the toggles show as on by default.
    /// Respects `userDisabledToolIds` — tools the user explicitly toggled
    /// OFF during this session are NOT re-enabled by server defaults.
    private func syncToolSelectionWithDefaults() {
        // 1. Globally-enabled tools (server admin marked as active)
        for tool in availableTools where tool.isEnabled {
            if !userDisabledToolIds.contains(tool.id) {
                selectedToolIds.insert(tool.id)
            }
        }
        // 2. Model-assigned tools (admin attached to the selected model)
        if let model = selectedModel {
            for toolId in model.toolIds {
                if !userDisabledToolIds.contains(toolId) {
                    selectedToolIds.insert(toolId)
                }
            }
        }
    }

    // MARK: - Knowledge

    /// Timestamp of the last knowledge fetch — used for stale-while-revalidate.
    private var lastKnowledgeFetchTime: Date = .distantPast

    /// Fetches knowledge bases and user files for the `#` picker.
    ///
    /// Uses a **stale-while-revalidate** strategy:
    /// - If cache exists, shows it instantly and refreshes in the background.
    /// - If no cache, shows a loading state while fetching.
    /// - Cache is refreshed every time the picker opens (async).
    func loadKnowledgeItems() {
        // If we already have cached items, show them immediately
        // and refresh in the background (stale-while-revalidate)
        if !knowledgeItems.isEmpty {
            // Background refresh — no loading indicator
            Task { await fetchKnowledgeItemsFromServer() }
            return
        }

        // No cache — show loading state
        isLoadingKnowledge = true
        Task {
            await fetchKnowledgeItemsFromServer()
            isLoadingKnowledge = false
        }
    }

    /// Fetches folders + knowledge bases + knowledge files from the server
    /// and updates the cache. All 3 APIs are called concurrently.
    private func fetchKnowledgeItemsFromServer() async {
        guard let manager else { return }

        // Fetch all 3 sources concurrently — each is independent and
        // a single failure shouldn't prevent the others from showing.
        async let foldersReq: [KnowledgeItem] = {
            (try? await manager.fetchFolderItems()) ?? []
        }()
        async let collectionsReq: [KnowledgeItem] = {
            (try? await manager.fetchKnowledgeItems()) ?? []
        }()
        async let filesReq: [KnowledgeItem] = {
            (try? await manager.fetchKnowledgeFileItems()) ?? []
        }()

        let (folders, collections, files) = await (foldersReq, collectionsReq, filesReq)

        // Only update if we got at least something
        let combined = folders + collections + files
        if !combined.isEmpty || knowledgeItems.isEmpty {
            knowledgeItems = combined
        }
        lastKnowledgeFetchTime = Date()
    }

    /// Called when a knowledge item is selected from the `#` picker.
    ///
    /// Adds the item to the selected list (if not already there),
    /// removes the `#query` from the input text, and dismisses the picker.
    func selectKnowledgeItem(_ item: KnowledgeItem) {
        // Avoid duplicates
        guard !selectedKnowledgeItems.contains(where: { $0.id == item.id }) else {
            dismissKnowledgePicker()
            return
        }
        selectedKnowledgeItems.append(item)

        // Remove the `#query` token from input text
        removeHashToken()
        dismissKnowledgePicker()
    }

    /// Removes the `#...` token from the input text (the text from the last `#`
    /// at a word boundary up to the cursor position).
    private func removeHashToken() {
        let text = inputText
        // Find the last `#` at a word boundary
        guard let hashIndex = text.lastIndex(of: "#") else { return }
        let hashPos = text.distance(from: text.startIndex, to: hashIndex)
        let isAtStart = hashPos == 0
        let precededBySpace = hashPos > 0 && {
            let beforeIdx = text.index(before: hashIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            // Remove from `#` to the end of the current token (no whitespace after #)
            let afterHash = text[hashIndex...]
            let tokenEnd = afterHash.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<hashIndex]) + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Removes the `@...` token from the input text (the text from the last `@`
    /// at a word boundary up to the cursor position).
    func removeMentionToken() {
        let text = inputText
        guard let atIndex = text.lastIndex(of: "@") else { return }
        let atPos = text.distance(from: text.startIndex, to: atIndex)
        let isAtStart = atPos == 0
        let precededBySpace = atPos > 0 && {
            let beforeIdx = text.index(before: atIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            let afterAt = text[atIndex...]
            let tokenEnd = afterAt.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<atIndex]) + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Dismisses the knowledge picker popup.
    func dismissKnowledgePicker() {
        isShowingKnowledgePicker = false
        knowledgeSearchQuery = ""
    }

    // MARK: - Reference Chats

    /// Called when a reference chat is selected from the picker.
    /// Adds the chat to the selected list (avoiding duplicates).
    func selectReferenceChat(_ item: ReferenceChatItem) {
        guard !selectedReferenceChats.contains(where: { $0.id == item.id }) else { return }
        selectedReferenceChats.append(item)
        Haptics.play(.light)
    }

    // MARK: - Context Item Removal (Controls Panel)

    /// Removes a knowledge item from the active context.
    /// Adds the item's ID to `removedContextIds` so `collectHistoryFileRefs` skips
    /// it in future RAG requests, preventing ghost-re-injection from history nodes.
    func removeKnowledgeItem(_ item: KnowledgeItem) {
        selectedKnowledgeItems.removeAll { $0.id == item.id }
        removedContextIds.insert(item.id)
    }

    /// Removes a reference chat from the active context.
    /// Adds the chat's ID to `removedContextIds` so it is not re-injected from history.
    func removeReferenceChat(_ item: ReferenceChatItem) {
        selectedReferenceChats.removeAll { $0.id == item.id }
        removedContextIds.insert(item.id)
    }

    /// Removes a top-level chat file from this conversation and persists the removal to the server.
    /// Adds the file ID to `removedContextIds` so it is not re-injected from history refs.
    func removeFile(_ file: ChatMessageFile) {
        chatFiles.removeAll { $0.url == file.url }
        if let fileId = file.url {
            removedContextIds.insert(fileId)
        }
        guard let chatId = conversationId ?? conversation?.id,
              let manager else { return }
        let currentFiles = chatFiles
        Task {
            try? await manager.apiClient.updateChatControls(id: chatId, files: currentFiles)
        }
    }

    // MARK: - Prompt Slash Commands

    /// Fetches the prompt library from the server.
    ///
    /// Uses a **stale-while-revalidate** strategy like knowledge items:
    /// - If cache exists, shows it instantly and refreshes in the background.
    /// - If no cache, shows a loading state while fetching.
    /// - Only fetches active prompts (is_active == true) from `GET /api/v1/prompts/`.
    func loadPrompts() {
        if !availablePrompts.isEmpty {
            // Background refresh — no loading indicator
            Task { await fetchPromptsFromServer() }
            return
        }

        // No cache — show loading state
        isLoadingPrompts = true
        Task {
            await fetchPromptsFromServer()
            isLoadingPrompts = false
        }
    }

    /// Fetches prompts from the server API.
    private func fetchPromptsFromServer() async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let raw = try await apiClient.getPrompts()
            let parsed = raw.compactMap { PromptItem(json: $0) }
            // Only cache active prompts — disabled prompts don't appear in slash commands
            availablePrompts = parsed.filter(\.isActive)
            logger.info("Loaded \(self.availablePrompts.count) active prompts")
        } catch {
            logger.warning("Failed to load prompts: \(error.localizedDescription)")
        }
    }

    /// Called when the user selects a prompt from the `/` picker.
    ///
    /// 1. Removes the `/query` token from the input text
    /// 2. Dismisses the picker
    /// 3. Extracts custom variables from the prompt content
    /// 4. If variables exist → presents the variable input sheet
    /// 5. If no variables → processes and inserts the prompt directly
    func selectPrompt(_ prompt: PromptItem) {
        // Remove the `/command` token from input text
        removeSlashToken()
        dismissPromptPicker()

        // Extract custom input variables (skips system variables)
        let variables = PromptService.extractCustomVariables(from: prompt.content)

        if variables.isEmpty {
            // No variables — process system variables and insert directly
            let processed = PromptService.resolveSystemVariables(
                in: prompt.content,
                userName: nil,
                userEmail: nil
            )
            // Append prompt text to whatever the user already typed (after slash token removal)
            let remaining = inputText.trimmingCharacters(in: .whitespaces)
            inputText = remaining.isEmpty ? processed : remaining + " " + processed
        } else {
            // Has variables — present the variable input sheet
            pendingPromptForVariables = prompt
            pendingPromptVariables = variables
        }

        Haptics.play(.light)
    }

    /// Called when the user submits variable values from the PromptVariableSheet.
    func submitPromptVariables(values: [String: String]) {
        guard let prompt = pendingPromptForVariables else { return }
        let variables = pendingPromptVariables

        let processed = PromptService.processPrompt(
            content: prompt.content,
            userValues: values,
            variables: variables,
            userName: nil,
            userEmail: nil
        )

        // Append prompt text to whatever the user already typed (after slash token removal)
        let remaining = inputText.trimmingCharacters(in: .whitespaces)
        inputText = remaining.isEmpty ? processed : remaining + " " + processed
        pendingPromptForVariables = nil
        pendingPromptVariables = []

        Haptics.play(.light)
    }

    /// Called when the user cancels the variable input sheet.
    func cancelPromptVariables() {
        pendingPromptForVariables = nil
        pendingPromptVariables = []
    }

    /// Removes the `/...` token from the input text (the text from the last `/`
    /// at a word boundary up to the cursor position).
    private func removeSlashToken() {
        let text = inputText
        guard let slashIndex = text.lastIndex(of: "/") else { return }
        let slashPos = text.distance(from: text.startIndex, to: slashIndex)
        let isAtStart = slashPos == 0
        let precededBySpace = slashPos > 0 && {
            let beforeIdx = text.index(before: slashIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            let afterSlash = text[slashIndex...]
            let tokenEnd = afterSlash.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<slashIndex]) + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Dismisses the prompt picker popup.
    func dismissPromptPicker() {
        isShowingPromptPicker = false
        promptSearchQuery = ""
    }

    // MARK: - Skills Dollar Commands

    /// Fetches active skills from the server for the `$` picker.
    ///
    /// Uses a **stale-while-revalidate** strategy like prompts:
    /// - If cache exists, shows it instantly and refreshes in the background.
    /// - If no cache, shows a loading state while fetching.
    func loadSkills() {
        if !availableSkills.isEmpty {
            // Background refresh — no loading indicator
            Task { await fetchSkillsFromServer() }
            return
        }

        // No cache — show loading state
        isLoadingSkills = true
        Task {
            await fetchSkillsFromServer()
            isLoadingSkills = false
        }
    }

    /// Fetches skills from the server API.
    private func fetchSkillsFromServer() async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let items = try await apiClient.getSkills()
            // Only cache active skills — disabled skills don't appear in $ commands
            availableSkills = items.filter(\.isActive)
            logger.info("Loaded \(self.availableSkills.count) active skills")
        } catch {
            logger.warning("Failed to load skills: \(error.localizedDescription)")
        }
    }

    /// Called when the user selects a skill from the `$` picker.
    ///
    /// Replaces the `$query` token with `<$slug|slug> ` in the input text
    /// (matching the Open WebUI wire format), and records the skill ID in
    /// `selectedSkillIds` so it is sent as `skill_ids` in the API request.
    func selectSkill(_ skill: SkillItem) {
        // Use the web UI format: <$slug|slug>
        replaceDollarTokenWith("<$\(skill.id)|\(skill.id)> ")
        dismissSkillPicker()

        if !selectedSkillIds.contains(skill.id) {
            selectedSkillIds.append(skill.id)
        }

        Haptics.play(.light)
    }

    /// Replaces the `$...` token in the input text with `replacement`.
    /// The token is the text from the last bare `$` (at start or preceded by
    /// whitespace) up to the next whitespace or end of string.
    private func replaceDollarTokenWith(_ replacement: String) {
        let text = inputText
        guard let dollarIndex = text.lastIndex(of: "$") else { return }
        let dollarPos = text.distance(from: text.startIndex, to: dollarIndex)
        let isAtStart = dollarPos == 0
        let precededBySpace = dollarPos > 0 && {
            let beforeIdx = text.index(before: dollarIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            let afterDollar = text[dollarIndex...]
            let tokenEnd = afterDollar.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<dollarIndex]) + replacement + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Removes the `$...` token from the input text (replaces with empty string).
    private func removeDollarToken() {
        replaceDollarTokenWith("")
    }

    /// Dismisses the skill picker popup.
    func dismissSkillPicker() {
        isShowingSkillPicker = false
        skillSearchQuery = ""
    }

    /// Restores `selectedKnowledgeItems` from the conversation's user messages.
    ///
    /// When loading an existing conversation, scans user messages for files
    /// with `type == "collection"`, `"folder"`, or knowledge `"file"` entries
    /// and rebuilds the knowledge chips so they persist across navigation.
    private func restoreKnowledgeItemsFromConversation() {
        guard let conversation, selectedKnowledgeItems.isEmpty else { return }

        // Collect unique knowledge files from the most recent user message
        // that has them. Knowledge files are stored with type "collection"/"folder"/"file".
        let knowledgeTypes: Set<String> = ["collection", "folder"]
        var restored: [KnowledgeItem] = []
        var seenIds = Set<String>()

        // Scan from newest to oldest — find the first user message with knowledge files
        for message in conversation.messages.reversed() where message.role == .user {
            let knowledgeFiles = message.files.filter { f in
                guard let type = f.type else { return false }
                return knowledgeTypes.contains(type)
            }
            if !knowledgeFiles.isEmpty {
                for file in knowledgeFiles {
                    guard let id = file.url, !seenIds.contains(id) else { continue }
                    seenIds.insert(id)
                    let knowledgeType: KnowledgeItem.KnowledgeType
                    switch file.type {
                    case "folder": knowledgeType = .folder
                    case "collection": knowledgeType = .collection
                    default: knowledgeType = .file
                    }
                    restored.append(KnowledgeItem(
                        id: id,
                        name: file.name ?? id,
                        description: nil,
                        type: knowledgeType,
                        fileCount: nil
                    ))
                }
                break // Only restore from the most recent user message
            }
        }

        if !restored.isEmpty {
            selectedKnowledgeItems = restored
            logger.info("Restored \(restored.count) knowledge item(s) from conversation history")
        }
    }

    // MARK: - Passive Socket Listener (Cross-Client Stream Observation)
    private func startPassiveSocketListener() {
        // Only for existing conversations with a known ID
        guard let chatId = conversationId ?? conversation?.id else { return }
        guard let socket = socketService, socket.isConnected else { return }

        // Dispose any previous passive subscription
        passiveSubscription?.dispose()

        passiveSubscription = socket.addChatEventHandler(
            conversationId: chatId,
            sessionId: nil // No session filter — observe ALL events for this chat
        ) { [weak self] event, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handlePassiveEvent(event)
            }
        }

        logger.info("Passive socket listener registered for chat \(chatId)")
    }

    /// Handles a socket event received by the passive listener.
    private func handlePassiveEvent(_ event: [String: Any]) {
        let data = event["data"] as? [String: Any] ?? event
        let type = data["type"] as? String
        let payload = data["data"] as? [String: Any]
        let messageId = event["message_id"] as? String
        let chatId = conversationId ?? conversation?.id

        // 🔍 DIAGNOSTIC: log every event arriving at the passive listener
        logger.info("👁️ [Passive] type=\(type ?? "nil", privacy: .public) msgId=\(messageId ?? "nil", privacy: .public) selfInitiated=\(self.selfInitiatedStream, privacy: .public) isStreaming=\(self.isStreaming, privacy: .public) isExternal=\(self.isExternallyStreaming, privacy: .public) isSyncing=\(self.isSyncingExternalStream, privacy: .public)")

        // --- Metadata events: ALWAYS process (title, tags, follow-ups) ---
        switch type {
        case "chat:title":
            var newTitle: String?
            if let titleStr = data["data"] as? String, !titleStr.isEmpty {
                newTitle = titleStr
            } else if let p = payload, let t = p["title"] as? String, !t.isEmpty {
                newTitle = t
            }
            if let newTitle {
                conversation?.title = newTitle
                if let chatId {
                    NotificationCenter.default.post(
                        name: .conversationTitleUpdated,
                        object: nil,
                        userInfo: ["conversationId": chatId, "title": newTitle]
                    )
                }
            }
            return

        case "chat:tags":
            if let chatId, let msgId = messageId {
                Task { try? await refreshConversationMetadata(chatId: chatId, assistantMessageId: msgId) }
            }
            return

        case "chat:message:follow_ups":
            // Use top-level message_id if present; fall back to the most-recently
            // completed self-initiated message. During regeneration the server may
            // emit this event without a top-level message_id — the active handler
            // uses a closure-captured ID, but the passive listener only sees the
            // event payload. Without this fallback the follow-ups are silently
            // dropped every time the passive path is the only one still alive.
            let targetMsgId = messageId ?? lastCompletedSelfInitiatedMessageId
            if let targetMsgId {
                var followUps: [String] = []
                if let payload {
                    followUps = payload["follow_ups"] as? [String]
                        ?? payload["followUps"] as? [String]
                        ?? payload["suggestions"] as? [String] ?? []
                }
                if followUps.isEmpty, let directArray = data["data"] as? [String] {
                    followUps = directArray
                }
                let trimmed = followUps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !trimmed.isEmpty {
                    appendFollowUps(id: targetMsgId, followUps: trimmed)
                }
            }
            return

        default:
            break
        }

        // --- Handle chat:reload ---
        // The server fires chat:reload when a new message node is added to the history tree
        // (e.g. when a background sub-agent's assistant response starts streaming). This is
        // the CRITICAL signal that a new message ID is about to receive chat:completion tokens.
        // We must fetch immediately so the message exists locally before tokens arrive —
        // otherwise all completion tokens buffer and get lost when chat:active{active:false}
        // clears the accumulator before syncOnceForExternalStream can replay them.
        if type == "chat:reload" {
            if !selfInitiatedStream, !isSyncingExternalStream, let chatId, let manager {
                // Set the sync flag immediately to block duplicate fetches from concurrent tokens
                isSyncingExternalStream = true
                isExternallyStreaming = true
                isStreaming = true
                hasFinishedStreaming = false
                // A new external stream is beginning — clear the replay-block so it can't
                // accidentally suppress tokens for the new message ID.
                lastCompletedSelfInitiatedMessageId = nil
                let reloadMsgId = messageId
                Task {
                    if let serverConv = try? await manager.fetchConversation(id: chatId) {
                        self.adoptServerMessages(serverConversation: serverConv)
                        // If we know the message ID, begin the streaming pipeline now
                        // so tokens that arrive immediately can flow through it.
                        if let msgId = reloadMsgId,
                           let msg = self.conversation?.messages.first(where: { $0.id == msgId }) {
                            let modelId = msg.model ?? self.selectedModelId
                            if !self.streamingStore.isActive {
                                self.streamingStore.beginStreaming(messageId: msgId, modelId: modelId)
                                self.externalStreamAccumulatedContent = ""
                                self.logger.info("chat:reload: pre-started streaming pipeline for \(msgId)")
                            }
                        }
                    }
                    self.isSyncingExternalStream = false
                }
            }
            return
        }

        // --- Handle chat:list ---
        // Background sub-agents complete on their own chat ID (not the parent's).
        // The only signal the parent chat receives when a background sub-agent finishes
        // is chat:list — the server fires it when it appends new nodes to the parent tree.
        // We reload unless we're already mid-sync for an external stream (which would
        // be a duplicate fetch). adoptServerMessages has its own guards to avoid
        // corrupting a live stream (isCurrentlyInPipeline check in Phase 2).
        if type == "chat:list" {
            if !selfInitiatedStream, !isSyncingExternalStream, let chatId, let manager {
                Task {
                    if let serverConv = try? await manager.fetchConversation(id: chatId) {
                        self.adoptServerMessages(serverConversation: serverConv)
                    }
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                }
            }
            return
        }

        // --- Handle chat:active — fires when a background sub-agent task finishes ---
        // WebUI's chatEventHandler (Chat.svelte): when active=false AND hasPendingAssistantLeaf()
        // → calls loadChat(). Importantly WebUI does NOT clear any streaming state here —
        // chat:active{active:false} fires after the task scheduler finishes, which may be
        // BEFORE the summary response finishes streaming (the LLM tokens follow after).
        // We must NOT wipe isExternallyStreaming/externalStreamAccumulatedContent here or we
        // corrupt an in-progress external stream. Just reload the conversation tree.
        if type == "chat:active" {
            let activePayload = data["data"] as? [String: Any]
            let isActive = activePayload?["active"] as? Bool ?? true
            if !isActive, let chatId, let manager {
                // Do NOT clear isExternallyStreaming / isSyncingExternalStream /
                // externalStreamAccumulatedContent here — those are managed by the
                // content-token and done handlers. Clearing them here would corrupt an
                // in-progress external stream whose tokens arrive after this event.
                Task {
                    if let serverConv = try? await manager.fetchConversation(id: chatId) {
                        self.adoptServerMessages(serverConversation: serverConv)
                    }
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                }
            }
            return
        }

        // --- Block replayed events for the just-completed self-initiated stream --------
        // When startPassiveSocketListener() re-subscribes after a stream finishes, the
        // OpenWebUI socket server re-delivers recent events to the newly-subscribed client.
        // These replayed events would re-route the completed response through the external
        // streaming path (handlePassiveEvent), causing the typewriter to replay the whole
        // response from the beginning. Block them by checking the top-level event message_id
        // against lastCompletedSelfInitiatedMessageId (set in cleanupStreaming()).
        //
        // IMPORTANT: Only use the top-level event["message_id"] — do NOT fall back to
        // payload?["message_id"] (which is from data.data and may hold a different message's
        // context ID). Using the payload fallback would cause subagent summary tokens to be
        // incorrectly blocked when the server embeds context message IDs in the payload.
        if let recentId = lastCompletedSelfInitiatedMessageId,
           let incomingMsgId = messageId,   // ONLY top-level event["message_id"], never payload fallback
           incomingMsgId == recentId {
            logger.debug("👁️ [Passive] Blocked replay event for just-completed message \(recentId)")
            return
        }

        // --- Content/streaming events: skip only if this event is for the message we're
        //     actively streaming ourselves. Allow through if it's a different message ID
        //     (e.g. a background subagent completing and spawning a new response).
        //     CRITICAL: Only apply this guard while we're actually streaming (isStreaming==true).
        //     After our own stream completes, selfInitiatedStream stays true until cleanupStreaming()
        //     but streamingStore.streamingMessageId becomes nil — causing activeId==nil which drops
        //     ALL subsequent passive events (including subagent completion tokens). Adding &&isStreaming
        //     ensures we only skip echo events during our active stream window, never after. ---
        if selfInitiatedStream && isStreaming {
            let incomingMsgId = event["message_id"] as? String
            let activeId = streamingStore.streamingMessageId
            // If both IDs are known and they differ → this is an external stream, let it through.
            // If either is nil or they match → this is our own stream echo, skip it.
            if incomingMsgId == nil || activeId == nil || incomingMsgId == activeId {
                return
            }
        }

        // Extract content from events. Handle both message AND chat:completion
        // event types, using replace-if-longer to prevent duplication.
        var contentDelta: String?
        var isReplace = false
        
        switch type {
        case "chat:message:delta", "event:message:delta":
            contentDelta = payload?["content"] as? String
        case "message", "chat:message", "replace":
            contentDelta = payload?["content"] as? String
            isReplace = true
        case "chat:completion":
            // structured output: reconstruct full content string (text + tool call
            // <details> blocks) from the output array, using the same helper as history
            // parsing. This ensures tool cards, preamble, and final answer all render.
            if let outputArr = payload?["output"] as? [[String: Any]],
               let reconstructed = MessageHistory.reconstructContentFromOutput(outputArr) {
                contentDelta = reconstructed
                isReplace = true  // Server sends cumulative snapshots
            }
            // Legacy choices format
            if contentDelta == nil {
                if let choices = payload?["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let delta = first["delta"] as? [String: Any],
                   let c = delta["content"] as? String, !c.isEmpty {
                    contentDelta = c
                } else if let c = payload?["content"] as? String, !c.isEmpty {
                    contentDelta = c
                    isReplace = true
                }
            }
        default:
            break
        }

        // If this is a content event with actual text
        if let contentDelta, !contentDelta.isEmpty {
            guard let msgId = messageId else { return }

            // If message doesn't exist locally, we need to sync first.
            // Buffer the token content NOW so it isn't lost while the async
            // fetch is in-flight (tokens arriving during sync are accumulated
            // here and replayed by syncOnceForExternalStream once it finishes).
            if conversation?.messages.first(where: { $0.id == msgId }) == nil {
                // Always accumulate the token, even if a sync is already running.
                if isReplace {
                    externalStreamAccumulatedContent = contentDelta
                } else {
                    externalStreamAccumulatedContent += contentDelta
                }
                // Only start ONE sync — subsequent tokens just accumulate above.
                if !isSyncingExternalStream {
                    isSyncingExternalStream = true
                    isExternallyStreaming = true
                    isStreaming = true
                    hasFinishedStreaming = false
                    Task {
                        await self.syncOnceForExternalStream(messageId: msgId)
                        self.isSyncingExternalStream = false
                    }
                }
                return
            }

            // Message exists — route through the StreamingContentStore pipeline
            // so tokens get the same typewriter/drain effect as self-initiated streams.
            if !isExternallyStreaming {
                isExternallyStreaming = true
                isStreaming = true
                // Reset hasFinishedStreaming for each new external stream session
                hasFinishedStreaming = false
                externalStreamAccumulatedContent = ""
                // Clear the replay-block — a new external stream is beginning for this message.
                lastCompletedSelfInitiatedMessageId = nil
                // Begin the streaming store for this message (activates drain pipeline).
                // Guard against double-start: chat:reload may have already called beginStreaming
                // for this msgId. Starting it again would reset the pipeline mid-stream.
                if !streamingStore.isActive {
                    let modelId = conversation?.messages.first(where: { $0.id == msgId })?.model
                        ?? selectedModelId
                    streamingStore.beginStreaming(messageId: msgId, modelId: modelId)
                    logger.info("External stream: first token for message \(msgId), routing via StreamingContentStore")
                } else {
                    logger.info("External stream: first token for message \(msgId), pipeline already active (pre-started by chat:reload)")
                }
            }

            // Accumulate content (delta or replace) then push full accumulated
            // string into the store — exactly like ContentAccumulator does.
            if isReplace {
                externalStreamAccumulatedContent = contentDelta
            } else {
                externalStreamAccumulatedContent += contentDelta
            }
            updateAssistantMessage(id: msgId, content: externalStreamAccumulatedContent, isStreaming: true)

            // Also check for done signal within content events (chat:completion
            // can carry both content AND done:true in the same event)
            if type == "chat:completion", let payload, payload["done"] as? Bool == true {
                let finalContent = externalStreamAccumulatedContent
                isExternallyStreaming = false
                isSyncingExternalStream = false
                externalStreamAccumulatedContent = ""
                // Route through the drain-deferral path — isStreaming is cleared
                // inside the onDrained callback after all buffered tokens are displayed.
                updateAssistantMessage(id: msgId, content: finalContent, isStreaming: false)
                let chatId = conversationId ?? conversation?.id
                Task {
                    await self.sendCompletionNotificationIfNeeded(content: finalContent)
                    if let chatId {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard let manager = self.manager else { return }
                        if let serverConv = try? await manager.fetchConversation(id: chatId) {
                            self.adoptServerMessages(serverConversation: serverConv)
                        }
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                    }
                }
            }
            return
        }

        // Handle done signal (when no content in the event)
        if type == "chat:completion", let payload, payload["done"] as? Bool == true {
            let msgId = messageId ?? streamingStore.streamingMessageId
            let finalContent = externalStreamAccumulatedContent.isEmpty
                ? (msgId.flatMap { id in conversation?.messages.first(where: { $0.id == id })?.content } ?? "")
                : externalStreamAccumulatedContent
            isExternallyStreaming = false
            isSyncingExternalStream = false
            externalStreamAccumulatedContent = ""
            // Route through drain-deferral so typewriter finishes before UI resets.
            if let msgId {
                updateAssistantMessage(id: msgId, content: finalContent, isStreaming: false)
            }
            // Final sync to pick up complete content, files, sources
            let chatId = conversationId ?? conversation?.id
            Task {
                await self.sendCompletionNotificationIfNeeded(content: finalContent)
                if let chatId {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let manager = self.manager else { return }
                    if let serverConv = try? await manager.fetchConversation(id: chatId) {
                        self.adoptServerMessages(serverConversation: serverConv)
                    }
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                }
            }
            return
        }

        // Handle errors and cancellation
        if type == "chat:message:error" || type == "chat:tasks:cancel" {
            isExternallyStreaming = false
            isSyncingExternalStream = false
            externalStreamAccumulatedContent = ""
            // Abort the streaming store (no drain needed for errors)
            if let msgId = messageId ?? streamingStore.streamingMessageId,
               streamingStore.streamingMessageId == msgId {
                _ = streamingStore.abortStreaming()
            }
            cleanupStreaming()
            return
        }
    }

    /// Fetches conversation from server ONCE to pick up the message structure
    /// (user + assistant messages) that an external client created. After this
    /// sync, the message exists locally and subsequent socket tokens can be
    /// appended directly without needing another fetch.
    private func syncOnceForExternalStream(messageId: String) async {
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }
        do {
            let serverConversation = try await manager.fetchConversation(id: chatId)
            adoptServerMessages(serverConversation: serverConversation)

            // After syncing, begin routing tokens through the StreamingContentStore pipeline
            guard let msg = conversation?.messages.first(where: { $0.id == messageId }) else { return }
            let modelId = msg.model ?? selectedModelId

            // Check if tokens arrived while the sync was in-flight.
            // externalStreamAccumulatedContent is written by handlePassiveEvent while
            // isSyncingExternalStream is true — those tokens were buffered rather than dropped.
            let bufferedContent = externalStreamAccumulatedContent
            let serverContent = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)

            // Pick the best starting content:
            //   - bufferedContent: tokens that arrived while we were fetching (live stream)
            //   - serverContent: what the server already has (might be a finished response)
            // Prefer buffered tokens if they exist (they represent the live stream);
            // fall back to server content if no tokens arrived during sync.
            let startContent = bufferedContent.isEmpty ? serverContent : bufferedContent

            // Begin the streaming pipeline with the buffered content as the initial state.
            streamingStore.beginStreaming(messageId: messageId, modelId: modelId)

            if startContent.isEmpty {
                // No content yet from either source — just wait for incoming tokens.
                externalStreamAccumulatedContent = ""
                logger.info("External stream: synced messages, now tracking \(messageId) via pipeline (empty content)")
            } else if !bufferedContent.isEmpty {
                // We have live token data buffered — pump it into the pipeline for
                // character-by-character typewriter streaming.
                streamingStore.updateContent(bufferedContent)
                updateAssistantMessage(id: messageId, content: bufferedContent, isStreaming: true)
                logger.info("External stream: replaying \(bufferedContent.count) buffered chars into pipeline for \(messageId)")
                // Do NOT mark as done here — more tokens will continue to arrive
                // via handlePassiveEvent which will call updateAssistantMessage(isStreaming:true)
                // and eventually updateAssistantMessage(isStreaming:false) when done:true fires.
            } else {
                // Server already has the complete response (no live tokens buffered).
                // Animate it through the typewriter pipeline.
                externalStreamAccumulatedContent = serverContent
                streamingStore.updateContent(serverContent)
                updateAssistantMessage(id: messageId, content: serverContent, isStreaming: false)
                isExternallyStreaming = false
                isSyncingExternalStream = false
                externalStreamAccumulatedContent = ""
                logger.info("External stream: synced complete message \(messageId), animating \(serverContent.count) chars via typewriter")
            }
        } catch {
            logger.warning("External stream sync failed: \(error.localizedDescription)")
            isExternallyStreaming = false
            isSyncingExternalStream = false
            externalStreamAccumulatedContent = ""
        }
    }

    /// Task for the external stream polling loop.
    private var externalStreamPollTask: Task<Void, Never>?

    // MARK: - Model-Switch Status Polling (issue #79)

    /// Live status from the per-server switch-status endpoint.
    /// Non-nil only while a model switch is in progress. Cleared by stopSwitchStatusPolling().
    var modelSwitchStatus: ModelSwitchStatus?

    /// Background polling task — cancelled as soon as the first SSE token arrives or streaming ends.
    private var switchPollingTask: Task<Void, Never>?

    /// Starts polling the server's model-switch status URL every 1 s.
    /// No-op when `switchStatusURL` is nil or empty on the active server.
    private func startSwitchStatusPolling() {
        guard let switchURL = manager?.apiClient.network.serverConfig.switchStatusURL,
              !switchURL.isEmpty else { return }
        switchPollingTask?.cancel()
        switchPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let apiClient = self.manager?.apiClient
            while !Task.isCancelled {
                if let status = await apiClient?.fetchModelSwitchStatus(url: switchURL) {
                    if status.isSwitching {
                        self.modelSwitchStatus = status
                    } else {
                        // Switch finished — clear banner and stop polling
                        self.modelSwitchStatus = nil
                        self.switchPollingTask?.cancel()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s
            }
        }
    }

    /// Cancels the polling task and clears the banner.
    private func stopSwitchStatusPolling() {
        switchPollingTask?.cancel()
        switchPollingTask = nil
        modelSwitchStatus = nil
    }

    /// Starts a polling loop that fetches conversation content from the server
    /// every 1.5 seconds during an external stream. The server persists streamed
    /// content to the database in real-time, so each poll gets the latest
    /// accumulated text — giving a near-real-time streaming effect.
    private func startExternalStreamPolling() {
        // Cancel any existing poll task
        externalStreamPollTask?.cancel()

        let chatId = conversationId ?? conversation?.id
        externalStreamPollTask = Task { @MainActor [weak self] in
            guard let self, let chatId, let manager = self.manager else { return }

            // Initial fetch to pick up new messages (user + assistant from website)
            do {
                let serverConv = try await manager.fetchConversation(id: chatId)
                self.adoptServerMessages(serverConversation: serverConv)
                // Mark last assistant as streaming for UI
                if let lastIdx = self.conversation?.messages.lastIndex(where: { $0.role == .assistant }) {
                    self.conversation?.messages[lastIdx].isStreaming = true
                }
            } catch {
                self.logger.warning("External stream initial fetch failed: \(error.localizedDescription)")
            }

            while !Task.isCancelled && self.isExternallyStreaming {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, self.isExternallyStreaming else { break }

                do {
                    let serverConv = try await manager.fetchConversation(id: chatId)
                    if let serverAssistant = serverConv.messages.last(where: { $0.role == .assistant }),
                       let localIdx = self.conversation?.messages.firstIndex(where: { $0.id == serverAssistant.id }) {
                        self.conversation?.messages[localIdx].content = serverAssistant.content
                        self.conversation?.messages[localIdx].isStreaming = true
                    }
                    // Also update title if changed
                    if !serverConv.title.isEmpty && serverConv.title != "New Chat" {
                        self.conversation?.title = serverConv.title
                    }
                } catch {
                    self.logger.warning("External stream poll failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stops the external stream polling loop and does a final sync.
    private func stopExternalStreamPolling() {
        externalStreamPollTask?.cancel()
        externalStreamPollTask = nil
        isExternallyStreaming = false
                isStreaming = false

        // Mark last assistant as not streaming
        if let lastIdx = conversation?.messages.lastIndex(where: { $0.role == .assistant }) {
            conversation?.messages[lastIdx].isStreaming = false
        }

        logger.info("External stream completed — final sync")

        // Final sync to pick up complete content, files, sources
        let chatId = conversationId ?? conversation?.id
        if let chatId {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let manager = self.manager else { return }
                if let serverConv = try? await manager.fetchConversation(id: chatId) {
                    self.adoptServerMessages(serverConversation: serverConv)
                }
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            }
        }
    }

    // MARK: - New Conversation

    func startNewConversation() {
        conversation = nil
        inputText = ""
        attachments = []
        errorMessage = nil
        cleanupStreaming()
        webSearchEnabled = false
        imageGenerationEnabled = false
        codeInterpreterEnabled = false
        isTemporaryChat = UserDefaults.standard.bool(forKey: "temporaryChatDefault")
        userDisabledToolIds = []
        userDisabledBuiltinFeatures = []
        selectedToolIds = []
        selectedKnowledgeItems = []
        selectedSkillIds = []
        // Sync UI toggles with the selected model's server-configured defaults.
        syncUIWithModelDefaults()
    }

    /// `true` while `saveTemporaryChat()` is in-flight — used to show a loading state.
    var isSavingTemporaryChat: Bool = false

    /// Converts a temporary chat into a permanent one using a single
    /// `POST /api/v1/chats/new` call with the full chat payload (history tree +
    /// flat messages array), mirroring the web UI "save temp chat" flow exactly.
    ///
    /// After success:
    /// - `conversation.id` is updated to the server-assigned ID in-place
    /// - `isTemporaryChat` is set to `false`
    /// - `conversationListNeedsRefresh` is posted so the sidebar picks up the new chat
    ///
    /// The view stays in place — no navigation happens — so there is zero visual glitch.
    func saveTemporaryChat() async {
        guard isTemporaryChat, let conversation, let manager else { return }
        guard !isSavingTemporaryChat else { return }
        isSavingTemporaryChat = true
        defer { isSavingTemporaryChat = false }

        let modelId = selectedModelId ?? conversation.model ?? ""
        // Strip the "local:" prefix to get a plain UUID for the server payload.
        // The server will assign its own ID, but we pass ours as a hint.
        let localId = conversation.id.hasPrefix("local:")
            ? String(conversation.id.dropFirst("local:".count))
            : conversation.id

        do {
            let created = try await manager.apiClient.createConversationWithHistory(
                id: localId,
                title: conversation.title,
                model: modelId.isEmpty ? nil : modelId,
                history: conversation.history,
                messages: conversation.messages,
                chatParams: conversation.chatParams,
                folderId: folderContextId
            )
            // Swap the local ID for the server-assigned one — in-place, no reload.
            self.conversation?.id = created.id
            isTemporaryChat = false
            logger.info("Temporary chat saved as permanent: \(created.id)")
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        } catch {
            logger.error("Failed to save temporary chat: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sending Messages

    /// Sends a message. When `directText` is provided (e.g. tapping a suggested
    /// starter prompt), that text is used directly and is NOT written to the
    /// bound `inputText` — this avoids the prompt briefly flashing in the input
    /// field before being sent.
    func sendMessage(directText: String? = nil) async {
        let text = (directText ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }


        // If message queue is enabled and we're currently streaming, enqueue the text
        // (only text messages can be queued — attachments are sent normally when not streaming)
        if enableMessageQueue && isStreaming && !text.isEmpty && attachments.isEmpty {
            messageQueue.append(QueuedMessage(id: UUID(), text: text))
            inputText = ""
            return
        }

        guard let manager else { return }
        // Use mentioned model (@ override) if set, otherwise the chat's selected model
        guard let modelId = mentionedModelId ?? selectedModelId else {
            errorMessage = "Please select a model first."
            return
        }

        // Process audio attachments depending on transcription mode.
        // Server mode: audio was already uploaded via /api/v1/files/?process=true —
        //   treat it like any other uploaded file (pass through with its uploadedFileId).
        // Device mode: on-device transcription produced transcribedText — convert that
        //   to a .txt file attachment so the model can read it as a document.
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        var processedAttachments: [ChatAttachment] = []

        for attachment in attachments {
            if attachment.type == .audio {
                if audioFileMode == "server" {
                    // Server already transcribed the file — pass it through so
                    // the uploadedFileId is included in the message payload.
                    processedAttachments.append(attachment)
                } else {
                    // On-device mode: convert transcription to a text file attachment.
                    if let transcript = attachment.transcribedText, !transcript.isEmpty {
                        let baseName = (attachment.name as NSString).deletingPathExtension
                        let transcriptFileName = "\(baseName)_transcript.txt"
                        let transcriptData = transcript.data(using: .utf8) ?? Data()

                        let textAttachment = ChatAttachment(
                            type: .file,
                            name: transcriptFileName,
                            thumbnail: nil,
                            data: transcriptData
                        )
                        processedAttachments.append(textAttachment)
                    }
                    // Don't include the raw audio file in device mode — only the transcript
                }
            } else {
                processedAttachments.append(attachment)
            }
        }

        // Capture and clear knowledge items — they attach to this message only.
        // The server handles RAG retrieval per-message from the files array.
        let currentKnowledgeItems = selectedKnowledgeItems
        selectedKnowledgeItems = []
        // Capture and clear reference chats — they attach to this message only.
        let currentReferenceChats = selectedReferenceChats
        selectedReferenceChats = []

        // Capture and clear notes — sent as file refs (type "note") in the API request.
        let currentNotes = selectedNotes
        selectedNotes = []

        // Capture and clear skill IDs — sent as skill_ids in the API request.
        let currentSkillIds = selectedSkillIds
        selectedSkillIds = []

        let currentText = text
        let currentAttachments = processedAttachments
        inputText = ""
        attachments = []
        errorMessage = nil

        // Build file references from pre-uploaded attachments.
        // Files are uploaded at attach time (uploadAttachmentImmediately),
        // so we just collect the already-assigned file IDs here.
        // Only fall back to uploading at send time for attachments that
        // somehow don't have a file ID yet (e.g., audio transcription text files).
        var fileRefs: [[String: Any]] = []
        for attachment in currentAttachments {
            if let fileId = attachment.uploadedFileId {
                // Already uploaded + processed — build rich web-UI-format ref
                var fileObject = attachment.uploadedFileObject ?? [:]
                let isImage = attachment.type == .image
                let contentType: String = isImage ? "image/jpeg" : mimeType(for: attachment.name)
                let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0

                // If the user chose "Using Entire Document", inject the cached extracted
                // text into data.content so the server receives the full document inline.
                if attachment.useFullContext {
                    if var dataDict = fileObject["data"] as? [String: Any] {
                        dataDict["status"] = "completed"
                        fileObject["data"] = dataDict
                    }
                }

                var ref: [String: Any] = [
                    "type": "file",
                    "file": fileObject.isEmpty ? [
                        "id": fileId,
                        "filename": attachment.name,
                        "meta": ["name": attachment.name, "content_type": contentType, "size": size]
                    ] : fileObject,
                    "id": fileId,
                    "url": fileId,
                    "name": attachment.name,
                    "status": "uploaded",
                    "size": size,
                    "error": "",
                    "content_type": contentType
                ]
                if attachment.useFullContext {
                    ref["context"] = "full"
                }
                fileRefs.append(ref)
            } else if let data = attachment.data, attachment.uploadStatus != .error {
                // Fallback: upload now (e.g., audio transcript text files that don't go
                // through uploadAttachmentImmediately). Skip attachments that previously
                // failed — the error chip is already shown; the user must retry or remove.
                do {
                    let (fileId, uploadedFileObject) = try await manager.uploadFile(data: data, fileName: attachment.name)
                    let isImage = attachment.type == .image
                    let contentType: String = isImage ? "image/jpeg" : mimeType(for: attachment.name)
                    let size: Int = (uploadedFileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0
                    var fallbackRef: [String: Any] = [
                        "type": "file",
                        "file": uploadedFileObject.isEmpty ? [
                            "id": fileId,
                            "filename": attachment.name,
                            "meta": ["name": attachment.name, "content_type": contentType, "size": size]
                        ] : uploadedFileObject,
                        "id": fileId,
                        "url": fileId,
                        "name": attachment.name,
                        "status": "uploaded",
                        "size": size,
                        "error": "",
                        "content_type": contentType
                    ]
                    if attachment.useFullContext {
                        fallbackRef["context"] = "full"
                    }
                    fileRefs.append(fallbackRef)
                } catch {
                    logger.error("Upload failed: \(error.localizedDescription)")
                }
            }
            // Note: attachments with uploadStatus == .error and no uploadedFileId are
            // intentionally skipped — they failed at attach-time and must be retried or removed.
        }

        // Create user message - store file IDs (not base64) matching Flutter behavior
        let uploadedAttachmentIds = fileRefs.compactMap { $0["id"] as? String }
        var messageFiles: [ChatMessageFile] = fileRefs.map { ref in
            // Derive content_type from filename so the Open WebUI web client
            // knows to append `/content` to the file URL. Without content_type,
            // the web client constructs `/files/{id}` (returns JSON metadata)
            // instead of `/files/{id}/content` (returns actual file bytes).
            // This affects images (broken thumbnails), PDFs, docs, and all files.
            let name = ref["name"] as? String
            let contentType: String? = mimeType(for: name ?? "file")
            return ChatMessageFile(
                type: ref["type"] as? String,
                url: ref["id"] as? String,  // Store file ID, not base64
                name: name,
                contentType: contentType
            )
        }
        // Also store knowledge items (collection/folder/file) on the user message
        // so they persist in conversation history and appear on reload.
        for knowledgeItem in currentKnowledgeItems {
            messageFiles.append(ChatMessageFile(
                type: knowledgeItem.type.rawValue,
                url: knowledgeItem.id,
                name: knowledgeItem.name,
                contentType: nil
            ))
        }
        // Store note refs on the user message so they appear as pills in the chat bubble.
        for note in currentNotes {
            let noteTitle = note.title.isEmpty ? "Untitled" : note.title
            messageFiles.append(ChatMessageFile(
                type: "note",
                url: note.id,
                name: noteTitle,
                contentType: nil
            ))
        }
        let userMessage = ChatMessage(
            role: .user,
            content: currentText,
            timestamp: .now,
            attachmentIds: uploadedAttachmentIds,
            files: messageFiles
        )

        // Capture the ID of the last message before appending the user message.
        // This becomes the user message's parentId in the history tree.
        let userMessageParentId = conversation?.messages.last?.id

        // Ensure conversation exists on server (skip for temporary chats)
        if conversation == nil {
            let chatTitle = String(currentText.prefix(50))
            var serverId: String?
            if !isTemporaryChat {
                do {
                    let created = try await manager.createConversation(
                        title: chatTitle, messages: [], model: modelId,
                        folderId: folderContextId)
                    serverId = created.id
                } catch {
                    logger.warning("Pre-create failed: \(error.localizedDescription)")
                }
            }
            let localId = isTemporaryChat ? "local:\(UUID().uuidString)" : (serverId ?? UUID().uuidString)
            var newConv = Conversation(
                id: localId,
                title: chatTitle, model: modelId, messages: [userMessage])
            // Apply any chat params that were set before the conversation existed
            if let pending = pendingChatParams {
                newConv.chatParams = pending
                pendingChatParams = nil
            }
            conversation = newConv
            // Update active conversation ID so notifications are suppressed
            // while the user is viewing this newly created chat
            NotificationService.shared.activeConversationId = localId
        } else {
            conversation?.messages.append(userMessage)
        }

        // Assistant placeholder
        let assistantMessageId = UUID().uuidString
        conversation?.messages.append(ChatMessage(
            id: assistantMessageId, role: .assistant, content: "",
            timestamp: .now, model: modelId, isStreaming: true))

        // ── Build / update the history tree ─────────────────────────────────
        // This ensures the tree is always populated with correct parentId /
        // childrenIds from the very first message, so that later calls to
        // editMessage() (which bootstraps the tree if empty) see a proper
        // branching structure instead of an orphaned root node.
        let userNodeModels = [modelId]
        let userHistoryNode = HistoryNode(
            id: userMessage.id,
            parentId: userMessageParentId,
            childrenIds: [assistantMessageId],
            role: .user,
            content: currentText,
            timestamp: userMessage.timestamp,
            files: messageFiles,
            models: userNodeModels
        )
        let assistantHistoryNode = HistoryNode(
            id: assistantMessageId,
            parentId: userMessage.id,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: userMessage.timestamp,
            model: modelId,
            done: false
        )
        conversation?.history.nodes[userMessage.id] = userHistoryNode
        conversation?.history.nodes[assistantMessageId] = assistantHistoryNode
        // Wire user node as a child of its parent (if parent exists in tree)
        if let pid = userMessageParentId {
            conversation?.history.appendChildId(userMessage.id, to: pid)
        }
        conversation?.history.currentId = assistantMessageId
        // ────────────────────────────────────────────────────────────────────

        // Build API messages with image content fetched from server
        let apiMessages = await buildAPIMessagesAsync()
        let parentId = userMessage.id
        sessionId = UUID().uuidString
        let effectiveChatId = conversationId ?? conversation?.id

        // Cancel any previous message's completion task that may still be
        // running delayed polls — prevents it from overwriting this new
        // message's content via adoptServerMessages/refreshConversationMetadata.
        completionTask?.cancel()
        completionTask = nil

        isStreaming = true
        hasFinishedStreaming = false
        socketHasReceivedContent = false
        selfInitiatedStream = true
        streamingSessionId += 1
        // Clear the replay-block for the previous completed message — a new
        // stream is starting, so the old ID is no longer relevant and we don't
        // want to accidentally block events for future messages that might
        // reuse this ID (extremely unlikely but defensive).
        lastCompletedSelfInitiatedMessageId = nil

        // Start model-switch polling if a switchStatusURL is configured.
        // Stopped automatically when the first SSE token arrives or streaming ends.
        startSwitchStatusPolling()

        // Activate the isolated streaming store so token updates bypass
        // conversation.messages and only invalidate the streaming message view.
        streamingStore.beginStreaming(messageId: assistantMessageId, modelId: modelId)

        // Ensure socket connected with resilient retry.
        // For Cloudflare-protected servers, WebSocket connections may be blocked
        // entirely. In that case, we fall back to SSE streaming (normal HTTPS).
        let socket = socketService
        // Readiness requires BOTH isConnected AND isUserJoined. A socket can be
        // "connected" while the server has not yet processed user-join and added
        // it to the user:{id} room — sending a message during that window results
        // in the server emitting completion events to an empty room, which the
        // app previously interpreted as "waiting for socket events" forever.
        var socketConnected = (socket?.isConnected ?? false) && (socket?.isUserJoined ?? false)

        if let socket, !socketConnected {
            // Show "Reconnecting..." status while we wait
            appendStatusUpdate(id: assistantMessageId,
                status: ChatStatusUpdate(action: "reconnecting", description: "Reconnecting to server…", done: false))

            // Try up to 3 times with increasing timeouts (5s, 8s, 12s)
            for (attempt, timeout) in [(1, 5.0), (2, 8.0), (3, 12.0)] as [(Int, TimeInterval)] {
                socketConnected = await socket.ensureConnected(timeout: timeout)
                if socketConnected { break }
                logger.warning("Socket connect attempt \(attempt) failed, retrying…")
            }


            if socketConnected {
                appendStatusUpdate(id: assistantMessageId,
                    status: ChatStatusUpdate(action: "reconnecting", description: "Connected", done: true))
            } else {
                // Socket failed — will use SSE fallback below
                appendStatusUpdate(id: assistantMessageId,
                    status: ChatStatusUpdate(action: "reconnecting", description: "Using direct connection", done: true))
                logger.info("Socket unavailable — falling back to SSE streaming")
            }
        }

        let useSSEFallback = !socketConnected
        let socketSessionId = socket?.sid ?? sessionId

        // Register socket handlers BEFORE HTTP POST (only if socket is connected)
        if socketConnected, let socket {
            registerSocketHandlers(
                socket: socket, assistantMessageId: assistantMessageId,
                modelId: modelId, socketSessionId: socketSessionId,
                effectiveChatId: effectiveChatId)
        }

        // Sync conversation to server — this writes the complete message tree
        // (with proper parentId/childrenIds) so the server has the full branching
        // structure before the generation starts. Uses tree-based sync now that the
        // history tree is always populated in sendMessage().
        await syncToServerViaTree()

        // Send message to server. When socket is connected, use HTTP POST + socket events.
        // When socket is unavailable (e.g., Cloudflare blocking WebSocket), fall back to
        // SSE streaming which uses normal HTTPS and passes through CF with cookie + UA.
        let capturedUseSSEFallback = useSSEFallback
        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = ChatCompletionRequest(
                    model: modelId, messages: apiMessages, stream: true,
                    chatId: effectiveChatId, sessionId: socketSessionId,
                    messageId: assistantMessageId, parentId: parentId)

                // Merge file attachment refs + knowledge item refs into request.files
                var allFileRefs = fileRefs
                for knowledgeItem in currentKnowledgeItems {
                    allFileRefs.append(knowledgeItem.toChatFileRef())
                }
                for refChat in currentReferenceChats {
                    allFileRefs.append(refChat.toChatFileRef())
                }
                for note in currentNotes {
                    let noteTitle = note.title.isEmpty ? "Untitled" : note.title
                    allFileRefs.append([
                        "type": "note",
                        "id": note.id,
                        "name": noteTitle,
                        "data": ["content": ["md": note.content]],
                        "status": "processed"
                    ])
                }

                // Snapshot the current-message-only file refs before merging history.
                // userMsgDict["files"] must only contain files the user actually attached
                // to THIS message — otherwise every follow-up message would visually
                // show the previous attachments as its own attachment pills.
                let currentMsgFileRefs = allFileRefs

                // Also include file refs from ALL prior user messages so the server
                // continues RAG retrieval for documents attached in earlier turns.
                // This mirrors the OpenWebUI web client which always sends the full
                // accumulated file list — without this, the AI "forgets" attachments
                // after the first reply.
                // NOTE: History refs go into request.files only, NOT into userMsgDict["files"].
                let historyFileRefs = await self.collectHistoryFileRefs(excludingId: userMessage.id)
                var allFileRefsForRAG = allFileRefs
                for ref in historyFileRefs {
                    guard let refId = ref["id"] as? String else { continue }
                    if !allFileRefsForRAG.contains(where: { ($0["id"] as? String) == refId }) {
                        allFileRefsForRAG.append(ref)
                    }
                }

                if !allFileRefsForRAG.isEmpty { request.files = allFileRefsForRAG }

                // Build the user_message node required by updated OpenWebUI servers.
                // Without this, the server doesn't link the user message into the history
                // tree, causing it to disappear when the chat is re-opened.
                // Only include THIS message's own files here — not history refs.
                var userMsgDict: [String: Any] = [
                    "id": userMessage.id,
                    "parentId": (userMessageParentId as Any?) ?? NSNull(),
                    "childrenIds": [assistantMessageId],
                    "role": "user",
                    "content": currentText,
                    "timestamp": Int(userMessage.timestamp.timeIntervalSince1970),
                    "models": [modelId]
                ]
                if !currentMsgFileRefs.isEmpty { userMsgDict["files"] = currentMsgFileRefs }
                request.userMessage = userMsgDict

                // Populate all common request fields (model metadata, features, params,
                // system variables, tool IDs, terminal, background tasks, etc.)
                await self.populateCommonRequestFields(&request)

                // Include skill IDs selected via the `$` picker.
                // Sent as `skill_ids` in the top-level request body (separate from tool_ids).
                if !currentSkillIds.isEmpty { request.skillIds = currentSkillIds }

                if capturedUseSSEFallback {
                    // ── HTTP + POLLING FALLBACK ──
                    // Socket.IO is unavailable (e.g., Cloudflare blocks WebSocket).
                    // OpenWebUI delivers content via socket events, not SSE — so we
                    // use HTTP POST + aggressive server polling to pick up content
                    // in near-real-time. Poll every 1.5s with no initial delay.
                    self.logger.info("Using HTTP + polling fallback (no socket)")
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }
                    if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: detail))
                        self.cleanupStreaming()
                        return
                    }
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    // Aggressive polling: start immediately, poll every 1.5s
                    // Content is being generated server-side and persisted to DB
                    // in real-time. Each poll picks up the latest accumulated text.
                    self.logger.info("HTTP POST done – starting aggressive polling (no socket)")
                    guard let chatId = effectiveChatId else {
                        self.cleanupStreaming()
                        return
                    }
                    var lastContentLength = 0
                    var staleCount = 0
                    for _ in 0..<40 { // up to ~60s of polling
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if Task.isCancelled { break }

                        do {
                            let refreshed = try await manager.fetchConversation(id: chatId)
                            if let serverAssistant = refreshed.messages.last(where: { $0.role == .assistant }) {
                                let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !serverContent.isEmpty {
                                    self.updateAssistantMessage(id: assistantMessageId, content: serverAssistant.content, isStreaming: true)
                                    // Check if content is still growing
                                    if serverContent.count > lastContentLength {
                                        lastContentLength = serverContent.count
                                        staleCount = 0
                                    } else {
                                        staleCount += 1
                                    }
                                    // If content hasn't changed for 3 consecutive polls (4.5s), it's done
                                    if staleCount >= 3 {
                                        self.logger.info("Polling: content stable at \(serverContent.count) chars — finalizing")
                                        self.updateAssistantMessage(id: assistantMessageId, content: serverAssistant.content, isStreaming: false)
                                        self.hasFinishedStreaming = true
                                        self.isStreaming = false
                                        // Post-completion
                                        self.adoptServerMessages(serverConversation: refreshed)
                                        await manager.sendChatCompleted(chatId: chatId, messageId: assistantMessageId, model: modelId, sessionId: socketSessionId, messages: self.buildSimpleAPIMessages())
                                        try? await self.refreshConversationMetadata(chatId: chatId, assistantMessageId: assistantMessageId)
                                        self.cleanupStreaming()
                                        await self.sendCompletionNotificationIfNeeded(content: serverContent)
                                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                                        return
                                    }
                                }
                            }
                        } catch {
                            self.logger.warning("Polling failed: \(error.localizedDescription)")
                        }
                    }
                    // Polling exhausted — finalize with whatever we have
                    self.updateAssistantMessage(id: assistantMessageId,
                        content: self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? "",
                        isStreaming: false)
                    self.cleanupStreaming()
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                } else {
                    // ── SOCKET PATH (normal) ──
                    // HTTP POST returns immediately; content delivered via socket events
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }
                    if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: detail))
                        self.cleanupStreaming()
                        return
                    }

                    // Capture the server's task_id for server-side stop
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    self.logger.info("HTTP POST done – waiting for socket events")
                    self.startRecoveryTimer(assistantMessageId: assistantMessageId, chatId: effectiveChatId)
                }
            } catch {
                if !Task.isCancelled {
                    self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                 isStreaming: false,
                                                 error: ChatMessageError(content: error.localizedDescription))
                    self.cleanupStreaming()
                }
            }
        }
    }

    /// Stops the current streaming response by cancelling the server-side task
    /// via `/api/tasks/stop/{taskId}` and cleaning up local state.
    func stopStreaming() {
        // Cancel the local HTTP task
        streamingTask?.cancel()
        streamingTask = nil

        // Stop the server-side task.
        // For self-initiated streams we already have the task_id from the HTTP POST response.
        // For externally-initiated streams (another device/browser) activeTaskId is nil,
        // so we query /api/tasks/chat/{chat_id} to discover and stop all active tasks.
        let chatId = conversationId ?? conversation?.id
        if let taskId = activeTaskId, let apiClient = manager?.apiClient {
            Task {
                try? await apiClient.stopTask(taskId: taskId)
                logger.info("Server task stopped: \(taskId)")
            }
        } else if let chatId, let apiClient = manager?.apiClient {
            Task {
                do {
                    try await apiClient.stopTasksByChatId(chatId: chatId)
                    logger.info("All external server tasks stopped for chat: \(chatId)")
                } catch {
                    logger.warning("Failed to stop tasks for chat \(chatId): \(error.localizedDescription)")
                }
            }
        }

        // Flush streaming store content back to conversation.messages
        // before cleanup so the partial content is preserved for server sync.
        if streamingStore.isActive, let msgId = streamingStore.streamingMessageId,
           let idx = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
            let result = streamingStore.abortStreaming()
            conversation?.messages[idx].content = result.content
            conversation?.messages[idx].isStreaming = false
            if !result.statusHistory.isEmpty {
                conversation?.messages[idx].statusHistory = result.statusHistory
            }
            if !result.sources.isEmpty {
                conversation?.messages[idx].sources = result.sources
            }
            // Also write partial content into the history tree node so that
            // when regenerateResponse() later calls rederiveMessages() (which
            // rebuilds the flat list FROM the tree), the stopped version
            // retains its partial content instead of showing empty.
            conversation?.history.updateNode(id: msgId) { node in
                node.content = result.content
                if !result.statusHistory.isEmpty {
                    node.statusHistory = result.statusHistory
                }
                if !result.sources.isEmpty {
                    node.sources = result.sources
                }
            }
        } else if let idx = conversation?.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            conversation?.messages[idx].isStreaming = false
        }

        cleanupStreaming()

        // Sync partial content to server so the chat isn't blank.
        // Use tree-based sync so the history node (with partial content) is
        // what gets persisted — this ensures version switching works correctly.
        Task {
            await self.syncToServerViaTree()
        }
    }

    /// Regenerates the last assistant response. Convenience wrapper
    /// around ``regenerateResponse(messageId:)`` for the most common case.
    func regenerateLastResponse() async {
        guard let lastAssistant = conversation?.messages.last(where: { $0.role == .assistant }) else { return }
        await regenerateResponse(messageId: lastAssistant.id)
    }

    /// Forks (clones) the current conversation by calling POST /api/v1/chats/{id}/clone,
    /// then navigates to the newly created chat via the .adminClonedChat notification.
    /// Matches open-webui's fork behaviour exactly.
    func forkChat(messageId: String) async {
        guard let chatId = conversationId ?? conversation?.id,
              let manager else { return }
        isForkingChat = true
        defer { Task { @MainActor in self.isForkingChat = false } }
        do {
            let cloned = try await manager.forkConversation(id: chatId, messageId: messageId)
            let clonedId = cloned.id
            NotificationCenter.default.post(
                name: .adminClonedChat,
                object: clonedId
            )
        } catch {
            // silent failure — forking is non-destructive; user can retry
        }
    }

    /// Continues the last assistant response by appending new tokens to the existing content.
    ///
    /// Mirrors OpenWebUI's `continueResponse()` — it reuses the **same message ID**, does
    /// NOT create a new history node, and passes `assistant_message_id` in the request so
    /// the server knows to prefix its output with the existing message content.
    ///
    /// The streaming pipeline is pre-seeded with the existing content so the typewriter
    /// starts at the END of what's already displayed — old content is never re-streamed.
    func continueLastResponse() async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard let lastAssistant = conversation?.messages.last(where: { $0.role == .assistant }) else { return }
        let assistantId = lastAssistant.id
        let existingContent = lastAssistant.content

        let modelId = lastAssistant.model ?? selectedModelId ?? conversation?.model ?? ""
        guard let lastUser = conversation?.messages.last(where: { $0.role == .user }) else { return }

        let apiMessages = await buildAPIMessagesAsync()
        let parentId = lastUser.id
        let effectiveChatId = conversationId ?? conversation?.id

        // Cancel any background completion task from the previous message's streaming.
        // Without this, the delayed metadata refreshes (1.5s + 2/3/5s file polls)
        // from the just-finished response will call updateAssistantMessage(isStreaming:false)
        // on the same message ID during the continue — triggering endStreaming() mid-continue
        // and replacing the content with only the new server tokens.
        completionTask?.cancel()
        completionTask = nil

        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        regenerateScrollToken = UUID()

        // Mark message as streaming and keep existing content visible.
        if let idx = conversation?.messages.firstIndex(where: { $0.id == assistantId }) {
            conversation?.messages[idx].isStreaming = true
        }

        // Pre-seed the pipeline so the typewriter starts AFTER the existing content.
        // Only new tokens from the server will be revealed — old content is not re-streamed.
        streamingStore.beginStreamingForContinue(
            messageId: assistantId,
            modelId: modelId,
            existingContent: existingContent
        )

        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil

        guard let socket = socketService else {
            updateAssistantMessage(id: assistantId, content: existingContent,
                                   isStreaming: false, error: ChatMessageError(content: "No connection available."))
            isStreaming = false
            return
        }
        if !socket.isConnected {
            let ok = await socket.ensureConnected(timeout: 10.0)
            if !ok {
                updateAssistantMessage(id: assistantId, content: existingContent,
                    isStreaming: false, error: ChatMessageError(content: "Connection failed"))
                isStreaming = false
                return
            }
        }

        sessionId = UUID().uuidString
        let socketSessionId = socket.sid ?? sessionId

        await syncToServerViaTree()

        registerSocketHandlers(
            socket: socket, assistantMessageId: assistantId,
            modelId: modelId, socketSessionId: socketSessionId,
            effectiveChatId: effectiveChatId,
            continuePrefix: existingContent)

        streamingTask = Task { [weak self] in
            guard let self, let manager = self.manager else { return }
            do {
                var request = ChatCompletionRequest(
                    model: modelId, messages: apiMessages, stream: true,
                    chatId: effectiveChatId, sessionId: socketSessionId,
                    messageId: assistantId, parentId: parentId)

                // Tell the server to continue from the existing message content.
                request.assistantMessageId = assistantId

                // Build user_message node.
                let userNodeParentId: String? = {
                    guard let idx = self.conversation?.messages.firstIndex(where: { $0.id == lastUser.id }),
                          idx > 0 else { return nil }
                    return self.conversation?.messages[idx - 1].id
                }()
                let allChildIds = self.conversation?.history.nodes[parentId]?.childrenIds ?? [assistantId]
                let userMsgDict: [String: Any] = [
                    "id": parentId,
                    "parentId": (userNodeParentId as Any?) ?? NSNull(),
                    "childrenIds": allChildIds,
                    "role": "user",
                    "content": lastUser.content,
                    "timestamp": Int(lastUser.timestamp.timeIntervalSince1970),
                    "models": [modelId]
                ]
                request.userMessage = userMsgDict

                await self.populateCommonRequestFields(&request)

                let json = try await manager.sendMessageHTTP(request: request)

                if let err = json["error"] as? String, !err.isEmpty {
                    self.updateAssistantMessage(id: assistantId, content: existingContent,
                                                isStreaming: false, error: ChatMessageError(content: err))
                    self.cleanupStreaming()
                    return
                }
                if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                    self.updateAssistantMessage(id: assistantId, content: existingContent,
                                                isStreaming: false, error: ChatMessageError(content: detail))
                    self.cleanupStreaming()
                    return
                }

                if let taskId = json["task_id"] as? String {
                    self.activeTaskId = taskId
                }

                self.logger.info("Continue HTTP POST done – waiting for socket events")
            } catch {
                if !Task.isCancelled {
                    self.updateAssistantMessage(id: assistantId, content: existingContent,
                                                isStreaming: false,
                                                error: ChatMessageError(content: error.localizedDescription))
                    self.cleanupStreaming()
                }
            }
        }
    }

    /// Regenerates a specific assistant response by its message ID.
    ///
    /// If the targeted message is NOT the last assistant message, all messages
    /// after it are removed first (truncating the conversation to that point),
    /// matching the OpenWebUI web client's regeneration behavior for mid-conversation
    /// messages.
    func regenerateResponse(messageId: String) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard conversation != nil else { return }

        // Cancel any in-flight completion task from the previous stream.
        // Without this, sendMessage's completionTask continues running its
        // delayed polls (1.5 s, 2 s, 3 s, 5 s) and keeps capturedChatSub
        // alive. Both the old and new subscriptions share the same socket
        // session, so the old task receives follow-up events and routes them
        // to the WRONG (old) assistant message ID — and its eventual
        // capturedChatSub?.dispose() can tear down the new stream's socket
        // delivery mid-flight.
        completionTask?.cancel()
        completionTask = nil

        // ── Tree-first regeneration (replicates OpenWebUI exactly) ──────────
        // 1. Look up the old assistant node in the history tree.
        //    If the tree isn't populated yet, bootstrap it from the flat list.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }
        guard let oldNode = conversation!.history.nodes[messageId], oldNode.role == .assistant else { return }

        // 2. The parent of the old assistant node (the user message).
        guard let parentId = oldNode.parentId else {
            // Root-level assistant with no parent — can't regenerate without a user message
            return
        }

        // 3. Create a NEW assistant placeholder node (new UUID) as a sibling of the old one.
        //    Both are children of the same user node.
        let newAssistantId = UUID().uuidString
        let modelId = selectedModelId ?? conversation?.model ?? ""
        let newAssistantNode = HistoryNode(
            id: newAssistantId,
            parentId: parentId,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: .now,
            model: modelId,
            done: false
        )
        conversation!.history.nodes[newAssistantId] = newAssistantNode

        // 4. Add the new assistant as a child of the user node (sibling to old assistant).
        if conversation!.history.nodes[parentId] != nil {
            if !conversation!.history.nodes[parentId]!.childrenIds.contains(newAssistantId) {
                conversation!.history.nodes[parentId]!.childrenIds.append(newAssistantId)
            }
        }

        // 5. Update currentId to the new assistant.
        conversation!.history.currentId = newAssistantId

        // 6. Re-derive the flat messages list from the tree.
        conversation!.rederiveMessages()

        // Mark the new assistant message as streaming so the DRAIN-DEFERRAL
        // system works correctly (rederiveMessages() rebuilds from HistoryNode
        // which has no isStreaming field, so it defaults to false).
        if let idx = conversation?.messages.firstIndex(where: { $0.id == newAssistantId }) {
            conversation?.messages[idx].isStreaming = true
        }

        // Reset the task list — the new regen branch starts with no tasks.
        tasks = []
        conversation?.tasks = []

        // 7. Sync to server via tree-based API before streaming.
        await syncToServerViaTree()

        // 8. Get the user message (parentId) for the API messages build.
        guard conversation?.messages.contains(where: { $0.role == .user }) == true else { return }
        let apiMessages = await buildAPIMessagesAsync()
        let effectiveChatId = conversationId ?? conversation?.id
        sessionId = UUID().uuidString

        // Reset streaming state
        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true

        // Bump scroll token so ChatDetailView scrolls to the regenerating message
        regenerateScrollToken = UUID()

        // Activate the isolated streaming store for the regenerated message
        streamingStore.beginStreaming(messageId: newAssistantId, modelId: modelId)

        // Cancel any previous subscriptions/timers
        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil

        guard let socket = socketService else {
            updateAssistantMessage(id: newAssistantId, content: "No connection available.",
                                   isStreaming: false, error: ChatMessageError(content: "No socket"))
            isStreaming = false
            return
        }
        if !socket.isConnected {
            let ok = await socket.ensureConnected(timeout: 10.0)
            if !ok {
                updateAssistantMessage(
                    id: newAssistantId,
                    content: "Unable to connect. Check your connection.",
                    isStreaming: false,
                    error: ChatMessageError(content: "Connection failed"))
                isStreaming = false
                return
            }
        }

        let socketSessionId = socket.sid ?? sessionId

        // Get the user message node to build user_message dict for the request.
        // The parentId of the new assistant IS the user message ID.
        guard let userNode = conversation!.history.nodes[parentId] else { return }

        registerSocketHandlers(
            socket: socket, assistantMessageId: newAssistantId,
            modelId: modelId, socketSessionId: socketSessionId,
            effectiveChatId: effectiveChatId)

        let capturedNewAssistantId = newAssistantId
        let capturedParentId = parentId
        let capturedUserNode = userNode

        streamingTask = Task { [weak self] in
            guard let self, let manager = self.manager else { return }
            do {
                var request = ChatCompletionRequest(
                    model: modelId, messages: apiMessages, stream: true,
                    chatId: effectiveChatId, sessionId: socketSessionId,
                    messageId: capturedNewAssistantId, parentId: capturedParentId)

                // Build the user_message node for the server's history tree.
                // childrenIds = all children of the user node (includes old + new assistant).
                let allChildrenIds = self.conversation?.history.nodes[capturedParentId]?.childrenIds ?? [capturedNewAssistantId]
                let userGrandParentId = capturedUserNode.parentId
                let userMsgDict: [String: Any] = [
                    "id": capturedParentId,
                    "parentId": (userGrandParentId as Any?) ?? NSNull(),
                    "childrenIds": allChildrenIds,
                    "role": "user",
                    "content": capturedUserNode.content,
                    "timestamp": Int(capturedUserNode.timestamp.timeIntervalSince1970),
                    "models": capturedUserNode.models.isEmpty ? [modelId] : capturedUserNode.models
                ]
                request.userMessage = userMsgDict

                // Re-include files (notes, knowledge, uploaded files) from the original user node,
                // plus files from ALL other user messages so the server keeps RAG active.
                let capturedNotesManager = self.notesManager
                var fileRefs: [[String: Any]] = []
                for storedFile in capturedUserNode.files {
                    guard let fileId = storedFile.url else { continue }
                    if storedFile.type == "note" {
                        var ref: [String: Any] = [
                            "type": "note",
                            "id": fileId,
                            "name": storedFile.name ?? "Note",
                            "status": "processed"
                        ]
                        if let note = await capturedNotesManager?.fetchNote(id: fileId) {
                            ref["data"] = ["content": ["md": note.content]]
                        }
                        fileRefs.append(ref)
                    } else if storedFile.type == "collection" {
                        fileRefs.append([
                            "type": "collection",
                            "id": fileId,
                            "name": storedFile.name ?? fileId
                        ])
                    } else {
                        var ref: [String: Any] = ["type": storedFile.type ?? "file", "id": fileId]
                        if let name = storedFile.name { ref["name"] = name }
                        if let ct = storedFile.contentType { ref["content_type"] = ct }
                        fileRefs.append(ref)
                    }
                }
                // Merge in file refs from all other user messages (deduped by id).
                let historyFileRefsRegen = await self.collectHistoryFileRefs(excludingId: capturedUserNode.id)
                for ref in historyFileRefsRegen {
                    guard let refId = ref["id"] as? String else { continue }
                    if !fileRefs.contains(where: { ($0["id"] as? String) == refId }) {
                        fileRefs.append(ref)
                    }
                }
                if !fileRefs.isEmpty { request.files = fileRefs }

                // Populate all common request fields
                await self.populateCommonRequestFields(&request)

                let json = try await manager.sendMessageHTTP(request: request)

                if let err = json["error"] as? String, !err.isEmpty {
                    self.updateAssistantMessage(id: capturedNewAssistantId, content: "",
                                                 isStreaming: false, error: ChatMessageError(content: err))
                    self.cleanupStreaming()
                    return
                }
                if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                    self.updateAssistantMessage(id: capturedNewAssistantId, content: "",
                                                 isStreaming: false, error: ChatMessageError(content: detail))
                    self.cleanupStreaming()
                    return
                }

                // Capture the server's task_id for server-side stop
                if let taskId = json["task_id"] as? String {
                    self.activeTaskId = taskId
                }

                self.logger.info("Regenerate HTTP POST done – waiting for socket events")
            } catch {
                if !Task.isCancelled {
                    self.updateAssistantMessage(id: capturedNewAssistantId, content: "",
                                                 isStreaming: false,
                                                 error: ChatMessageError(content: error.localizedDescription))
                    self.cleanupStreaming()
                }
            }
        }
    }

    func selectModel(_ modelId: String) {
        selectedModelId = modelId
        // Switching models is a deliberate user action — reset disabled tools
        // so the new model's defaults apply cleanly without stale overrides.
        userDisabledToolIds = []
        userDisabledBuiltinFeatures = []
        syncUIWithModelDefaults()
        conversation?.model = modelId
        // Fetch full model config from single-model endpoint to get params.function_calling,
        // toolIds, defaultFeatureIds, and capabilities — which /api/models doesn't return.
        // Store the task so sendMessage/regenerate can await it if the user sends
        // before this completes.
        modelConfigTask?.cancel()
        modelConfigTask = Task { [weak self] in
            await self?.refreshSelectedModelConfig()
        }
    }

    // MARK: - Edit & Delete Messages

    /// Edits a user message by creating a proper new branch.
    ///
    /// This matches OpenWebUI's tree model exactly:
    /// - The OLD user message becomes a "version" (sibling node) storing its content,
    ///   the old assistant response, any regeneration versions on that assistant,
    ///   and ALL downstream messages (messages after the user+assistant pair).
    /// - A NEW assistant message is created with a NEW UUID (not reused) so that
    ///   the WebUI tree has distinct nodes for each branch.
    /// - The current flat list is updated to show: existing messages up to and
    ///   including the (mutated) user message + new assistant placeholder.
    ///
    /// This ensures:
    /// - AI version indicators only show on their own branch's assistant
    /// - WebUI can navigate branches (each branch has unique assistant IDs)
    /// - Switching back to an old branch restores all downstream messages
    /// Edits a user message. If `files` is provided, the new node uses those
    /// files (allowing attachment removal); otherwise it inherits the original
    /// node's files unchanged.
    func editMessage(id: String, newContent: String, files: [ChatMessageFile]? = nil) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard conversation != nil else { return }

        // ── Tree-first edit (replicates OpenWebUI exactly) ─────────────────
        // 1. Look up the old user node in the history tree.
        //    If the tree isn't populated yet, bootstrap it from the flat list.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }
        guard let oldNode = conversation!.history.nodes[id], oldNode.role == .user else { return }

        // 2. The parent of the old user node (an assistant node, or nil for root).
        let parentId = oldNode.parentId

        // 3. Create a NEW user node (new UUID) with the edited content.
        //    This is a sibling of the old user node under the same parent.
        //    Use caller-provided files if given (e.g. after removing an attachment),
        //    otherwise inherit from the original node.
        let newUserId = UUID().uuidString
        let newUserNode = HistoryNode(
            id: newUserId,
            parentId: parentId,
            childrenIds: [],   // will get the assistant ID below
            role: .user,
            content: newContent,
            timestamp: .now,
            files: files ?? oldNode.files,
            models: oldNode.models
        )

        conversation!.history.nodes[newUserId] = newUserNode

        // 4. Add the new user node as a child of the parent (if parent exists).
        if let pid = parentId {
            if conversation!.history.nodes[pid] != nil {
                if !(conversation!.history.nodes[pid]!.childrenIds.contains(newUserId)) {
                    conversation!.history.nodes[pid]!.childrenIds.append(newUserId)
                }
            }
        }
        // For root-level user edits (parentId == nil), both nodes are root siblings.
        // The server treats all null-parentId nodes as root siblings automatically.

        // 5. Create a NEW assistant placeholder node.
        let newAssistantId = UUID().uuidString
        let assistantModel = selectedModelId ?? conversation?.model ?? ""
        let newAssistantNode = HistoryNode(
            id: newAssistantId,
            parentId: newUserId,
            childrenIds: [],
            role: .assistant,
            content: "",
            timestamp: .now,
            model: assistantModel,
            done: false
        )
        conversation!.history.nodes[newAssistantId] = newAssistantNode

        // 6. Wire the assistant as a child of the new user node.
        conversation!.history.nodes[newUserId]!.childrenIds.append(newAssistantId)

        // 7. Update currentId to the new assistant (deepest leaf of the new branch).
        conversation!.history.currentId = newAssistantId

        // 8. Re-derive the flat messages list from the tree.
        conversation!.rederiveMessages()

        // Reset the task list — the new edit branch starts fresh.
        tasks = []
        conversation?.tasks = []

        // 9. Sync to server via tree-based API (lossless, no buildChatPayload).
        await syncToServerViaTree()

        // 10. Stream the AI response into the new assistant placeholder.
        await regenerateIntoExistingMessage(assistantMessageId: newAssistantId)
    }

    /// Saves an edited assistant message content **in-place** — no new branch, no regeneration.
    ///
    /// Mirrors the WebUI `editMessage(id, { content }, false)` call used when the user
    /// edits an assistant response and saves without regenerating (the third argument `false`
    /// means "don't create a new message pair, just update the content in the tree").
    ///
    /// Flow:
    /// 1. Update the message content in the flat messages array (immediate UI update).
    /// 2. Update the history tree node so `syncToServerViaTree()` gets the correct content.
    /// 3. Sync to the server via `syncToServerViaTree()` → `PUT /api/v1/chats/{id}`.
    /// Saves an edited assistant message content **in-place** — no new branch, no regeneration.
    ///
    /// Mirrors the WebUI `editMessage(id, { content }, false)` call used when the user
    /// edits an assistant response and saves without regenerating (the third argument `false`
    /// means "don't create a new message pair, just update the content in the tree").
    ///
    /// Flow:
    /// 1. Update the message content in the flat messages array (immediate UI update).
    /// 2. Update the history tree node so the sync carries the correct content.
    /// 3. Persist via `saveConversationToServer()` — this sends the full chat payload
    ///    (history tree + flat messages) to `PUT /api/v1/chats/{id}`, matching exactly
    ///    what the WebUI does: it sends the complete `chat` object including both
    ///    `history.messages` (tree) and `messages` (flat array) in a single PUT call.
    func saveAssistantMessageContent(id: String, newContent: String) async {
        guard conversation != nil else { return }

        // 1. Update in the flat messages array for immediate UI refresh.
        if let idx = conversation!.messages.firstIndex(where: { $0.id == id }) {
            conversation!.messages[idx].content = newContent
        }

        // 2. Ensure tree is populated, then update the node content directly.
        //    WebUI writes: history.messages[id].content = messageContent into its store.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }
        if conversation!.history.nodes[id] != nil {
            conversation!.history.nodes[id]!.content = newContent
            conversation!.history.nodes[id]!.done = true
        }

        // 3. Persist the full chat to the server.
        //    saveConversationToServer() calls manager.saveConversation(conversation)
        //    which sends the complete payload — both history tree and flat messages —
        //    to PUT /api/v1/chats/{id}, matching WebUI's updateChatById() call exactly.
        await saveConversationToServer()
    }

    /// Restores an old user message branch by switching `history.currentId` to the
    /// selected sibling's deepest leaf, then re-deriving the flat message list from
    /// the tree. Matches OpenWebUI's `showMessage()` function exactly.
    ///
    /// - Parameters:
    ///   - userMessageId: The ID of the user message currently on the active branch.
    ///   - version: The sibling version to switch to (nil = latest / `userMessageId` itself).
    func restoreUserVersion(userMessageId: String, version: ChatMessageVersion?) {
        guard conversation != nil else { return }

        // Determine the target user node to switch to.
        // `version.id` is the sibling user node the user wants to view.
        // nil means "go back to the current/latest user node".
        let targetUserId = version?.id ?? userMessageId

        // Ensure the tree is populated.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        // Walk to the deepest leaf of the target user node's branch and set currentId.
        let leaf = conversation!.history.deepestLeaf(from: targetUserId)
        conversation!.history.currentId = leaf

        // Re-derive the flat message list from the new active branch.
        conversation!.rederiveMessages()

        // Navigation-only: use syncCurrentIdToServer to avoid corrupting tree order.
        Task { await syncCurrentIdToServer() }
    }

    /// Navigates to a specific assistant regeneration version by switching
    /// `history.currentId` to the selected sibling's deepest leaf, then
    /// re-deriving the flat message list from the tree.
    ///
    /// Matches OpenWebUI's `showMessage()` function: change currentId, re-derive.
    ///
    /// - Parameters:
    ///   - assistantMessageId: The ID of the assistant message currently active.
    ///   - versionIndex: -1 = stay on current (`assistantMessageId`), 0...N-1 = sibling version
    func restoreAssistantVersion(assistantMessageId: String, versionIndex: Int) {
        guard conversation != nil else { return }

        // Ensure the tree is populated.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        // Determine the target assistant node ID.
        // versionIndex == -1: stay on the current node (assistantMessageId).
        // versionIndex >= 0: switch to that sibling from message.versions[].id
        let targetAssistantId: String
        if versionIndex >= 0,
           let msgIdx = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }),
           versionIndex < (conversation?.messages[msgIdx].versions.count ?? 0) {
            targetAssistantId = conversation!.messages[msgIdx].versions[versionIndex].id
        } else {
            targetAssistantId = assistantMessageId
        }

        // Walk to the deepest leaf of the target assistant node's branch and set currentId.
        let leaf = conversation!.history.deepestLeaf(from: targetAssistantId)
        conversation!.history.currentId = leaf

        // Re-derive the flat message list from the new active branch, animated so
        // SwiftUI cross-fades the changed rows instead of abruptly swapping them.
        withAnimation(.easeInOut(duration: 0.2)) {
            conversation!.rederiveMessages()
        }

        // Navigation-only: use syncCurrentIdToServer to avoid corrupting tree order.
        Task { await syncCurrentIdToServer() }
    }

    /// Navigates to a specific assistant version by its sibling node ID directly.
    ///
    /// This is the preferred navigation method for the UI ← → version arrows.
    /// Unlike `restoreAssistantVersion(versionIndex:)`, this does NOT depend on
    /// `message.versions[]` index arithmetic — it works correctly regardless of
    /// which sibling is currently the "main" message (i.e. after any branch switch
    /// that rebuilds the flat message list via `rederiveMessages()`).
    ///
    /// - Parameters:
    ///   - targetSiblingId: The ID of the sibling assistant node to switch to.
    func restoreAssistantVersionById(targetSiblingId: String) {
        guard conversation != nil else { return }

        // Ensure the tree is populated.
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        // Walk to the deepest leaf of the target node and set currentId.
        let leaf = conversation!.history.deepestLeaf(from: targetSiblingId)
        conversation!.history.currentId = leaf

        // Re-derive the flat message list from the new active branch, animated so
        // SwiftUI cross-fades the changed rows instead of abruptly swapping them.
        withAnimation(.easeInOut(duration: 0.2)) {
            conversation!.rederiveMessages()
            // Re-extract image/file URLs from tool-call blocks in the switched message's
            // content. These URLs live inside <details type="tool_calls"> and are not stored
            // in node.files on the server, so they must be re-parsed after every version switch.
            populateFilesFromToolResults(messageId: targetSiblingId)
            if leaf != targetSiblingId {
                populateFilesFromToolResults(messageId: leaf)
            }
        }

        // Sync ONLY currentId to server — do NOT call syncFlatMessagesToTreeNodes()
        // first. Version switching is navigation-only: no content changed, so copying
        // the flat list back into tree nodes would risk corrupting inactive-branch nodes.
        Task { await syncCurrentIdToServer() }
    }

    /// Navigates to a specific user version by its sibling node ID directly.
    ///
    /// This is the preferred navigation method for the UI user ← → version arrows.
    /// Unlike `restoreUserVersion(version:)`, this always switches to the target
    /// regardless of which sibling is currently the main message.
    ///
    /// - Parameters:
    ///   - targetSiblingId: The ID of the sibling user node to switch to.
    func restoreUserVersionById(targetSiblingId: String) {
        guard conversation != nil else { return }

        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        let leaf = conversation!.history.deepestLeaf(from: targetSiblingId)
        conversation!.history.currentId = leaf
        withAnimation(.easeInOut(duration: 0.2)) {
            conversation!.rederiveMessages()

            // Re-extract image/file URLs from tool-call blocks for all assistant messages
            // on the newly active branch. When switching user versions, the assistant
            // messages that follow may not have files stored in node.files (they live
            // inside <details type="tool_calls"> in the content), so we re-parse them
            // to ensure images render correctly after a user version switch.
            for msg in conversation!.messages where msg.role == .assistant {
                populateFilesFromToolResults(messageId: msg.id)
            }
        }

        // Same as restoreAssistantVersionById — navigation only, skip flat→tree copy.
        Task { await syncCurrentIdToServer() }
    }

    /// Sends the full history tree to the server WITHOUT first copying the flat
    /// message list back into tree nodes.
    ///
    /// Used exclusively by version-switch operations (restoreAssistantVersionById /
    /// restoreUserVersionById) where only `currentId` changed and all tree node
    /// content/childrenIds are already correct from the original server data.
    /// Calling syncFlatMessagesToTreeNodes() in these cases risks overwriting
    /// metadata on inactive-branch nodes with stale/empty flat-list data,
    /// which can cause the server to reorder childrenIds.
    private func syncCurrentIdToServer() async {
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }
        let modelId = selectedModelId ?? conversation?.model ?? ""

        guard let conv = conversation, conv.history.isPopulated else {
            return
        }

        try? await manager.apiClient.syncConversationHistory(
            id: chatId,
            history: conv.history,
            model: modelId,
            systemPrompt: conv.systemPrompt,
            chatParams: conv.chatParams,
            title: conv.title
        )
    }

    /// Regenerates content for an existing assistant message placeholder.
    /// Called after `editMessage()` when the assistant message already exists in the list.
    private func regenerateIntoExistingMessage(assistantMessageId: String) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard conversation?.messages.contains(where: { $0.id == assistantMessageId && $0.role == .assistant }) == true else { return }

        let modelId = selectedModelId ?? conversation?.model ?? ""
        guard let lastUser = conversation?.messages.last(where: { $0.role == .user }) else { return }

        let apiMessages = await buildAPIMessagesAsync()
        let parentId = lastUser.id
        let effectiveChatId = conversationId ?? conversation?.id

        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true
        regenerateScrollToken = UUID()

        streamingStore.beginStreaming(messageId: assistantMessageId, modelId: modelId)

        // Mark the assistant message as streaming so the DRAIN-DEFERRAL system
        // works correctly. editMessage() creates the placeholder with the default
        // isStreaming: false (rederiveMessages rebuilds from HistoryNode which has
        // no isStreaming field), bypassing the drain deferral without this.
        if let idx = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) {
            conversation?.messages[idx].isStreaming = true
        }

        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil

        guard let socket = socketService else {
            updateAssistantMessage(id: assistantMessageId, content: "No connection available.",
                                   isStreaming: false, error: ChatMessageError(content: "No socket"))
            isStreaming = false
            return
        }
        if !socket.isConnected {
            let ok = await socket.ensureConnected(timeout: 10.0)
            if !ok {
                updateAssistantMessage(id: assistantMessageId, content: "Unable to connect.",
                    isStreaming: false, error: ChatMessageError(content: "Connection failed"))
                isStreaming = false
                return
            }
        }

        sessionId = UUID().uuidString
        let socketSessionId = socket.sid ?? sessionId

        // Sync the full tree (not just the active branch flat-list) so the original
        // branch's assistant node is preserved on the server.
        await syncToServerViaTree()

        registerSocketHandlers(
            socket: socket, assistantMessageId: assistantMessageId,
            modelId: modelId, socketSessionId: socketSessionId,
            effectiveChatId: effectiveChatId)

        streamingTask = Task { [weak self] in
            guard let self, let manager = self.manager else { return }
            do {
                var request = ChatCompletionRequest(
                    model: modelId, messages: apiMessages, stream: true,
                    chatId: effectiveChatId, sessionId: socketSessionId,
                    messageId: assistantMessageId, parentId: parentId)

                // Build the user_message node for the server's history tree.
                // For edit-regeneration, the user message already exists on the server.
                let editUserParentId: String? = {
                    guard let idx = self.conversation?.messages.firstIndex(where: { $0.id == lastUser.id }),
                          idx > 0 else { return nil }
                    return self.conversation?.messages[idx - 1].id
                }()
                let editUserMsgDict: [String: Any] = [
                    "id": lastUser.id,
                    "parentId": (editUserParentId as Any?) ?? NSNull(),
                    // Send ALL children from the tree, not just the new assistant.
                    // This preserves all existing regeneration siblings on the server.
                    "childrenIds": self.conversation?.history.nodes[lastUser.id]?.childrenIds ?? [assistantMessageId],
                    "role": "user",
                    "content": lastUser.content,
                    "timestamp": Int(lastUser.timestamp.timeIntervalSince1970),
                    "models": [modelId]
                ]
                request.userMessage = editUserMsgDict

                // Re-include files (notes, knowledge, uploaded files) from the original user node,
                // plus files from ALL other user messages so the server keeps RAG active.
                let editNotesManager = self.notesManager
                let editUserFiles = self.conversation?.history.nodes[lastUser.id]?.files ?? lastUser.files
                var editFileRefs: [[String: Any]] = []
                for storedFile in editUserFiles {
                    guard let fileId = storedFile.url else { continue }
                    if storedFile.type == "note" {
                        var ref: [String: Any] = [
                            "type": "note",
                            "id": fileId,
                            "name": storedFile.name ?? "Note",
                            "status": "processed"
                        ]
                        if let note = await editNotesManager?.fetchNote(id: fileId) {
                            ref["data"] = ["content": ["md": note.content]]
                        }
                        editFileRefs.append(ref)
                    } else if storedFile.type == "collection" {
                        editFileRefs.append([
                            "type": "collection",
                            "id": fileId,
                            "name": storedFile.name ?? fileId
                        ])
                    } else {
                        var ref: [String: Any] = ["type": storedFile.type ?? "file", "id": fileId]
                        if let name = storedFile.name { ref["name"] = name }
                        if let ct = storedFile.contentType { ref["content_type"] = ct }
                        editFileRefs.append(ref)
                    }
                }
                // Merge in file refs from all other user messages (deduped by id).
                let historyFileRefsEdit = await self.collectHistoryFileRefs(excludingId: lastUser.id)
                for ref in historyFileRefsEdit {
                    guard let refId = ref["id"] as? String else { continue }
                    if !editFileRefs.contains(where: { ($0["id"] as? String) == refId }) {
                        editFileRefs.append(ref)
                    }
                }
                if !editFileRefs.isEmpty { request.files = editFileRefs }

                // Populate all common request fields (model metadata, features, params,
                // system variables, tool IDs, terminal, background tasks, etc.)
                await self.populateCommonRequestFields(&request)

                let json = try await manager.sendMessageHTTP(request: request)
                if let err = json["error"] as? String, !err.isEmpty {
                    self.updateAssistantMessage(id: assistantMessageId, content: "", isStreaming: false,
                        error: ChatMessageError(content: err))
                    self.cleanupStreaming()
                    return
                }
                if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                    self.updateAssistantMessage(id: assistantMessageId, content: "", isStreaming: false,
                        error: ChatMessageError(content: detail))
                    self.cleanupStreaming()
                    return
                }
                if let taskId = json["task_id"] as? String { self.activeTaskId = taskId }
                self.logger.info("Edit-regen HTTP POST done – waiting for socket events")
            } catch {
                if !Task.isCancelled {
                    self.updateAssistantMessage(id: assistantMessageId, content: "", isStreaming: false,
                        error: ChatMessageError(content: error.localizedDescription))
                    self.cleanupStreaming()
                }
            }
        }
    }

    /// Deletes a specific message (and its entire descendant subtree) from the
    /// conversation tree. Matches OpenWebUI's tree-based `deleteMessage()`:
    ///
    /// 1. Remove the node from its parent's `childrenIds`
    /// 2. Remove the node and all descendants from `history.nodes`
    /// 3. Navigate to the deepest leaf of the parent node (or any remaining root)
    /// 4. Re-derive the flat message list from the updated tree
    /// 5. Sync to server via the tree-based API
    ///
    /// The `activeVersionIndex` parameter is kept for call-site compatibility
    /// but is no longer used — versions are sibling nodes in the tree, so
    /// deleting "the active version" just means removing the node we're currently on.
    func deleteMessage(id: String, activeVersionIndex: Int? = nil) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard conversation != nil else { return }

        // Ensure tree is populated
        if !conversation!.history.isPopulated {
            conversation!.history = APIClient.buildHistoryFromFlatMessages(conversation!.messages)
        }

        guard conversation!.history.nodes[id] != nil else { return }
        let parentId = conversation!.history.nodes[id]!.parentId

        // Collect all subtree IDs before removal so we can blacklist them.
        // This prevents adoptServerMessages from re-adding them if the server
        // still returns these nodes (e.g. in chatCompleted after delete+regenerate).
        var subtreeIds: [String] = []
        var queue = [id]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            subtreeIds.append(current)
            if let children = conversation!.history.nodes[current]?.childrenIds {
                queue.append(contentsOf: children)
            }
        }
        deletedMessageIds.formUnion(subtreeIds)

        // Remove the node and its entire subtree (also cleans up parent's childrenIds)
        conversation!.history.removeSubtree(rootId: id)

        // Recalculate the active branch pointer
        if let parentId, conversation!.history.nodes[parentId] != nil {
            // Navigate into parent's remaining children (if any), or stay on parent
            conversation!.history.currentId = conversation!.history.deepestLeaf(from: parentId)
        } else if let anyRoot = conversation!.history.nodes.values
            .filter({ $0.parentId == nil })
            .sorted(by: { $0.timestamp < $1.timestamp })
            .first {
            // No parent — find any remaining root node
            conversation!.history.currentId = conversation!.history.deepestLeaf(from: anyRoot.id)
        } else {
            // Tree is now empty
            conversation!.history.currentId = nil
        }

        // Re-derive the flat message list from the updated tree
        conversation!.rederiveMessages()

        // If all messages were deleted, reset to a true new-chat state.
        // Without this, conversation is still non-nil (just with zero messages),
        // and sendMessage() would append the next user message to the same old
        // conversation object instead of creating a fresh chat — causing the new
        // message to become a sibling/version of the deleted node rather than
        // the start of a new conversation.
        if conversation?.messages.isEmpty == true {
            conversation = nil
        }

        // Sync tree to server
        await syncToServerViaTree()

        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    // MARK: - WebSocket Event Handlers

    private func registerSocketHandlers(
        socket: SocketIOService,
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?,
        continuePrefix: String? = nil
    ) {
        chatSubscription?.dispose()
        channelSubscription?.dispose()
        let acc = ContentAccumulator()

        // For continue responses: pre-seed the accumulator with the existing message
        // content so that delta tokens are appended to the correct base.
        // Without this, chat:message:delta events call acc.append(newToken) giving
        // acc.content = "" + newToken (tiny). When pipeline.append(tinyString) is
        // called, buffer = tinyString but displayedCount = existingContent.count (large),
        // so currentBuffered < 0 — nothing drains and the continuation is invisible.
        if let prefix = continuePrefix, !prefix.isEmpty {
            acc.replace(prefix)
        }

        // Wire up the immediate UI update callback.
        // The accumulator coalesces concurrent token arrivals into a single
        // pending MainActor Task — preventing main actor flooding while still
        // delivering each token as fast as Swift's task scheduler allows.
        let msgId = assistantMessageId
        acc.onUpdate = { [weak self] content in
            // Guard: if streaming already finished (done:true processed),
            // ignore late-arriving accumulated content dispatches.
            guard let self, !self.hasFinishedStreaming else { return }
            self.socketHasReceivedContent = true
            self.updateAssistantMessage(id: msgId, content: content, isStreaming: true)
        }

        chatSubscription = socket.addChatEventHandler(
            conversationId: effectiveChatId,
            sessionId: socketSessionId
        ) { [weak self] event, ack in
            guard let self else { return }
            // Fast-path: check if this is a content delta we can handle
            // entirely through the throttled accumulator WITHOUT scheduling
            // a @MainActor task per token.
            let data = event["data"] as? [String: Any] ?? event
            let type = data["type"] as? String
            if type == "chat:message:delta" || type == "message" || type == "event:message:delta" {
                let payload = data["data"] as? [String: Any]
                let content = payload?["content"] as? String ?? ""
                if !content.isEmpty {
                    // Append directly — the accumulator dispatches to
                    // the main actor immediately on every token.
                    acc.append(content)
                    return
                }
            }
            // For all other event types, dispatch to main actor normally
            Task { @MainActor in
                self.handleChatEvent(
                    event, ack: ack, assistantMessageId: assistantMessageId,
                    modelId: modelId, socketSessionId: socketSessionId,
                    effectiveChatId: effectiveChatId, acc: acc)
            }
        }

        channelSubscription = socket.addChannelEventHandler(
            conversationId: effectiveChatId,
            sessionId: socketSessionId
        ) { [weak self] event, _ in
            guard let self else { return }
            // Fast-path for channel content deltas
            let data = event["data"] as? [String: Any] ?? event
            let type = data["type"] as? String
            let payload = data["data"] as? [String: Any]
            if type == "message", let content = payload?["content"] as? String, !content.isEmpty {
                acc.append(content)
                return
            }
            Task { @MainActor in
                self.handleChannelEvent(event, assistantMessageId: assistantMessageId, acc: acc)
            }
        }
    }

    private func handleChatEvent(
        _ event: [String: Any], ack: ((Any?) -> Void)?,
        assistantMessageId: String, modelId: String,
        socketSessionId: String, effectiveChatId: String?,
        acc: ContentAccumulator
    ) {
        let data = event["data"] as? [String: Any] ?? event
        let type = data["type"] as? String
        let payload = data["data"] as? [String: Any]

        // Title, tags, follow-ups, and sources can arrive AFTER done:true
        // so we must NOT guard on hasFinishedStreaming for those event types.
        // Only guard for content-producing events.

        switch type {
        // --- Events that MUST work after streaming finishes ---

        case "chat:title":
            // Title can be a direct string or nested in payload
            var newTitle: String?
            if let titleStr = data["data"] as? String, !titleStr.isEmpty {
                newTitle = titleStr
            } else if let p = payload, let t = p["title"] as? String, !t.isEmpty {
                newTitle = t
            } else if let p = payload {
                for (_, value) in p {
                    if let s = value as? String, !s.isEmpty && s.count < 200 {
                        newTitle = s
                        break
                    }
                }
            }
            if let newTitle {
                conversation?.title = newTitle
                logger.info("Title updated: \(newTitle)")
                // NOTE: We do NOT persist the title back to the server here.
                // The server generated this title via background_tasks and already
                // has it stored. Writing it back would be redundant and could race
                // with the server's own save.
                if let chatId = effectiveChatId {
                    // Notify the conversation list to update
                    NotificationCenter.default.post(
                        name: .conversationTitleUpdated,
                        object: nil,
                        userInfo: ["conversationId": chatId, "title": newTitle]
                    )
                }
            }

        case "chat:tags":
            // Refresh conversation from server to get tags
            if let chatId = effectiveChatId {
                Task {
                    try? await refreshConversationMetadata(chatId: chatId, assistantMessageId: assistantMessageId)
                }
            }

        case "chat:message:follow_ups":
            // Follow-ups can arrive in various formats:
            // 1. { data: { follow_ups: [...] } }
            // 2. { data: { followUps: [...] } }
            // 3. { data: [...] } (direct array)
            var followUps: [String] = []
            if let payload {
                followUps = payload["follow_ups"] as? [String]
                    ?? payload["followUps"] as? [String]
                    ?? payload["suggestions"] as? [String] ?? []
            }
            // Try direct array format
            if followUps.isEmpty, let directArray = data["data"] as? [String] {
                followUps = directArray
            }
            if !followUps.isEmpty {
                let trimmed = followUps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !trimmed.isEmpty {
                    logger.info("Received \(trimmed.count) follow-ups")
                    appendFollowUps(id: assistantMessageId, followUps: trimmed)
                }
            }

        case "source", "citation":
            if let payload, let sources = parseSources([payload]) {
                appendSources(id: assistantMessageId, sources: sources)
            }

        case "notification":
            if let msg = payload?["content"] as? String { logger.info("Notification: \(msg)") }

        case "confirmation":
            ack?(true)

        case "execute":
            logger.info("🔧 [Socket] Acknowledging execute event for tool pipeline")
            ack?(true)

        // --- Events that should only work during active streaming ---

        default:
            guard !hasFinishedStreaming else { return }

            switch type {
            case "chat:completion":
                guard let payload else { break }
                handleChatCompletion(payload, assistantMessageId: assistantMessageId,
                                      modelId: modelId, socketSessionId: socketSessionId,
                                      effectiveChatId: effectiveChatId, acc: acc)

            case "chat:message:delta", "message", "event:message:delta":
                let content = payload?["content"] as? String ?? ""
                if !content.isEmpty {
                    acc.append(content)
                    updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
                }

            case "chat:message", "replace":
                let content = payload?["content"] as? String ?? ""
                if !content.isEmpty {
                    acc.replace(content)
                    updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
                }

            case "status", "event:status":
                if let payload {
                    let su = parseStatusData(payload)
                    appendStatusUpdate(id: assistantMessageId, status: su)
                }

            case "chat:message:error":
                let errContent = extractErrorContent(from: payload ?? data)
                updateAssistantMessage(id: assistantMessageId, content: acc.content,
                                        isStreaming: false, error: ChatMessageError(content: errContent))
                cleanupStreaming()

            case "chat:tasks:cancel":
                updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
                cleanupStreaming()

            case "request:chat:completion":
                if let ch = payload?["channel"] as? String, !ch.isEmpty {
                    logger.info("Channel request: \(ch)")
                }

            case "execute:tool":
                if let name = payload?["name"] as? String, !name.isEmpty {
                    let su = ChatStatusUpdate(action: name, description: "Executing \(name)…", done: false)
                    appendStatusUpdate(id: assistantMessageId, status: su)
                }

            default:
                break
            }
        }
    }

    private func handleChatCompletion(
        _ payload: [String: Any],
        assistantMessageId: String, modelId: String,
        socketSessionId: String, effectiveChatId: String?,
        acc: ContentAccumulator
    ) {
        // structured output format: content lives in `output` array.
        // The server sends cumulative snapshots (each event contains the full
        // output so far), so we use `replace` not `append`.
        //
        // Reconstruct the full content string (text + inline <details type="tool_calls">
        // blocks + reasoning blocks) using the same helper as history parsing. This
        // ensures tool call cards, preamble text, and final answer all render in order
        // via the existing ToolCallParser — no separate status-pill logic needed.
        if let outputArr = payload["output"] as? [[String: Any]] {
            if let reconstructed = MessageHistory.reconstructContentFromOutput(outputArr) {
                acc.replace(reconstructed)
                updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
            }
        }

        // OpenAI choices format (legacy / non-agent models)
        if let choices = payload["choices"] as? [[String: Any]],
           let first = choices.first,
           let delta = first["delta"] as? [String: Any] {
            if let c = delta["content"] as? String, !c.isEmpty {
                acc.append(c)
                updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    if let fn = call["function"] as? [String: Any],
                       let name = fn["name"] as? String, !name.isEmpty {
                        appendStatusUpdate(id: assistantMessageId,
                            status: ChatStatusUpdate(action: name, description: "Calling \(name)…", done: false))
                    }
                }
            }
            if let status = delta["status"] as? [String: Any] {
                appendStatusUpdate(id: assistantMessageId, status: parseStatusData(status))
            }
            if let sourcesArray = delta["sources"] as? [[String: Any]],
               let sources = parseSources(sourcesArray) {
                appendSources(id: assistantMessageId, sources: sources)
            }
            if let citations = delta["citations"] as? [[String: Any]],
               let sources = parseSources(citations) {
                appendSources(id: assistantMessageId, sources: sources)
            }
        }

        // Direct content field (legacy format)
        if let content = payload["content"] as? String, !content.isEmpty {
            acc.replace(content)
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
        }

        // Top-level tool_calls (legacy format)
        if let toolCalls = payload["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                if let fn = call["function"] as? [String: Any],
                   let name = fn["name"] as? String, !name.isEmpty {
                    appendStatusUpdate(id: assistantMessageId,
                        status: ChatStatusUpdate(action: name, description: "Calling \(name)…", done: false))
                }
            }
        }

        // Top-level sources
        if let rawSources = payload["sources"] as? [[String: Any]] ?? payload["citations"] as? [[String: Any]],
           let sources = parseSources(rawSources) {
            appendSources(id: assistantMessageId, sources: sources)
        }

        // Done signal
        if payload["done"] as? Bool == true {
            logger.info("Received done:true – finalizing streaming")
            finishStreamingSuccessfully(
                assistantMessageId: assistantMessageId,
                modelId: modelId,
                socketSessionId: socketSessionId,
                effectiveChatId: effectiveChatId,
                acc: acc
            )
        }

        // Error in completion payload
        if let err = payload["error"] as? String, !err.isEmpty {
            updateAssistantMessage(id: assistantMessageId, content: acc.content,
                                    isStreaming: false, error: ChatMessageError(content: err))
            cleanupStreaming()
        }
    }

    /// Handles channel events (secondary streaming channel).
    private func handleChannelEvent(
        _ event: [String: Any],
        assistantMessageId: String,
        acc: ContentAccumulator
    ) {
        guard !hasFinishedStreaming else { return }
        let data = event["data"] as? [String: Any] ?? event
        let type = data["type"] as? String
        let payload = data["data"] as? [String: Any]

        if type == "message", let content = payload?["content"] as? String, !content.isEmpty {
            acc.append(content)
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
        }
    }

    // MARK: - Streaming Completion

    private func finishStreamingSuccessfully(
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?,
        acc: ContentAccumulator
    ) {
        // If content is empty, poll server for it
        if acc.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await pollAndFinish(
                    assistantMessageId: assistantMessageId,
                    modelId: modelId,
                    socketSessionId: socketSessionId,
                    effectiveChatId: effectiveChatId,
                    acc: acc
                )
            }
            return
        }

        // Finalize the message — mark as not streaming but DON'T dispose
        // socket subscriptions yet. Follow-ups, title, and tags arrive
        // AFTER done:true via socket events, so we need to keep listening.
        updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
        hasFinishedStreaming = true
        isStreaming = false

        // Register the passive listener now that the conversation has a real server ID.
        // For new chats, startPassiveSocketListener() is skipped in load() because no
        // conversationId exists yet. After the first stream completes the conversation is
        // created on the server and conversation.id is populated — this is the first safe
        // moment to register, and it must happen here before hasFinishedStreaming=true
        // blocks cleanupStreaming() from ever reaching the call at the bottom.
        startPassiveSocketListener()

        // Drain the message queue: if there are queued messages, combine them
        // with "\n\n" and send as a single message after streaming finishes.
        // Use directText so the text never flashes in the input box.
        // A short delay lets the UI settle (action bar, animations) before the
        // next message fires.
        if !messageQueue.isEmpty {
            let combined = messageQueue.map(\.text).joined(separator: "\n\n")
            messageQueue.removeAll()
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await sendMessage(directText: combined)
            }
        }

        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recoveryDelayTask?.cancel()
        recoveryDelayTask = nil
        emptyPollCount = 0
        lastRecoveryPollContentLength = 0
        // NOTE: endBackgroundTask() is intentionally called INSIDE the
        // completionTask below, AFTER the notification has been awaited.
        // Calling it here (before the Task) causes iOS to immediately suspend
        // the process, preventing the notification from ever being scheduled.

        // Capture the current subscriptions by value so the async Task below
        // disposes ONLY the subscriptions that belong to this streaming session.
        //
        // Without this capture, if the user sends a 2nd message before this
        // Task completes (which can take 10+ seconds due to file-poll sleeps),
        // the Task would dispose the NEW subscriptions created for the 2nd
        // message — killing live socket delivery mid-stream and causing all
        // text to appear at once at the end instead of token-by-token.
        let capturedChatSub = chatSubscription
        let capturedChannelSub = channelSubscription
        chatSubscription = nil
        channelSubscription = nil

        // Send chatCompleted, refresh metadata immediately for files/images,
        // then poll for tool-generated files before final cleanup.
        // Store as completionTask so it can be cancelled if user sends a new
        // message before it finishes (prevents content overwrite bug).
        completionTask = Task {
            // Send notification first, THEN end the background task.
            // This ordering is critical: if endBackgroundTask() is called first,
            // iOS may immediately suspend the process before the notification
            // is scheduled — causing the banner to never appear.
            await sendCompletionNotificationIfNeeded(content: acc.content)
            // Now it is safe to release the background time assertion.
            self.endBackgroundTask()

            if let chatId = effectiveChatId {
                await manager?.sendChatCompleted(
                    chatId: chatId, messageId: assistantMessageId,
                    model: modelId, sessionId: socketSessionId,
                    messages: buildSimpleAPIMessages())

                // Immediately refresh metadata to pick up tool-generated files/images
                try? await refreshConversationMetadata(
                    chatId: chatId, assistantMessageId: assistantMessageId)

                // Short delay re-fetch to catch server-side post-processing that happens
                // AFTER chatCompleted (e.g. filter functions that append timing/performance
                // stats like "⏱ 12.2s · ⚡ 77.7 t/s" to the message content).
                // The filter runs asynchronously after chatCompleted finishes, so the
                // immediate refresh above may miss it — this 1.5s delay catches it.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                try? await refreshConversationMetadata(
                    chatId: chatId, assistantMessageId: assistantMessageId)

                // Check if files are still missing (tool outputs take time to process).
                // Poll with increasing delays specifically for files.
                let needsFilePoll = self.conversation?.messages
                    .first(where: { $0.id == assistantMessageId })?.files.isEmpty ?? true
                if needsFilePoll {
                    for delay: UInt64 in [2, 3, 5] {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        try? await refreshConversationMetadata(
                            chatId: chatId, assistantMessageId: assistantMessageId)
                        let hasFiles = !(self.conversation?.messages
                            .first(where: { $0.id == assistantMessageId })?.files.isEmpty ?? true)
                        if hasFiles { break }
                    }

                    // Last resort: if server still hasn't provided files, extract
                    // file IDs directly from tool call results in the message content.
                    // This handles the case where the server metadata doesn't include
                    // files but the tool response clearly references generated images.
                    self.populateFilesFromToolResults(messageId: assistantMessageId)
                    // Re-sync to server so the extracted files array is persisted.
                    // Without this, the tree node has files but the server still shows
                    // files:[] and WebUI can't render images when switching versions.
                    await self.syncToServerViaTree()
                } else {
                    // Files already present — just wait for follow-ups/title
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    try? await refreshConversationMetadata(
                        chatId: chatId, assistantMessageId: assistantMessageId)
                }
            }
            // NOTE: Do NOT call saveConversationToServer() here.
            // The server already has the authoritative state after chatCompleted
            // processed tool results (web search, image gen). Saving our local
            // copy back would overwrite the server's clean format with raw
            // streamed content containing <details> blocks, causing the chat
            // to appear blank on the web client.

            // Dispose only the subscriptions captured at the start of THIS
            // completion handler — not the instance vars (which may already
            // belong to a newer streaming session).
            capturedChatSub?.dispose()
            capturedChannelSub?.dispose()

            // Notify the conversation list to refresh
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        }
    }

    /// Polls the server for content when the done signal arrives with empty content.
    private func pollAndFinish(
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?,
        acc: ContentAccumulator
    ) async {
        guard let chatId = effectiveChatId, let manager else {
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
            cleanupStreaming()
            return
        }

        // Poll up to 5 times with 1s delay
        for attempt in 1...5 {
            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                if let lastAssistant = refreshed.messages.last(where: { $0.role == .assistant }),
                   !lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    acc.replace(lastAssistant.content)
                    logger.info("Server poll \(attempt): got content (\(lastAssistant.content.count) chars)")
                    break
                }
            } catch {
                logger.warning("Poll attempt \(attempt) failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)

        // Send background notification if app is not active
        await sendCompletionNotificationIfNeeded(content: acc.content)

        await manager.sendChatCompleted(
            chatId: chatId, messageId: assistantMessageId,
            model: modelId, sessionId: socketSessionId,
            messages: buildSimpleAPIMessages())

        // Refresh metadata to pick up tool-generated files/images.
        // Poll with retries since tool outputs may take time to process.
        for delay: UInt64 in [1, 2, 3] {
            try? await refreshConversationMetadata(
                chatId: chatId, assistantMessageId: assistantMessageId)
            let hasFiles = !(conversation?.messages
                .first(where: { $0.id == assistantMessageId })?.files.isEmpty ?? true)
            if hasFiles { break }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }

        // Last resort: extract file IDs from tool call results in content
        populateFilesFromToolResults(messageId: assistantMessageId)
        // Re-sync to server so the extracted files array is persisted.
        // Without this, the tree node has files but the server still shows
        // files:[] and WebUI can't render images when switching versions.
        await syncToServerViaTree()

        // NOTE: Do NOT call saveConversationToServer() here — same reason
        // as finishStreamingSuccessfully. The server's chatCompleted has the
        // authoritative state; pushing our local copy would corrupt tool results.

        // Drain the message queue (same as in finishStreamingSuccessfully).
        if !messageQueue.isEmpty {
            let combined = messageQueue.map(\.text).joined(separator: "\n\n")
            messageQueue.removeAll()
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await sendMessage(directText: combined)
            }
        }

        cleanupStreaming()
    }

    // MARK: - Recovery Timer

    /// Starts a timer that polls the server periodically to recover from stuck streaming.
    ///
    /// The first poll is delayed by 8 seconds to give socket streaming time to
    /// begin. The previous 3-second initial fire competed with socket events for
    /// main actor time and sometimes caused the "all text at once" symptom by
    /// triggering a full conversation fetch right when tokens were starting to flow.
    private func startRecoveryTimer(assistantMessageId: String, chatId: String?) {
        recoveryTimer?.invalidate()
        recoveryDelayTask?.cancel()
        emptyPollCount = 0
        lastRecoveryPollContentLength = 0
        recoveryTaskCheckFailures = 0
        recoveryTimerStartDate = Date()

        // Use a cancellable Task for the initial delay instead of
        // DispatchQueue.main.asyncAfter, which cannot be cancelled when
        // the user navigates away or sends a new message.
        recoveryDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.isStreaming, !self.hasFinishedStreaming else { return }

            self.recoveryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.runRecoveryPoll(assistantMessageId: assistantMessageId, chatId: chatId)
                }
            }
            // Also run the first poll immediately after the delay
            self.runRecoveryPoll(assistantMessageId: assistantMessageId, chatId: chatId)
        }
    }

    /// Extracted recovery poll logic (called by the recovery timer).
    ///
    /// ## Completion detection
    /// We intentionally do NOT rely on `lastAssistant.isStreaming` (the server's `done` flag)
    /// as the sole signal because that flag is only set when the app calls `chatCompleted` —
    /// which only happens AFTER the app receives `done:true` from the socket.  On a slow
    /// connection the `done:true` socket event can be delayed or dropped, creating a circular
    /// dependency where neither side ever marks the response as finished.
    ///
    /// Instead we use **content-based completion detection**: the server always persists the
    /// full response content once generation finishes, regardless of whether `chatCompleted`
    /// was sent.  A response is considered complete when:
    ///   1. The server explicitly sets `done = true` (`!lastAssistant.isStreaming`), OR
    ///   2. The content is non-empty AND all tool-call `<details>` blocks are closed
    ///      (i.e. generation finished but `chatCompleted` was never sent due to dropped event).
    ///
    /// For the give-up threshold we no longer reset `emptyPollCount` based on tool statuses —
    /// that reset was the mechanism that caused the timer to loop indefinitely when a
    /// `done:true` socket event was dropped.  Instead we let `emptyPollCount` increment
    /// freely and trust the content-stability check above to finalize first.
    private func runRecoveryPoll(assistantMessageId: String, chatId: String?) {
        Task { @MainActor in
            guard self.isStreaming, !self.hasFinishedStreaming else {
                self.recoveryTimer?.invalidate()
                self.recoveryTimer = nil
                return
            }
            guard let chatId, let manager = self.manager else { return }

            // polledContentLength captures the server content length from the fetch below.
            // It is set inside the do-block and reused for the content-growth check after,
            // avoiding a second redundant fetchConversation call.
            var polledContentLength = self.lastRecoveryPollContentLength

            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                if let lastAssistant = refreshed.messages.last(where: { $0.role == .assistant }) {
                    let serverContent = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let localContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    // Capture the raw (non-trimmed) character count for the growth check below.
                    polledContentLength = lastAssistant.content.count

                    // Server has more content than local — but ONLY update if the socket
                    // has NOT been delivering tokens. If the socket is actively streaming,
                    // let it continue token-by-token rather than dumping the entire server
                    // content at once.
                    if !serverContent.isEmpty && serverContent.count > localContent.count && !self.socketHasReceivedContent {
                        self.logger.info("Recovery: adopting server content (socket silent)")
                        self.updateAssistantMessage(
                            id: assistantMessageId, content: lastAssistant.content, isStreaming: true)
                    }

                    // Determine if the response is complete.
                    //
                    // Primary signal: server's done flag (set when chatCompleted is processed).
                    // Fallback signal: content-based detection — the response is structurally
                    // complete when all tool-call blocks are closed, regardless of the done flag.
                    // This catches the slow-connection case where the done:true socket event
                    // was delayed or dropped and chatCompleted was never sent.
                    let serverDone = !lastAssistant.isStreaming
                    let contentComplete = !serverContent.isEmpty && Self.toolCallResponseIsComplete(serverContent)

                    if (serverDone || contentComplete) && !serverContent.isEmpty {
                        self.logger.info("Recovery: finalizing — serverDone=\(serverDone) contentComplete=\(contentComplete) chars=\(serverContent.count)")
                        self.updateAssistantMessage(
                            id: assistantMessageId, content: lastAssistant.content, isStreaming: false)
                        let doneContent = lastAssistant.content
                        Task { await self.sendCompletionNotificationIfNeeded(content: doneContent) }
                        self.cleanupStreaming()
                        return
                    }
                }
            } catch {
                self.logger.warning("Recovery poll failed: \(error.localizedDescription)")
            }

            // Track whether the server content grew since the last poll.
            // If the model is still actively generating (content grew), reset
            // emptyPollCount so we never give up on a slow-but-progressing model
            // (large reasoning models, long MCP tool chains, local models, etc.).
            // Only increment when content has been completely static — meaning the
            // model has genuinely stopped producing output.
            let currentServerContentLength = polledContentLength

            if currentServerContentLength > self.lastRecoveryPollContentLength {
                // Model is still generating — stay patient, reset both counters
                self.logger.debug("Recovery: content growing (\(self.lastRecoveryPollContentLength) → \(currentServerContentLength) chars) — resetting give-up counters")
                self.lastRecoveryPollContentLength = currentServerContentLength
                self.emptyPollCount = 0
                self.recoveryTaskCheckFailures = 0
            } else {
                // Content is static this poll — consult the server task registry before giving up.
                // The server's GET /api/tasks/chat/{chatId} is the authoritative completion signal:
                // an empty task_ids array means the generation coroutine has finished and we should
                // do a final fetch-and-finalize instead of waiting another poll cycle.

                // Hard absolute timeout (10 minutes) regardless of task status
                let elapsed = Date().timeIntervalSince(self.recoveryTimerStartDate)
                if elapsed > 600 {
                    self.logger.warning("Recovery: hard timeout after \(Int(elapsed))s — giving up")
                    let giveUpContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
                    self.updateAssistantMessage(
                        id: assistantMessageId,
                        content: giveUpContent,
                        isStreaming: false)
                    Task { await self.sendCompletionNotificationIfNeeded(content: giveUpContent) }
                    self.cleanupStreaming()
                    return
                }

                do {
                    let activeTaskIds = try await manager.apiClient.getTasksForChat(chatId: chatId)
                    self.recoveryTaskCheckFailures = 0

                    if !activeTaskIds.isEmpty {
                        // Server confirms the task is still running — stay patient and
                        // reset emptyPollCount so the stale-content counter never fires
                        // while the server is genuinely processing (e.g. long web search).
                        self.logger.debug("Recovery: task still active (\(activeTaskIds.count) task(s)) — content=\(currentServerContentLength) chars, waiting")
                        self.emptyPollCount = 0
                    } else {
                        // Server says the task is finished — do a final conversation fetch
                        // and finalize so we display the complete response immediately.
                        self.logger.info("Recovery: server task finished (empty task list) — performing final sync")
                        if let refreshed = try? await manager.fetchConversation(id: chatId),
                           let lastAssistant = refreshed.messages.last(where: { $0.role == .assistant }) {
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: lastAssistant.content,
                                isStreaming: false)
                            let doneContent = lastAssistant.content
                            Task { await self.sendCompletionNotificationIfNeeded(content: doneContent) }
                        } else {
                            let giveUpContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: giveUpContent,
                                isStreaming: false)
                            Task { await self.sendCompletionNotificationIfNeeded(content: giveUpContent) }
                        }
                        self.cleanupStreaming()
                    }
                } catch {
                    // Task-check network error — count consecutive failures
                    self.recoveryTaskCheckFailures += 1
                    self.logger.warning("Recovery: task-check failed (\(self.recoveryTaskCheckFailures)/5): \(error.localizedDescription)")
                    if self.recoveryTaskCheckFailures >= 5 {
                        // 5 consecutive failures means we can't reach the server reliably;
                        // fall back to the old stale-content give-up threshold (12 polls).
                        self.emptyPollCount += 1
                        self.logger.debug("Recovery: falling back to stale-poll counter (\(self.emptyPollCount)/12) after task-check failures")
                        if self.emptyPollCount >= 12 {
                            self.logger.warning("Recovery: giving up after \(self.emptyPollCount) static polls (task-check unreachable)")
                            let giveUpContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: giveUpContent,
                                isStreaming: false)
                            Task { await self.sendCompletionNotificationIfNeeded(content: giveUpContent) }
                            self.cleanupStreaming()
                        }
                    }
                    // If fewer than 5 failures, assume still running and keep waiting
                }
            }
        }
    }

    /// Returns `true` when the content string represents a structurally complete tool-call
    /// response — i.e. every `<details type="tool_calls">` opening tag has a matching
    /// `</details>` closing tag.
    ///
    /// This is used by the recovery timer to detect response completion without relying on
    /// the server's `done` flag, which may never be set if the `done:true` socket event was
    /// dropped and `chatCompleted` was never sent.
    ///
    /// - Returns: `true` if there are no unclosed tool-call blocks (including when there are
    ///   no tool-call blocks at all, which means the response is a plain-text completion).
    private static func toolCallResponseIsComplete(_ content: String) -> Bool {
        // Fast path: no tool calls in the content → nothing to check, response is complete.
        guard content.contains("tool_calls") else { return true }

        // We need at least one opening AND one closing details tag to have a complete block.
        guard content.contains("<details"), content.contains("</details>") else { return false }

        // Find the last opening <details type="tool_calls"> tag and the last </details> tag.
        // If </details> comes AFTER the last opening tag, all blocks are closed.
        // This is an O(n) scan but only runs every 5s in the recovery path.
        guard let lastOpenRange = content.range(of: "<details", options: [.caseInsensitive, .backwards]),
              let lastCloseRange = content.range(of: "</details>", options: [.caseInsensitive, .backwards]) else {
            return false
        }

        // The last close tag must come after the last open tag for the block to be closed.
        return lastCloseRange.lowerBound > lastOpenRange.lowerBound
    }

    // MARK: - Cleanup

    /// Sends a local notification when generation completes.
    /// Always schedules the notification — the `UNUserNotificationCenterDelegate`
    /// controls presentation (banner vs silent) based on foreground state.
    private func sendCompletionNotificationIfNeeded(content: String) async {
        // Check if user has disabled generation notifications
        let notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard notificationsEnabled else { return }

        // Always schedule the notification. The UNUserNotificationCenterDelegate
        // (willPresent) handles foreground suppression — if the user is viewing
        // this conversation, it returns [] (no banner). This avoids stale
        // UIApplication.shared.connectedScenes state when called from background tasks.
        let chatId = conversationId ?? conversation?.id ?? ""
        let title = conversation?.title ?? "Chat"
        let preview = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return }

        // Sync activeConversationId to the real server-assigned ID before firing the
        // notification. For new chats, activeConversationId was set to the local UUID
        // (localId) at sendMessage() time, but by now the server has assigned a real ID
        // stored in conversationId / conversation?.id. The willPresent suppression check
        // compares chatId == activeConversationId — without this sync the IDs mismatch
        // and an in-app notification banner fires incorrectly.
        if !chatId.isEmpty {
            await MainActor.run {
                NotificationService.shared.activeConversationId = chatId
            }
        }

        await NotificationService.shared.notifyGenerationComplete(
            conversationId: chatId,
            title: title,
            preview: preview
        )
    }

    /// Updates a task status locally and syncs to server.
    /// Called from TaskListView when the user taps a task row.
    func updateTaskStatus(taskId: String, newStatus: String) {
        // Update locally immediately (optimistic)
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[idx].status = newStatus
        }
        if let idx = conversation?.tasks.firstIndex(where: { $0.id == taskId }) {
            conversation?.tasks[idx].status = newStatus
        }
        // Sync to server
        guard let chatId = conversationId ?? conversation?.id,
              let apiClient = manager?.apiClient else { return }
        Task {
            _ = try? await apiClient.updateChatTask(chatId: chatId, taskId: taskId, status: newStatus)
        }
    }

    private func cleanupStreaming() {
        guard !hasFinishedStreaming else { return }
        stopSwitchStatusPolling()
        hasFinishedStreaming = true
        isStreaming = false
        isExternallyStreaming = false
        // Record the just-completed message ID BEFORE clearing selfInitiatedStream.
        // handlePassiveEvent uses this to block replayed socket events for the message
        // this VM just streamed (re-subscription to the passive listener causes the server
        // to re-deliver recent events, which would otherwise replay the whole response).
        if let completedId = streamingStore.streamingMessageId ?? {
            conversation?.messages.last(where: { $0.role == .assistant && !$0.isStreaming })?.id
        }() {
            lastCompletedSelfInitiatedMessageId = completedId
        }
        selfInitiatedStream = false
        activeTaskId = nil
        lastTaskExtractionLength = 0

        // Always fire the notification — the UNUserNotificationCenterDelegate's
        // willPresent handler suppresses the banner when the user is actively
        // viewing this chat. Checking applicationState here is unreliable because
        // this method is called from async Task contexts where the app state value
        // may already be stale or incorrect at the time of the call.
        // The notification service de-duplicates by conversation ID, so a second
        // call within the same second from a path that already called
        // sendCompletionNotificationIfNeeded is a no-op.
        let content = conversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await self.sendCompletionNotificationIfNeeded(content: content)
            }
        }

        // CRITICAL: Flush the streaming store if it's still active.
        // Without this, background recovery paths (recoverFromBackgroundStreaming,
        // startBackgroundCompletionPolling) bypass updateAssistantMessage(isStreaming:false)
        // and go directly to adoptServerMessages → cleanupStreaming. The store's
        // isActive stays true, causing IsolatedAssistantMessage to remain stuck
        // in the fixed-height streaming container forever.
        if streamingStore.isActive, let msgId = streamingStore.streamingMessageId,
           let idx = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
            let result = streamingStore.abortStreaming()
            // Only overwrite content if the store has meaningful content
            // (adoptServerMessages may have already set the correct content)
            if !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               conversation?.messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                conversation?.messages[idx].content = result.content
            }
            conversation?.messages[idx].isStreaming = false
            if !result.sources.isEmpty && (conversation?.messages[idx].sources.isEmpty ?? true) {
                conversation?.messages[idx].sources = result.sources
            }
            if !result.statusHistory.isEmpty {
                conversation?.messages[idx].statusHistory = result.statusHistory
            }
        } else if streamingStore.isActive {
            // Store is active but message not found — just flush it
            streamingStore.abortStreaming()
        }
        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        emptyPollCount = 0
        lastRecoveryPollContentLength = 0
        recoveryTaskCheckFailures = 0
        recoveryTimerStartDate = .distantPast
        // or remove them if they never produced meaningful output
        if let lastIdx = conversation?.messages.lastIndex(where: { $0.role == .assistant }) {
            let statuses = conversation?.messages[lastIdx].statusHistory ?? []
            let hasContent = !(conversation?.messages[lastIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            if hasContent {
                // Mark any incomplete statuses as done
                for (i, status) in statuses.enumerated() {
                    if status.done != true {
                        conversation?.messages[lastIdx].statusHistory[i].done = true
                    }
                }
            }

            // Remove statuses that are all incomplete and have no meaningful info
            // (they were just transient placeholders that never completed)
            let allIncomplete = statuses.allSatisfy { $0.done != true }
            if allIncomplete && !statuses.isEmpty {
                conversation?.messages[lastIdx].statusHistory = []
            }
        }

        // Auto-drain the message queue: if messages were queued while streaming,
        // send them now that streaming has finished. This covers ALL completion
        // paths (recovery timer, background poll, error paths, etc.) — not just
        // the happy-path finishStreamingSuccessfully/pollAndFinish paths which
        // already have their own drain. The `streamingSessionId` guard in the
        // onDrained callback ensures a queue-fired sendMessage() doesn't get
        // torn down by the OLD session's deferred cleanup.
        if !messageQueue.isEmpty {
            let combined = messageQueue.map(\.text).joined(separator: "\n\n")
            messageQueue.removeAll()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                await self?.sendMessage(directText: combined)
            }
        }

        // CRITICAL: Re-register the passive socket listener after each stream completes.
        //
        // For new chats (conversationId == nil at VM init), `startPassiveSocketListener()`
        // is intentionally skipped in `load()` because the conversation doesn't exist yet.
        // After the first response finishes, the conversation has a real server ID but the
        // passive listener has never been set up — so subsequent background subagent events
        // are never delivered to `handlePassiveEvent`. Re-registering here ensures the passive
        // listener is always alive after any streaming session completes, regardless of whether
        // the VM was created for a new chat or an existing one.
        startPassiveSocketListener()

    }

    // MARK: - Message Queue Actions

    /// Sends the specified queued item immediately: stop streaming, restore remaining
    /// queue items, set input to the chosen text, and send now.
    func sendQueuedMessageNow(id: UUID) {
        guard let idx = messageQueue.firstIndex(where: { $0.id == id }) else { return }
        let item = messageQueue[idx]
        var remaining = messageQueue
        remaining.remove(at: idx)

        // Clear queue before stopStreaming so cleanupStreaming's drain does NOT fire,
        // then restore remaining items so they persist after this send completes.
        messageQueue = []
        stopStreaming()
        messageQueue = remaining
        inputText = item.text
        Task { await sendMessage() }
    }

    /// Pops a queued message back into the input field so the user can edit it.
    func editQueuedMessage(id: UUID) {
        guard let idx = messageQueue.firstIndex(where: { $0.id == id }) else { return }
        let item = messageQueue[idx]
        messageQueue.remove(at: idx)
        inputText = item.text
    }

    /// Removes a queued message without sending it.
    func deleteQueuedMessage(id: UUID) {
        messageQueue.removeAll { $0.id == id }
    }

    // MARK: - Private Helpers

    /// Timestamp of the last model metadata refresh. Used to throttle
    /// the per-send refresh so we don't add 100-500ms of network latency
    /// to every message when the models haven't changed.
    private var lastModelMetadataRefreshTime: Date = .distantPast

    /// Fetches full model config from `/api/v1/models/model?id={id}` for the selected model.
    ///
    /// This is the authoritative source for:
    /// - `params.function_calling` ("native" | absent) — which /api/models never returns
    /// - `meta.capabilities`, `meta.toolIds`, `meta.defaultFeatureIds`
    ///
    /// Called when a model is selected (selectModel) so the UI always reflects
    /// the server's actual config. Updates the model in `availableModels` and
    /// re-syncs UI defaults.
    private func refreshSelectedModelConfig() async {
        guard let modelId = selectedModelId, let manager else { return }
        do {
            if var fullModel = try await manager.apiClient.fetchModelConfig(modelId: modelId) {
                // Preserve pipe fields from the list endpoint — the single-model endpoint
                // (/api/v1/models/model) returns workspace-model schema which lacks
                // pipe/filters fields. Overwriting them would destroy isPipeModel=true,
                // filterIds, and the correct rawModelItem needed for pipe routing.
                if let existingModel = availableModels.first(where: { $0.id == modelId }) {
                    if existingModel.isPipeModel {
                        fullModel.isPipeModel = existingModel.isPipeModel
                        fullModel.filterIds = existingModel.filterIds
                    }
                    if existingModel.rawModelItem != nil {
                        fullModel.rawModelItem = existingModel.rawModelItem
                    }
                }
                // Resolve actions and filters from IDs + global functions.
                // The single-model endpoint returns actionIds/filterIds but not full objects.
                // Fetch functions to build proper entries with name/icon.
                await resolveActionsForModel(&fullModel)
                await resolveFiltersForModel(&fullModel)
                if let idx = availableModels.firstIndex(where: { $0.id == modelId }) {
                    availableModels[idx] = fullModel
                } else {
                    availableModels.append(fullModel)
                }
                lastModelMetadataRefreshTime = Date()
                syncUIWithModelDefaults()
                logger.info("Model config loaded: \(modelId) function_calling=\(fullModel.functionCallingMode ?? "(absent)") isPipe=\(fullModel.isPipeModel)")
            }
        } catch {
            logger.debug("Model config fetch failed for \(modelId): \(error.localizedDescription)")
        }
    }

    /// Refreshes the selected model's metadata (capabilities, defaultFeatureIds, toolIds)
    /// from the server. Called before each message send to pick up live admin changes
    /// without requiring the user to restart the chat.
    ///
    /// Throttled to at most once per 60 seconds to avoid adding unnecessary
    /// network latency to every send operation. Uses the single-model endpoint
    /// (/api/v1/models/model) which also returns params.function_calling.
    ///
    /// IMPORTANT: Uses `applyIncrementalModelDefaults` instead of `syncUIWithModelDefaults`
    /// to avoid wiping tools/features the user has manually toggled during the session.
    private func refreshSelectedModelMetadata() async {
        guard let modelId = selectedModelId, let manager else { return }
        do {
            if var fullModel = try await manager.apiClient.fetchModelConfig(modelId: modelId) {
                lastModelMetadataRefreshTime = Date()
                // Preserve pipe fields from the list endpoint — the single-model endpoint
                // (/api/v1/models/model) returns workspace-model schema which lacks
                // pipe/filters fields. Overwriting them would destroy isPipeModel=true,
                // filterIds, and the correct rawModelItem needed for pipe routing.
                if let existingModel = availableModels.first(where: { $0.id == modelId }) {
                    if existingModel.isPipeModel {
                        fullModel.isPipeModel = existingModel.isPipeModel
                        fullModel.filterIds = existingModel.filterIds
                    }
                    if existingModel.rawModelItem != nil {
                        fullModel.rawModelItem = existingModel.rawModelItem
                    }
                }
                // Resolve actions and filters from IDs + global functions (fresh every time).
                await resolveActionsForModel(&fullModel)
                await resolveFiltersForModel(&fullModel)
                if let idx = availableModels.firstIndex(where: { $0.id == modelId }) {
                    availableModels[idx] = fullModel
                }
                // Use incremental sync — only ADD new defaults; never wipe user selections.
                // syncUIWithModelDefaults() resets selectedToolIds = [] which would discard
                // any tools the user manually enabled this session.
                applyIncrementalModelDefaults(for: fullModel)
            }
        } catch {
            // Non-critical — proceed with cached model data
            logger.debug("Model metadata refresh failed: \(error.localizedDescription)")
        }
    }

    /// Resolves action buttons for a model by combining:
    /// 1. Global action functions (is_global == true, is_active == true) → always included
    /// 2. Per-model action IDs (model.actionIds) → included if active
    ///
    /// Fetches the functions list from `/api/v1/functions/` to get full action
    /// metadata (name, icon) and global/active status. This ensures actions are
    /// always fresh and correctly reflect admin changes (e.g., turning global off).
    private func resolveActionsForModel(_ model: inout AIModel) async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let functions = try await apiClient.getFunctions()
            let actionFunctions = functions.filter { $0.type == "action" && $0.isActive }

            var resolvedActions: [AIModelAction] = []
            var seenIds = Set<String>()

            for fn in actionFunctions {
                // Include if globally enabled OR if the model has this action in its actionIds
                let isGlobal = fn.isGlobal
                let isPerModel = model.actionIds.contains(fn.id)

                if isGlobal || isPerModel {
                    guard !seenIds.contains(fn.id) else { continue }
                    seenIds.insert(fn.id)
                    resolvedActions.append(AIModelAction(
                        id: fn.id,
                        name: fn.name,
                        description: fn.description,
                        icon: fn.iconURL
                    ))
                }
            }

            model.actions = resolvedActions
        } catch {
            // Non-critical — keep whatever actions the model already has
            logger.debug("Failed to resolve actions: \(error.localizedDescription)")
        }
    }

    /// Resolves filter IDs for a model by combining:
    /// 1. Global filter functions (is_global == true, is_active == true) → always included
    /// 2. Per-model filter IDs (model.filterIds from meta.filterIds) → included if active
    ///
    /// Fetches the functions list from `/api/v1/functions/` to get global/active status.
    /// This ensures filterIds sent in chat requests always reflect the current server state.
    ///
    /// Also injects a `filters` array into `rawModelItem` containing full filter objects
    /// (id, name, description, icon, has_user_valves). This matches the web client's
    /// `model_item.filters` shape and is required so filter functions (e.g. Thinking presets)
    /// can read their configuration correctly. Without this, filters that modify
    /// `chat_template_kwargs` (Qwen3 thinking mode) fail on backends like Bedrock that
    /// reject unknown parameters — because the filter can't detect its target model type
    /// and falls back to injecting incompatible kwargs.
    private func resolveFiltersForModel(_ model: inout AIModel) async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let functions = try await apiClient.getFunctions()
            let filterFunctions = functions.filter { $0.type == "filter" && $0.isActive }

            var resolvedFilterIds: [String] = []
            var resolvedFilterObjects: [[String: Any]] = []
            var seenIds = Set<String>()

            for fn in filterFunctions {
                let isGlobal = fn.isGlobal
                let isPerModel = model.filterIds.contains(fn.id)

                if isGlobal || isPerModel {
                    guard !seenIds.contains(fn.id) else { continue }
                    seenIds.insert(fn.id)

                    // Only add to filterIds (top-level activation list) when this is a
                    // toggle-filter AND the user has the pill turned ON.
                    // Non-toggle global filters run server-side automatically via is_global
                    // and must NOT be in filter_ids — sending them causes the backend to
                    // forward chat_template_kwargs to models like Bedrock that reject it.
                    // This matches exactly what WebUI does: filter_ids is only populated
                    // for toggle-filters whose pill is enabled.
                    let isToggleOn = fn.hasToggle && selectedToolIds.contains(fn.id)
                    if isToggleOn {
                        resolvedFilterIds.append(fn.id)
                    }

                    // Always build the full filter object for model_item.filters[] so the
                    // server receives the complete filter list (same as WebUI) regardless of
                    // pill state — filters read model_item to detect model type.
                    var filterObj: [String: Any] = [
                        "id": fn.id,
                        "name": fn.name,
                        "description": fn.description,
                        "has_user_valves": false  // default; server-side checks its own DB
                    ]
                    if let icon = fn.iconURL, !icon.isEmpty {
                        filterObj["icon"] = icon
                    }
                    resolvedFilterObjects.append(filterObj)
                }
            }

            model.filterIds = resolvedFilterIds

            // Inject the resolved filter objects into rawModelItem["filters"] so the
            // server receives model_item.filters[] just like the web client sends.
            if model.rawModelItem != nil {
                model.rawModelItem?["filters"] = resolvedFilterObjects
            }
        } catch {
            // Non-critical — keep whatever filterIds the model already has
            logger.debug("Failed to resolve filters: \(error.localizedDescription)")
        }
    }

    /// Incrementally applies server-side model defaults to the current session
    /// **without** clearing existing user selections.
    ///
    /// Unlike `syncUIWithModelDefaults()` (which is a full reset intended for
    /// model switches and new conversations), this method only ADDS newly-discovered
    /// defaults. It respects `userDisabledToolIds` so tools the user explicitly
    /// toggled off stay off, and it never removes tools/features the user turned on.
    ///
    /// Called by `refreshSelectedModelMetadata()` before each message send.
    private func applyIncrementalModelDefaults(for model: AIModel) {
        let defaults = model.defaultFeatureIds
        let caps = model.capabilities ?? [:]

        func isTruthy(_ key: String) -> Bool {
            guard let value = caps[key] else { return false }
            return ["1", "true"].contains(value.lowercased())
        }

        // Only enable features if admin has them on AND the user hasn't explicitly
        // turned them off this session. Never force-disable ones the user turned on.
        if defaults.contains("web_search") && isTruthy("web_search")
            && !userDisabledBuiltinFeatures.contains("web_search") {
            webSearchEnabled = true
        }
        if defaults.contains("image_generation") && isTruthy("image_generation")
            && !userDisabledBuiltinFeatures.contains("image_generation") {
            imageGenerationEnabled = true
        }
        if defaults.contains("code_interpreter") && isTruthy("code_interpreter")
            && !userDisabledBuiltinFeatures.contains("code_interpreter") {
            codeInterpreterEnabled = true
        }

        // Add model-assigned tools (admin attached to this model) that aren't
        // user-disabled and aren't already selected.
        for toolId in model.toolIds {
            if !userDisabledToolIds.contains(toolId) {
                selectedToolIds.insert(toolId)
            }
        }

        // Add any globally-enabled tools (is_active) that aren't user-disabled.
        for tool in availableTools where tool.isEnabled {
            if !userDisabledToolIds.contains(tool.id) {
                selectedToolIds.insert(tool.id)
            }
        }
    }

    /// Whether the memory feature is available for use in chats.
    ///
    /// Memory context injection is model-agnostic on the server — it works for ALL models
    /// by default (server's `model_allows_memory` defaults to `true`). The only server-side
    /// gate is `memories.system_context.enable` (controlled via admin settings).
    ///
    /// We show the memory toggle whenever the server has memories enabled (`features.memories`)
    /// AND the user has opted in (`memoryEnabled`), not just for models with `builtinTools.memory`.
    /// The `builtinTools.memory` flag is for the native function-calling memory *tool*, which is
    /// a separate concept from system-context injection.
    var isMemoryAvailable: Bool {
        // Use server config's memories feature flag — same logic as web UI which shows
        // the memory toggle based on `$config?.features?.enable_memories` not model metadata.
        activeChatStore?.serverFeatures?.memories ?? memoryEnabled
    }

    /// Syncs the UI toggles (web search pill, selected tools) with the selected
    /// model's server-configured defaults. Matches the OpenWebUI web client's
    /// `setDefaults()` which pre-enables features and tools from model metadata.
    ///
    /// Called on:
    /// - Initial model load (`loadModels`)
    /// - Model switch (`selectModel`)
    /// - New conversation (`startNewConversation`)
    private func syncUIWithModelDefaults() {
        guard let model = selectedModel else { return }
        let defaults = model.defaultFeatureIds
        let caps = model.capabilities ?? [:]

        func isTruthy(_ key: String) -> Bool {
            guard let value = caps[key] else { return false }
            return ["1", "true"].contains(value.lowercased())
        }

        // Reset all feature toggles to match THIS model's config.
        // Each toggle is set to true only if the model has it as a
        // default AND the capability is enabled. This ensures switching
        // models correctly reflects per-model feature availability.
        // Suppress tracking so these internal resets don't pollute userDisabledBuiltinFeatures.
        suppressBuiltinFeatureTracking = true
        webSearchEnabled = defaults.contains("web_search") && isTruthy("web_search")
        imageGenerationEnabled = defaults.contains("image_generation") && isTruthy("image_generation")
        codeInterpreterEnabled = defaults.contains("code_interpreter") && isTruthy("code_interpreter")
        suppressBuiltinFeatureTracking = false

        // Memory is an account-level preference stored server-side (ui.memory).
        // Fetch it once for all models (not just memory-capable ones) so the
        // value is cached for when a capable model is selected later.
        Task { await fetchMemorySettingFromServer() }
        Task { await fetchMessageQueueSettingFromServer() }
        // Store the task so populateCommonRequestFields can await it before
        // building a request — prevents the race where params are read before
        // the fetch completes (which caused the system prompt to be ignored).
        userDefaultParamsTask = Task { await fetchUserDefaultParamsFromServer() }

        // Reset and re-populate tool selections for this model.
        // Clear first so tools from a previous model don't persist.
        selectedToolIds = []
        if !model.toolIds.isEmpty {
            for toolId in model.toolIds {
                selectedToolIds.insert(toolId)
            }
        }
        // Also re-add globally-enabled tools (server admin marked as active)
        for tool in availableTools where tool.isEnabled {
            selectedToolIds.insert(tool.id)
        }
    }

    /// Fetches the user's memory preference from the server.
    ///
    /// Calls `GET /api/v1/users/user/settings` and reads `ui.memory`.
    /// This is the same endpoint the web UI writes to when the user
    /// toggles memory in Settings → Personalization. Fire-and-forget
    /// — failure just leaves `memoryEnabled` at its last known value.
    func fetchMemorySettingFromServer() async {
        // Use session-level cache — avoids a redundant GET /api/v1/users/user/settings
        // on every model load/switch. Cache is cleared by ActiveChatStore.clear()
        // on logout or server switch, ensuring a fresh fetch each session.
        if let cached = activeChatStore?.cachedMemorySetting {
            memoryEnabled = cached
            logger.debug("Memory setting from cache: \(cached)")
            return
        }
        guard let apiClient = manager?.apiClient else { return }
        do {
            let settings = try await apiClient.getUserSettings()
            if let ui = settings["ui"] as? [String: Any],
               let memory = ui["memory"] as? Bool {
                // User has an explicit preference stored in their settings
                memoryEnabled = memory
                activeChatStore?.cachedMemorySetting = memory
                logger.debug("Memory setting fetched from server: \(memory)")
            } else {
                // ui.memory is absent — the user has never explicitly set the toggle.
                // Fall back to the server-level default, exactly matching OpenWebUI:
                //   $settings?.memory ?? $config?.features?.enable_memories ?? false
                // When an admin enables memories globally, new accounts inherit `true`
                // without ever having a ui.memory key in their settings JSON.
                let serverDefault = activeChatStore?.serverFeatures?.memories ?? false
                memoryEnabled = serverDefault
                activeChatStore?.cachedMemorySetting = serverDefault
                logger.debug("Memory setting absent — using server default: \(serverDefault)")
            }
        } catch {
            logger.debug("Failed to fetch memory setting: \(error.localizedDescription)")
        }
    }

    /// Persists the memory toggle state to the server user settings.
    ///
    /// Calls `POST /api/v1/users/user/settings/update` with `{"ui":{"memory":enabled}}`
    /// so the web UI and app stay in sync. Fire-and-forget — the toggle
    /// is already updated locally.
    func updateMemorySettingOnServer(enabled: Bool) {
        guard let apiClient = manager?.apiClient else { return }
        Task {
            do {
                // Use merge helper so we only update `memory` without
                // overwriting `models`, `pinnedModels`, or any other ui keys.
                try await apiClient.mergeUserUISettings(["memory": enabled])
                logger.debug("Memory setting saved to server: \(enabled)")
            } catch {
                logger.debug("Failed to save memory setting: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Message Queue Setting

    /// Fetches the user's message queue preference from the server (`ui.enableMessageQueue`).
    /// Uses session-level cache to avoid redundant fetches.
    func fetchMessageQueueSettingFromServer() async {
        if let cached = activeChatStore?.cachedMessageQueueSetting {
            enableMessageQueue = cached
            logger.debug("Message queue setting from cache: \(cached)")
            return
        }
        guard let apiClient = manager?.apiClient else { return }
        do {
            let settings = try await apiClient.getUserSettings()
            if let ui = settings["ui"] as? [String: Any],
               let enabled = ui["enableMessageQueue"] as? Bool {
                enableMessageQueue = enabled
                activeChatStore?.cachedMessageQueueSetting = enabled
                logger.debug("Message queue setting fetched from server: \(enabled)")
            }
        } catch {
            logger.debug("Failed to fetch message queue setting: \(error.localizedDescription)")
        }
    }

    /// Persists the message queue toggle state to the server user settings.
    func updateMessageQueueSettingOnServer(enabled: Bool) {
        guard let apiClient = manager?.apiClient else { return }
        activeChatStore?.cachedMessageQueueSetting = enabled
        Task {
            do {
                try await apiClient.mergeUserUISettings(["enableMessageQueue": enabled])
                logger.debug("Message queue setting saved to server: \(enabled)")
            } catch {
                logger.debug("Failed to save message queue setting: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - User Default Params

    /// Fetches the user's default params (`ui.system` + `ui.params`) from the server.
    /// Always re-fetches so changes made on other devices or the web UI are picked
    /// up immediately — no stale system prompt or param override is ever injected.
    /// The result is stored in `activeChatStore?.cachedUserDefaultParams` for use
    /// by the current request; previous value is replaced on each successful fetch.
    func fetchUserDefaultParamsFromServer() async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let params = try await apiClient.fetchUserDefaultParams()
            activeChatStore?.cachedUserDefaultParams = params
            logger.debug("User default params fetched from server (hasOverride=\(params.hasAnyOverride))")
        } catch {
            logger.debug("Failed to fetch user default params: \(error.localizedDescription)")
        }
    }

    // MARK: - Pinned Models

    /// Fetches the user's pinned model IDs from the server.
    ///
    /// Reads `ui.pinnedModels` from `GET /api/v1/users/user/settings`.
    /// Uses session-level cache to avoid redundant fetches.
    func fetchPinnedModels() async {
        // Use session-level cache
        if let cached = activeChatStore?.cachedPinnedModelIds {
            pinnedModelIds = cached
            return
        }
        guard let apiClient = manager?.apiClient else { return }
        do {
            let settings = try await apiClient.getUserSettings()
            if let ui = settings["ui"] as? [String: Any],
               let pinned = ui["pinnedModels"] as? [String] {
                pinnedModelIds = pinned
                activeChatStore?.cachedPinnedModelIds = pinned
                logger.debug("Pinned models fetched: \(pinned)")
            }
        } catch {
            logger.debug("Failed to fetch pinned models: \(error.localizedDescription)")
        }
    }

    /// Toggles a model's pinned state and syncs to the server.
    ///
    /// Calls `POST /api/v1/users/user/settings/update` with
    /// `{"ui": {"models": [...], "pinnedModels": [...]}}` matching the web UI format.
    func togglePinModel(_ modelId: String) {
        if pinnedModelIds.contains(modelId) {
            pinnedModelIds.removeAll { $0 == modelId }
        } else {
            pinnedModelIds.append(modelId)
        }
        // Update cache immediately
        activeChatStore?.cachedPinnedModelIds = pinnedModelIds

        // Sync to server (fire-and-forget).
        // Use merge helper so we ONLY update `pinnedModels` — previously this
        // also wrote `models` (the default model key) with the pinned IDs array,
        // which overwrote the user's default model selection on every pin action.
        let currentPinned = pinnedModelIds
        guard let apiClient = manager?.apiClient else { return }
        Task {
            do {
                try await apiClient.mergeUserUISettings(["pinnedModels": currentPinned])
                logger.debug("Pinned models saved to server: \(currentPinned)")
            } catch {
                logger.debug("Failed to save pinned models: \(error.localizedDescription)")
            }
        }
    }

    /// Populates all common request fields that are shared across sendMessage,
    /// regenerateResponse, and regenerateIntoExistingMessage.
    ///
    /// This is the single source of truth for:
    /// - model metadata (modelItem, filterIds, isPipeModel)
    /// - features, params (system prompt + function_calling)
    /// - stream_options, variables (system vars + substitution into system prompt)
    /// - toolIds, skillIds, terminalId, backgroundTasks
    ///
    /// Call this after constructing the basic ChatCompletionRequest and before sending.
    private func populateCommonRequestFields(_ request: inout ChatCompletionRequest) async {
        // Refresh model metadata to pick up live admin changes
        await refreshSelectedModelMetadata()
        if var mi = selectedModel?.rawModelItem {
            // Ensure owned_by and object are non-null strings for pipe model routing.
            // The single-model endpoint omits these fields; without them the server's
            // Python pipe code does `owned_by.startswith(...)` on None and crashes.
            if mi["owned_by"] == nil || mi["owned_by"] is NSNull { mi["owned_by"] = "openai" }
            if mi["object"] == nil || mi["object"] is NSNull { mi["object"] = "model" }
            // Also patch info.base_model_id: OpenWebUI's pipe routing middleware does
            // `base_model_id.startswith(...)` which crashes with NoneType when null.
            if var info = mi["info"] as? [String: Any] {
                if info["base_model_id"] == nil || info["base_model_id"] is NSNull {
                    info["base_model_id"] = ""
                }
                mi["info"] = info
            } else {
                // info is absent or NSNull — the server's pipe middleware calls
                // base_model_id.startswith(...) which crashes on None.
                // Inject a minimal dict matching what get_function_models() always provides.
                mi["info"] = ["base_model_id": ""]
            }
            request.modelItem = mi
        } else {
            if self.selectedModel?.isPipeModel == true {
                self.logger.warning("[pipe] rawModelItem is nil for pipe model '\(self.selectedModel?.id ?? "?")' — model_item will be omitted from request")
            }
            request.modelItem = nil
        }

        // Filter IDs from model's server-configured filter list
        let filterIds = selectedModel?.filterIds ?? []
        if !filterIds.isEmpty { request.filterIds = filterIds }

        // Always send the full features object with explicit true/false values
        request.features = buildChatFeatures()

        // Await any pending model config fetch (ensures functionCallingMode is populated)
        await modelConfigTask?.value
        // Await any pending user default params fetch (ensures system prompt and params
        // are populated before building the request — prevents the race where params are
        // read as nil when the user sends immediately after opening a new chat).
        await userDefaultParamsTask?.value

        // Build request params: chat-level overrides + system prompt + function_calling
        // Priority: per-chat params > user My Defaults params
        var params: [String: Any] = activeChatStore?.cachedUserDefaultParams?.toRequestParams() ?? [:]
        if let chatP = conversation?.chatParams {
            params = chatP.mergedOver(base: params)
        }
        let effectiveSP: String? = {
            if let cp = conversation?.chatParams?.systemPrompt,
               !cp.trimmingCharacters(in: .whitespaces).isEmpty { return cp }
            // Fallback to user My Defaults system prompt
            if let dp = activeChatStore?.cachedUserDefaultParams?.systemPrompt,
               !dp.trimmingCharacters(in: .whitespaces).isEmpty { return dp }
            // Fallback to the workspace model's server-side system prompt.
            // This ensures that when a user changes the workspace model's system
            // prompt in OpenWebUI, the app picks up the fresh value on the next
            // send — even for existing chats where chatParams was set at creation
            // time and never re-read from the server.
            if let info = selectedModel?.rawModelItem?["info"] as? [String: Any],
               let mParams = info["params"] as? [String: Any],
               let sp = mParams["system"] as? String,
               !sp.trimmingCharacters(in: .whitespaces).isEmpty { return sp }
            return nil
        }()
        if let sp = effectiveSP, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            params["system"] = sp
        }
        if let fc = selectedModel?.functionCallingMode, fc == "native" {
            params["function_calling"] = "native"
        }
        if !params.isEmpty { request.params = params }

        // Always include usage stats in streaming response
        request.streamOptions = ["include_usage": true]

        // Build and merge system variables ({{USER_LOCATION}}, {{USER_NAME}}, etc.)
        // Keys use {{VARIABLE_NAME}} format — the server does literal find-and-replace
        // on the model's system prompt. Also nested in metadata.variables (where the
        // server's apply_system_prompt_to_body() actually reads them).
        let sysVars = PromptService.buildSystemVariablesDict(
            userName: activeChatStore?.cachedUserName,
            userEmail: activeChatStore?.cachedUserEmail
        )
        var mergedVars = request.variables ?? [:]
        for (k, v) in sysVars { mergedVars[k] = v }
        request.variables = mergedVars

        // Also substitute directly into the overridden system prompt string.
        // The server uses params.system as-is without re-substituting variables,
        // so we must resolve them here for client-side system prompt overrides.
        if let rawSP = params["system"] as? String {
            var resolved = rawSP
            for (placeholder, value) in sysVars {
                if let strValue = value as? String {
                    resolved = resolved.replacingOccurrences(of: placeholder, with: strValue)
                }
            }
            if resolved != rawSP {
                params["system"] = resolved
                request.params = params
            }
        }

        // Tool IDs (user selection respects manual toggles via userDisabledToolIds)
        let allToolIds = Array(selectedToolIds)
        if !allToolIds.isEmpty { request.toolIds = allToolIds }

        // folder_id: include when chatting inside a folder so the server tags the
        // chat, emits sidebar events with the right folder_id, and applies
        // folder-level knowledge/system prompts — mirrors OpenWebUI's folder_id field.
        let effectiveFolderId = folderContextId ?? conversation?.folderId
        if let fid = effectiveFolderId, !fid.isEmpty {
            request.folderId = fid
        }

        // Terminal ID if enabled
        if terminalEnabled, let terminalServer = selectedTerminalServer {
            request.terminalId = terminalServer.id
        }

        // Background tasks — respect both server config and user settings
        let serverConfig = activeChatStore?.serverTaskConfig ?? .default
        let titleGenEnabled = (UserDefaults.standard.object(forKey: "titleGenerationEnabled") as? Bool ?? true)
            && serverConfig.enableTitleGeneration
        let suggestionsEnabled = (UserDefaults.standard.object(forKey: "suggestionsEnabled") as? Bool ?? true)
            && serverConfig.enableFollowUpGeneration
        let tagsEnabled = serverConfig.enableTagsGeneration
        let isFirst = (conversation?.messages.filter { !$0.isStreaming }.count ?? 0) <= 2

        // Build background_tasks matching the web client's exact behaviour:
        // - follow_up_generation is ALWAYS sent with its boolean value (true/false)
        // - title_generation and tags_generation are only included on the first
        //   message of a saved chat (with their boolean value); omitted otherwise
        // - web_search is NOT a background task — it belongs only in features.web_search
        var bgTasks: [String: Any] = [:]
        bgTasks["follow_up_generation"] = suggestionsEnabled
        if isFirst {
            bgTasks["title_generation"] = titleGenEnabled
            bgTasks["tags_generation"] = tagsEnabled
        }
        request.backgroundTasks = bgTasks

        #if DEBUG
        if let body = try? JSONSerialization.data(withJSONObject: request.toJSON(), options: .prettyPrinted),
           let str = String(data: body, encoding: .utf8) {
            logger.debug("[chat request body]\n\(str)")
        }
        #endif
    }

    /// Builds chat features by merging user toggles with the model's admin-configured
    /// default features. Matches the OpenWebUI web client's `setDefaults()` + `getFeatures()`.
    ///
    /// Memory is based solely on the user's account setting (`memoryEnabled`), matching
    /// the web client which sends `features.memory` based on `$user.settings.ui.memory`
    /// without gating on per-model `builtinTools`. The server already knows which models
    /// support memory and ignores the flag for models that don't.
    private func buildChatFeatures() -> ChatCompletionRequest.ChatFeatures {
        var features = ChatCompletionRequest.ChatFeatures()

        // Use ONLY the current toggle state. Server defaults are already applied
        // to these toggles at init time via syncUIWithModelDefaults() — which runs
        // on model load, model switch, and new-conversation. By the time we build
        // the request, the toggle reflects either the server default OR the user's
        // explicit override. Checking server defaults again here would ignore the
        // user toggling a feature OFF mid-chat (the original bug).
        if webSearchEnabled {
            features.webSearch = true
        }
        if imageGenerationEnabled {
            features.imageGeneration = true
        }
        if codeInterpreterEnabled {
            features.codeInterpreter = true
        }
        // Memory: send based on account-level setting only (matches web client).
        // No gate on selectedModel?.supportsMemory — the server decides per-model
        // whether to inject the memory tool; we just relay the user's preference.
        if memoryEnabled {
            features.memory = true
        }
        if isVoiceMode {
            features.voice = true
        }

        return features
    }

    /// Builds API messages array, fetching image base64 from server for vision.
    /// Matches Flutter's `_buildMessagePayloadWithAttachments` which calls
    /// `api.getFileContent(fileId)` to get base64 data URLs for the LLM.
    /// Builds a lightweight `[{role, content}]` message array from the current
    /// conversation without fetching image data from the server.
    /// Used for `/api/chat/completed` so filter outlets receive the full
    /// conversation history and can run their post-processing logic.
    private func buildSimpleAPIMessages() -> [[String: Any]] {
        guard let conversation else { return [] }
        var msgs: [[String: Any]] = []
        let simpleEffectiveSP: String? = {
            if let cp = conversation.chatParams?.systemPrompt,
               !cp.trimmingCharacters(in: .whitespaces).isEmpty { return cp }
            if let dp = activeChatStore?.cachedUserDefaultParams?.systemPrompt,
               !dp.trimmingCharacters(in: .whitespaces).isEmpty { return dp }
            return nil
        }()
        if let sp = simpleEffectiveSP, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            msgs.append(["role": "system", "content": sp])
        }
        for msg in conversation.messages where !msg.isStreaming {
            msgs.append(["role": msg.role.rawValue, "content": msg.content])
        }
        return msgs
    }

    /// Builds a deduplicated list of file reference dicts from ALL user messages in the
    /// current conversation's history tree, optionally excluding a specific message ID.
    ///
    /// This ensures the server always has all previously-uploaded file references so it
    /// continues RAG retrieval for documents attached in earlier turns of the conversation.
    ///
    /// - Parameter excludingId: A user message ID to skip (e.g. the current message whose
    ///   files are already included via the live fileRefs/allFileRefs array). Pass `nil`
    ///   to include every user message.
    private func collectHistoryFileRefs(excludingId: String?) async -> [[String: Any]] {
        guard let conv = conversation else { return [] }

        // Gather files only from user messages on the ACTIVE branch (flat list).
        // Using all tree nodes would include sibling/version nodes from inactive
        // branches — e.g. the old user node after an edit with an attachment
        // removed — causing the removed file to be re-added to the request.
        var allStoredFiles: [ChatMessageFile] = []
        let activeMsgIds = Set(conv.messages.map { $0.id })
        let userNodes: [HistoryNode]
        if conv.history.isPopulated {
            userNodes = conv.history.nodes.values
                .filter { $0.role == .user && $0.id != excludingId && activeMsgIds.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
        } else {
            // Fallback: use flat messages array
            userNodes = conv.messages
                .filter { $0.role == .user && $0.id != excludingId }
                .map { msg in
                    HistoryNode(id: msg.id, role: msg.role, content: msg.content,
                                timestamp: msg.timestamp, files: msg.files)
                }
        }
        for node in userNodes {
            allStoredFiles.append(contentsOf: node.files)
        }

        guard !allStoredFiles.isEmpty else { return [] }

        var seenIds = Set<String>()
        var refs: [[String: Any]] = []
        for storedFile in allStoredFiles {
            guard let fileId = storedFile.url else { continue }
            guard !seenIds.contains(fileId) else { continue }
            // Skip IDs that the user explicitly removed via the Controls panel.
            // This prevents ghost re-injection from history nodes.
            guard !removedContextIds.contains(fileId) else { continue }
            seenIds.insert(fileId)

            if storedFile.type == "note" {
                var ref: [String: Any] = [
                    "type": "note",
                    "id": fileId,
                    "name": storedFile.name ?? "Note",
                    "status": "processed"
                ]
                if let note = await notesManager?.fetchNote(id: fileId) {
                    ref["data"] = ["content": ["md": note.content]]
                }
                refs.append(ref)
            } else if storedFile.type == "collection" {
                refs.append([
                    "type": "collection",
                    "id": fileId,
                    "name": storedFile.name ?? fileId
                ])
            } else {
                var ref: [String: Any] = ["type": storedFile.type ?? "file", "id": fileId, "url": fileId]
                if let name = storedFile.name { ref["name"] = name }
                if let ct = storedFile.contentType { ref["content_type"] = ct }
                refs.append(ref)
            }
        }
        return refs
    }

    private func buildAPIMessagesAsync() async -> [[String: Any]] {
        guard let conversation else { return [] }
        var apiMessages: [[String: Any]] = []
        let asyncEffectiveSP: String? = {
            if let cp = conversation.chatParams?.systemPrompt,
               !cp.trimmingCharacters(in: .whitespaces).isEmpty { return cp }
            if let dp = activeChatStore?.cachedUserDefaultParams?.systemPrompt,
               !dp.trimmingCharacters(in: .whitespaces).isEmpty { return dp }
            return nil
        }()
        if let sp = asyncEffectiveSP, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            apiMessages.append(["role": "system", "content": sp])
        }
        for message in conversation.messages where !message.isStreaming {
            let imageFiles = message.files.filter { f in
                f.type == "image" || (f.contentType ?? "").hasPrefix("image/")
            }
            let nonImageFiles = message.files.filter { f in
                f.type != "image" && !(f.contentType ?? "").hasPrefix("image/")
            }

            if !imageFiles.isEmpty && message.role == .user {
                // Build multimodal content array (OpenAI vision format)
                // Fetch image base64 from server, matching Flutter behavior
                var contentArray: [[String: Any]] = []
                if !message.content.isEmpty {
                    contentArray.append(["type": "text", "text": message.content])
                }
                for imgFile in imageFiles {
                    if let fileId = imgFile.url, !fileId.isEmpty {
                        if fileId.hasPrefix("data:image/") {
                            // Already a data URL
                            contentArray.append([
                                "type": "image_url",
                                "image_url": ["url": fileId]
                            ])
                        } else {
                            // Fetch from server, downsample to ≤ 2 MP, then base64-encode.
                            // The server stores the original full-resolution file; without
                            // downsampling here, the base64 payload easily exceeds the
                            // vision API's 5 MB per-image limit.
                            if let apiClient = manager?.apiClient {
                                do {
                                    let (rawData, contentType) = try await apiClient.getFileContent(id: fileId)
                                    let data = FileAttachmentService.downsampleForUpload(data: rawData)
                                    let base64 = data.base64EncodedString()
                                    let mimeType = contentType.hasPrefix("image/") ? contentType : "image/jpeg"
                                    let dataUrl = "data:\(mimeType);base64,\(base64)"
                                    contentArray.append([
                                        "type": "image_url",
                                        "image_url": ["url": dataUrl]
                                    ])
                                } catch {
                                    logger.warning("Failed to fetch image content for \(fileId): \(error)")
                                    // Fallback: send file ID, server may resolve it
                                    contentArray.append([
                                        "type": "image_url",
                                        "image_url": ["url": fileId]
                                    ])
                                }
                            }
                        }
                    }
                }

                var msgDict: [String: Any] = [
                    "role": message.role.rawValue,
                    "content": contentArray
                ]

                if !nonImageFiles.isEmpty {
                    msgDict["files"] = nonImageFiles.compactMap { f -> [String: Any]? in
                        guard let id = f.url else { return nil }
                        return ["type": "file", "id": id, "url": id]
                    }
                }

                apiMessages.append(msgDict)
            } else {
                var msgDict: [String: Any] = [
                    "role": message.role.rawValue,
                    "content": message.content
                ]

                if !message.files.isEmpty {
                    msgDict["files"] = message.files.compactMap { f -> [String: Any]? in
                        guard let id = f.url else { return nil }
                        return ["type": f.type ?? "file", "id": id, "url": id]
                    }
                } else if !message.attachmentIds.isEmpty {
                    msgDict["files"] = message.attachmentIds.map { id -> [String: Any] in
                        ["type": "file", "id": id, "url": id]
                    }
                }

                apiMessages.append(msgDict)
            }
        }
        return apiMessages
    }

    private func parseStatusData(_ data: [String: Any]) -> ChatStatusUpdate {
        // Parse queries from various formats (array of strings, or single string)
        var queries: [String] = []
        if let qArray = data["queries"] as? [String] {
            queries = qArray.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else if let qStr = data["queries"] as? String, !qStr.isEmpty {
            queries = [qStr]
        }

        return ChatStatusUpdate(
            action: data["action"] as? String,
            description: data["description"] as? String,
            done: data["done"] as? Bool,
            hidden: data["hidden"] as? Bool,
            urls: (data["urls"] as? [String]) ?? [],
            occurredAt: .now,
            count: data["count"] as? Int ?? (data["count"] as? Double).map { Int($0) },
            query: data["query"] as? String,
            queries: queries
        )
    }

    /// Parses OpenWebUI source payloads into ChatSourceReference objects.
    /// Matches the Flutter `parseOpenWebUISourceList` logic which handles
    /// nested `source`, `document`, `metadata`, `distances` arrays.
    ///
    /// OpenWebUI sends sources as:
    /// ```json
    /// [{ "source": {...}, "document": ["...","..."],
    ///    "metadata": [{"source":"url1","name":"..."}, {"source":"url2",...}],
    ///    "distances": [0.5, 0.7] }]
    /// ```
    /// Each metadata item = one unique source reference. The Flutter parser
    /// groups by metadata.source key and creates one ChatSourceReference per
    /// unique URL.
    private func parseSources(_ array: [[String: Any]]) -> [ChatSourceReference]? {
        // Accumulate by unique key (URL or fallback index)
        var accumulated: [(key: String, url: String?, title: String?, snippet: String?, type: String?, meta: [String: String])] = []
        var seenKeys = Set<String>()
        var fallbackIdx = 0

        for entry in array {
            // Extract nested source object
            var baseSource = (entry["source"] as? [String: Any]) ?? [:]
            for key in ["id", "name", "title", "url", "link", "type"] {
                if let value = entry[key], baseSource[key] == nil {
                    baseSource[key] = value
                }
            }

            let documents = (entry["document"] as? [Any]) ?? []
            let metadataRaw = entry["metadata"]
            let metadataList: [[String: Any]]
            if let list = metadataRaw as? [[String: Any]] {
                metadataList = list
            } else if let single = metadataRaw as? [String: Any] {
                metadataList = [single]
            } else {
                metadataList = []
            }

            // Determine iteration count — max of documents, metadata, distances
            let loopCount = max(1, max(documents.count, metadataList.count))

            for i in 0..<loopCount {
                let meta = i < metadataList.count ? metadataList[i] : [:]
                let document = i < documents.count ? documents[i] : nil

                // Resolve unique key for this source (usually the URL)
                let idCandidate: String? = {
                    for k in ["source", "id"] {
                        if let v = meta[k] as? String, !v.isEmpty { return v }
                    }
                    if let v = baseSource["id"] as? String, !v.isEmpty { return v }
                    return nil
                }()

                let key = idCandidate ?? "__fallback_\(fallbackIdx)"
                if idCandidate == nil { fallbackIdx += 1 }

                // Skip duplicates with the same key
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)

                // Resolve URL
                let url: String? = {
                    for k in ["source", "url", "link"] {
                        if let v = meta[k] as? String, v.hasPrefix("http") { return v }
                    }
                    if let v = baseSource["url"] as? String, v.hasPrefix("http") { return v }
                    if let id = idCandidate, id.hasPrefix("http") { return id }
                    return nil
                }()

                // Resolve title — reject any value that is itself a URL (starts with
                // "http"). Some providers store the page URL in the "name"/"title" field
                // when no real title is available; those fall through to the domain
                // extractor in displayLabel() instead of showing a raw URL as the pill label.
                let title: String? = {
                    func validTitle(_ s: String?) -> String? {
                        guard let s, !s.isEmpty,
                              !s.hasPrefix("http://"), !s.hasPrefix("https://") else { return nil }
                        return s
                    }
                    if let n = validTitle(meta["name"] as? String) { return n }
                    if let t = validTitle(meta["title"] as? String) { return t }
                    if let n = validTitle(baseSource["name"] as? String) { return n }
                    if let t = validTitle(baseSource["title"] as? String) { return t }
                    if let id = idCandidate, !id.isEmpty, !id.hasPrefix("http") { return id }
                    return nil
                }()

                // Extract snippet from document
                let snippet: String? = {
                    if let doc = document {
                        if let s = doc as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                            return String(s.trimmingCharacters(in: .whitespaces).prefix(200))
                        }
                    }
                    return nil
                }()

                let type = (baseSource["type"] as? String) ?? (meta["type"] as? String)

                // Build metadata dict
                var metaDict: [String: String] = [:]
                for (k, v) in meta {
                    if let s = v as? String { metaDict[k] = s }
                }

                accumulated.append((
                    key: key,
                    url: url,
                    title: title,
                    snippet: snippet,
                    type: type,
                    meta: metaDict
                ))
            }
        }

        let results = accumulated.map { item in
            ChatSourceReference(
                id: item.key.hasPrefix("__fallback_") ? nil : item.key,
                title: item.title,
                url: item.url,
                snippet: item.snippet,
                type: item.type,
                metadata: item.meta.isEmpty ? nil : item.meta
            )
        }

        return results.isEmpty ? nil : results
    }

    private func extractErrorContent(from data: [String: Any]) -> String {
        // Try multiple error formats used by OpenWebUI/LiteLLM
        if let err = data["error"] {
            if let errMap = err as? [String: Any] {
                if let content = errMap["content"] as? String, !content.isEmpty { return content }
                if let message = errMap["message"] as? String, !message.isEmpty { return message }
            }
            if let errStr = err as? String, !errStr.isEmpty { return errStr }
        }
        if let msg = data["message"] as? String, !msg.isEmpty { return msg }
        if let detail = data["detail"] as? String, !detail.isEmpty { return detail }
        // Try to extract from nested content
        if let content = data["content"] as? String, !content.isEmpty { return content }
        // Last resort: serialize entire payload for debugging
        if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []),
           let jsonStr = String(data: jsonData, encoding: .utf8), !jsonStr.isEmpty {
            return jsonStr
        }
        return "An unexpected error occurred"
    }

    /// Extracts and updates tasks from a create_tasks or update_task tool call block
    /// embedded in the streaming assistant message content.
    /// Only processes tool calls that are fully complete (isDone == true) to avoid
    /// parsing truncated/invalid JSON that arrives token-by-token during streaming.
    private func extractAndApplyTasksFromContent(_ content: String) {
        guard content.contains("create_tasks") || content.contains("update_task") else { return }

        let ordered = ToolCallParser.parseOrdered(content)
        for segment in ordered.segments {
            guard case .toolCall(let tc) = segment else { continue }
            guard tc.name == "create_tasks" || tc.name == "update_task" else { continue }
            // Only process complete tool calls — streaming delivers truncated JSON
            // in the arguments attribute which JSONSerialization cannot parse.
            guard tc.isDone else { continue }

            if tc.name == "create_tasks" {
                // Prefer tc.result (server-authoritative, contains assigned IDs),
                // fall back to tc.arguments using robust multi-strategy parsing.
                let taskDict = parseTaskJSON(tc.result) ?? parseTaskJSON(tc.arguments)
                if let taskArray = taskDict?["tasks"] as? [[String: Any]] {
                    let parsed = taskArray.compactMap { t -> ChatTask? in
                        guard let id = t["id"] as? String,
                              let content = t["content"] as? String,
                              let status = t["status"] as? String
                        else { return nil }
                        return ChatTask(id: id, content: content, status: status)
                    }
                    if !parsed.isEmpty {
                        tasks = parsed
                        conversation?.tasks = parsed
                    }
                }
            } else if tc.name == "update_task" {
                // Prefer tc.result — server returns the full updated task list after each update_task call.
                // Fall back to single-task delta from tc.arguments if result is unavailable.
                if let resultDict = parseTaskJSON(tc.result),
                   let taskArray = resultDict["tasks"] as? [[String: Any]] {
                    let parsed = taskArray.compactMap { t -> ChatTask? in
                        guard let id = t["id"] as? String,
                              let content = t["content"] as? String,
                              let status = t["status"] as? String
                        else { return nil }
                        return ChatTask(id: id, content: content, status: status)
                    }
                    if !parsed.isEmpty {
                        tasks = parsed
                        conversation?.tasks = parsed
                    }
                } else {
                    // Fallback: apply a single-task status change from arguments
                    let argsDict = parseTaskJSON(tc.arguments)
                    if let json = argsDict,
                       let taskId = json["id"] as? String ?? json["task_id"] as? String,
                       let newStatus = json["status"] as? String {
                        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
                            tasks[idx].status = newStatus
                        }
                        if let convIdx = conversation?.tasks.firstIndex(where: { $0.id == taskId }) {
                            conversation?.tasks[convIdx].status = newStatus
                        }
                    }
                }
            }
        }
    }

    /// Robustly parses a JSON string into a `[String: Any]` dictionary.
    /// Handles four encoding variations seen in server-sent tool call attributes:
    /// 1. Plain JSON object string
    /// 2. Double-encoded: outer JSON is a string whose value is a JSON object
    /// 3. Backslash-escaped quotes (`\"`) that must be stripped before parsing
    /// 4. Regex extraction of individual task objects as a last resort
    private func parseTaskJSON(_ source: String?) -> [String: Any]? {
        guard let source, !source.isEmpty else { return nil }

        // Strategy 1: direct parse
        if let data = source.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        // Strategy 2: double-encoded — outer value is a JSON string wrapping another JSON object
        if let data = source.data(using: .utf8),
           let str = try? JSONSerialization.jsonObject(with: data) as? String,
           let innerData = str.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] {
            return json
        }

        // Strategy 3: strip backslash-escaped quotes produced by HTML attribute encoding
        let unescaped = source.replacingOccurrences(of: "\\\"", with: "\"")
        if let data = unescaped.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        // Strategy 4: regex extraction — pull task objects directly from the raw string
        let taskPattern = #"\{[^{}]*"id"\s*:\s*"[^"]+[^{}]*"content"\s*:\s*"[^"]+[^{}]*"status"\s*:\s*"[^"]+"[^{}]*\}"#
        if let regex = try? NSRegularExpression(pattern: taskPattern),
           let tasksRange = source.range(of: #""tasks"\s*:\s*\["#, options: .regularExpression) {
            let searchString = String(source[tasksRange.lowerBound...])
            let nsSearch = searchString as NSString
            let matches = regex.matches(in: searchString, range: NSRange(location: 0, length: nsSearch.length))
            let taskDicts: [[String: Any]] = matches.compactMap { match in
                let raw = nsSearch.substring(with: match.range)
                guard let d = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return nil }
                return obj
            }
            if !taskDicts.isEmpty {
                return ["tasks": taskDicts]
            }
        }

        return nil
    }

    private func updateAssistantMessage(
        id: String, content: String, isStreaming: Bool,
        sources: [ChatSourceReference]? = nil,
        statusHistory: [ChatStatusUpdate]? = nil,
        error: ChatMessageError? = nil
    ) {
        if isStreaming && streamingStore.streamingMessageId == id {
            // ── STREAMING PATH ──
            // Route content to the isolated StreamingContentStore.
            // This avoids mutating conversation.messages on every token,
            // which would invalidate ALL message views via @Observable.
            streamingStore.updateContent(content)
            if let sources { streamingStore.appendSources(sources) }
            if let statusHistory {
                for s in statusHistory { streamingStore.appendStatus(s) }
            }
            if let error { streamingStore.setError(error) }
        } else {
            // ── COMPLETION / ERROR PATH ──
            // Write final content back to conversation.messages ONCE.
            // If transitioning from streaming → done, also flush the store.
            guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }

            if !isStreaming && streamingStore.streamingMessageId == id {
                // Streaming just ended — flush store to conversation.
                //
                // DRAIN-DEFERRAL: We defer message.isStreaming=false and cleanupStreaming()
                // until the pipeline has fully drained all buffered tokens. This prevents
                // the stop button from disappearing and the action bar/input from appearing
                // while the typewriter effect is still running.
                //
                // Content is written immediately (it doesn't affect UI chrome) so the
                // message history tree node is always up-to-date regardless of timing.
                // Capture session ID now so the callback can detect if a new stream
                // started (e.g., queue drain triggered sendMessage) while we waited.
                let capturedSessionId = streamingSessionId
                let result = streamingStore.endStreaming(onDrained: { [weak self] in
                    guard let self else { return }
                    // If a new streaming session started while we were draining
                    // (e.g., the queue auto-fired), this callback belongs to the
                    // OLD session — don't tear down the new stream.
                    guard self.streamingSessionId == capturedSessionId else { return }
                    guard let idx = self.conversation?.messages.firstIndex(where: { $0.id == id }) else {
                        // Message may have been removed (e.g., user cleared chat); just cleanup.
                        self.cleanupStreaming()
                        return
                    }
                    // Mark message as no longer streaming — this hides the stop button
                    // and shows the action bar, but only once all tokens are displayed.
                    self.conversation?.messages[idx].isStreaming = false
                    self.cleanupStreaming()
                })
                let finalContent = content.isEmpty ? result.content : content
                conversation?.messages[index].content = finalContent
                // NOTE: message.isStreaming = false is intentionally deferred above.
                // Merge sources from store into message
                if !result.sources.isEmpty {
                    for source in result.sources {
                        if !conversation!.messages[index].sources.contains(where: {
                            ($0.url != nil && $0.url == source.url) || ($0.id != nil && $0.id == source.id)
                        }) {
                            conversation?.messages[index].sources.append(source)
                        }
                    }
                }
                // Merge status history
                if !result.statusHistory.isEmpty {
                    conversation?.messages[index].statusHistory = result.statusHistory
                }
                if let storeError = result.error {
                    conversation?.messages[index].error = storeError
                }
                // ── CRITICAL: Write final content into the history tree node NOW ──
                // This is the ONLY correct place to do this. The flat messages list
                // (`conversation.messages`) only contains the ACTIVE branch. As soon as
                // the user edits this message, `rederiveMessages()` switches to the new
                // branch and this message disappears from the flat list. Any subsequent
                // `syncToServerViaTree()` call (which iterates the flat list) will never
                // see this node again and can't update it — causing the empty-content bug.
                // By writing to the tree node here (at the moment streaming completes,
                // while the message is still on the active branch), the node is permanently
                // up-to-date in the tree regardless of any future branch switches.
                if !finalContent.isEmpty {
                    conversation?.history.updateNode(id: id) { node in
                        node.content = finalContent
                        node.done = true
                        if !result.sources.isEmpty { node.sources = result.sources }
                        if !result.statusHistory.isEmpty { node.statusHistory = result.statusHistory }
                    }
                }
            } else {
                // Normal non-streaming update (e.g., error before streaming started)
                conversation?.messages[index].content = content
                conversation?.messages[index].isStreaming = isStreaming
                // Also update tree node for non-streaming completions (e.g., error paths)
                if !isStreaming && !content.isEmpty {
                    conversation?.history.updateNode(id: id) { node in
                        node.content = content
                        node.done = true
                    }
                }
            }
            if let sources { conversation?.messages[index].sources = sources }
            if let statusHistory { conversation?.messages[index].statusHistory = statusHistory }
            if let error { conversation?.messages[index].error = error }
        }

        // Extract and apply task list updates live from the streaming content.
        // Gate on a 100-char delta to avoid the O(n) string scan on every token.
        // The function also guards internally (only fires when the magic keywords are present),
        // so normal messages pay only the cheap length comparison.
        if content.count - lastTaskExtractionLength >= 100 {
            lastTaskExtractionLength = content.count
            extractAndApplyTasksFromContent(content)
        }

    }

    private func appendStatusUpdate(id: String, status: ChatStatusUpdate) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }

        // Deduplicate: update existing in-progress status with same action
        if let existingIdx = conversation?.messages[index].statusHistory.firstIndex(
            where: { $0.action == status.action && $0.done != true }
        ) {
            conversation?.messages[index].statusHistory[existingIdx] = status
        } else {
            // Don't add duplicate done statuses with the same action
            let isDuplicate = conversation?.messages[index].statusHistory.contains(where: {
                $0.action == status.action && $0.done == true && status.done == true
            }) ?? false
            if !isDuplicate {
                conversation?.messages[index].statusHistory.append(status)
            }
        }

        // Also write to the streaming store so the isolated streaming status
        // view sees the update in real-time (it reads from streamingStore,
        // not conversation.messages, during active streaming).
        if streamingStore.streamingMessageId == id && streamingStore.isActive {
            streamingStore.appendStatus(status)
        }
    }

    private func appendFollowUps(id: String, followUps: [String]) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else {
            // Still update the tree node even if not in the flat array
            conversation?.history.updateNode(id: id) { node in
                node.followUps = followUps
            }
            return
        }
        // Use direct in-place mutation. The @Observable macro on ChatViewModel
        // tracks mutations to `conversation` itself — mutating through the
        // optional chain works because `conversation` is a var on an @Observable
        // class. Avoid full `conversation = conv` reassignment which can cause
        // "setting value during update" crashes if a navigation event (e.g.,
        // new chat) fires concurrently.
        conversation?.messages[index].followUps = followUps

        // Update the history tree node so follow-ups survive rederiveMessages() calls.
        // Without this, rederiveMessages() rebuilds from the tree (which has followUps: [])
        // and erases follow-ups after any edit/regenerate/version switch.
        conversation?.history.updateNode(id: id) { node in
            node.followUps = followUps
        }

        // Also propagate follow-ups to all SIBLING tree nodes (alternative versions
        // generated by regeneration). Sibling nodes must also have follow-ups so they
        // are correctly populated after a version switch (which calls rederiveMessages()
        // and makes the sibling the main message). Without this, switching from
        // version 2 → version 1 shows no follow-ups until the conversation is reloaded.
        if let siblingIds = conversation?.history.siblings(of: id) {
            for sibId in siblingIds where sibId != id {
                // Only copy if the sibling doesn't already have its own follow-ups.
                let sibHasFollowUps = (conversation?.history.nodes[sibId]?.followUps.isEmpty == false)
                if !sibHasFollowUps {
                    conversation?.history.updateNode(id: sibId) { node in
                        node.followUps = followUps
                    }
                }
            }
        }
    }

    /// Refreshes conversation metadata (title, sources, follow-ups, files) from server.
    private func refreshConversationMetadata(chatId: String, assistantMessageId: String) async throws {
        guard let manager else { return }
        let refreshed = try await manager.fetchConversation(id: chatId)

        // Update title
        if !refreshed.title.isEmpty && refreshed.title != "New Chat" {
            conversation?.title = refreshed.title
        }

        // Update sources, follow-ups, and files from refreshed assistant message.
        // Match by EXACT message ID only — do NOT fall back to last assistant.
        // The fallback previously caused the "duplicate stream" bug: when the
        // first message's completion task was still running its delayed polls
        // while the second message was streaming, the fallback would pick up
        // the second message's content and write it into the first message.
        let serverAssistant = refreshed.messages.first(where: { $0.id == assistantMessageId })
        if let serverAssistant {
            if !serverAssistant.sources.isEmpty {
                appendSources(id: assistantMessageId, sources: serverAssistant.sources)
            }
            if !serverAssistant.followUps.isEmpty {
                appendFollowUps(id: assistantMessageId, followUps: serverAssistant.followUps)
            }
            // Copy files from server (tool-generated images etc.)
            if !serverAssistant.files.isEmpty {
                if let index = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    conversation?.messages[index].files = serverAssistant.files
                }
            }
            // Also update content if server has different content (e.g., tool appended text,
            // server-side filter functions that add timing/performance stats after completion)
            if let index = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                let localContent = conversation?.messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !serverContent.isEmpty && serverContent != localContent {
                    conversation?.messages[index].content = serverAssistant.content
                }
                // Copy usage stats from server — the server stores them after
                // sendChatCompleted processes the chat. This is how app-sent
                // messages pick up usage data (the /api/chat/completed endpoint
                // doesn't return usage directly, but the stored message has it).
                if conversation?.messages[index].usage == nil,
                   let serverUsage = serverAssistant.usage, !serverUsage.isEmpty {
                    conversation?.messages[index].usage = serverUsage
                }
                // Copy embeds from server — never overwrite non-empty embeds
                if conversation?.messages[index].embeds.isEmpty == true,
                   !serverAssistant.embeds.isEmpty {
                    conversation?.messages[index].embeds = serverAssistant.embeds
                }
            }
        }
        // Sync tasks from server after a metadata refresh — catches tasks that
        // were created/updated during streaming and are now stored server-side.
        if !refreshed.tasks.isEmpty && refreshed.tasks != tasks {
            tasks = refreshed.tasks
            conversation?.tasks = refreshed.tasks
        }
    }

    /// Ensures the assistant message has its file references populated.
    ///
    /// This is a safety net for when the server's `files` array is empty but
    /// the message content contains tool call results with file references
    /// (e.g., image generation tool returned a file ID). This can happen when:
    /// - The app was backgrounded during generation and missed socket events
    /// - Network issues prevented the server metadata refresh from completing
    /// - The server hasn't yet populated the files array on its side
    ///
    /// Uses `ToolCallParser.extractFileReferences` to scan the `<details>` blocks
    /// in the message content for file IDs, then adds them to `message.files`.
    private func populateFilesFromToolResults(messageId: String) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        let message = conversation!.messages[index]

        // Only run if files array is empty — don't override server-provided files
        guard message.files.isEmpty else { return }

        // Only check assistant messages with content (tool results are embedded in content)
        guard message.role == .assistant,
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let extractedFiles = ToolCallParser.extractFileReferences(from: message.content)
        if !extractedFiles.isEmpty {
            logger.info("Extracted \(extractedFiles.count) file(s) from tool results for message \(messageId)")
            conversation?.messages[index].files = extractedFiles
            // Also update the history tree node so syncToServerViaTree() persists the
            // files array — without this the server receives files:[] and WebUI can't
            // render the image when switching between versions.
            conversation?.history.updateNode(id: messageId) { node in
                if node.files.isEmpty {
                    node.files = extractedFiles
                }
            }
        }

    }

    private func appendSources(id: String, sources: [ChatSourceReference]) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }
        for source in sources {
            if !conversation!.messages[index].sources.contains(where: {
                ($0.url != nil && $0.url == source.url) || ($0.id != nil && $0.id == source.id)
            }) {
                conversation?.messages[index].sources.append(source)
            }
        }
        // Mirror into streamingStore so IsolatedAssistantMessage has sources
        // both during streaming AND in the post-stream handoff window before
        // the final message commit propagates back through the view hierarchy.
        if streamingStore.streamingMessageId == id {
            streamingStore.appendSources(sources)
        }
    }

    // MARK: - Message Feedback / Rating

    /// Fetches the message rating feature flag from the backend config.
    /// Uses session-level cache so we only call /api/config once per session.
    func fetchMessageRatingEnabled() async {
        if let cached = activeChatStore?.cachedMessageRatingEnabled {
            messageRatingEnabled = cached
            return
        }
        guard let apiClient = manager?.apiClient else { return }
        do {
            let config = try await apiClient.getBackendConfig()
            let enabled = config.features?.enableMessageRating ?? false
            messageRatingEnabled = enabled
            activeChatStore?.cachedMessageRatingEnabled = enabled
        } catch {
            logger.debug("Failed to fetch message rating setting: \(error.localizedDescription)")
        }
    }

    /// Builds a full messages array matching the web UI feedback snapshot format.
    private func buildSnapshotMessages(from conv: Conversation) -> [[String: Any]] {
        conv.messages.map { m -> [String: Any] in
            let childrenIds = conv.history.nodes[m.id]?.childrenIds ?? []
            var msg: [String: Any] = [
                "id": m.id,
                "parentId": m.parentId as Any? ?? NSNull(),
                "childrenIds": childrenIds,
                "role": m.role.rawValue,
                "content": m.content,
                "timestamp": Int(m.timestamp.timeIntervalSince1970),
                "done": !m.isStreaming
            ]
            if let model = m.model { msg["model"] = model }
            if let model = m.model { msg["modelName"] = model }
            msg["modelIdx"] = 0
            if let annotation = m.annotation {
                var ann: [String: Any] = ["rating": annotation.rating as Any]
                if !annotation.tags.isEmpty { ann["tags"] = annotation.tags }
                if let reason = annotation.reason { ann["reason"] = reason }
                if let comment = annotation.comment { ann["comment"] = comment }
                if let detail = annotation.detailRating { ann["details"] = ["rating": detail] }
                msg["annotation"] = ann
            } else {
                msg["annotation"] = NSNull()
            }
            if let feedbackId = m.feedbackId { msg["feedbackId"] = feedbackId }
            return msg
        }
    }

    /// Builds the snapshot dict matching the web UI double-nested format.
    private func buildSnapshot(chatId: String, conv: Conversation, modelId: String) -> [String: Any] {
        let historyDict = conv.history.toServerDict()
        let messages = buildSnapshotMessages(from: conv)
        let innerChat: [String: Any] = [
            "title": conv.title,
            "models": [modelId],
            "id": "",
            "params": conv.chatParams?.toRequestParams() ?? [:] as [String: Any],
            "history": historyDict,
            "messages": messages,
            "tags": conv.tags,
            "timestamp": Int(conv.createdAt.timeIntervalSince1970 * 1000),
            "files": [] as [Any]
        ]
        var outerChat: [String: Any] = [
            "id": chatId,
            "title": conv.title,
            "chat": innerChat,
            "updated_at": Int(conv.updatedAt.timeIntervalSince1970),
            "created_at": Int(conv.createdAt.timeIntervalSince1970),
            "share_id": conv.shareId as Any? ?? NSNull(),
            "archived": conv.archived,
            "pinned": conv.pinned,
            "meta": ["tags": conv.tags] as [String: Any],
            "tasks": NSNull(),
            "summary": NSNull()
        ]
        if let folderId = conv.folderId { outerChat["folder_id"] = folderId } else { outerChat["folder_id"] = NSNull() }
        return ["chat": outerChat]
    }

    /// Called when user taps 👍 or 👎 on an assistant message.
    /// Creates a feedback record on the server and writes the initial annotation to the local tree.
    func submitThumbsRating(message: ChatMessage, rating: Int) async {
        guard let chatId = conversationId ?? conversation?.id,
              let apiClient = manager?.apiClient,
              let conv = conversation else { return }

        let modelId = message.model ?? selectedModelId ?? ""
        let messageIndex = conv.messages.firstIndex(where: { $0.id == message.id }) ?? 0
        let snapshot = buildSnapshot(chatId: chatId, conv: conv, modelId: modelId)
        let meta: [String: Any] = [
            "model_id": modelId,
            "message_id": message.id,
            "message_index": messageIndex,
            "chat_id": chatId,
            "base_models": [modelId: NSNull()]
        ]
        let data: [String: Any] = [
            "rating": rating,
            "model_id": modelId,
            "tags": [String]()
        ]

        do {
            let result = try await apiClient.createFeedback(
                type: "rating", data: data, meta: meta, snapshot: snapshot)
            let feedbackId = result["id"] as? String
            let annotation = MessageAnnotation(rating: rating, tags: [])
            // Update tree node
            conversation?.history.updateNode(id: message.id) { node in
                node.annotation = annotation
                node.feedbackId = feedbackId
            }
            // Update flat messages list so UI reflects rating immediately
            if let idx = conversation?.messages.firstIndex(where: { $0.id == message.id }) {
                conversation?.messages[idx].annotation = annotation
                conversation?.messages[idx].feedbackId = feedbackId
            }
            await syncToServerViaTree()
            logger.info("Feedback created: \(feedbackId ?? "nil") rating=\(rating)")
        } catch {
            logger.error("Failed to create feedback: \(error.localizedDescription)")
        }
    }

    /// Called when user saves the feedback detail sheet.
    func saveFeedbackDetails(message: ChatMessage, detailRating: Int, reason: String?, comment: String?, tags: [String]) async {
        guard let chatId = conversationId ?? conversation?.id,
              let apiClient = manager?.apiClient,
              let conv = conversation,
              let feedbackId = message.feedbackId else { return }

        let modelId = message.model ?? selectedModelId ?? ""
        let currentRating = message.annotation?.rating ?? 1
        let messageIndex = conv.messages.firstIndex(where: { $0.id == message.id }) ?? 0
        let snapshot = buildSnapshot(chatId: chatId, conv: conv, modelId: modelId)
        let meta: [String: Any] = [
            "model_id": modelId,
            "message_id": message.id,
            "message_index": messageIndex,
            "chat_id": chatId,
            "base_models": [modelId: NSNull()]
        ]
        var dataDict: [String: Any] = [
            "rating": currentRating,
            "model_id": modelId,
            "tags": tags
        ]
        if let reason { dataDict["reason"] = reason }
        if let c = comment, !c.isEmpty { dataDict["comment"] = c }
        dataDict["details"] = ["rating": detailRating]

        do {
            try await apiClient.updateFeedback(
                id: feedbackId, type: "rating", data: dataDict, meta: meta, snapshot: snapshot)
            let newAnnotation = MessageAnnotation(
                rating: currentRating, tags: tags, reason: reason,
                comment: (comment?.isEmpty == false) ? comment : nil, detailRating: detailRating)
            conversation?.history.updateNode(id: message.id) { node in
                node.annotation = newAnnotation
            }
            if let idx = conversation?.messages.firstIndex(where: { $0.id == message.id }) {
                conversation?.messages[idx].annotation = newAnnotation
            }
            await syncToServerViaTree()
            logger.info("Feedback details saved for \(feedbackId)")
        } catch {
            logger.error("Failed to save feedback details: \(error.localizedDescription)")
        }
    }

    /// Fetches AI-generated tag suggestions for a message.
    func loadTagSuggestions(for message: ChatMessage) async -> [String] {
        guard let chatId = conversationId ?? conversation?.id,
              let apiClient = manager?.apiClient,
              let conv = conversation else { return [] }
        let modelId = message.model ?? selectedModelId ?? ""
        let msgs: [[String: Any]] = conv.messages.prefix(while: { $0.id != message.id }).map { m in
            ["role": m.role.rawValue, "content": m.content]
        } + [["role": message.role.rawValue, "content": message.content]]
        do {
            return try await apiClient.getTagSuggestions(model: modelId, messages: msgs, chatId: chatId)
        } catch {
            logger.debug("Tag suggestions failed: \(error.localizedDescription)")
            return []
        }
    }

    private func saveConversationToServer() async {
        guard let manager, let conversation else { return }
        // Skip server persistence for temporary chats
        guard !isTemporaryChat else { return }
        // Always sync messages to existing conversation — never create a new one.
        // The conversation is already created in sendMessage() when conversation == nil.
        // Calling createConversation again would produce a duplicate entry.
        do {
            try await manager.saveConversation(conversation)
        } catch {
            logger.error("Failed to save conversation: \(error.localizedDescription)")
        }

        // Notify history to refresh
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }
}

// MARK: - Content Accumulator

/// Thread-safe token accumulator with immediate main-actor dispatch.
///
/// Accumulates token deltas from background socket/SSE callbacks into a
/// single string and dispatches every token to the main actor immediately,
/// giving smooth character-by-character streaming in the UI.
final class ContentAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _content: String = ""
    private nonisolated(unsafe) var _onUpdate: (@MainActor @Sendable (_ content: String) -> Void)?

    /// Guards against flooding the main actor with redundant Tasks.
    /// When true, a Task is already queued and will read the latest content
    /// when it executes — no need to create another one.
    private nonisolated(unsafe) var _pendingUpdate: Bool = false

    /// Callback invoked on the main actor with the latest accumulated
    /// content. Set by the view model when socket handlers are registered.
    nonisolated var onUpdate: (@MainActor @Sendable (_ content: String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onUpdate
        }
        set {
            lock.lock()
            _onUpdate = newValue
            lock.unlock()
        }
    }

    nonisolated var content: String {
        lock.lock()
        let value = _content
        lock.unlock()
        return value
    }

    /// Clears the pending-update flag after the queued Task executes.
    /// Extracted as a synchronous nonisolated helper so NSLock is never
    /// acquired from an async context (avoids Swift 6 strict-concurrency warnings).
    nonisolated private func clearPendingFlag() {
        lock.lock()
        _pendingUpdate = false
        lock.unlock()
    }

    nonisolated func append(_ text: String) {
        lock.lock()
        _content += text
        // Only enqueue a new MainActor Task if none is already in-flight.
        // The in-flight Task will read _content at execution time, so it will
        // always deliver the very latest accumulated text — even if many tokens
        // arrived while it was waiting for MainActor scheduling.
        let needsDispatch = !_pendingUpdate
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        guard needsDispatch else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Read the LATEST content — may include tokens that arrived
            // after append() returned but before this Task executed.
            let latest = self.content
            callback?(latest)
            // Clear the flag so the next token can enqueue a new Task.
            self.clearPendingFlag()
        }
    }

    nonisolated func replace(_ text: String) {
        lock.lock()
        _content = text
        let needsDispatch = !_pendingUpdate
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        guard needsDispatch else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let latest = self.content
            callback?(latest)
            self.clearPendingFlag()
        }
    }
}
