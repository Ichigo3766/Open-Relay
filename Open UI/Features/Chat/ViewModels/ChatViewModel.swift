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
    /// Posted by AdminConsoleView when a user's chat is cloned.
    static let adminClonedChat = Notification.Name("adminClonedChat")
    /// Posted by the audio attachment thumbnail's retry button.
    /// `object` is the `UUID` of the attachment to retry uploading.
    static let retryAttachmentUpload = Notification.Name("retryAttachmentUpload")
    /// Posted when function config changes (toggle active/global in Admin, or model editor save).
    /// ChatViewModel observes this to re-resolve actions/filters for the current model immediately.
    static let functionsConfigChanged = Notification.Name("functionsConfigChanged")
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
    var isStreaming: Bool = false
    var isLoadingConversation: Bool = false
    var isLoadingModels: Bool = false
    /// Tasks managed by the model's built-in task tools (create_tasks / update_task).
    /// Populated from the server on load and updated in real-time during streaming.
    var tasks: [ChatTask] = []
    var errorMessage: String?
    var inputText: String = ""
    var attachments: [ChatAttachment] = []
    var webSearchEnabled: Bool = false
    var imageGenerationEnabled: Bool = false
    var codeInterpreterEnabled: Bool = false
    /// Whether memory is enabled for this chat session.
    /// Persisted to server user settings (`ui.memory`) so the web UI stays in sync.
    var memoryEnabled: Bool = false
    /// Pinned model IDs synced with server `ui.pinnedModels`.
    var pinnedModelIds: [String] = []
    var isTemporaryChat: Bool = false
    /// Chat params set before the conversation is created (new-chat flow).
    /// Applied to `conversation.chatParams` as soon as the conversation is created.
    var pendingChatParams: ChatAdvancedParams?
    var availableTools: [ToolItem] = []
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
    var selectedKnowledgeItems: [KnowledgeItem] = []
    var knowledgeItems: [KnowledgeItem] = []
    /// Reference chat conversations selected for context in the next message.
    var selectedReferenceChats: [ReferenceChatItem] = []
    var isLoadingTools: Bool = false
    /// Available terminal servers fetched from the backend.
    var availableTerminalServers: [TerminalServer] = []
    /// Whether the user has enabled terminal for this chat session.
    var terminalEnabled: Bool = false
    /// The currently selected terminal server (auto-selects first if only one).
    var selectedTerminalServer: TerminalServer?
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
    var suggestedEmoji: String?
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
    private var chatSubscription: SocketSubscription?
    private var channelSubscription: SocketSubscription?
    /// Persistent passive socket listener that observes events for this chat
    /// regardless of who initiated the generation. Mirrors the website's
    /// `Chat.svelte` `socket.on("events", chatEventHandler)` pattern.
    private var passiveSubscription: SocketSubscription?
    /// True when this VM initiated the current streaming session (sendMessage/regenerate).
    /// The passive listener skips processing when this is true to avoid conflicts.
    private var selfInitiatedStream: Bool = false
    /// Guards against flooding syncForExternalStream with duplicate fetch tasks
    /// when many socket tokens arrive before the first fetch completes.
    private var isSyncingExternalStream: Bool = false
    private(set) var sessionId: String = UUID().uuidString
    private let logger = Logger(subsystem: "com.openui", category: "ChatViewModel")
    private var hasFinishedStreaming = false
    /// Tracks the content length at the last `extractAndApplyTasksFromContent` call.
    /// Prevents the O(n) task-extraction scan from running on every single token;
    /// it only fires when the content has grown by ≥ 100 chars since the last scan.
    private var lastTaskExtractionLength: Int = 0
    /// Cached value of the "streamingHaptics" UserDefaults preference.
    /// Updated whenever UserDefaults.didChangeNotification fires so toggling in
    /// Settings takes effect immediately without a per-token UserDefaults read.
    private var streamingHapticsEnabled: Bool = true
    private var activeTaskId: String?
    private var recoveryTimer: Timer?
    /// Cancellable delay task for the initial recovery timer delay.
    /// Replaces `DispatchQueue.main.asyncAfter` so it can be cancelled
    /// when the user navigates away or sends a new message.
    private var recoveryDelayTask: Task<Void, Never>?
    private var emptyPollCount = 0
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
            title: conv.title
        )
    }

    var selectedModel: AIModel? {
        guard let id = selectedModelId else { return nil }
        return availableModels.first { $0.id == id }
    }

    var canSend: Bool {
        !isStreaming
            && !attachments.contains(where: { $0.type == .audio && $0.isTranscribing })
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

    func configure(with manager: ConversationManager, socket: SocketIOService? = nil, store: ActiveChatStore? = nil, asr: OnDeviceASRService? = nil) {
        self.manager = manager
        self.socketService = socket
        self.serverBaseURL = manager.baseURL
        self.activeChatStore = store
        self.asrService = asr
        setupRetryAttachmentObserver()
        setupMemorySettingObserver()
        setupFunctionsConfigObserver()
        setupStreamingHapticsObserver()
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
            }
        }
    }

    /// Seeds `streamingHapticsEnabled` from UserDefaults and keeps it in sync.
    /// Using a cached Bool avoids a per-token UserDefaults read (the hot path
    /// calls `triggerStreamingHaptic()` on every token at up to 60 Hz).
    private func setupStreamingHapticsObserver() {
        // Seed initial value
        streamingHapticsEnabled = UserDefaults.standard.object(forKey: "streamingHaptics") as? Bool ?? true
        // Keep in sync when Settings changes the preference
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let newValue = UserDefaults.standard.object(forKey: "streamingHaptics") as? Bool ?? true
            Task { @MainActor [weak self] in
                self?.streamingHapticsEnabled = newValue
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

        // Check if an external client is currently streaming to this chat
        // (only meaningful for existing conversations)
        if !isNew {
            await checkForActiveExternalStream()
        }

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
            // Populate tasks from the server conversation
            tasks = fetched.tasks
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
                    // New node from server — add directly
                    conversation?.history.nodes[id] = serverNode
                }
            }
            // Update currentId from server unless we're actively streaming
            if !isStreaming, let serverCurrentId = serverConversation.history.currentId {
                conversation?.history.currentId = serverCurrentId
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
                    conversation!.messages[localIdx].followUps = serverMsg.followUps
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
            if selectedModelId == nil {
                if let def = await manager.fetchDefaultModel() {
                    selectedModelId = def
                } else {
                    selectedModelId = availableModels.first?.id
                }
            }
            // Write back to shared cache so subsequent VMs are pre-populated
            activeChatStore?.updateModelCache(models: availableModels, selectedId: selectedModelId)
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
            // Auto-select first terminal if only one available
            if selectedTerminalServer == nil, let first = availableTerminalServers.first {
                selectedTerminalServer = first
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
                for fn in toggleFilters {
                    // Avoid duplicates (a filter could theoretically have the same ID as a tool)
                    if !allItems.contains(where: { $0.id == fn.id }) {
                        allItems.append(ToolItem(
                            id: fn.id,
                            name: fn.name,
                            description: fn.description.isEmpty ? nil : fn.description,
                            isEnabled: fn.isGlobal // Global toggle-filters are enabled by default
                        ))
                    }
                }
            }

            if !allItems.isEmpty {
                availableTools = allItems
                syncToolSelectionWithDefaults()
                isLoadingTools = false
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
        isLoadingTools = false
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
            if let msgId = messageId {
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
                    appendFollowUps(id: msgId, followUps: trimmed)
                }
            }
            return

        default:
            break
        }

        // --- Content/streaming events: only process when NOT self-initiated ---
        guard !selfInitiatedStream else { return }

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
            if let choices = payload?["choices"] as? [[String: Any]],
               let first = choices.first,
               let delta = first["delta"] as? [String: Any],
               let c = delta["content"] as? String, !c.isEmpty {
                contentDelta = c
            } else if let c = payload?["content"] as? String, !c.isEmpty {
                contentDelta = c
                isReplace = true
            }
        default:
            break
        }

        // If this is a content event with actual text
        if let contentDelta, !contentDelta.isEmpty {
            guard let msgId = messageId else { return }

            // If message doesn't exist locally, do ONE sync (guarded by flag)
            if conversation?.messages.first(where: { $0.id == msgId }) == nil {
                guard !isSyncingExternalStream else { return }
                isSyncingExternalStream = true
                isExternallyStreaming = true
                isStreaming = true
                // Reset hasFinishedStreaming so self-initiated cleanup guards
                // don't interfere with this new external stream
                hasFinishedStreaming = false
                Task {
                    await self.syncOnceForExternalStream(messageId: msgId)
                    self.isSyncingExternalStream = false
                }
                return
            }

            // Message exists — append content directly (real-time socket streaming)
            if !isExternallyStreaming {
                isExternallyStreaming = true
                isStreaming = true
                // Reset hasFinishedStreaming for each new external stream session
                hasFinishedStreaming = false
                logger.info("External stream: first token for message \(msgId)")
            }
            if let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                if isReplace {
                    // Full content replacement (message, chat:message, replace, chat:completion fallback)
                    conversation?.messages[index].content = contentDelta
                } else {
                    // Delta/token append (chat:message:delta, chat:completion choices.delta)
                    conversation?.messages[index].content += contentDelta
                }
                conversation?.messages[index].isStreaming = true
                triggerStreamingHaptic()
            }

            // Also check for done signal within content events (chat:completion
            // can carry both content AND done:true in the same event)
            if type == "chat:completion", let payload, payload["done"] as? Bool == true {
                let finalContent = conversation?.messages.first(where: { $0.id == msgId })?.content ?? ""
                isExternallyStreaming = false
                isStreaming = false
                isSyncingExternalStream = false
                if let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                    conversation?.messages[index].isStreaming = false
                }
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
            let finalContent = messageId.flatMap { id in
                conversation?.messages.first(where: { $0.id == id })?.content
            } ?? ""
            isExternallyStreaming = false
            isStreaming = false
            isSyncingExternalStream = false
            if let msgId = messageId,
               let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                conversation?.messages[index].isStreaming = false
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
                isStreaming = false
            isSyncingExternalStream = false
            if let msgId = messageId,
               let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                conversation?.messages[index].isStreaming = false
            }
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

            // After syncing, mark the target message as streaming
            if let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) {
                conversation?.messages[index].isStreaming = true
            }
            logger.info("External stream: synced messages, now tracking \(messageId)")
        } catch {
            logger.warning("External stream sync failed: \(error.localizedDescription)")
        }
    }

    /// Task for the external stream polling loop.
    private var externalStreamPollTask: Task<Void, Never>?

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

    /// Checks whether an external client is currently streaming to this chat.
    ///
    /// Uses the `POST /api/v1/tasks/active/chats` endpoint to detect in-progress
    /// generations. If active, sets isExternallyStreaming and isStreaming to true, and marks
    /// the last assistant message as streaming so the UI shows the correct state.
    private func checkForActiveExternalStream() async {
        guard let chatId = conversationId ?? conversation?.id else { return }
        guard let apiClient = manager?.apiClient else { return }

        do {
            let activeChats = try await apiClient.checkActiveChats(chatIds: [chatId])
            if activeChats.contains(chatId) {
                // This chat has an active generation from another client
                if let lastAssistant = conversation?.messages.last(where: { $0.role == .assistant }) {
                    // Only mark as externally streaming if the message looks incomplete
                    // (empty or the server is still producing content)
                    let content = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if content.isEmpty || lastAssistant.isStreaming {
                        isExternallyStreaming = true
                isStreaming = true
                        if let index = conversation?.messages.firstIndex(where: { $0.id == lastAssistant.id }) {
                            conversation?.messages[index].isStreaming = true
                        }
                        logger.info("Detected active external stream on chat open")
                    }
                }
            }
        } catch {
            // Non-critical — passive listener will catch events anyway
            logger.debug("Active chat check failed: \(error.localizedDescription)")
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
        selectedToolIds = []
        selectedKnowledgeItems = []
        selectedSkillIds = []
        // Sync UI toggles with the selected model's server-configured defaults.
        syncUIWithModelDefaults()
    }

    /// Converts a temporary chat into a permanent one by saving it to the server.
    func saveTemporaryChat() async {
        guard isTemporaryChat, let conversation, let manager else { return }
        let modelId = selectedModelId ?? conversation.model ?? ""
        do {
            let created = try await manager.createConversation(
                title: conversation.title, messages: [], model: modelId,
                folderId: folderContextId)
            // Update the conversation ID to the server-assigned one
            self.conversation?.id = created.id
            // Sync all messages
            try await manager.syncConversationMessages(
                id: created.id, messages: conversation.messages, model: modelId,
                chatParams: conversation.chatParams)
            isTemporaryChat = false
            logger.info("Temporary chat saved as \(created.id)")
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        } catch {
            logger.error("Failed to save temporary chat: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sending Messages

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
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
                let fileObject = attachment.uploadedFileObject ?? [:]
                let isImage = attachment.type == .image
                let contentType: String = isImage ? "image/jpeg" : mimeType(for: attachment.name)
                let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0
                fileRefs.append([
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
                ])
            } else if let data = attachment.data, attachment.uploadStatus != .error {
                // Fallback: upload now (e.g., audio transcript text files that don't go
                // through uploadAttachmentImmediately). Skip attachments that previously
                // failed — the error chip is already shown; the user must retry or remove.
                do {
                    let (fileId, fileObject) = try await manager.uploadFile(data: data, fileName: attachment.name)
                    let isImage = attachment.type == .image
                    let contentType: String = isImage ? "image/jpeg" : mimeType(for: attachment.name)
                    let size: Int = (fileObject["meta"] as? [String: Any]).flatMap { $0["size"] as? Int } ?? 0
                    fileRefs.append([
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
                    ])
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

        // Activate the isolated streaming store so token updates bypass
        // conversation.messages and only invalidate the streaming message view.
        streamingStore.beginStreaming(messageId: assistantMessageId, modelId: modelId)

        // Ensure socket connected with resilient retry.
        // For Cloudflare-protected servers, WebSocket connections may be blocked
        // entirely. In that case, we fall back to SSE streaming (normal HTTPS).
        let socket = socketService
        var socketConnected = socket?.isConnected ?? false

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
                if !allFileRefs.isEmpty { request.files = allFileRefs }

                // Build the user_message node required by updated OpenWebUI servers.
                // Without this, the server doesn't link the user message into the history
                // tree, causing it to disappear when the chat is re-opened.
                var userMsgDict: [String: Any] = [
                    "id": userMessage.id,
                    "parentId": (userMessageParentId as Any?) ?? NSNull(),
                    "childrenIds": [assistantMessageId],
                    "role": "user",
                    "content": currentText,
                    "timestamp": Int(userMessage.timestamp.timeIntervalSince1970),
                    "models": [modelId]
                ]
                if !allFileRefs.isEmpty { userMsgDict["files"] = allFileRefs }
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
                } else if request.isPipeModel {
                    // ── PIPE MODEL SSE PATH ──
                    // Pipe/function models bypass the Redis async-task queue when
                    // session_id, chat_id, and id are absent. Content streams directly
                    // from the HTTP response body as standard OpenAI SSE.
                    self.logger.info("Using pipe model SSE path for \(modelId)")
                    let acc = ContentAccumulator()

                    do {
                        let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                        for try await event in sseStream {
                            if Task.isCancelled { break }

                            // Content delta tokens
                            if let delta = event.contentDelta, !delta.isEmpty {
                                acc.append(delta)
                                self.updateAssistantMessage(
                                    id: assistantMessageId,
                                    content: acc.content,
                                    isStreaming: true
                                )
                            }

                            // Stream finished
                            if event.isFinished { break }
                        }
                    } catch {
                        if !Task.isCancelled {
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: acc.content.isEmpty ? "" : acc.content,
                                isStreaming: false,
                                error: ChatMessageError(content: error.localizedDescription)
                            )
                            self.cleanupStreaming()
                            return
                        }
                    }

                    if Task.isCancelled { return }

                    // Finalize — sync the completed message to server, then do
                    // metadata refresh to pick up any tool-generated files/sources.
                    self.finishStreamingSuccessfully(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        socketSessionId: socketSessionId,
                        effectiveChatId: effectiveChatId,
                        acc: acc
                    )
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
                    let taskIds = try await apiClient.getTasksForChat(chatId: chatId)
                    for taskId in taskIds {
                        try? await apiClient.stopTask(taskId: taskId)
                        logger.info("External server task stopped: \(taskId)")
                    }
                } catch {
                    logger.warning("Failed to fetch tasks for chat \(chatId): \(error.localizedDescription)")
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

    /// Regenerates a specific assistant response by its message ID.
    ///
    /// If the targeted message is NOT the last assistant message, all messages
    /// after it are removed first (truncating the conversation to that point),
    /// matching the OpenWebUI web client's regeneration behavior for mid-conversation
    /// messages.
    func regenerateResponse(messageId: String) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard conversation != nil else { return }

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

                // Populate all common request fields
                await self.populateCommonRequestFields(&request)

                if request.isPipeModel {
                    // ── PIPE MODEL SSE PATH (regeneration) ──
                    self.logger.info("Regenerate: using pipe model SSE path for \(modelId)")
                    let acc = ContentAccumulator()

                    do {
                        let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                        for try await event in sseStream {
                            if Task.isCancelled { break }
                            if let delta = event.contentDelta, !delta.isEmpty {
                                acc.append(delta)
                                self.updateAssistantMessage(
                                    id: capturedNewAssistantId, content: acc.content, isStreaming: true)
                            }
                            if event.isFinished { break }
                        }
                    } catch {
                        if !Task.isCancelled {
                            self.updateAssistantMessage(
                                id: capturedNewAssistantId,
                                content: acc.content.isEmpty ? "" : acc.content,
                                isStreaming: false,
                                error: ChatMessageError(content: error.localizedDescription))
                            self.cleanupStreaming()
                            return
                        }
                    }

                    if Task.isCancelled { return }

                    self.finishStreamingSuccessfully(
                        assistantMessageId: capturedNewAssistantId,
                        modelId: modelId,
                        socketSessionId: socketSessionId,
                        effectiveChatId: effectiveChatId,
                        acc: acc
                    )
                } else {
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: capturedNewAssistantId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }

                    // Capture the server's task_id for server-side stop
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    self.logger.info("Regenerate HTTP POST done – waiting for socket events")
                }
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
    func editMessage(id: String, newContent: String) async {
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
        let newUserId = UUID().uuidString
        let newUserNode = HistoryNode(
            id: newUserId,
            parentId: parentId,
            childrenIds: [],   // will get the assistant ID below
            role: .user,
            content: newContent,
            timestamp: .now,
            files: oldNode.files,
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

        // Re-derive the flat message list from the new active branch.
        conversation!.rederiveMessages()

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

        // Re-derive the flat message list from the new active branch.
        conversation!.rederiveMessages()

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
        conversation!.rederiveMessages()

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

        streamingStore.beginStreaming(messageId: assistantMessageId, modelId: modelId)

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

                // Populate all common request fields (model metadata, features, params,
                // system variables, tool IDs, terminal, background tasks, etc.)
                await self.populateCommonRequestFields(&request)

                if request.isPipeModel {
                    let acc = ContentAccumulator()
                    do {
                        let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                        for try await event in sseStream {
                            if Task.isCancelled { break }
                            if let delta = event.contentDelta, !delta.isEmpty {
                                acc.append(delta)
                                self.updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
                            }
                            if event.isFinished { break }
                        }
                    } catch {
                        if !Task.isCancelled {
                            self.updateAssistantMessage(id: assistantMessageId, content: "", isStreaming: false,
                                error: ChatMessageError(content: error.localizedDescription))
                            self.cleanupStreaming()
                            return
                        }
                    }
                    if Task.isCancelled { return }
                    self.finishStreamingSuccessfully(assistantMessageId: assistantMessageId, modelId: modelId,
                        socketSessionId: socketSessionId, effectiveChatId: effectiveChatId, acc: acc)
                } else {
                    let json = try await manager.sendMessageHTTP(request: request)
                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: assistantMessageId, content: "", isStreaming: false,
                            error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }
                    if let taskId = json["task_id"] as? String { self.activeTaskId = taskId }
                    self.logger.info("Edit-regen HTTP POST done – waiting for socket events")
                }
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
        effectiveChatId: String?
    ) {
        chatSubscription?.dispose()
        channelSubscription?.dispose()
        let acc = ContentAccumulator()

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
        // OpenAI choices format
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

        // Direct content field
        if let content = payload["content"] as? String, !content.isEmpty {
            acc.replace(content)
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
        }

        // Top-level tool_calls
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
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recoveryDelayTask?.cancel()
        recoveryDelayTask = nil
        emptyPollCount = 0
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

            // Generate a suggested emoji for the response (fire-and-forget)
            await self.generateSuggestedEmoji(for: acc.content)
        }
    }

    /// Generates a suggested emoji for the assistant's response via the server's
    /// emoji completions endpoint. Fire-and-forget — failure just means no emoji.
    private func generateSuggestedEmoji(for content: String) async {
        guard let apiClient = manager?.apiClient,
              let modelId = selectedModelId else { return }
        // Only generate if content is meaningful
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20 else { return }
        // Use first 200 chars as prompt to keep it fast
        let prompt = String(trimmed.prefix(200))
        do {
            if let emoji = try await apiClient.generateEmoji(model: modelId, prompt: prompt) {
                // Only accept single emoji or very short strings
                let cleaned = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.count <= 4 {
                    suggestedEmoji = cleaned
                }
            }
        } catch {
            // Non-critical — just skip the emoji suggestion
            logger.debug("Emoji generation failed: \(error.localizedDescription)")
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

        // NOTE: Do NOT call saveConversationToServer() here — same reason
        // as finishStreamingSuccessfully. The server's chatCompleted has the
        // authoritative state; pushing our local copy would corrupt tool results.
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
    private func runRecoveryPoll(assistantMessageId: String, chatId: String?) {
        Task { @MainActor in
            guard self.isStreaming, !self.hasFinishedStreaming else {
                self.recoveryTimer?.invalidate()
                self.recoveryTimer = nil
                return
            }
            guard let chatId, let manager = self.manager else { return }

            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                if let lastAssistant = refreshed.messages.last(where: { $0.role == .assistant }) {
                    let serverContent = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let localContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    // Server has more content than local — but ONLY update
                    // if the socket has NOT been delivering tokens. If the
                    // socket is actively streaming, let it continue token-by-token
                    // rather than dumping the entire server content at once.
                    if !serverContent.isEmpty && serverContent.count > localContent.count && !self.socketHasReceivedContent {
                        self.logger.info("Recovery: adopting server content (socket silent)")
                        self.updateAssistantMessage(
                            id: assistantMessageId, content: lastAssistant.content, isStreaming: true)
                    }

                    // Server says streaming is done
                    if !lastAssistant.isStreaming && !serverContent.isEmpty {
                        self.logger.info("Recovery: server says done with \(serverContent.count) chars")
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

            // Check if there are active (pending) tool statuses — if so, tools
            // are still executing on the server. Do NOT count these polls toward
            // the give-up threshold. The server will eventually finish or error;
            // the user can also cancel manually via the stop button.
            let hasActiveToolStatus: Bool = {
                guard let msgIdx = self.conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) else { return false }
                let statuses = self.conversation?.messages[msgIdx].statusHistory ?? []
                return statuses.contains { $0.done != true && $0.hidden != true }
            }()

            if hasActiveToolStatus {
                // Tools still running — reset the empty poll counter so we
                // never give up while the server is actively processing.
                self.emptyPollCount = 0
                self.logger.debug("Recovery: tools still active, resetting poll count")
            } else {
                self.emptyPollCount += 1
            }

            // After 60s (12 polls at 5s) with NO active tools, give up.
            // When tools ARE active, emptyPollCount stays at 0 so we wait
            // indefinitely until the server finishes or the user cancels.
            if self.emptyPollCount >= 12 {
                self.logger.warning("Recovery: giving up after \(self.emptyPollCount) polls (no active tools)")
                let giveUpContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
                self.updateAssistantMessage(
                    id: assistantMessageId,
                    content: giveUpContent,
                    isStreaming: false)
                Task { await self.sendCompletionNotificationIfNeeded(content: giveUpContent) }
                self.cleanupStreaming()
            }
        }
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
        hasFinishedStreaming = true
        isStreaming = false
        isExternallyStreaming = false
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
    private func resolveFiltersForModel(_ model: inout AIModel) async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let functions = try await apiClient.getFunctions()
            let filterFunctions = functions.filter { $0.type == "filter" && $0.isActive }

            var resolvedFilterIds: [String] = []
            var seenIds = Set<String>()

            for fn in filterFunctions {
                let isGlobal = fn.isGlobal
                let isPerModel = model.filterIds.contains(fn.id)

                if isGlobal || isPerModel {
                    guard !seenIds.contains(fn.id) else { continue }
                    seenIds.insert(fn.id)
                    resolvedFilterIds.append(fn.id)
                }
            }

            model.filterIds = resolvedFilterIds
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

        // Only enable features if admin has them on — never force-disable ones
        // the user turned on manually.
        if defaults.contains("web_search") && isTruthy("web_search") {
            webSearchEnabled = true
        }
        if defaults.contains("image_generation") && isTruthy("image_generation") {
            imageGenerationEnabled = true
        }
        if defaults.contains("code_interpreter") && isTruthy("code_interpreter") {
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

    /// Whether the selected model supports the memory builtin tool.
    /// Controls visibility of the memory toggle in ToolsMenuSheet.
    var isMemoryAvailable: Bool {
        selectedModel?.supportsMemory ?? false
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
        webSearchEnabled = defaults.contains("web_search") && isTruthy("web_search")
        imageGenerationEnabled = defaults.contains("image_generation") && isTruthy("image_generation")
        codeInterpreterEnabled = defaults.contains("code_interpreter") && isTruthy("code_interpreter")

        // Memory is an account-level preference stored server-side (ui.memory).
        // Fetch it once for all models (not just memory-capable ones) so the
        // value is cached for when a capable model is selected later.
        Task { await fetchMemorySettingFromServer() }

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
                memoryEnabled = memory
                activeChatStore?.cachedMemorySetting = memory
                logger.debug("Memory setting fetched from server: \(memory)")
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
        request.modelItem = selectedModel?.rawModelItem

        // Flag pipe/function models so toJSON() omits session_id/chat_id/id
        if selectedModel?.isPipeModel == true {
            request.isPipeModel = true
        }

        // Filter IDs from model's server-configured filter list
        let filterIds = selectedModel?.filterIds ?? []
        if !filterIds.isEmpty { request.filterIds = filterIds }

        // Always send the full features object with explicit true/false values
        request.features = buildChatFeatures()

        // Await any pending model config fetch (ensures functionCallingMode is populated)
        await modelConfigTask?.value

        // Build request params: chat-level overrides + system prompt + function_calling
        var params: [String: Any] = [:]
        if let chatP = conversation?.chatParams {
            params = chatP.mergedOver(base: params)
        }
        let effectiveSP: String? = {
            if let cp = conversation?.chatParams?.systemPrompt,
               !cp.trimmingCharacters(in: .whitespaces).isEmpty { return cp }
            return conversation?.systemPrompt
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

        var bgTasks: [String: Any] = [:]
        if suggestionsEnabled { bgTasks["follow_up_generation"] = true }
        if isFirst && titleGenEnabled { bgTasks["title_generation"] = true }
        if isFirst && tagsEnabled { bgTasks["tags_generation"] = true }
        if webSearchEnabled { bgTasks["web_search"] = true }
        if !bgTasks.isEmpty { request.backgroundTasks = bgTasks }
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
            return conversation.systemPrompt
        }()
        if let sp = simpleEffectiveSP, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            msgs.append(["role": "system", "content": sp])
        }
        for msg in conversation.messages where !msg.isStreaming {
            msgs.append(["role": msg.role.rawValue, "content": msg.content])
        }
        return msgs
    }

    private func buildAPIMessagesAsync() async -> [[String: Any]] {
        guard let conversation else { return [] }
        var apiMessages: [[String: Any]] = []
        let asyncEffectiveSP: String? = {
            if let cp = conversation.chatParams?.systemPrompt,
               !cp.trimmingCharacters(in: .whitespaces).isEmpty { return cp }
            return conversation.systemPrompt
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

                // Resolve title
                let title: String? = {
                    if let n = meta["name"] as? String, !n.isEmpty { return n }
                    if let t = meta["title"] as? String, !t.isEmpty { return t }
                    if let n = baseSource["name"] as? String, !n.isEmpty { return n }
                    if let t = baseSource["title"] as? String, !t.isEmpty { return t }
                    if let id = idCandidate, !id.isEmpty { return id }
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
                // Streaming just ended — flush store to conversation
                let result = streamingStore.endStreaming()
                let finalContent = content.isEmpty ? result.content : content
                conversation?.messages[index].content = finalContent
                conversation?.messages[index].isStreaming = false
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

        // Trigger streaming haptic feedback (throttled to ~10 Hz to avoid
        // overwhelming the Taptic Engine while still feeling responsive)
        if isStreaming && error == nil {
            triggerStreamingHaptic()
        }
    }

    /// Fires a subtle haptic pulse during token streaming, throttled via
    /// the centralized `Haptics` service to avoid excessive motor usage.
    /// Uses the cached `streamingHapticsEnabled` flag (updated via
    /// UserDefaults.didChangeNotification) to avoid a per-token UserDefaults read.
    private func triggerStreamingHaptic() {
        guard streamingHapticsEnabled else { return }
        Haptics.streamingTick()
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
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }
        // Use direct in-place mutation. The @Observable macro on ChatViewModel
        // tracks mutations to `conversation` itself — mutating through the
        // optional chain works because `conversation` is a var on an @Observable
        // class. Avoid full `conversation = conv` reassignment which can cause
        // "setting value during update" crashes if a navigation event (e.g.,
        // new chat) fires concurrently.
        conversation?.messages[index].followUps = followUps
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
