import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import QuickLook
import MarkdownView
import Litext
import os.log

// MARK: - Scroll Geometry Snapshot
//
// A single atomic snapshot of the scroll view's geometry, captured inside
// onScrollGeometryChange so that contentOffset, contentSize, and containerSize
// are ALWAYS from the same render pass.  Using three separate @State variables
// (the old approach) meant they could be stale by 1-2 frames relative to each
// other, which caused isBouncing to mis-fire during bottom-edge rubber-banding
// and triggered the nav-bar / FAB jitter the user reported.
private struct ScrollSnapshot: Equatable {
    var offset: CGPoint
    var contentSize: CGSize
    var containerSize: CGSize
}

// MARK: - Pump Rate-Limiter

/// A reference-type box that holds the last programmatic scroll timestamp
/// and the last scroll offset Y for nav-bar direction detection.
/// Written inside `onScrollGeometryChange` callbacks at high frequency —
/// using a class avoids SwiftUI @State observation overhead on every write.
private final class PumpRef {
    var lastScrollTime: Date = .distantPast
    /// Last offset used to compute scroll direction for nav-bar direction detection.
    var lastNavBarOffsetY: CGFloat = 0
    /// When set, suppresses all nav-bar hide/show reactions until this date.
    /// Armed before every programmatic scrollTo() call so reflow-induced offset
    /// changes (FAB scroll, stream start, pagination) never trigger the nav bar.
    var programmaticScrollUntil: Date = .distantPast
    /// Current scroll offset Y — tracked at 120Hz but stored here (not @State) so that
    /// writing it never triggers a SwiftUI body re-evaluation. Read at tap-time by FAB.
    var currentScrollOffsetY: CGFloat = 0
    /// The ID of the message currently nearest the top of the visible viewport.
    /// Updated continuously; read at FAB tap-time for layout-stable jump targeting.
    var topmostVisibleMessageId: String? = nil
}

// MARK: - Chat Detail View

struct ChatDetailView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let logger = Logger(subsystem: "com.openui", category: "ChatDetailView")

    private let initialConversationId: String?
    @State private var viewModel: ChatViewModel

    // MARK: Model selector sheet
    @State private var isShowingModelSelectorSheet = false
    @State private var isShowingChatParams = false
    @State private var editingModelDetail: ModelDetail? = nil
    @State private var isLoadingModelDetail = false

    // MARK: Scroll state (iOS 18 ScrollPosition API)
    /// iOS 18+ declarative scroll position. Used with `.scrollPosition($scrollPosition)`
    /// to drive programmatic scrolling via `scrollTo(edge:)`.
    @State private var scrollPosition: ScrollPosition = .init()
    /// True when the user has manually scrolled away from the bottom.
    @State private var isScrolledUp = false
    /// Curtain flag: keeps the message area invisible until messages are loaded
    /// AND the scroll position has been set to the bottom. Prevents the user
    /// from seeing skeleton → messages → scroll animation. Resets to false on
    /// every new ChatDetailView instance (each conversation has a unique .id).
    @State private var isContentReady = false
    /// True when the scroll position is at or very near the top (offset.y < 50pt).
    /// Used to hide the ↑ FAB when already at the very top.
    @State private var isAtTop = false
    /// The index (into `viewModel.messages`) of the user message we last jumped to via the ↑ FAB.
    /// nil = haven't jumped yet (next tap jumps to the user message nearest the current viewport top).
    /// Reset to nil whenever the user scrolls back to the bottom.
    @State private var userMessageJumpIndex: Int? = nil
    /// Cached scroll content height — updated via onScrollGeometryChange.
    @State private var viewState_contentHeight: CGFloat = 0
    /// Cached scroll container height — updated via onScrollGeometryChange.
    /// Pre-seeded with screen height so welcomeView Spacers can centre content
    /// from the very first frame (avoids the top→centre jump when a new
    /// ChatDetailView is instantiated and the async measurement hasn't fired yet).
    @State private var viewState_containerHeight: CGFloat = UIScreen.main.bounds.height
    // currentScrollOffsetY and topmostVisibleMessageId are stored in _pumpRef (PumpRef class)
    // to avoid @State observation overhead — writing them on every 120Hz scroll frame was
    // causing the entire view body to re-evaluate, causing low-FPS scrolling. They are read
    // at button tap-time from _pumpRef where needed.
    /// True while a user gesture (finger touch or inertia deceleration) is driving
    /// the scroll view. Used by the streaming pump to yield to the user's finger/inertia.
    /// Layout reflows, WKWebView resizes, and programmatic scrolls never set this flag
    /// because they emit .animating/.idle phases, not .interacting or .decelerating.
    @State private var isUserDriving = false
    /// True ONLY while the user's finger is physically on the screen (.interacting phase).
    /// Used exclusively for nav-bar hide/show and isScrolledUp trip so that inertia
    /// deceleration + bounce recovery (which is .decelerating, NOT .interacting) can
    /// never trigger jittery nav-bar show/hide at the bottom edge.
    @State private var isFingerDriving = false
    /// True while iOS is decelerating (coasting) after the user lifts their finger.
    /// The streaming pump must NOT fire during deceleration — each programmatic
    /// scrollTo() call cancels the OS momentum curve, causing the instant-stop
    /// behaviour the user reported (swipe → lifts finger → scroll stops dead instead
    /// of coasting to a smooth stop). Stored in @State rather than PumpRef so that
    /// the pump guard inside onScrollGeometryChange reads the live value.
    @State private var isDecelerating = false
    /// Rate-limit timestamp for the streaming scroll pump (writes are non-rendering).
    private let _pumpRef = PumpRef()
    /// Whether the navigation bar is currently hidden.
    /// HIDE: any downward scroll (immediately, regardless of distance from bottom).
    /// SHOW: any upward manual scroll, or when scrolled back to bottom (FAB disappears).
    @State private var navBarHidden = false
    /// Whether streaming responses should automatically scroll the chat to the bottom.
    /// Enabled by default (matches existing behaviour). Users can disable in Chat Behavior settings.
    @AppStorage("streamingAutoScroll") private var streamingAutoScroll = true

    // MARK: Message pagination (sliding window — memory optimization)
    /// The ending index (exclusive) of the visible message window.
    /// `nil` means "pinned to latest" — the window always includes the newest messages.
    @State private var windowEnd: Int? = nil
    /// Number of messages currently in the window. Starts small, grows to `maxWindowSize`.
    @State private var windowSize: Int = 5
    /// Guard to prevent rapid-fire pagination triggers.
    @State private var isLoadingMoreMessages = false
    /// Maximum messages rendered at once (the sliding-window cap).
    private let maxWindowSize = 12


    // MARK: UI state
    @State private var showCopiedToast = false
    @State private var activeActionMessageId: String?
    @State private var activeVersionIndex: [String: Int] = [:]

    // MARK: Action event handling (dynamic input/confirmation/notification)

    /// Pending `__event_call__` input prompt waiting for user text.
    @State private var actionInputRequest: ActionInputRequest? = nil
    /// Pending `__event_call__` confirmation waiting for user yes/no.
    @State private var actionConfirmRequest: ActionConfirmRequest? = nil
    /// Toast message from `__event_emitter__` notification events.
    @State private var actionNotificationToast: String? = nil
    /// Continuation used to resume the streaming task with the user's input/confirmation response.
    @State private var actionCallContinuation: CheckedContinuation<ActionCallResponse, Never>? = nil
    /// Bound to the TextField inside the action input alert.
    @State private var actionInputText: String = ""
    @State private var speakingMessageId: String?
    @State private var ttsGeneratingMessageId: String?
    @State private var usagePopoverMessageId: String?
    @State private var sourcesSheetMessage: ChatMessage?
    @State private var feedbackDetailMessage: ChatMessage? = nil
    @State private var subagentDetailMessage: ChatMessage? = nil
    @State private var randomPrompts: [SuggestedPrompt] = []

    // MARK: Model mention (@ trigger)
    @State private var isShowingModelPicker = false
    @State private var modelPickerQuery = ""
    @State private var mentionedModel: AIModel? = nil

    // MARK: Inline edit (user messages)
    @State private var editingMessageId: String?
    @State private var editingMessageText = ""
    @State private var editingMessageFiles: [ChatMessageFile] = []
    @FocusState private var isEditFieldFocused: Bool

    // MARK: Inline edit (assistant messages — in-place content save, no regeneration)
    @State private var editingAssistantMessageId: String?
    @State private var editingAssistantText = ""
    @FocusState private var isAssistantEditFocused: Bool

    // MARK: User message version navigation
    /// Tracks the active version index for user messages (edit history).
    /// -1 means the current (latest) user message content. 0...N-1 = an older version.
    @State private var activeUserVersionIndex: [String: Int] = [:]

    /// Maps assistant message ID → content override when viewing an older user version.
    /// When nil, the assistant shows its own current content.
    /// When set, the assistant displays this overridden content instead.
    @State private var assistantContentOverride: [String: String] = [:]

    // Bug 10: cached indexMap rebuilt only when message count changes.
    @State private var cachedIndexMap: [String: Int] = [:]

    // MARK: Chat menu actions
    @State private var showDeleteChatConfirm = false

    // MARK: Dictation
    @State private var isDictating = false

    // MARK: Keyboard
    @State private var keyboard = KeyboardTracker()

    // MARK: Attachment pickers
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showFilePicker = false
    @State private var showPhotosPicker = false
    @State private var showAudioPicker = false
    @State private var showCameraPicker = false
    @State private var showWebURLAlert = false
    @State private var webURLInput = ""
    @State private var showReferenceChatPicker = false
    @State private var showServerFilesPicker = false
    @State private var showNotesPicker = false
    @State private var showKnowledgeFromMenuPicker = false

    // MARK: #URL inline suggestion
    @State private var detectedWebURL: String?


    // MARK: File download & preview
    @State private var isDownloadingFile = false
    @State private var downloadedFileURL: URL?
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""
    /// URL for QuickLook in-app file preview (PDF, images, docs, etc.)
    @State private var previewFileURL: URL?
    /// User-valves sheet: set to a .tool(id) or .function(id) to present UserValvesSheet.
    @State private var toolUserValvesKind: UserValvesKind?
    /// Code preview from MarkdownView's eye button (fullscreen code view)
    @State private var codePreviewCode: String?
    @State private var codePreviewLanguage: String = ""

    // MARK: Init

    init(conversationId: String, viewModel: ChatViewModel) {
        self.initialConversationId = conversationId
        self._viewModel = State(initialValue: viewModel)
    }

    init(viewModel: ChatViewModel) {
        self.initialConversationId = nil
        self._folderWorkspace = nil
        self._viewModel = State(initialValue: viewModel)
    }

    // MARK: - Folder Workspace Init

    /// Creates a ChatDetailView in "folder workspace" mode.
    /// When `folderWorkspace` is set, the welcome/empty state shows the folder
    /// icon + name centered (matching the web UI). New chats are created inside
    /// the folder with its system prompt injected.
    init(viewModel: ChatViewModel, folderWorkspace: ChatFolder?) {
        self.initialConversationId = nil
        self._folderWorkspace = folderWorkspace
        self._viewModel = State(initialValue: viewModel)
    }

    private var _folderWorkspace: ChatFolder?

    /// Called after the chat is successfully deleted, so the parent can
    /// navigate away smoothly (e.g. animate to new chat). Defaults to nil
    /// which falls back to router.popToRoot().
    /// When true, this chat is from a shared folder where the user only has read permission.
    /// Hides the input field and shows a "Read only" banner instead.
    private var isReadOnly: Bool = false

    /// Chainable modifier — enables read-only mode (for shared folders with view-only access).
    func readOnly(_ enabled: Bool = true) -> ChatDetailView {
        var copy = self
        copy.isReadOnly = enabled
        return copy
    }

    private var deleteChatAction: (() -> Void)?

    /// Chainable modifier — lets call sites set the post-delete callback:
    /// `ChatDetailView(viewModel: vm).onDeleteChat { startNewChat() }`
    func onDeleteChat(_ action: @escaping () -> Void) -> ChatDetailView {
        var copy = self
        copy.deleteChatAction = action
        return copy
    }

    /// Optional callback invoked when the hamburger menu button is tapped.
    /// When set, a hamburger icon is shown at the leading edge of the custom top bar.
    private var toggleDrawerAction: (() -> Void)?

    func onToggleDrawer(_ action: @escaping () -> Void) -> ChatDetailView {
        var copy = self
        copy.toggleDrawerAction = action
        return copy
    }

    /// Optional callback invoked when the new-chat button is tapped.
    /// When set, a compose icon is shown at the trailing edge of the custom top bar.
    private var newChatAction: (() -> Void)?

    func onNewChat(_ action: @escaping () -> Void) -> ChatDetailView {
        var copy = self
        copy.newChatAction = action
        return copy
    }

    /// Optional callback invoked when the "Browse Files" button is tapped in the terminal toolbar.
    /// When set, opens the file browser drawer from the parent (MainChatView) using the
    /// same scale/blur/push effect as the chat history drawer.
    private var openFileBrowserAction: (() -> Void)?

    func onOpenFileBrowser(_ action: @escaping () -> Void) -> ChatDetailView {
        var copy = self
        copy.openFileBrowserAction = action
        return copy
    }

    // MARK: - Body

    var body: some View {
        @Bindable var vm = viewModel

        ZStack {
            theme.background.ignoresSafeArea()
            messageListArea
        }
        // Custom top bar replaces the system navigation bar entirely.
        //
        // CRITICAL: The safeAreaInset height must NEVER change — it is the source
        // of viewState_containerHeight (via the scroll geometry callback). If the
        // inset collapses when navBarHidden flips true, containerHeight changes,
        // which changes the minHeight VStack, which causes the content to jump
        // (the jitter seen at the bottom edge).
        //
        // Solution: always reserve the full bar height in the safeAreaInset.
        // Hide the bar purely visually using offset + opacity — the layout
        // footprint stays constant at all times so the scroll view geometry
        // never changes when the bar hides or shows.
        .safeAreaInset(edge: .top, spacing: 0) {
            customTopBar
                .opacity(navBarHidden ? 0 : 1)
                .offset(y: navBarHidden ? -56 : 0)
                // DO NOT use .frame(height:) here — that would collapse the
                // reserved safeAreaInset space and change containerHeight.
                .animation(.easeInOut(duration: 0.22), value: navBarHidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editingMessageId != nil {
                editInputBar
            } else {
                inputFieldArea(vm: vm)
            }
        }
        .navigationBarHidden(true)
        // Configure the view model synchronously on first appearance so that the
        // toolbar (model selector, terminal icon) is fully populated before the
        // very first render.  The `isConfigured` guard prevents a second call if
        // `ActiveChatStore.prewarm()` already ran before navigation.
        .onAppear {
            guard !viewModel.isConfigured, let manager = dependencies.conversationManager else { return }
            viewModel.configure(
                with: manager,
                socket: dependencies.socketService,
                store: dependencies.activeChatStore,
                asr: dependencies.asrService,
                notes: dependencies.notesManager
            )
        }
        .task { await handleViewTask() }
        // Reactive fallback: if backendConfig wasn't ready when .task ran
        // (first app launch), rebuild prompts as soon as the config arrives.
        // Watch the suggestion count (Int?) — always Equatable, avoids
        // asking the type-checker to diff the entire BackendConfig struct.
        .onChange(of: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions?.count) { _, _ in
            // Always rebuild when the server config changes — this handles both the
            // first-launch timing case (randomPrompts is empty) AND the case where
            // the admin updates suggestions on the server while the app is running.
            let updated = Self.resolvePromptSuggestions(
                adminSuggestions: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions,
                modelSuggestions: viewModel.selectedModel?.suggestionPrompts,
                count: promptCardCount
            )
            withTransaction(\.animation, nil) { randomPrompts = updated }
        }
        // Also rebuild prompts when the selected model changes — the new model may
        // have per-model suggestion_prompts that should show as a fallback when the
        // admin hasn't set global prompts.
        .onChange(of: viewModel.selectedModelId) { _, _ in
            let updated = Self.resolvePromptSuggestions(
                adminSuggestions: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions,
                modelSuggestions: viewModel.selectedModel?.suggestionPrompts,
                count: promptCardCount
            )
            withTransaction(\.animation, nil) { randomPrompts = updated }
        }
        .onAppear {
            viewModel.syncOnEntry()
        }
        .onDisappear { handleDisappear() }
        // Stop TTS when app enters background to prevent Metal GPU crashes
        // and keep the speakingMessageId state in sync with actual playback.
        // NOTE: Server TTS (AVQueuePlayer) is intentionally NOT stopped here.
        // AVQueuePlayer continues playing in the background via UIBackgroundModes "audio".
        // Stopping it here would deactivate the shared AVAudioSession before iOS grants
        // background audio priority, killing the audio. On-device engines (Kokoro/Qwen3)
        // MUST be stopped to prevent Metal GPU crashes in the background.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            let tts = dependencies.textToSpeechService
            if tts.activeEngine == .server {
                // Server TTS keeps playing in background — do NOT stop it here.
                // speakingMessageId stays set so the stop button is still shown when
                // the user returns to the foreground and the audio has finished.
                return
            }
            if speakingMessageId != nil || ttsGeneratingMessageId != nil {
                tts.stop()
                speakingMessageId = nil
                ttsGeneratingMessageId = nil
            }
        }
        // Toasts & banners
        .overlay(alignment: .top) {
            if showCopiedToast { copiedToastView }
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                errorBannerView(error)
                    .padding(.bottom, keyboard.height + 80)
            }
        }
        // Sheets & alerts
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { urls in
                Task {
                    for url in urls {
                        let ext = url.pathExtension.lowercased()
                        let audioExts = ["mp3","wav","m4a","aac","flac","ogg","caf","aiff","wma"]
                        if audioExts.contains(ext) {
                            await processAudioFileURL(url)
                        } else {
                            await processFileURL(url)
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPickerView { image in processCameraImage(image) }
                .ignoresSafeArea()
        }
        .alert("Add Web Link", isPresented: $showWebURLAlert) {
            TextField("https://example.com", text: $webURLInput)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocapitalization(.none)
            Button("Cancel", role: .cancel) { webURLInput = "" }
            Button("Add") { processWebURL() }
        } message: {
            Text("Enter a URL to include as context in your message.")
        }
        .onChange(of: selectedPhotos) { _, newItems in
            Task { await processSelectedPhotos(newItems); selectedPhotos = [] }
        }
        // Pick up files shared from other apps via "Open In" / document import.
        // The version counter fires this even when the view is already visible.
        .onChange(of: dependencies.pendingIncomingFileVersion) { _, _ in
            if let file = dependencies.pendingIncomingFile {
                viewModel.attachments.append(file)
                // Trigger immediate upload for shared files (via "Open In")
                viewModel.uploadAttachmentImmediately(attachmentId: file.id)
                dependencies.pendingIncomingFile = nil
            }
        }
        // Pick up extra attachments from the Share Extension (URLs shared alongside files).
        // These are any attachments beyond the first (which uses pendingIncomingFile).
        .onChange(of: dependencies.pendingIncomingFileVersion) { _, _ in
            let extras = dependencies.pendingIncomingExtraAttachments
            if !extras.isEmpty {
                for attachment in extras {
                    viewModel.attachments.append(attachment)
                    viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
                }
                dependencies.pendingIncomingExtraAttachments = []
            }
        }
        // Pre-fill input text and trigger web-scraping for URLs from the Share Extension.
        // Extracted into a private extension to keep the type-checker expression size manageable.
        .applyShareExtensionHandlers(dependencies: dependencies, viewModel: viewModel)
        .sheet(item: $sourcesSheetMessage) { message in
            SourcesDetailSheet(sources: message.sources)
        }
        .sheet(item: $feedbackDetailMessage) { msg in
            FeedbackDetailSheet(message: msg, viewModel: viewModel)
        }
        .sheet(item: $subagentDetailMessage) { msg in
            SubagentResultSheet(message: msg)
        }
        // Assistant inline edit sheet — shown when the user taps the pencil icon
        // on an assistant message. Allows editing content in-place (no regeneration).
        .sheet(isPresented: Binding(
            get: { editingAssistantMessageId != nil },
            set: { if !$0 { cancelAssistantEdit() } }
        )) {
            AssistantEditSheet(
                text: $editingAssistantText,
                isFocused: $isAssistantEditFocused,
                onSave: { submitAssistantEdit() },
                onCancel: { cancelAssistantEdit() }
            )
            .themed()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // Prompt variable input sheet — shown when a selected prompt has {{variables}}
        .sheet(isPresented: Binding<Bool>(
            get: { viewModel.pendingPromptForVariables != nil },
            set: { if !$0 { viewModel.cancelPromptVariables() } }
        )) {
            if let prompt = viewModel.pendingPromptForVariables {
                PromptVariableSheet(
                    promptName: prompt.name,
                    variables: viewModel.pendingPromptVariables,
                    onSave: { values in
                        viewModel.submitPromptVariables(values: values)
                    },
                    onCancel: {
                        viewModel.cancelPromptVariables()
                    }
                )
            }
        }
        // Intercept link taps from MarkdownView and vizSendPrompt bridge calls.
        // Extracted into a private extension to keep the type-checker expression size manageable.
        .applyLinkAndPromptHandlers(
            viewModel: viewModel,
            downloadAndShare: { fileId in Task { await downloadAndShareFile(fileId: fileId) } },
            downloadAndShareURL: { url in Task { await downloadAndShareArbitraryURL(url) } }
        )
        // Handle "Ask" / "Explain" taps from the text selection menu in assistant
        // messages. Extracted into a private extension to keep the type-checker
        // expression size manageable.
        .applyTextSelectionHandlers(viewModel: viewModel)
        // Drive keyboard focus via the ViewModel flag rather than directly setting
        // FocusState from inside an onReceive — the indirect path avoids a race
        // with UIKit's responder-chain cleanup (LTXLabel calls resignFirstResponder
        // during clearSelection(), which fires after the menu dismisses).
        .onChange(of: viewModel.shouldFocusInput) { _, newValue in
            guard newValue else { return }
            // Prevent the keyboard appearance from triggering an auto-scroll —
            // the user is looking at the selected text they want to ask about
            // and should stay at their current scroll position.
            isScrolledUp = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
                viewModel.shouldFocusInput = false
            }
        }
        .overlay {
            if isDownloadingFile {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Downloading…")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.white)
                    }
                    .padding(Spacing.lg)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .alert("Download Failed", isPresented: $showDownloadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadErrorMessage)
        }
        // MARK: Action event modifiers (input dialog, confirmation, notification toast)
        .applyActionEventModifiers(
            actionInputRequest: $actionInputRequest,
            actionConfirmRequest: $actionConfirmRequest,
            actionNotificationToast: $actionNotificationToast,
            actionCallContinuation: $actionCallContinuation,
            actionInputText: $actionInputText
        )
        .sheet(item: $downloadedFileURL) { url in
            ShareSheetView(activityItems: [url])
        }
        // User-configurable valves sheet (gear icon on tool rows in ToolsMenuSheet)
        .sheet(item: $toolUserValvesKind) { kind in
            UserValvesSheet(kind: kind)
                .environment(dependencies)
                .themed()
        }
        // In-app file preview using QuickLook (PDFs, images, docs, etc.)
        .quickLookPreview($previewFileURL)
        // Chat advanced parameters sheet (slider icon in toolbar)
        .sheet(isPresented: $isShowingChatParams) {
            ChatAdvancedParamsSheet(
                params: Binding(
                    get: { viewModel.conversation?.chatParams ?? viewModel.pendingChatParams ?? ChatAdvancedParams() },
                    set: { newParams in
                        if viewModel.conversation != nil {
                            viewModel.conversation?.chatParams = newParams
                        } else {
                            viewModel.pendingChatParams = newParams
                        }
                    }
                )
            )
            .environment(dependencies)
            .themed()
        }
        .sheet(item: $editingModelDetail) { detail in
            NavigationStack {
                ModelEditorView(existingModel: detail) { _ in
                    Task { viewModel.refreshModelsInBackground() }
                    editingModelDetail = nil
                }
            }
            .environment(dependencies)
            .themed()
        }
        .applyWidgetAndPickerHandlers(
            showCameraPicker: $showCameraPicker,
            showPhotosPicker: $showPhotosPicker,
            showFilePicker: $showFilePicker,
            selectedPhotos: $selectedPhotos,
            codePreviewCode: $codePreviewCode,
            codePreviewLanguage: $codePreviewLanguage,
            onDismissOverlays: { dismissAllPickers() }
        )
        .applyDeleteChatConfirmation(isPresented: $showDeleteChatConfirm, onDelete: performDeleteChat)
    }

    // MARK: - Custom top bar (replaces system nav bar to avoid split-layer hide/show bug)

    // MARK: - Custom top bar

    private var customTopBar: some View {
        HStack(spacing: Spacing.sm) {
            // Leading: hamburger — large circle pill matching image 2
            if let drawerAction = toggleDrawerAction {
                Button {
                    drawerAction()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .scaledFont(size: 18, weight: .medium, context: .ui)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Menu")
            }

            // Center: model selector
            HStack(spacing: Spacing.xs) {
                modelSelectorButton
            }
            .frame(maxWidth: .infinity)

            // Trailing: all action icons in one grouped pill (matching image 2)
            trailingActionsPill
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 8)
        .background(theme.background)
    }

    /// All trailing action icons grouped into a single rounded-rect pill, matching the original design.
    @ViewBuilder
    private var trailingActionsPill: some View {
        HStack(spacing: 0) {
            // New chat
            if let newChat = newChatAction {
                pillIconButton(icon: "square.and.pencil", accessibilityLabel: "New Chat") {
                    newChat()
                }
            }

            // Chat parameters
            pillIconButton(
                icon: "slider.horizontal.3",
                tint: (viewModel.conversation?.chatParams != nil || viewModel.pendingChatParams != nil) ? theme.brandPrimary : nil,
                accessibilityLabel: "Chat parameters"
            ) {
                Haptics.play(.light)
                isShowingChatParams = true
            }

            // Temporary chat toggle (new chats only)
            if viewModel.messages.isEmpty {
                pillIconButton(
                    icon: viewModel.isTemporaryChat ? "eye.slash.fill" : "eye",
                    tint: viewModel.isTemporaryChat ? theme.warning : nil,
                    accessibilityLabel: viewModel.isTemporaryChat ? "Temporary chat on" : "Temporary chat off"
                ) {
                    withAnimation(MicroAnimation.snappy) { viewModel.isTemporaryChat.toggle() }
                    Haptics.play(.light)
                }
            }

            // Save temporary chat (active temp chats with messages)
            if viewModel.isTemporaryChat && !viewModel.messages.isEmpty {
                Button {
                    Haptics.play(.medium)
                    Task { await viewModel.saveTemporaryChat() }
                } label: {
                    ZStack {
                        if viewModel.isSavingTemporaryChat {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                                .tint(theme.brandPrimary)
                        } else {
                            ZStack {
                                Circle()
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                                    .foregroundStyle(theme.brandPrimary)
                                    .frame(width: 16, height: 16)
                                Image(systemName: "checkmark")
                                    .scaledFont(size: 8, weight: .bold)
                                    .foregroundStyle(theme.brandPrimary)
                            }
                        }
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(viewModel.isSavingTemporaryChat)
                .accessibilityLabel("Save as permanent chat")
            }

            // Overflow menu
            if viewModel.conversation != nil || !viewModel.messages.isEmpty {
                Menu {
                    if viewModel.conversation != nil {
                        Button(role: .destructive) {
                            showDeleteChatConfirm = true
                        } label: {
                            Label("Delete Chat", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Icon button for use inside the trailing grouped pill.
    @ViewBuilder
    private func pillIconButton(
        icon: String,
        tint: Color? = nil,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(tint ?? theme.textSecondary)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var modelSelectorButton: some View {
        Group {
            if viewModel.availableModels.isEmpty {
                Text(viewModel.conversation?.title ?? String(localized: "New Chat"))
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Button {
                    Haptics.play(.light)
                    viewModel.refreshModelsInBackground()
                    isShowingModelSelectorSheet = true
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if let model = viewModel.selectedModel {
                            ModelAvatar(
                                size: 22,
                                imageURL: viewModel.resolvedImageURL(for: model),
                                label: model.shortName,
                                authToken: viewModel.serverAuthToken
                            )
                            .fixedSize()
                            .id(model.id)
                            .transition(.opacity)
                        }
                        Text(viewModel.selectedModel?.shortName ?? String(localized: "Select Model"))
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(0)
                            .contentTransition(.opacity)
                        Image(systemName: "chevron.down")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.cardBackground.opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isShowingModelSelectorSheet) {
                    ModelSelectorSheet(
                        models: viewModel.availableModels,
                        selectedModelId: viewModel.selectedModelId,
                        serverBaseURL: viewModel.serverBaseURL,
                        authToken: viewModel.serverAuthToken,
                        isAdmin: dependencies.authViewModel.currentUser?.role == .admin,
                        pinnedModelIds: viewModel.pinnedModelIds,
                        onEdit: dependencies.authViewModel.currentUser?.role == .admin ? { model in
                            isShowingModelSelectorSheet = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await openModelEditorFromPicker(model)
                            }
                        } : nil,
                        onTogglePin: { modelId in
                            viewModel.togglePinModel(modelId)
                        },
                        onSelect: { model in
                            withAnimation(MicroAnimation.snappy) {
                                viewModel.selectModel(model.id)
                            }
                        }
                    )
                    .themed()
                    .presentationBackgroundInteraction(.disabled)
                    .onDisappear {
                        Task { await ImageCacheService.shared.clearMemory() }
                    }
                }
            }
        }
        // Cap the model selector width so long names truncate
        // instead of pushing into trailing toolbar buttons.
        .frame(maxWidth: 220)
    }

    // MARK: - Input Field Area

    // MARK: - Read-Only Banner

    /// Shown in place of the input field when this chat is from a read-only shared folder.
    private var readOnlyBanner: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "lock.fill")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
            Text("Read only — shared folder")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 14)
        .background(theme.surfaceContainer.opacity(0.6))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    @ViewBuilder
    private func inputFieldArea(vm: ChatViewModel) -> some View {
        @Bindable var vm = vm

        if isReadOnly {
            // ── Read-only mode: show banner instead of input field ──────────
            readOnlyBanner
        } else {
        // ── Normal mode: full input field ────────────────────────────────────
        VStack(spacing: 0) {
            // Picker overlays — rendered above the input field so input stays visible
            if let url = detectedWebURL {
                webURLSuggestionPill(url: url)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if vm.isShowingKnowledgePicker {
                KnowledgePickerView(
                    query: vm.knowledgeSearchQuery,
                    items: vm.knowledgeItems,
                    isLoading: vm.isLoadingKnowledge,
                    keyboardHeight: keyboard.height,
                    onSelect: { item in
                        viewModel.selectKnowledgeItem(item)
                    },
                    onDismiss: {
                        viewModel.dismissKnowledgePicker()
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if vm.isShowingPromptPicker {
                PromptPickerView(
                    query: vm.promptSearchQuery,
                    prompts: vm.availablePrompts,
                    isLoading: vm.isLoadingPrompts,
                    keyboardHeight: keyboard.height,
                    onSelect: { prompt in
                        viewModel.selectPrompt(prompt)
                    },
                    onDismiss: {
                        viewModel.dismissPromptPicker()
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if vm.isShowingSkillPicker {
                SkillPickerView(
                    query: vm.skillSearchQuery,
                    skills: vm.availableSkills,
                    isLoading: vm.isLoadingSkills,
                    keyboardHeight: keyboard.height,
                    onSelect: { skill in
                        viewModel.selectSkill(skill)
                    },
                    onDismiss: {
                        viewModel.dismissSkillPicker()
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if isShowingModelPicker {
                ModelPickerView(
                    query: modelPickerQuery,
                    models: vm.availableModels,
                    serverBaseURL: vm.serverBaseURL,
                    authToken: vm.serverAuthToken,
                    keyboardHeight: keyboard.height,
                    onSelect: { model in
                        withAnimation(.easeOut(duration: 0.15)) {
                            mentionedModel = model
                            viewModel.mentionedModelId = model.id
                        }
                        viewModel.removeMentionToken()
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingModelPicker = false
                            modelPickerQuery = ""
                        }
                        Haptics.play(.light)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingModelPicker = false
                            modelPickerQuery = ""
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            // ── Model-Switch Banner (above input field, issue #79) ──
            if let switchStatus = vm.modelSwitchStatus, switchStatus.isSwitching {
                ModelSwitchBannerView(status: switchStatus)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // ── Task List Panel (above input field) ──
            if !vm.tasks.isEmpty {
                TaskListView(
                    tasks: vm.tasks,
                    isStreaming: vm.isStreaming,
                    onToggleStatus: { taskId, newStatus in
                        viewModel.updateTaskStatus(taskId: taskId, newStatus: newStatus)
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            ChatInputField(
                text: $vm.inputText,
                attachments: $vm.attachments,
                placeholder: placeholderText,
                isEnabled: !vm.isStreaming || vm.enableMessageQueue,
                onSend: { Task { await viewModel.sendMessage() } },
                onStopGenerating: vm.isStreaming ? { viewModel.stopStreaming() } : nil,
                webSearchEnabled: $vm.webSearchEnabled,
                imageGenerationEnabled: $vm.imageGenerationEnabled,
                codeInterpreterEnabled: $vm.codeInterpreterEnabled,
                isWebSearchAvailable: dependencies.authViewModel.featurePermissions.webSearch && isFeatureAvailable("web_search", serverEnabled: dependencies.authViewModel.backendConfig?.features?.enableWebSearch),
                isImageGenerationAvailable: dependencies.authViewModel.featurePermissions.imageGeneration && isFeatureAvailable("image_generation", serverEnabled: dependencies.authViewModel.backendConfig?.features?.enableImageGeneration),
                isCodeInterpreterAvailable: dependencies.authViewModel.featurePermissions.codeInterpreter && isFeatureAvailable("code_interpreter", serverEnabled: dependencies.authViewModel.backendConfig?.features?.enableCodeInterpreter),
                tools: vm.availableTools,
                selectedToolIds: $vm.selectedToolIds,
                isLoadingTools: vm.isLoadingTools,
                terminalEnabled: vm.terminalEnabled,
                isTerminalAvailable: !vm.availableTerminalServers.isEmpty && vm.isTerminalCapableForSelectedModel,
                terminalServerName: vm.selectedTerminalServer?.displayName ?? "",
                availableTerminalServers: vm.availableTerminalServers,
                onTerminalToggle: { viewModel.toggleTerminal() },
                onTerminalServerSelected: { server in
                    viewModel.selectedTerminalServer = server
                },
                onBrowseFiles: openFileBrowserAction,
                mentionedModel: $mentionedModel,
                mentionedModelImageURL: mentionedModel.flatMap { viewModel.resolvedImageURL(for: $0) },
                mentionedModelAuthToken: viewModel.serverAuthToken,
                onAtTrigger: { query in
                    modelPickerQuery = query
                    if !isShowingModelPicker {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isShowingModelPicker = true
                        }
                        viewModel.refreshModelsInBackground()
                    }
                },
                onAtDismiss: {
                    if isShowingModelPicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingModelPicker = false
                            modelPickerQuery = ""
                        }
                    }
                },
                selectedKnowledgeItems: $vm.selectedKnowledgeItems,
                selectedReferenceChats: $vm.selectedReferenceChats,
                selectedNotes: $vm.selectedNotes,
                onHashTrigger: { query in
                    // Detect if the query looks like a URL → show inline suggestion pill
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("www.") {
                        // Dismiss knowledge picker if it was showing
                        if viewModel.isShowingKnowledgePicker {
                            withAnimation(.easeOut(duration: 0.15)) {
                                viewModel.dismissKnowledgePicker()
                            }
                        }
                        withAnimation(.easeOut(duration: 0.2)) {
                            detectedWebURL = trimmed
                        }
                    } else {
                        // Not a URL → normal knowledge picker behavior
                        if detectedWebURL != nil {
                            withAnimation(.easeOut(duration: 0.15)) {
                                detectedWebURL = nil
                            }
                        }
                        viewModel.knowledgeSearchQuery = query
                        if !viewModel.isShowingKnowledgePicker {
                            withAnimation(.easeOut(duration: 0.2)) {
                                viewModel.isShowingKnowledgePicker = true
                            }
                            viewModel.loadKnowledgeItems()
                        }
                    }
                },
                onHashDismiss: {
                    if detectedWebURL != nil {
                        withAnimation(.easeOut(duration: 0.15)) {
                            detectedWebURL = nil
                        }
                    }
                    if viewModel.isShowingKnowledgePicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissKnowledgePicker()
                        }
                    }
                },
                onSlashTrigger: { query in
                    viewModel.promptSearchQuery = query
                    if !viewModel.isShowingPromptPicker {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.isShowingPromptPicker = true
                        }
                        viewModel.loadPrompts()
                    }
                },
                onSlashDismiss: {
                    if viewModel.isShowingPromptPicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissPromptPicker()
                        }
                    }
                },
                onDollarTrigger: { query in
                    viewModel.skillSearchQuery = query
                    if !viewModel.isShowingSkillPicker {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.isShowingSkillPicker = true
                        }
                        viewModel.loadSkills()
                    }
                },
                onDollarDismiss: {
                    if viewModel.isShowingSkillPicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissSkillPicker()
                        }
                    }
                },
                onFileAttachment: { showFilePicker = true },
                onPhotoAttachment: { showPhotosPicker = true },
                onCameraCapture: { showCameraPicker = true },
                onWebAttachment: { showWebURLAlert = true },
                // Voice call — gated by permissions.chat.call
                onVoiceInput: dependencies.authViewModel.chatPermissions.call ? { toggleVoiceInput() } : nil,
                apiClient: dependencies.apiClient,
                notesManager: dependencies.notesManager,
                conversationManager: dependencies.conversationManager,
                onFilesSelected: { selectedAttachments in
                    withAnimation { viewModel.attachments.append(contentsOf: selectedAttachments) }
                },
                skills: viewModel.availableSkills,
                selectedSkillIds: $viewModel.selectedSkillIds,
                isLoadingSkills: viewModel.isLoadingSkills,
                // Dictation — gated by permissions.chat.stt
                onDictationStart: dependencies.authViewModel.chatPermissions.stt ? { startDictation() } : nil,
                onDictationStop: { stopDictation() },
                onDictationCancel: { cancelDictation() },
                isDictating: isDictating,
                dictationService: dependencies.dictationService,
                onToolsSheetPresented: {
                    Task { await viewModel.loadTools() }
                    viewModel.loadSkills()
                },
                onOpenToolUserValves: { id, isFunction in
                    toolUserValvesKind = isFunction ? .function(id) : .tool(id)
                },
                messageQueue: vm.messageQueue,
                onQueueSendNow: { id in viewModel.sendQueuedMessageNow(id: id) },
                onQueueEdit: { id in viewModel.editQueuedMessage(id: id) },
                onQueueDelete: { id in viewModel.deleteQueuedMessage(id: id) }
            )
        }
        .background(theme.background)
        .animation(.easeOut(duration: 0.2), value: vm.isShowingKnowledgePicker)
        .animation(.easeOut(duration: 0.15), value: vm.selectedKnowledgeItems.count)
        .animation(.easeOut(duration: 0.15), value: vm.selectedReferenceChats.count)
        .animation(.easeOut(duration: 0.25), value: vm.tasks.count)
        .sheet(isPresented: $showReferenceChatPicker) {
            ReferenceChatPickerView(
                isPresented: $showReferenceChatPicker,
                conversationManager: dependencies.conversationManager
            ) { item in
                viewModel.selectReferenceChat(item)
            }
        }
        .sheet(isPresented: $showServerFilesPicker) {
            ServerFilesPickerSheet(
                isPresented: $showServerFilesPicker,
                apiClient: dependencies.apiClient
            ) { selectedAttachments in
                withAnimation { viewModel.attachments.append(contentsOf: selectedAttachments) }
            }
        }
        .sheet(isPresented: $showNotesPicker) {
            NotesPickerSheet(
                isPresented: $showNotesPicker,
                notesManager: dependencies.notesManager
            ) { note in
                viewModel.selectedNotes.append(note)
            }
        }
        .sheet(isPresented: $showKnowledgeFromMenuPicker) {
            KnowledgeMenuPickerSheet(
                isPresented: $showKnowledgeFromMenuPicker,
                selectedItems: $viewModel.selectedKnowledgeItems,
                apiClient: dependencies.apiClient
            )
        }
        // Sync mentionedModel → viewModel.mentionedModelId when user taps × on chip
        .onChange(of: mentionedModel) { _, newModel in
            viewModel.mentionedModelId = newModel?.id
        }
        } // end else (normal input mode)
    }

    private var photoPickerLabel: some View {
        VStack(spacing: Spacing.xs) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [theme.brandPrimary.opacity(0.2), theme.brandPrimary.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 36, height: 36)
                Image(systemName: "photo")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
            Text("Photo")
                .scaledFont(size: 12, weight: .medium)
                .fontWeight(.semibold)
                .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.45 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var placeholderText: String {
        if let model = viewModel.selectedModel {
            return String(localized: "Message \(model.shortName)")
        }
        return String(localized: "Message")
    }

    /// Checks whether a feature (web_search, image_generation, code_interpreter)
    /// should be visible in the tools sheet. A feature is available only when:
    /// 1. The server-level feature flag is enabled (from `/api/config`), AND
    /// 2. The selected model has that capability enabled (from `info.meta.capabilities`).
    ///
    /// If the admin unchecks a capability on the model, the toggle disappears
    /// from the app — the model simply can't use it.
    private func isFeatureAvailable(_ capabilityKey: String, serverEnabled: Bool?) -> Bool {
        // Server must have the feature enabled globally
        guard serverEnabled == true else { return false }
        // Model must have the capability enabled
        guard let model = viewModel.selectedModel,
              let caps = model.capabilities,
              let value = caps[capabilityKey] else {
            // If model has no capabilities dict at all, default to showing
            // (backward compat — older servers may not send capabilities)
            return serverEnabled == true
        }
        return ["1", "true"].contains(value.lowercased())
    }
    
    // MARK: - iPad Layout Helpers

    /// Maximum reading width for iPad. Content is centered in the available space.
    /// On iPhone, this is effectively unlimited (fills the screen).
    private var iPadMaxContentWidth: CGFloat { .infinity }

    /// Number of columns in the welcome prompt grid.
    private var promptColumnCount: Int {
        horizontalSizeClass == .regular ? 4 : 2
    }

    /// Number of prompt cards to show (4 cols needs 8, 2 cols needs 4).
    private var promptCardCount: Int {
        horizontalSizeClass == .regular ? 8 : 4
    }

    // MARK: - Message List Area

    private var messageListArea: some View {
        ZStack {
            scrollContent

            // Welcome screen — shown when no messages and not loading.
            if !viewModel.isLoadingConversation && viewModel.messages.isEmpty {
                if let folder = _folderWorkspace {
                    folderWelcomeView(folder: folder)
                        .transaction { $0.animation = nil }
                } else {
                    welcomeView
                        .transaction { $0.animation = nil }
                }
            }
        }
        // ── Opacity curtain ──────────────────────────────────────────────────
        // Keep the entire message area invisible until:
        //   • Messages are loaded AND positioned at the bottom (existing chats), OR
        //   • Load completes with no messages (new chat — show welcome instantly).
        // This eliminates the three-stage glitch: skeleton → messages appear at top
        // → visible scroll-to-bottom animation. The user sees only the final state.
        // isContentReady is set in handleViewTask() after the 150ms settle + scrollTo.
        // It resets to false automatically on each new ChatDetailView instance because
        // every conversation gets a unique .id() key in MainChatView / iPadMainChatView.
        //
        // New chats (initialConversationId == nil) bypass the curtain entirely —
        // there are no messages to position, so the welcome hero should render
        // visible from frame 1 with no blank-screen flash.
        .opacity((isContentReady || initialConversationId == nil) ? 1 : 0)
        .blur(radius: (isContentReady || initialConversationId == nil) ? 0 : 8)
        .animation(.easeOut(duration: 0.2), value: isContentReady)

        // FAB overlay — attached pill group: ↑ (top half) + ↓ (bottom half) when scrolled away from bottom.
        // Both appear together as one unit. ↑ is hidden when already at the very top.
        .overlay(alignment: .bottomTrailing) {
            scrollFABGroup
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isScrolledUp)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isAtTop)
        }
        .onAppear {
            // Snap instantly to bottom on chat open.
            _pumpRef.programmaticScrollUntil = Date().addingTimeInterval(0.4)
            scrollPosition.scrollTo(edge: .bottom)
        }
        // Auto-scroll: when a new message arrives, scroll to bottom.
        // The minHeight trick on the last conversation turn ensures that
        // scrolling to bottom naturally places the user's sent message
        // near the top of the viewport (ChatGPT-style).
        .onChange(of: viewModel.messages.count) { old, new in
            // ── Keep pagination window pinned to latest on new messages ──
            // When new messages arrive (user sent or assistant appended),
            // reset the window to show the latest messages so they're visible.
            // Skip bulk loads (old == 0) — those start paginated at 5.
            if new > old && old > 0 {
                // Pin window to the end (latest messages)
                windowEnd = nil
                // Grow the window to include the new messages, capped at maxWindowSize
                windowSize = min(max(windowSize, maxWindowSize), new)
            }

            guard new > old else { return }

            // ── Scroll to bottom when a new message is added ──
            // When streamingAutoScroll is off, skip the scroll if the newly-added
            // message is an assistant placeholder (i.e. streaming is about to start).
            // User-sent messages always scroll so the user sees what they sent.
            let lastMessage = viewModel.messages.last
            let isAssistantAddition = lastMessage?.role == .assistant && old > 0
            guard streamingAutoScroll || !isAssistantAddition else { return }

            // Don't yank the user back to the bottom for post-stream assistant
            // additions (follow-ups, adoptServerMessages, metadata refreshes) if
            // they have manually scrolled up. The next message send or streaming
            // start will re-engage auto-scroll via their own handlers.
            if isScrolledUp && isAssistantAddition && !viewModel.isStreaming { return }

            // Capture whether the user was scrolled up BEFORE resetting the flag.
            let wasScrolledUp = isScrolledUp
            isScrolledUp = false
            isUserDriving = false
            // Arm suppression window so the spring scroll's deceleration phase
            // never falsely sets isScrolledUp = true via the offset observer.
            _pumpRef.programmaticScrollUntil = Date().addingTimeInterval(0.5)

            if old == 0 {
                // Brief delay so the welcome view swap and initial layout settle.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    withAnimation(.easeOut(duration: 0.3)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            } else if keyboard.isVisible {
                // Keyboard dismiss changes the layout significantly — always scroll here.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            } else if wasScrolledUp {
                // User was away from the bottom — bring them back.
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } else if lastMessage?.role == .user {
                // Animate the sent message gliding up to the top. Arm suppression
                // first so the in-flight offset changes don't misfire the nav-bar /
                // breakout observer while the spring is running.
                _pumpRef.programmaticScrollUntil = Date().addingTimeInterval(0.7)
                Task { @MainActor in
                    // 80ms settle: gives the layout engine one pass to measure the
                    // new bubble + empty assistant placeholder before the spring fires.
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }
            // else: assistant addition already at bottom — .defaultScrollAnchor(.bottom) handles it.
        }
        // Streaming start/end: manage auto-scroll state.
        // When streaming STARTS with streamingAutoScroll enabled, re-engage and jump to bottom.
        // When streaming ENDS: the unified render path (IsolatedAssistantMessage) no longer
        // performs any structural view swap — AssistantMessageContent is always child-0 of
        // the same VStack, so there is no height-rounding artifact at stream end.
        // We simply restore the scroll position for users who were scrolled up.
        .onChange(of: viewModel.isStreaming) { oldStreaming, newStreaming in
            if newStreaming && streamingAutoScroll {
                // Stream started — re-engage auto-scroll.
                // Use an instant snap (no withAnimation) so there is no in-flight
                // Core Animation competing with the user's touch when they try to
                // scroll up during streaming. The sent-message spring fired ~100ms
                // earlier has already glided the question to the top; at this point
                // the response placeholder is just appearing so the scroll distance
                // is negligible and the instant jump is invisible.
                isScrolledUp = false
                isUserDriving = false
                _pumpRef.programmaticScrollUntil = Date().addingTimeInterval(0.4)
                scrollPosition.scrollTo(edge: .bottom)
            } else if !newStreaming && oldStreaming {
                // Stream just ended — do nothing.
                // .scrollPosition($scrollPosition, anchor: .bottom) handles layout reflow
                // compensation automatically, so no programmatic scroll is needed here
                // regardless of whether the user is scrolled up or at the bottom.
            }
        }
        // Resume auto-scroll: when the user taps the FAB (isScrolledUp → false)
        // during a stream, scroll back to the bottom immediately.
        .onChange(of: isScrolledUp) { oldValue, newValue in
            if oldValue == true && newValue == false && viewModel.isStreaming {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        // Regenerate: scroll to bottom only if the user was scrolled up.
        // If already at the bottom, .defaultScrollAnchor(.bottom) handles
        // content replacement silently — no explicit scroll needed.
        .onChange(of: viewModel.regenerateScrollToken) { _, _ in
            let wasScrolledUp = isScrolledUp
            isScrolledUp = false
            isUserDriving = false
            if wasScrolledUp {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000) // 60ms layout settle
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Skeleton placeholders removed — the opacity curtain (isContentReady)
                // already hides the area during loading, so there is no need to render
                // and then crossfade out a skeleton. Showing only messagesList here
                // eliminates the stutter caused by the VStack structural swap
                // (4 skeleton rows → N message rows) that happened even under opacity 0.
                messagesList
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: iPadMaxContentWidth)
            .frame(maxWidth: .infinity)
        }
        // defaultScrollAnchor(.bottom): tells SwiftUI to render the ScrollView
        // with its initial content offset at the bottom on first appearance.
        // This is a one-shot initial-position hint — it does NOT continuously
        // pin to the bottom during streaming (that's handled by the pump).
        // Combined with the opacity curtain, the user sees the chat already at
        // the bottom on reveal, with no programmatic scroll animation at all.
        .defaultScrollAnchor(.bottom)
        .scrollContentBackground(.hidden)
        .background(ScrollViewHorizontalLock())
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(editingMessageId != nil ? .never : (viewModel.isStreaming ? .immediately : .interactively))
        .scrollPosition($scrollPosition)
        .onScrollPhaseChange { _, newPhase in
            // isUserDriving: yield the streaming pump to BOTH finger touch AND inertia/deceleration.
            // This prevents the pump from fighting the user during a flick-scroll.
            //
            // IMPORTANT: Do NOT reset isUserDriving when the new phase is .animating.
            // When the streaming pump fires scrollPosition.scrollTo(edge: .bottom), it
            // transitions the scroll phase to .animating — which would immediately reset
            // isUserDriving = false, unblocking the pump again on the very next frame.
            // That creates a frame-by-frame fight: finger scrolls up one frame, pump snaps
            // back the next, finger moves again, repeat — producing choppy "stuck" scrolling.
            // By treating .animating as a no-op here, a user-initiated isUserDriving = true
            // survives across pump-triggered .animating transitions and stays true until
            // the scroll genuinely reaches .idle (no motion) or the user lifts their finger
            // and inertia finishes (.decelerating → .idle).
            switch newPhase {
            case .interacting, .decelerating:
                isUserDriving = true
            case .idle:
                isUserDriving = false
            case .animating:
                // A programmatic scrollTo() just fired (either the streaming pump or a
                // FAB tap). Do NOT change isUserDriving — if the user was driving before
                // this programmatic scroll, keep the pump suppressed.
                break
            @unknown default:
                isUserDriving = false
            }
            // isDecelerating: true while iOS is coasting after the user lifts their finger.
            // The streaming pump must NOT fire during deceleration — each programmatic
            // scrollTo() cancels the OS momentum curve, killing the natural coast-to-stop.
            // Only set true for .decelerating; cleared on .idle (motion stopped) and
            // .interacting (new touch began, finger overrides inertia anyway).
            // .animating is left unchanged — a programmatic scroll during ongoing
            // deceleration should not reset the flag (very rare race, defensive).
            switch newPhase {
            case .decelerating:
                isDecelerating = true
                // During streaming: the moment the user lifts their finger and iOS starts
                // coasting, permanently lock out the pump by setting isScrolledUp = true.
                // Without this, isDecelerating blocks the pump DURING the coast, but the
                // moment deceleration finishes (.idle → isDecelerating = false), the pump
                // immediately resumes and snaps content back to the streaming bottom —
                // exactly the "flick then snap back" behaviour shown in the video.
                // Setting isScrolledUp here keeps the pump suppressed after deceleration
                // until the user explicitly taps the ↓ FAB to re-engage auto-scroll.
                if viewModel.isStreaming && !isScrolledUp {
                    isScrolledUp = true
                }
            case .idle, .interacting:
                isDecelerating = false
            case .animating:
                break
            @unknown default:
                isDecelerating = false
            }
            // isFingerDriving: ONLY set while the finger is physically on screen (.interacting).
            // The nav-bar and isScrolledUp upward-delta logic use this flag, NOT isUserDriving,
            // so that inertia deceleration + bottom-bounce recovery never trigger jittery
            // nav-bar hide/show or false isScrolledUp trips at the bottom edge.
            isFingerDriving = (newPhase == .interacting)
        }
        // ── Direct finger break-out ──────────────────────────────────────────
        // When the glide animation is running the scroll phase is `.animating`,
        // not `.interacting`, so isUserDriving never latches and the upward-drag
        // breakout path in the offset handler never fires.  A simultaneous
        // DragGesture side-steps the phase entirely: the moment the finger
        // moves ≥4pt we set isUserDriving = true (stops the next glide tick)
        // and, on an upward drag (positive height = moving down on screen =
        // scrolling up through content), we set isScrolledUp = true directly.
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if !isUserDriving {
                        isUserDriving = true
                        // Lift the programmatic suppression window so the offset
                        // handler immediately treats this as a genuine user scroll.
                        _pumpRef.programmaticScrollUntil = .distantPast
                    }
                    // Positive height = finger moved down the screen = scrolling up.
                    if value.translation.height > 8 && !isScrolledUp {
                        isScrolledUp = true
                    }
                }
        )
        // ── UNIFIED SCROLL GEOMETRY CALLBACK ─────────────────────────────────────────
        //
        // CRITICAL: This replaces the previous two separate callbacks (one for CGPoint
        // offset, one for CGSize content/container). The old design had a race condition:
        // the offset callback used @State viewState_contentHeight / viewState_containerHeight
        // which could be 1-2 frames stale relative to the current offset. This caused
        // isBouncing to compute incorrectly during rubber-band overscroll — it would
        // return false during a real bounce, letting nav-bar and FAB logic fire at 120Hz
        // on oscillating offsets, producing the violent jitter at the bottom edge.
        //
        // The fix: capture contentSize and containerSize in the SAME geometry snapshot
        // as contentOffset, so all three values are atomically consistent. isBouncing is
        // computed from the live snapshot, never from stale @State.
        //
        // Additionally, nav-bar hide/show and the upward-delta isScrolledUp trip now use
        // `isFingerDriving` (finger physically on screen) instead of `isUserDriving`
        // (finger OR inertia). This prevents bottom-bounce deceleration — which is
        // .decelerating phase, NOT .interacting — from triggering nav-bar jitter.
        .onScrollGeometryChange(for: ScrollSnapshot.self) { geo in
            ScrollSnapshot(
                offset: geo.contentOffset,
                contentSize: geo.contentSize,
                containerSize: geo.containerSize
            )
        } action: { oldSnap, snap in
            let newOffset = snap.offset
            let oldOffset = oldSnap.offset
            let contentHeight = snap.contentSize.height
            let containerHeight = snap.containerSize.height

            // ── Update @State size caches (used by messagesList minHeight, FAB reference) ──
            // These writes cause a SwiftUI re-eval, but only when the height actually changes
            // (the >1pt dead-band eliminates sub-pixel noise). They are still needed because
            // messagesList.frame(minHeight:) and the FAB reference height use @State.
            if abs(contentHeight - viewState_contentHeight) > 1 {
                viewState_contentHeight = contentHeight
            }
            if abs(containerHeight - viewState_containerHeight) > 1 {
                viewState_containerHeight = containerHeight
            }

            // Track raw offset for the ↑ FAB "find current question" logic.
            // Written to _pumpRef (not @State) so this 120Hz write never causes a body re-eval.
            _pumpRef.currentScrollOffsetY = newOffset.y

            // ── isBouncing: computed from the LIVE snapshot — never stale @State ──
            // maxScrollOffset is the furthest the content can scroll before rubber-banding.
            // isBouncing is true when the offset is past either edge (top overscroll < 0,
            // bottom overscroll > maxScrollOffset). A 1pt tolerance prevents floating-point
            // at-exact-bottom from being treated as a bounce.
            let maxScrollOffset = max(0, contentHeight - containerHeight)
            let isBouncing = newOffset.y < 0 || (maxScrollOffset > 0 && newOffset.y > maxScrollOffset + 1)

            let distanceFromBottom = max(0, contentHeight - newOffset.y - containerHeight)

            // Arm the programmatic-scroll suppression flag once so all logic below shares it.
            let programmaticActive = Date() < _pumpRef.programmaticScrollUntil

            // ── Near-bottom reset: re-engage auto-scroll when finger scrolls back down ──
            // Threshold tightened to 40pt (was 80pt) so this only fires when clearly at
            // the bottom and NOT during bounce recovery. The isBouncing guard is the primary
            // protection; 40pt provides an additional safety margin.
            if distanceFromBottom <= 40 && !isBouncing && !programmaticActive && !viewModel.isStreaming {
                if isScrolledUp {
                    isScrolledUp = false
                    userMessageJumpIndex = nil
                }
            } else if isUserDriving && !isBouncing {
                // User's finger (or inertia) is actively driving the scroll view —
                // the ONLY condition under which auto-scroll is allowed to disengage.
                // Require a small delta (>2pt) so sub-pixel layout reflow/settling noise
                // never falsely trips the breakout.
                let upwardDelta = oldOffset.y - newOffset.y
                if upwardDelta > 2 && !isScrolledUp { isScrolledUp = true }
            }
            // All other cases (layout reflows, programmatic scrolls, WKWebView resizes)
            // emit .animating/.idle → isUserDriving is false → no state change.

            // ── Nav bar direction-based hide/show ──
            // Uses isFingerDriving (NOT isUserDriving) so that:
            //   • Inertia deceleration and bounce recovery (.decelerating phase) NEVER
            //     trigger nav-bar changes — that was the primary source of bottom-edge jitter.
            //   • Only actual finger-contact scrolls (.interacting phase) hide/show the bar.
            //
            // Nav-bar baseline is only updated when NOT bouncing.
            // During a bottom overscroll the offset oscillates around maxScrollOffset —
            // freezing the baseline during bounce keeps the delta near zero, so the
            // nav bar stays completely still during overscroll recovery.
            if !isBouncing {
                let navSuppressed = Date() < _pumpRef.programmaticScrollUntil
                let navDelta = newOffset.y - _pumpRef.lastNavBarOffsetY
                _pumpRef.lastNavBarOffsetY = newOffset.y

                // Only respond to genuine finger-contact drags, not inertia or streaming pump.
                if !navSuppressed && isFingerDriving && !viewModel.isStreaming {
                    if distanceFromBottom > 80 {
                        if navDelta > 1 && !navBarHidden {
                            withAnimation(.easeInOut(duration: 0.2)) { navBarHidden = true }
                        } else if navDelta < -1 && navBarHidden {
                            withAnimation(.easeInOut(duration: 0.2)) { navBarHidden = false }
                        }
                    } else {
                        // Near/at bottom with finger scrolling upward — show bar
                        if navDelta < -1 && navBarHidden {
                            withAnimation(.easeInOut(duration: 0.2)) { navBarHidden = false }
                        }
                    }
                }
            }

            // ── At-top detection for ↑ FAB ──
            let atTop = newOffset.y < 50
            if atTop != isAtTop { isAtTop = atTop }

            // ── Track topmost visible message for layout-stable scroll restore ──
            if isScrolledUp {
                let allMsgs = viewModel.messages
                if !allMsgs.isEmpty && contentHeight > 0 {
                    let fraction = max(0, min(1, newOffset.y / contentHeight))
                    let estimatedIdx = min(Int(fraction * CGFloat(allMsgs.count)), allMsgs.count - 1)
                    _pumpRef.topmostVisibleMessageId = allMsgs[estimatedIdx].id
                }
            }

            // ── Sliding window: preload older messages when approaching the top ──
            let total = viewModel.messages.count
            let effectiveEnd = windowEnd ?? total
            let effectiveStart = max(0, effectiveEnd - windowSize)

            if newOffset.y < 600,
               !isLoadingMoreMessages,
               !programmaticActive,
               effectiveStart > 0,
               !viewModel.isLoadingConversation {
                isLoadingMoreMessages = true
                let capturedTotal = total
                let capturedEffectiveStart = effectiveStart

                Task { @MainActor in
                    let slideBy = min(5, capturedEffectiveStart)
                    if windowEnd == nil { windowEnd = capturedTotal }
                    windowSize = min(windowSize + slideBy, maxWindowSize)
                    let newStart = max(0, capturedEffectiveStart - slideBy)
                    windowEnd = min(newStart + windowSize, capturedTotal)
                    isLoadingMoreMessages = false
                }
            }

            // ── Sliding window: load newer messages when near the bottom ──
            if let wEnd = windowEnd, wEnd < total,
               distanceFromBottom < 200,
               !isLoadingMoreMessages,
               !programmaticActive,
               !viewModel.isLoadingConversation {
                isLoadingMoreMessages = true
                let anchorId = viewModel.messages[min(wEnd - 1, total - 1)].id
                let slideBy = min(5, total - wEnd)
                windowEnd = wEnd + slideBy
                if windowEnd! >= total { windowEnd = nil }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    scrollPosition.scrollTo(id: anchorId, anchor: .bottom)
                    isLoadingMoreMessages = false
                }
            }

            // ── Streaming auto-follow pump ──
            // Rate-limited instant snap — keeps viewport glued to the live tail during streaming.
            // Guards: not user-driving, not manually scrolled up, not paginating.
            let distFromBottom = max(0, contentHeight - containerHeight - newOffset.y)
            let driftedFar = distFromBottom > 4
            if driftedFar && viewModel.isStreaming && !isUserDriving && !isDecelerating && !isScrolledUp && !isLoadingMoreMessages {
                let now = Date()
                guard now.timeIntervalSince(_pumpRef.lastScrollTime) >= 0.016 else { return }
                _pumpRef.lastScrollTime = now
                _pumpRef.programmaticScrollUntil = now.addingTimeInterval(0.06)
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    // MARK: - Scroll FAB Pill Group

    @ViewBuilder
    private var scrollFABGroup: some View {
        if isScrolledUp && !viewModel.messages.isEmpty && !viewModel.isLoadingConversation {
            VStack(spacing: 0) {
                // ↑ FAB — jumps to the previous user question on each tap
                if !isAtTop {
                    Button {
                        // Build sorted list of user message indices from the full message list
                        let allMessages = viewModel.messages
                        let userIndices = allMessages.indices.filter { allMessages[$0].role == .user }
                        guard !userIndices.isEmpty else { return }

                        // Determine the target: one step before the last jump position,
                        // or the last user message if we haven't jumped yet.
                        let targetIdx: Int
                        if let currentJump = userMessageJumpIndex {
                            // Subsequent taps: find the user message just before the current jump position
                            if let pos = userIndices.lastIndex(where: { $0 < currentJump }) {
                                targetIdx = userIndices[pos]
                            } else {
                                // Already at or before the first user message — stay there
                                targetIdx = userIndices.first!
                            }
                        } else {
                            // First tap: use topmostVisibleMessageId (updated continuously by
                            // the scroll-offset handler) as the reference — version-agnostic
                            // and accurate regardless of window size or message branching.
                            let refIdx: Int = {
                                if let topId = _pumpRef.topmostVisibleMessageId,
                                   let idx = allMessages.firstIndex(where: { $0.id == topId }) {
                                    return idx
                                }
                                // Fallback: linear fraction estimate
                                guard viewState_contentHeight > 0 else { return allMessages.count - 1 }
                                let fraction = _pumpRef.currentScrollOffsetY / viewState_contentHeight
                                return Int(fraction * CGFloat(allMessages.count))
                            }()
                            // Find the last user message at or before the reference index.
                            // This is the "current context" question — the one whose answer
                            // the user is likely reading.
                            if let pos = userIndices.lastIndex(where: { $0 <= refIdx }) {
                                targetIdx = userIndices[pos]
                            } else {
                                // Reference index is before any user message — jump to first
                                targetIdx = userIndices.first!
                            }
                        }
                        userMessageJumpIndex = targetIdx

                        // Expand the window to include this message if needed.
                        // IMPORTANT: arm programmaticScrollUntil BEFORE mutating windowEnd/windowSize.
                        // The window mutation drops the newest messages from the rendered list, which
                        // causes a momentary content-height drop. Without suppression the geometry
                        // callback interprets that as "scrolled to bottom" and fires isScrolledUp=false,
                        // hiding the FABs and nulling userMessageJumpIndex. 0.8s covers the 30ms defer
                        // plus the full 0.45s spring settle plus layout stabilisation margin.
                        let total = allMessages.count
                        let currentEffectiveStart = max(0, (windowEnd ?? total) - windowSize)
                        let needsExpand = targetIdx < currentEffectiveStart
                        // Suppress the geometry handler for all programmatic jumps (expand or not) so
                        // the spring animation offset never falsely trips the near-bottom reset.
                        _pumpRef.programmaticScrollUntil = Date().addingTimeInterval(0.8)
                        if needsExpand {
                            windowEnd = min(targetIdx + windowSize, total)
                            if windowEnd! > total { windowEnd = nil }
                            windowSize = min(maxWindowSize, total)
                            // Defer scroll by one tick so newly-mounted rows are in the
                            // view hierarchy before scrollTo(id:) fires — otherwise it
                            // silently no-ops on IDs not yet rendered.
                            let targetId = allMessages[targetIdx].id
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                    scrollPosition.scrollTo(id: targetId, anchor: UnitPoint(x: 0.5, y: 0))
                                }
                            }
                        } else {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                scrollPosition.scrollTo(id: allMessages[targetIdx].id, anchor: UnitPoint(x: 0.5, y: 0))
                            }
                        }
                        Haptics.play(.light)
                    } label: {
                        ZStack {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 38, height: 38)
                            Image(systemName: "chevron.up")
                                .scaledFont(size: 13, weight: .bold)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Jump to previous question")

                    // Hairline divider between the two halves
                    Rectangle()
                        .fill(theme.cardBorder.opacity(0.4))
                        .frame(width: 38, height: 0.5)
                }

                // ↓ FAB — always shown when isScrolledUp
                Button {
                    isScrolledUp = false
                    userMessageJumpIndex = nil
                    windowEnd = nil
                    // Do NOT expand windowSize here — mounting the full maxWindowSize
                    // worth of Litext/MarkdownView rows synchronously in one frame
                    // causes a 2-second hang. Keep the window at its current size;
                    // the sliding-window pagination handler will grow it naturally
                    // if the user scrolls up after returning to the bottom.
                    if viewModel.isStreaming {
                        // During streaming, DON'T use a spring animation.
                        // A 0.45s spring fights the per-token linear pump (which fires
                        // many times per second) — they cancel each other out and the
                        // viewport barely moves. Instead, snap instantly to the bottom
                        // with a tiny suppression window (0.1s), then hand off to the
                        // pump which will keep the viewport pinned to the live tail.
                        _pumpRef.programmaticScrollUntil = Date().addingTimeInterval(0.1)
                        scrollPosition.scrollTo(edge: .bottom)
                    } else {
                        _pumpRef.programmaticScrollUntil = Date().addingTimeInterval(0.6)
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                        // Settle correction: heavy bottom messages may not be fully measured
                        // when the spring fires, so the spring targets a position that's short
                        // of the true bottom. Re-snap to the real bottom after heights settle.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000) // 400ms settle
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                    }
                    Haptics.play(.light)
                } label: {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 38, height: 38)
                        Image(systemName: "chevron.down")
                            .scaledFont(size: 13, weight: .bold)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Scroll to bottom")
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(.trailing, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.7).combined(with: .opacity),
                    removal: .scale(scale: 0.7).combined(with: .opacity)
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7))
            )
        }
    }

    // MARK: - Loading Placeholders

    private var loadingPlaceholders: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                SkeletonChatMessage(isUser: i % 2 == 1, lineCount: i == 0 ? 2 : i == 2 ? 3 : 2)
                    .padding(.vertical, 4)
            }
        }
        .padding(.top, Spacing.lg)
    }

    // MARK: - Messages List

    /// Splits messages into two groups around the last conversation turn.
    ///
    /// The **last turn** is defined as the last user message plus any
    /// assistant/system messages that follow it. This group is wrapped in a
    /// `VStack` with `minHeight: viewportHeight, alignment: .top` — the
    /// ChatGPT-style trick that makes scroll-to-bottom place the user's
    /// sent message near the **top** of the viewport, with the AI response
    /// streaming in below it.
    ///
    /// All earlier messages render at their natural height.
    private var messagesList: some View {
        let allMessages = viewModel.messages
        let total = allMessages.count

        // ── Sliding window: compute the visible slice ──
        let effectiveEnd = windowEnd ?? total
        let effectiveStart = max(0, effectiveEnd - windowSize)
        let clampedEnd = min(effectiveEnd, total)
        let messages = Array(allMessages[effectiveStart..<clampedEnd])
        let hasMoreAbove = effectiveStart > 0
        let hasMoreBelow = clampedEnd < total

        // Bug 10: indexMap was rebuilt (O(n) allocation) on every messagesList evaluation.
        // Cache it as a @State dictionary, only rebuilt when the message count changes
        // (messages are append-only so indices are stable until a deletion).
        // Avoid mutating @State directly during view update — compute locally and
        // schedule the cache update for after the current render pass.
        let indexMap: [String: Int]
        if cachedIndexMap.count == total && !cachedIndexMap.isEmpty {
            indexMap = cachedIndexMap
        } else {
            let freshMap = Dictionary(allMessages.enumerated().map { ($1.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
            indexMap = freshMap
            Task { @MainActor in cachedIndexMap = freshMap }
        }

        // Split point: index of the last user message *within the visible slice*.
        // Everything from here to the end is the "last turn".
        // If there are no user messages, splitAt == count → no split, all normal.
        let lastUserIdx = messages.lastIndex(where: { $0.role == .user })
        let splitAt = lastUserIdx ?? messages.count

        // Only apply minHeight trick when the window includes the actual last message
        let windowIncludesEnd = (windowEnd == nil || clampedEnd >= total)

        return Group {
            // ── "Loading more" indicator at the top ──
            if hasMoreAbove {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .id("pagination-spinner-top")
            }

            // ── Messages before the last turn (natural height) ──
            ForEach(Array(messages.prefix(splitAt))) { message in
                let index = indexMap[message.id] ?? 0
                messageRow(message: message, index: index)
                    .id(message.id)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.2), value: messages.prefix(splitAt).map(\.id))

            // ── Last turn (user msg + assistant reply) with minHeight ──
            if splitAt < messages.count {
                VStack(spacing: 0) {
                    ForEach(Array(messages.suffix(from: splitAt))) { message in
                        let index = indexMap[message.id] ?? 0
                        messageRow(message: message, index: index)
                            .id(message.id)
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: windowIncludesEnd ? max(viewState_containerHeight, 0) : nil,
                       alignment: .top)
            }

            // ── "Loading newer" indicator at the bottom ──
            if hasMoreBelow {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .id("pagination-spinner-bottom")
            }
        }
    }

    // MARK: - Message Row

    // MARK: - Background Sub-agent Completion Banner

    @ViewBuilder
    private func subagentCompletionBanner(message: ChatMessage) -> some View {
        let delegationId = message.subagentDelegationId ?? ""
        let shortId = delegationId.hasPrefix("deleg_") ? String(delegationId.dropFirst(6).prefix(8)) : String(delegationId.prefix(8))

        Button {
            subagentDetailMessage = message
            Haptics.play(.light)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Background sub-agent finished")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                if !shortId.isEmpty {
                    Text(shortId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func messageRow(message: ChatMessage, index: Int) -> some View {
        // Internal sub-agent completion messages get a compact banner, not a full bubble.
        // The isInternalMessage flag is set from meta.internal on the server node, but as a
        // safety net we also check the content prefix — OpenWebUI always injects these with
        // "[ASYNC SUBAGENT COMPLETE" so we can identify them even if meta is missing/absent.
        let isSubagentCompletion = (message.isInternalMessage || message.content.hasPrefix("[ASYNC SUBAGENT COMPLETE"))
            && message.role == .user
        if isSubagentCompletion {
            subagentCompletionBanner(message: message)
        } else {

        let isLastAssistant = message.role == .assistant && index == viewModel.messages.count - 1

        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {

            // ── Assistant header (avatar + model name) ──
            if message.role == .assistant {
                assistantHeader(for: message)
            }

            // ── Streaming status indicators ──
            if message.role == .assistant {
                // Bug 13: compute isActiveStore once here so each IsolatedStreamingStatus
                // instance receives it as a plain Bool. Non-active instances never read
                // any streamingStore properties in their body, making them completely
                // inert during token delivery.
                let isActiveStatus = viewModel.streamingStore.streamingMessageId == message.id
                    && viewModel.streamingStore.isActive
                IsolatedStreamingStatus(
                    streamingStore: viewModel.streamingStore,
                    message: message,
                    isActiveStore: isActiveStatus
                )
            }

            // ── User images (rendered ABOVE the text bubble, outside it) ──
            if message.role == .user {
                let userVIdxRow = activeUserVersionIndex[message.id] ?? -1
                let userImgFiles: [ChatMessageFile] = {
                    if userVIdxRow >= 0 && userVIdxRow < message.versions.count {
                        return message.versions[userVIdxRow].files.filter { isImageFile($0) }
                    }
                    return message.files.filter { isImageFile($0) }
                }()
                if !userImgFiles.isEmpty {
                    userImageMosaicGrid(imageFiles: userImgFiles)
                }
            }

            // ── Message bubble / content ──
            messageBubble(for: message, isLastAssistant: isLastAssistant)

            // ── Tool-generated images ──
            // AnimatedPresence smoothly expands the height when files become available
            // (i.e. when streaming completes and displayFiles becomes non-empty).
            let vIdxFiles = activeVersionIndex[message.id] ?? -1
            let displayFiles: [ChatMessageFile] = {
                if vIdxFiles >= 0 && vIdxFiles < message.versions.count {
                    return message.versions[vIdxFiles].files
                }
                return message.files
            }()
            AnimatedPresence(visible: message.role == .assistant && !message.isStreaming && !displayFiles.isEmpty) {
                if message.role == .assistant && !message.isStreaming && !displayFiles.isEmpty {
                    messageFilesView(files: displayFiles)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.xs)
                }
            }

            // ── Sources bar ──
            let vIdxSrc = activeVersionIndex[message.id] ?? -1
            let displaySources: [ChatSourceReference] = {
                if vIdxSrc >= 0 && vIdxSrc < message.versions.count {
                    return message.versions[vIdxSrc].sources
                }
                return message.sources
            }()
            AnimatedPresence(visible: message.role == .assistant && !message.isStreaming && !displaySources.isEmpty) {
                if message.role == .assistant && !message.isStreaming && !displaySources.isEmpty {
                    sourcesBar(sources: displaySources, messageId: message.id)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.xs)
                }
            }

            // ── Inline error ──
            AnimatedPresence(visible: message.error != nil) {
                if let error = message.error {
                    messageErrorView(error.content ?? String(localized: "An error occurred"))
                        .padding(.horizontal, Spacing.screenPadding)
                }
            }

            // ── Assistant action bar (appears when streaming ends) ──
            AnimatedPresence(visible: message.role == .assistant && !message.isStreaming) {
                if message.role == .assistant && !message.isStreaming {
                    assistantActionBar(for: message)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.xs)
                        // Popover must live at the row level (not inside the ForEach action bar)
                        // so that every message gets its own independent popover anchor.
                        // Attaching it inside assistantActionBar (which is called inside ForEach)
                        // causes SwiftUI to only register the last one.
                        .popover(isPresented: Binding(
                            get: { usagePopoverMessageId == message.id },
                            set: { if !$0 { usagePopoverMessageId = nil } }
                        ), arrowEdge: .bottom) {
                            let vIdx = activeVersionIndex[message.id] ?? -1
                            let popoverUsage: [String: Any] = {
                                if vIdx >= 0 && vIdx < message.versions.count {
                                    return message.versions[vIdx].usage ?? [:]
                                }
                                return message.usage ?? [:]
                            }()
                            UsageInfoPopover(usage: popoverUsage)
                                .themed()
                                .presentationCompactAdaptation(.popover)
                        }
                }
            }

            // ── User message version arrows (always visible when edit history exists) ──
            if message.role == .user && !message.versions.isEmpty && !viewModel.isStreaming {
                userVersionSwitcher(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, 2)
            }

            // ── Follow-up suggestions (last assistant message only) ──
            let vIdxFU = activeVersionIndex[message.id] ?? -1
            let displayFollowUps: [String] = {
                if vIdxFU >= 0 && vIdxFU < message.versions.count {
                    return message.versions[vIdxFU].followUps
                }
                return message.followUps
            }()
            AnimatedPresence(visible: isLastAssistant && !message.isStreaming && !displayFollowUps.isEmpty) {
                if isLastAssistant && !message.isStreaming && !displayFollowUps.isEmpty {
                    followUpSuggestions(displayFollowUps)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.sm)
                }
            }
        }
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(message.role == .user ? "You" : "Assistant"): \(message.content.prefix(200))"))
        } // end else (not internal message)
    }

    // MARK: - Assistant Header

    private func resolveModel(for message: ChatMessage) -> AIModel? {
        if let mid = message.model,
           let model = viewModel.availableModels.first(where: { $0.id == mid }) {
            return model
        }
        return viewModel.selectedModel
    }

    private func assistantHeader(for message: ChatMessage) -> some View {
        let model = resolveModel(for: message)
        return HStack(spacing: Spacing.sm) {
            if let m = model {
                ModelAvatar(size: 22, imageURL: viewModel.resolvedImageURL(for: m),
                            label: m.shortName, authToken: viewModel.serverAuthToken)
            } else {
                ModelAvatar(size: 22, label: message.model)
            }
            Text(model?.shortName ?? message.model ?? String(localized: "Assistant"))
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
        .padding(.bottom, 4)
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private func messageBubble(for message: ChatMessage, isLastAssistant: Bool) -> some View {
        ChatMessageBubble(
            role: message.role,
            showTimestamp: activeActionMessageId == message.id,
            timestamp: message.timestamp
        ) {
            messageContent(for: message)
        }
        // Only apply tap gesture to user bubbles — assistant content contains
        // interactive elements (links, text selection) that onTapGesture would block.
        // Assistant action bar is always visible so no tap-reveal is needed.
        .if(message.role == .user) { view in
            view.simultaneousGesture(TapGesture().onEnded {
                withAnimation(MicroAnimation.snappy) {
                    activeActionMessageId = activeActionMessageId == message.id ? nil : message.id
                }
                Haptics.play(.light)
            })
        }
        .if(message.role != .assistant) { view in
            view.contextMenu { messageContextMenu(for: message) }
        }
    }

    @ViewBuilder
    private func messageContextMenu(for message: ChatMessage) -> some View {
        Button { copyMessage(message) } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if message.role == .user && !viewModel.isStreaming {
            Button { beginInlineEdit(message: message) } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        if message.role == .assistant && !viewModel.isStreaming {
            Button { Task { await viewModel.regenerateResponse(messageId: message.id) } } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        if !viewModel.isStreaming {
            Button(role: .destructive) {
                let userVIdx = activeUserVersionIndex[message.id] ?? -1
                Task { await viewModel.deleteMessage(id: message.id, activeVersionIndex: message.role == .user ? userVIdx : nil) }
                // Clean up local navigation state after deletion
                if message.role == .user {
                    if !message.versions.isEmpty {
                        if userVIdx < 0 {
                            // Deleted main — reset to main (last version promoted)
                            activeUserVersionIndex.removeValue(forKey: message.id)
                        } else if message.versions.count <= 1 {
                            // Deleted last version — back to main
                            activeUserVersionIndex.removeValue(forKey: message.id)
                            // Clear AI override since we're back to main
                            if let userIdx = viewModel.messages.firstIndex(where: { $0.id == message.id }),
                               userIdx + 1 < viewModel.messages.count,
                               viewModel.messages[userIdx + 1].role == .assistant {
                                assistantContentOverride.removeValue(forKey: viewModel.messages[userIdx + 1].id)
                            }
                        } else if userVIdx >= message.versions.count - 1 {
                            activeUserVersionIndex[message.id] = max(0, userVIdx - 1)
                        }
                    }
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Message Content

    @ViewBuilder
    private func messageContent(for message: ChatMessage) -> some View {
        if message.role == .user {
            // Resolve which user version to display
            let userVIdx = activeUserVersionIndex[message.id] ?? -1
            let displayContent: String = {
                if userVIdx >= 0 && userVIdx < message.versions.count {
                    return message.versions[userVIdx].content
                }
                return message.content
            }()
            let displayFiles: [ChatMessageFile] = {
                if userVIdx >= 0 && userVIdx < message.versions.count {
                    return message.versions[userVIdx].files
                }
                return message.files
            }()

            // Non-image file cards + text content
            // Images are rendered ABOVE the bubble in messageRow — not inside it.
            let nonImageFiles = displayFiles.filter { !isImageFile($0) && $0.type != "collection" && $0.type != "folder" }
            let hasText = !displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if hasText || !nonImageFiles.isEmpty {
                VStack(alignment: .trailing, spacing: Spacing.sm) {
                    // Non-image file cards inside the bubble
                    if !nonImageFiles.isEmpty {
                        ForEach(Array(nonImageFiles.enumerated()), id: \.offset) { _, file in
                            fileAttachmentCard(file: file)
                        }
                    }

                    // Text content
                    if hasText {
                        UserMessageContentView(content: displayContent)
                            .lineSpacing(2)
                    }
                }
            }
        } else {
            // ── STREAMING ISOLATION ──
            // All streaming store reads (streamingContent, streamingSources,
            // isActive, streamingMessageId) are moved into IsolatedAssistantMessage
            // — a separate struct whose body is the only thing that re-evaluates
            // on every token. ChatDetailView.body never touches these properties,
            // so it stays completely inert during streaming.
            IsolatedAssistantMessage(
                streamingStore: viewModel.streamingStore,
                message: message,
                activeVersionIndex: activeVersionIndex[message.id] ?? -1,
                contentOverride: assistantContentOverride[message.id],
                serverBaseURL: viewModel.serverBaseURL,
                authToken: viewModel.serverAuthToken,
                apiClient: dependencies.apiClient
            )
        }
    }



    // MARK: - iMessage-Style Edit Input Bar

    /// Replaces the normal input bar when editing a message.
    /// Lives in the safeAreaInset bottom slot — exactly where the normal
    /// ChatInputField sits — so iOS keyboard avoidance just works.
    private var editInputBar: some View {
        VStack(spacing: 0) {
            // ── Attachment strip — shown when the message had files ───────────
            if !editingMessageFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(editingMessageFiles.enumerated()), id: \.offset) { idx, file in
                            editFileChip(file: file) {
                                var updated = editingMessageFiles
                                updated.remove(at: idx)
                                editingMessageFiles = updated
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)
                }
                .background(theme.surfaceContainer.opacity(0.5))
            }

            HStack(spacing: 10) {
                // Cancel button
                Button {
                    cancelInlineEdit()
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme.surfaceContainer)
                            .frame(width: 34, height: 34)
                        Image(systemName: "xmark")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel edit")

                // Text field — fills remaining space, grows vertically up to 6 lines
                TextField("Edit message…", text: $editingMessageText, axis: .vertical)
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textPrimary)
                    .tint(theme.brandPrimary)
                    .lineLimit(1...6)
                    .focused($isEditFieldFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        if !editingMessageText.contains("\n") { submitInlineEdit() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                // Send / confirm button
                Button {
                    submitInlineEdit()
                } label: {
                    ZStack {
                        Circle()
                            .fill(editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  ? theme.textTertiary.opacity(0.3)
                                  : theme.brandPrimary)
                            .frame(width: 34, height: 34)
                        Image(systemName: "arrow.up")
                            .scaledFont(size: 14, weight: .bold)
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Save and resend")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(theme.background)
        }
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
        .onAppear {
            isEditFieldFocused = true
        }
    }

    /// A chip shown in the edit attachment strip for one file.
    /// Shows an image thumbnail (if image) or a file-name pill (otherwise),
    /// with a × button to remove the attachment from the edit.
    @ViewBuilder
    private func editFileChip(file: ChatMessageFile, onRemove: @escaping () -> Void) -> some View {
        let isImage = isImageFile(file)
        ZStack(alignment: .topTrailing) {
            if isImage, let fileId = file.url, !fileId.isEmpty {
                AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: fileIconName(for: (file.name ?? "").components(separatedBy: ".").last?.lowercased() ?? ""))
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                    Text(file.name ?? "File")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 100)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
                )
            }

            // Remove button
            Button(action: onRemove) {
                ZStack {
                    Circle()
                        .fill(theme.textPrimary)
                        .frame(width: 18, height: 18)
                    Image(systemName: "xmark")
                        .scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(theme.background)
                }
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    private func beginInlineEdit(message: ChatMessage) {
        editingMessageId = message.id
        editingMessageText = message.content
        editingMessageFiles = message.files
        // Focus immediately — no delay needed since we're not fighting scroll layout
        isEditFieldFocused = true
        Haptics.play(.light)
    }

    private func cancelInlineEdit() {
        isEditFieldFocused = false
        withAnimation(.easeInOut(duration: 0.18)) {
            editingMessageId = nil
            editingMessageText = ""
            editingMessageFiles = []
        }
    }

    private func submitInlineEdit() {
        guard let id = editingMessageId else { return }
        let trimmed = editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isEditFieldFocused = false
        let filesToSend = editingMessageFiles
        withAnimation(.easeInOut(duration: 0.18)) {
            editingMessageId = nil
        }
        editingMessageText = ""
        editingMessageFiles = []
        Task { await viewModel.editMessage(id: id, newContent: trimmed, files: filesToSend) }
        Haptics.play(.medium)
    }

    // MARK: - Welcome View

    private struct SuggestedPrompt: Identifiable, Hashable {
        /// Stable, content-derived ID so SwiftUI never treats an identical card as a new view.
        /// Using a random UUID() caused every re-resolve to look like all-new items, triggering
        /// insertion animations (left-to-right slide) even when the text was the same.
        var id: String { "\(title)|\(subtitle)" }
        let title: String
        let subtitle: String
        private let _fullText: String?
        var fullText: String { _fullText ?? "\(title) \(subtitle)" }

        init(title: String, subtitle: String, fullText: String? = nil) {
            self.title = title
            self.subtitle = subtitle
            self._fullText = fullText
        }
    }

    /// Converts server-provided `default_prompt_suggestions` into display models.
    ///
    /// Returns an empty array when the server has no suggestions configured
    /// (admin turned them off or the field is absent), which collapses the
    /// entire prompt grid and shows a clean hero-only welcome screen.
    private static func buildServerPrompts(
        from suggestions: [BackendConfig.PromptSuggestion]?,
        count: Int
    ) -> [SuggestedPrompt] {
        guard let suggestions, !suggestions.isEmpty else { return [] }

        let mapped: [SuggestedPrompt] = suggestions.compactMap { suggestion in
            // title[0] = bold heading, title[1] = subtitle (may be absent)
            guard let titleParts = suggestion.title, !titleParts.isEmpty else { return nil }
            let title = titleParts[0]
            let subtitle = titleParts.count > 1 ? titleParts[1] : ""
            // Use the server's `content` field as the sent message; fall back
            // to joining the title parts if content is missing.
            let content = suggestion.content ?? titleParts.joined(separator: " ")
            return SuggestedPrompt(title: title, subtitle: subtitle, fullText: content)
        }

        // Shuffle so a different subset appears each time, then cap to `count`
        // (4 cards on iPhone, 8 on iPad).
        return Array(mapped.shuffled().prefix(count))
    }

    /// Resolves which prompt suggestions to show on the welcome screen.
    ///
    /// Priority:
    /// 1. Per-model `suggestion_prompts` (from the selected model's `meta.suggestion_prompts`) — if non-empty, use those.
    /// 2. Admin-level `default_prompt_suggestions` (from `/api/config`) — fallback if the model has none.
    /// 3. Neither → empty array (no prompt cards shown).
    private static func resolvePromptSuggestions(
        adminSuggestions: [BackendConfig.PromptSuggestion]?,
        modelSuggestions: [BackendConfig.PromptSuggestion]?,
        count: Int
    ) -> [SuggestedPrompt] {
        // 1. Per-model prompts take priority
        if let model = modelSuggestions, !model.isEmpty {
            return buildServerPrompts(from: model, count: count)
        }
        // 2. Fall back to admin-configured prompts
        if let admin = adminSuggestions, !admin.isEmpty {
            return buildServerPrompts(from: admin, count: count)
        }
        // 3. Neither → no prompts
        return []
    }

    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 60).layoutPriority(1)

                // ── Hero: avatar + greeting ──
                VStack(spacing: Spacing.sm) {
                    // Avatar — suppress all implicit animations so model-image
                    // loading never plays a scale/fade pop on the welcome screen.
                    Group {
                        if let model = viewModel.selectedModel {
                            ModelAvatar(
                                size: 52,
                                imageURL: viewModel.resolvedImageURL(for: model),
                                label: model.shortName,
                                authToken: viewModel.serverAuthToken
                            )
                        } else {
                            ModelAvatar(size: 52, label: nil)
                        }
                    }
                    .animation(nil, value: viewModel.selectedModel?.id)
                    .transaction { $0.animation = nil }

                    VStack(spacing: 4) {
                        Text("How can I help?")
                            .scaledFont(size: 24, weight: .bold)
                            .foregroundStyle(theme.textPrimary)

                        if let model = viewModel.selectedModel {
                            Text(model.shortName)
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }

                    if viewModel.isTemporaryChat {
                        HStack(spacing: 5) {
                            Image(systemName: "eye.slash.fill")
                                .scaledFont(size: 10, weight: .semibold)
                            Text("Temporary Chat")
                                .scaledFont(size: 11, weight: .semibold)
                        }
                        .foregroundStyle(theme.warning)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.warning.opacity(0.1))
                        .clipShape(Capsule())
                    }
                }

                // ── Suggested prompt cards ──
                // Only shown when the server has configured suggestions.
                // If the admin clears all suggestions (or the server doesn't
                // return any), this entire block is hidden and the welcome
                // screen shows only the hero avatar + "How can I help?".
                if !randomPrompts.isEmpty {
                    Spacer().frame(height: 32)

                    // Adaptive grid: 2-col iPhone, 4-col iPad
                    let cols = promptColumnCount
                    let rows = stride(from: 0, to: randomPrompts.count, by: cols).map { i in
                        Array(randomPrompts[i..<min(i + cols, randomPrompts.count)])
                    }
                    VStack(spacing: 10) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 10) {
                                ForEach(row) { prompt in
                                    promptCard(prompt)
                                }
                                // Fill empty slots if row has fewer items than column count
                                ForEach(0..<(cols - row.count), id: \.self) { _ in
                                    Color.clear
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, Spacing.screenPadding)
                        }
                    }
                    .frame(maxWidth: iPadMaxContentWidth)
                    // Suppress insertion/removal animations on the prompt grid —
                    // cards should appear instantly, not fly in from the side.
                    .transaction { $0.animation = nil }
                }

                Spacer(minLength: 60).layoutPriority(1)
            }
            .frame(minHeight: max(viewState_containerHeight, 0))
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ScrollViewHorizontalLock())
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Folder Welcome View

    private func folderWelcomeView(folder: ChatFolder) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60).layoutPriority(1)

            VStack(spacing: Spacing.md) {
                // Folder icon
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(theme.brandPrimary.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "folder.fill")
                        .scaledFont(size: 34, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }

                // Folder name
                Text(folder.name)
                    .scaledFont(size: 26, weight: .bold)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                // Subtitle hint
                Text("New chats will be saved to this folder")
                    .scaledFont(size: 13, weight: .regular)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)

                // Show system prompt badge if the folder has one
                if let systemPrompt = folder.systemPrompt,
                   !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "text.bubble")
                            .scaledFont(size: 11, weight: .medium)
                        Text("Custom system prompt active")
                            .scaledFont(size: 11, weight: .medium)
                    }
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(theme.brandPrimary.opacity(0.1))
                    .clipShape(Capsule())
                }

                // Show configured model badge if the folder has default models
                if let firstModel = folder.modelIds.first, !firstModel.isEmpty {
                    let modelName = viewModel.availableModels.first(where: { $0.id == firstModel })?.shortName ?? firstModel
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "cpu")
                            .scaledFont(size: 11, weight: .medium)
                        Text(modelName)
                            .scaledFont(size: 11, weight: .medium)
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(theme.surfaceContainer.opacity(0.6))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
                    )
                }
            }
            .padding(.horizontal, Spacing.screenPadding)

            Spacer(minLength: 60).layoutPriority(1)
        }
        .frame(maxWidth: iPadMaxContentWidth)
        .frame(maxWidth: .infinity)
        .onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    @ViewBuilder
    private func promptCard(_ prompt: SuggestedPrompt) -> some View {
        Button {
            // Send the prompt directly without populating the bound input field —
            // this avoids the text briefly flashing in the input box before send.
            Haptics.play(.light)
            Task { await viewModel.sendMessage(directText: prompt.fullText) }
        } label: {

            VStack(alignment: .leading, spacing: 5) {
                Text(prompt.title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.subtitle)
                    .scaledFont(size: 12, weight: .regular)
                    .foregroundStyle(theme.textSecondary.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.isDark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(PromptCardButtonStyle())
    }

    // MARK: - Assistant Action Bar

    private func assistantActionBar(for message: ChatMessage) -> some View {
        // Resolve chat permissions once for all guards in this bar.
        // Admins always get full access (GroupChatPermissions() defaults all to true).
        let chatPerms = dependencies.authViewModel.chatPermissions

        // Build a timestamp-sorted list of ALL sibling IDs (current main + versions).
        // This is the single source of truth for position — it never gets stale
        // because it is derived fresh from the message object on every render.
        // After any rederiveMessages() call (branch switch, edit, regen), the
        // message object is replaced with the new active sibling, so its
        // .timestamp and .versions[] are always authoritative.
        let allSiblings: [(id: String, timestamp: Date)] = {
            var sibs: [(id: String, timestamp: Date)] = [(message.id, message.timestamp)]
            for v in message.versions { sibs.append((v.id, v.timestamp)) }
            sibs.sort { $0.timestamp < $1.timestamp }
            return sibs
        }()
        let totalVersions = allSiblings.count
        // The current active sibling is the main message (message.id).
        // Its 1-based position in the sorted siblings list is the displayIndex.
        let displayIndex: Int = (allSiblings.firstIndex(where: { $0.id == message.id }) ?? 0) + 1

        return HStack(spacing: 6) {
            // Speak — gated by permissions.chat.tts
            if chatPerms.tts {
                Button {
                    toggleSpeech(for: message)
                    Haptics.play(.light)
                } label: {
                    if ttsGeneratingMessageId == message.id {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.65)
                            .frame(width: 28, height: 28)
                            .tint(theme.brandPrimary)
                    } else {
                        compactActionIcon(
                            icon: speakingMessageId == message.id ? "stop.fill" : "speaker.wave.2",
                            isActive: speakingMessageId == message.id
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speakingMessageId == message.id ? "Stop speaking" : "Speak")
            }

            // Copy (always available — no permission gate in WebUI either)
            Button { copyMessage(message) } label: {
                compactActionIcon(icon: "doc.on.doc", isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy")

            // Edit assistant message — gated by permissions.chat.edit
            // Mirrors WebUI's editMessage(id, { content }, false): updates content
            // in-place without creating a new branch or triggering regeneration.
            if chatPerms.edit && !viewModel.isStreaming {
                Button {
                    beginAssistantEdit(message: message)
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(icon: "pencil", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit response")
            }

            // Version switcher (only when siblings exist and not overriding with a user edit version)
            if totalVersions > 1 && !viewModel.isStreaming && assistantContentOverride[message.id] == nil {
                HStack(spacing: 2) {
                    Button {
                        // Navigate to the sibling BEFORE the current one in sorted order.
                        let currentPos = displayIndex - 1 // 0-based
                        let targetPos = currentPos - 1
                        if targetPos >= 0 {
                            let targetId = allSiblings[targetPos].id
                            // restoreAssistantVersionById() calls rederiveMessages() which
                            // replaces the message object entirely. After that, the target
                            // sibling IS the main message and all state is correct.
                            // Clear stale activeVersionIndex/assistantContentOverride so the
                            // new main message renders its own files and content — not whatever
                            // the old activeVersionIndex was pointing to.
                            activeVersionIndex.removeValue(forKey: message.id)
                            assistantContentOverride.removeValue(forKey: message.id)
                            viewModel.restoreAssistantVersionById(targetSiblingId: targetId)
                            Haptics.play(.light)
                        }
                    } label: {
                        compactActionIcon(icon: "chevron.left", isActive: false, size: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(displayIndex == 1)
                    .opacity(displayIndex == 1 ? 0.35 : 1)

                    Text("\(displayIndex)/\(totalVersions)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: 28)

                    Button {
                        // Navigate to the sibling AFTER the current one in sorted order.
                        let currentPos = displayIndex - 1 // 0-based
                        let targetPos = currentPos + 1
                        if targetPos < allSiblings.count {
                            let targetId = allSiblings[targetPos].id
                            // Same cleanup as the ← button above.
                            activeVersionIndex.removeValue(forKey: message.id)
                            assistantContentOverride.removeValue(forKey: message.id)
                            viewModel.restoreAssistantVersionById(targetSiblingId: targetId)
                            Haptics.play(.light)
                        }

                    } label: {
                        compactActionIcon(icon: "chevron.right", isActive: false, size: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(displayIndex == totalVersions)
                    .opacity(displayIndex == totalVersions ? 0.35 : 1)
                }
            }

            // Regenerate — gated by permissions.chat.regenerate_response
            if !viewModel.isStreaming && chatPerms.regenerateResponse {
                Button {
                    Task { await viewModel.regenerateResponse(messageId: message.id) }
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(icon: "arrow.clockwise", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate")
            }

            // Continue — gated by permissions.chat.continue_response.
            // Only shown on the LAST assistant message so the user can append
            // more content to an incomplete or truncated response.
            let isLastAssistantMsg = viewModel.messages.last(where: { $0.role == .assistant })?.id == message.id
            if !viewModel.isStreaming && chatPerms.continueResponse && isLastAssistantMsg {
                Button {
                    Task { await viewModel.continueLastResponse() }
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(icon: "play.fill", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Continue response")
            }

            // Fork chat — clones the entire conversation and navigates to the fork.
            // Matches open-webui's fork behaviour: POST /api/v1/chats/{id}/clone,
            // then navigate to the newly created chat.
            // Only shown when a saved conversation exists (not on brand-new chats).
            if !viewModel.isStreaming && viewModel.conversation != nil {
                Button {
                    Task { await viewModel.forkChat(messageId: message.id) }
                    Haptics.play(.light)
                } label: {
                    if viewModel.isForkingChat {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.65)
                            .frame(width: 28, height: 28)
                            .tint(theme.brandPrimary)
                    } else {
                        compactActionIcon(icon: "arrow.branch", isActive: false)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fork chat")
            }

            // Delete — gated by permissions.chat.delete_message (only when siblings exist)
            if !viewModel.isStreaming && totalVersions > 1 && chatPerms.deleteMessage {
                Button {
                    Task { await viewModel.deleteMessage(id: message.id) }
                    // After deletion, rederiveMessages() replaces the message list —
                    // no index tracking needed. Just clear any stale state.
                    activeVersionIndex.removeValue(forKey: message.id)
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(icon: "trash", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete Version")
            }

            // Usage info — always show from the current active message (message.usage).
            // The current message IS the active sibling after any rederiveMessages() call.
            let displayUsage: [String: Any]? = message.usage
            if let usage = displayUsage, !usage.isEmpty {
                Button {
                    withAnimation(MicroAnimation.snappy) {
                        usagePopoverMessageId = usagePopoverMessageId == message.id ? nil : message.id
                    }
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(
                        icon: "info.circle",
                        isActive: usagePopoverMessageId == message.id
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Token usage")
            }

            // Thumbs up / down — gated by server enable_message_rating flag AND
            // permissions.chat.rate_response. Also hidden during temporary chats
            // (WebUI: !temporaryChatEnabled check).
            if viewModel.messageRatingEnabled && !viewModel.isStreaming
                && !viewModel.isTemporaryChat && chatPerms.rateResponse {
                let currentRating = message.annotation?.rating
                Button {
                    Task {
                        await viewModel.submitThumbsRating(message: message, rating: 1)
                        // Open detail sheet with the updated message (feedbackId now set)
                        if let updated = viewModel.messages.first(where: { $0.id == message.id }) {
                            feedbackDetailMessage = updated
                        }
                    }
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(
                        icon: currentRating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup",
                        isActive: currentRating == 1
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Thumbs up")

                Button {
                    Task {
                        await viewModel.submitThumbsRating(message: message, rating: -1)
                        if let updated = viewModel.messages.first(where: { $0.id == message.id }) {
                            feedbackDetailMessage = updated
                        }
                    }
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(
                        icon: currentRating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                        isActive: currentRating == -1
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Thumbs down")
            }

            // Action buttons (from model's configured actions — e.g. Generate Image)
            if !viewModel.isStreaming {
                let model = resolveModel(for: message)
                if let actions = model?.actions, !actions.isEmpty {
                    ForEach(actions) { action in
                        Button {
                            Task { await invokeActionButton(action: action, message: message) }
                            Haptics.play(.medium)
                        } label: {
                            actionButtonIcon(action: action)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(action.name)
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Assistant Inline Edit (in-place save, no regeneration)

    /// Opens an inline edit sheet for an assistant message.
    /// Unlike user message editing (which creates a new branch + regenerates),
    /// this mirrors WebUI's `editMessage(id, { content }, false)` — it saves
    /// the edited content in-place to the history tree and syncs to the server
    /// without triggering a new AI response.
    private func beginAssistantEdit(message: ChatMessage) {
        editingAssistantMessageId = message.id
        editingAssistantText = message.content
        Haptics.play(.light)
    }

    private func cancelAssistantEdit() {
        isAssistantEditFocused = false
        editingAssistantMessageId = nil
        editingAssistantText = ""
    }

    private func submitAssistantEdit() {
        guard let id = editingAssistantMessageId else { return }
        let trimmed = editingAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isAssistantEditFocused = false
        editingAssistantMessageId = nil
        let savedText = editingAssistantText
        editingAssistantText = ""
        Task { await viewModel.saveAssistantMessageContent(id: id, newContent: savedText) }
        Haptics.play(.medium)
    }

    /// Compact action icon for the always-visible action bar.
    private func compactActionIcon(icon: String, isActive: Bool, size: CGFloat = 12) -> some View {
        Image(systemName: icon)
            .scaledFont(size: size, weight: .medium)
            .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary.opacity(0.7))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }

    // MARK: - User Version Switcher (always-visible when edit history exists)

    /// Compact ← N/N → version arrows shown directly below the user bubble.
    /// Navigates user edit branches by sibling ID (not index), matching the same
    /// approach as assistantActionBar. This ensures switching the user message
    /// ALSO switches the paired assistant — because restoreUserVersionById walks
    /// to the deepest leaf of the target user branch (which includes the assistant).
    private func userVersionSwitcher(for message: ChatMessage) -> some View {
        // Build a timestamp-sorted list of ALL sibling IDs (current + versions),
        // identical to the approach in assistantActionBar. This avoids stale index
        // state and is always correct even after rederiveMessages() rebuilds the list.
        let allSiblings: [(id: String, timestamp: Date)] = {
            var sibs: [(id: String, timestamp: Date)] = [(message.id, message.timestamp)]
            for v in message.versions { sibs.append((v.id, v.timestamp)) }
            sibs.sort { $0.timestamp < $1.timestamp }
            return sibs
        }()
        let totalVersions = allSiblings.count
        // Current active sibling is message.id. Its 1-based position = displayIndex.
        let displayIndex: Int = (allSiblings.firstIndex(where: { $0.id == message.id }) ?? 0) + 1

        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Button {
                    // Navigate to the sibling BEFORE the current one.
                    let currentPos = displayIndex - 1 // 0-based
                    let targetPos = currentPos - 1
                    if targetPos >= 0 {
                        let targetId = allSiblings[targetPos].id
                        // restoreUserVersionById navigates to the deepest leaf of the
                        // target user branch — this switches BOTH user AND assistant.
                        assistantContentOverride = [:]
                        activeVersionIndex = [:]
                        viewModel.restoreUserVersionById(targetSiblingId: targetId)
                        Haptics.play(.light)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(displayIndex == 1)
                .opacity(displayIndex == 1 ? 0.35 : 1)

                Text("\(displayIndex)/\(totalVersions)")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                    .frame(minWidth: 28)

                Button {
                    // Navigate to the sibling AFTER the current one.
                    let currentPos = displayIndex - 1 // 0-based
                    let targetPos = currentPos + 1
                    if targetPos < allSiblings.count {
                        let targetId = allSiblings[targetPos].id
                        assistantContentOverride = [:]
                        activeVersionIndex = [:]
                        viewModel.restoreUserVersionById(targetSiblingId: targetId)
                        Haptics.play(.light)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(displayIndex == totalVersions)
                .opacity(displayIndex == totalVersions ? 0.35 : 1)
            }
            .padding(.trailing, 2)
        }
    }

    // MARK: - User Action Bar (kept for backward compat — no longer shown in messageRow)

    private func userActionBar(for message: ChatMessage) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: Spacing.xs) {
                Button { copyMessage(message) } label: {
                    Image(systemName: "doc.on.doc")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                if !viewModel.isStreaming {
                    Button { beginInlineEdit(message: message) } label: {
                        Image(systemName: "pencil")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - User Attachment Images

    @ViewBuilder
    private func userAttachmentImages(for message: ChatMessage) -> some View {
        let imageFiles = message.files.filter { isImageFile($0) }
        let nonImageFiles = message.files.filter { !isImageFile($0) }

        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if !imageFiles.isEmpty {
                userImageMosaicGrid(imageFiles: imageFiles)
            }
            if !nonImageFiles.isEmpty {
                HStack(spacing: Spacing.sm) {
                    Spacer()
                    ForEach(Array(nonImageFiles.enumerated()), id: \.offset) { _, file in
                        fileAttachmentCard(file: file)
                    }
                }
            }
        }
    }

    /// Smart mosaic grid for user-sent images:
    /// - 1 image: full-width up to 260pt
    /// - 2 images: side-by-side
    /// - 3 images: one large left + two stacked right
    /// - 4+ images: 2×2 grid with +N overflow badge on last tile
    @ViewBuilder
    private func userImageMosaicGrid(imageFiles: [ChatMessageFile]) -> some View {
        let shown = imageFiles.prefix(4)
        let overflow = imageFiles.count - 4

        HStack(spacing: 0) {
            Spacer(minLength: 64)

            let tileCorner: CGFloat = 14
            let gap: CGFloat = 3

            Group {
                switch imageFiles.count {
                case 1:
                    // Single: full-width up to 260, natural aspect ratio
                    if let fileId = shown[0].url, !fileId.isEmpty {
                        AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                            .frame(maxWidth: 260, maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: tileCorner, style: .continuous))
                    }

                case 2:
                    // Two side-by-side
                    HStack(spacing: gap) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { idx, file in
                            if let fileId = file.url, !fileId.isEmpty {
                                AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                                    .scaledToFill()
                                    .frame(width: 126, height: 126)
                                    .clipped()
                                    .clipShape(
                                        .rect(
                                            topLeadingRadius: idx == 0 ? tileCorner : 0,
                                            bottomLeadingRadius: idx == 0 ? tileCorner : 0,
                                            bottomTrailingRadius: idx == 1 ? tileCorner : 0,
                                            topTrailingRadius: idx == 1 ? tileCorner : 0
                                        )
                                    )
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: tileCorner, style: .continuous))

                case 3:
                    // Large left + two stacked right
                    HStack(spacing: gap) {
                        if let fileId = shown[0].url, !fileId.isEmpty {
                            AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                                .scaledToFill()
                                .frame(width: 168, height: 168)
                                .clipped()
                                .clipShape(
                                    .rect(
                                        topLeadingRadius: tileCorner,
                                        bottomLeadingRadius: tileCorner,
                                        bottomTrailingRadius: 0,
                                        topTrailingRadius: 0
                                    )
                                )
                        }
                        VStack(spacing: gap) {
                            ForEach([1, 2], id: \.self) { idx in
                                if let fileId = shown[idx].url, !fileId.isEmpty {
                                    AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                                        .scaledToFill()
                                        .frame(width: 82, height: 82)
                                        .clipped()
                                        .clipShape(
                                            .rect(
                                                topLeadingRadius: 0,
                                                bottomLeadingRadius: 0,
                                                bottomTrailingRadius: idx == 2 ? tileCorner : 0,
                                                topTrailingRadius: idx == 1 ? tileCorner : 0
                                            )
                                        )
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: tileCorner, style: .continuous))

                default:
                    // 4+ images: 2×2 grid with overflow badge
                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            ForEach([0, 1], id: \.self) { idx in
                                if let fileId = shown[idx].url, !fileId.isEmpty {
                                    AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                                        .scaledToFill()
                                        .frame(width: 126, height: 126)
                                        .clipped()
                                        .clipShape(
                                            .rect(
                                                topLeadingRadius: idx == 0 ? tileCorner : 0,
                                                bottomLeadingRadius: 0,
                                                bottomTrailingRadius: 0,
                                                topTrailingRadius: idx == 1 ? tileCorner : 0
                                            )
                                        )
                                }
                            }
                        }
                        HStack(spacing: gap) {
                            ForEach([2, 3], id: \.self) { idx in
                                if let fileId = shown[idx].url, !fileId.isEmpty {
                                    ZStack {
                                        AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                                            .scaledToFill()
                                            .frame(width: 126, height: 126)
                                            .clipped()
                                            .clipShape(
                                                .rect(
                                                    topLeadingRadius: 0,
                                                    bottomLeadingRadius: idx == 2 ? tileCorner : 0,
                                                    bottomTrailingRadius: idx == 3 ? tileCorner : 0,
                                                    topTrailingRadius: 0
                                                )
                                            )

                                        // Overflow badge on tile 4 (idx == 3)
                                        if idx == 3 && overflow > 0 {
                                            Color.black.opacity(0.55)
                                                .frame(width: 126, height: 126)
                                                .clipShape(
                                                    .rect(
                                                        topLeadingRadius: 0,
                                                        bottomLeadingRadius: 0,
                                                        bottomTrailingRadius: tileCorner,
                                                        topTrailingRadius: 0
                                                    )
                                                )
                                            Text("+\(overflow)")
                                                .scaledFont(size: 22, weight: .bold)
                                                .foregroundStyle(.white)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: tileCorner, style: .continuous))
                }
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 2)
    }

    private func fileAttachmentCard(file: ChatMessageFile) -> some View {
        let fileName = file.name ?? file.url ?? "File"
        let fileExt = (fileName as NSString).pathExtension.lowercased()
        let icon = fileIconName(for: fileExt)

        return Button {
            if let fileId = file.url {
                Task { await previewFileInApp(fileId: fileId, fileName: fileName) }
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .scaledFont(size: 18)
                    .foregroundStyle(theme.brandPrimary)
                    .frame(width: 32, height: 32)
                    .background(theme.brandPrimary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .scaledFont(size: 14)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileExt.uppercased())
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .background(theme.surfaceContainer.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// Returns true if a ChatMessageFile represents an image, regardless of whether
    /// the server stored it with type "image" or type "file" + an image contentType.
    private func isImageFile(_ file: ChatMessageFile) -> Bool {
        if file.type == "image" { return true }
        if let ct = file.contentType, ct.hasPrefix("image/") { return true }
        // Fallback: check file extension from name
        if let name = file.name ?? file.url {
            let ext = (name as NSString).pathExtension.lowercased()
            if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"].contains(ext) {
                return true
            }
        }
        return false
    }

    private func fileIconName(for ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "rectangle.stack"
        case "json", "yaml", "yml", "xml", "conf", "toml", "ini", "cfg": return "curlybraces"
        case "txt", "md", "rtf": return "doc.plaintext"
        case "js", "ts", "py", "swift", "dart", "java", "cpp", "c", "h", "rb", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        case "HTML", "css", "scss": return "globe"
        case "zip", "tar", "gz", "rar", "7z": return "archivebox"
        case "mp3", "wav", "m4a", "flac": return "waveform"
        case "mp4", "mov", "avi", "mkv": return "film"
        default: return "doc"
        }
    }

    // MARK: - Tool-Generated Images

    @ViewBuilder
    private func messageFilesView(files: [ChatMessageFile]) -> some View {
        let imageFiles = files.filter { $0.type == "image" || ($0.contentType ?? "").hasPrefix("image/") }
        if !imageFiles.isEmpty {
            let columns = imageFiles.count == 1
                ? [GridItem(.flexible())]
                : [GridItem(.flexible(), spacing: Spacing.sm), GridItem(.flexible(), spacing: Spacing.sm)]

            LazyVGrid(columns: columns, spacing: Spacing.sm) {
                ForEach(Array(imageFiles.enumerated()), id: \.element) { _, file in
                    if let fileUrl = file.url, !fileUrl.isEmpty {
                        let fileId: String = {
                            if !fileUrl.contains("/") { return fileUrl }
                            let parts = fileUrl.split(separator: "/")
                            if let idx = parts.firstIndex(of: "files"), idx + 1 < parts.count {
                                return String(parts[idx + 1])
                            }
                            return fileUrl
                        }()
                        AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: - Sources Bar

    private func sourcesBar(sources: [ChatSourceReference], messageId: String) -> some View {
        Button {
            if let msg = viewModel.messages.first(where: { $0.id == messageId }) {
                sourcesSheetMessage = msg
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                HStack(spacing: -4) {
                    ForEach(Array(sources.prefix(3).enumerated()), id: \.offset) { _, source in
                        sourceIconBadge(source: source)
                    }
                    if sources.count > 3 {
                        Circle()
                            .fill(theme.surfaceContainer)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Text("+\(sources.count - 3)")
                                    .scaledFont(size: 8, weight: .bold)
                                    .foregroundStyle(theme.textSecondary)
                            )
                    }
                }
                Text("\(sources.count) Source\(sources.count == 1 ? "" : "s")")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(theme.surfaceContainer.opacity(0.6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A 18×18 circular icon for a source: favicon via Google S2 if a URL is available,
    /// or a letter avatar as fallback for knowledge/file sources with no domain.
    @ViewBuilder
    private func sourceIconBadge(source: ChatSourceReference) -> some View {
        let domain: String? = {
            guard let url = source.resolvedURL,
                  let parsed = URL(string: url),
                  let host = parsed.host, !host.isEmpty else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }()

        if let domain {
            AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=32&domain=\(domain)")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 18, height: 18)
                        .clipShape(Circle())
                default:
                    letterAvatarBadge(source: source)
                }
            }
        } else {
            letterAvatarBadge(source: source)
        }
    }

    private func letterAvatarBadge(source: ChatSourceReference) -> some View {
        Circle()
            .fill(theme.brandPrimary.opacity(0.2))
            .frame(width: 18, height: 18)
            .overlay(
                Text(String((source.title ?? source.url ?? "?").prefix(1)).uppercased())
                    .scaledFont(size: 8, weight: .bold)
                    .foregroundStyle(theme.brandPrimary)
            )
    }

    // MARK: - Follow-Up Suggestions

    private func followUpSuggestions(_ followUps: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "lightbulb").scaledFont(size: 12).foregroundStyle(theme.brandPrimary)
                Text("Continue with")
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.textTertiary)
            }
            ForEach(followUps, id: \.self) { suggestion in
                Button {
                    viewModel.inputText = suggestion
                    Task { await viewModel.sendMessage() }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "arrow.right")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                        Text(suggestion)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.brandPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(theme.brandPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .strokeBorder(theme.brandPrimary.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Message Error View

    private func messageErrorView(_ text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(theme.error)
            Text(text)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.error)
            Spacer()
            if !viewModel.isStreaming {
                Button { Task { await viewModel.regenerateLastResponse() } } label: {
                    Text("Retry").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.brandPrimary)
                }
            }
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: - Error Banner

    private func errorBannerView(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                withAnimation(MicroAnimation.snappy) { viewModel.errorMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
        }
        .padding(Spacing.md)
        .background(theme.errorBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(MicroAnimation.gentle, value: viewModel.errorMessage != nil)
    }

    // MARK: - Copied Toast

    private var copiedToastView: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.on.doc.fill").scaledFont(size: 12)
            Text("Copied to clipboard").scaledFont(size: 12, weight: .medium)
        }
        .foregroundStyle(theme.textInverse)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.textPrimary.opacity(0.85))
        .clipShape(Capsule())
        .padding(.top, Spacing.md)
        .transition(.toastTransition)
        .animation(MicroAnimation.gentle, value: showCopiedToast)
    }


    // MARK: - Actions

    /// Fetches the full model detail and opens the ModelEditorView sheet.
    /// Called when an admin taps the edit button in the model selector sheet.
    private func openModelEditorFromPicker(_ model: AIModel) async {
        guard let apiClient = dependencies.apiClient else { return }
        isLoadingModelDetail = true
        do {
            let detail = try await apiClient.getWorkspaceModelDetail(id: model.id)
            isLoadingModelDetail = false
            editingModelDetail = detail
        } catch {
            // Base models (not yet customized as workspace models) return 404.
            // Construct a default ModelDetail so the editor opens in "create" mode.
            isLoadingModelDetail = false
            editingModelDetail = ModelDetail(
                id: model.id,
                name: model.name,
                description: model.description,
                profileImageURL: model.profileImageURL
            )
        }
    }

    /// Deletes the current conversation and either calls the parent-supplied
    /// `deleteChatAction` callback (for smooth animated navigation to a new chat)
    /// or falls back to `router.popToRoot()` when used standalone.
    private func performDeleteChat() {
        guard let conversationId = viewModel.conversation?.id else { return }
        let action = deleteChatAction
        Task {
            try? await dependencies.conversationManager?.deleteConversation(id: conversationId)
            await MainActor.run {
                if let action {
                    withAnimation(.easeInOut(duration: 0.25)) { action() }
                } else {
                    router.popToRoot()
                }
            }
        }
    }

    /// Dismiss all picker/overlay states so a new quick action doesn't stack.
    private func dismissAllPickers() {
        showCameraPicker = false
        showFilePicker = false
        showPhotosPicker = false
        showAudioPicker = false
        showWebURLAlert = false
    }

    // MARK: - Lifecycle Helpers

    private func handleViewTask() async {
        // Start keyboard tracking FIRST so the bottom inset is
        // correct for the very first layout pass (D9 fix).
        keyboard.start()
        // Configure only when not already done by .onAppear or ActiveChatStore.prewarm().
        // .onAppear fires synchronously on the first render pass and covers the
        // toolbar/model-selector pop-in; this guard prevents a redundant second call.
        if !viewModel.isConfigured, let manager = dependencies.conversationManager {
            viewModel.configure(with: manager, socket: dependencies.socketService, store: dependencies.activeChatStore, asr: dependencies.asrService, notes: dependencies.notesManager)
        }
        // Populate server feature flags in ActiveChatStore so isMemoryAvailable
        // returns true for all models when the server has memories enabled —
        // not just for models with builtinTools.memory.
        if dependencies.activeChatStore.serverFeatures == nil {
            dependencies.activeChatStore.serverFeatures = dependencies.authViewModel.featurePermissions
        }
        // Perform non-async setup before awaiting load() so the UI
        // populates prompts and temporary-chat state instantly.
        if viewModel.isNewConversation {
            viewModel.isTemporaryChat = UserDefaults.standard.bool(forKey: "temporaryChatDefault")
        }
        // Only resolve prompts pre-load for new chats — existing chats
        // already have a model; we'll resolve after load() below (D10 fix).
        if viewModel.isNewConversation {
            let preLoadPrompts = Self.resolvePromptSuggestions(
                adminSuggestions: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions,
                modelSuggestions: viewModel.selectedModel?.suggestionPrompts,
                count: promptCardCount
            )
            withTransaction(\.animation, nil) { randomPrompts = preLoadPrompts }
        }
        NotificationService.shared.activeConversationId =
            viewModel.conversationId ?? viewModel.conversation?.id
        await viewModel.load()
        // After messages load, pin the window to the latest messages.
        let loadedCount = viewModel.messages.count
        if loadedCount > 0 {
            isScrolledUp = false
            windowEnd = nil
            // Start with a small window (last ~8 rows). The minHeight trick on the
            // last user→assistant turn (windowIncludesEnd) already stretches that
            // last turn to fill the full viewport, so 8 rows is more than enough to
            // land exactly on the true last message with no visible scroll.
            // Keeping the window small avoids synchronously instantiating all heavy
            // rows (WKWebView, MarkdownView, Litext) during cold-start.
            // Window growth happens on-demand via the scroll-up pagination handler
            // in scrollContent (onScrollGeometryChange / newOffset.y < 600), which
            // prepends rows while the user is actively scrolling up — that path
            // preserves scroll position correctly and never strands the user.
            windowSize = min(8, loadedCount)
            // Keep pump suppression armed — the settle loop below will extend it.
            _pumpRef.lastScrollTime = Date().addingTimeInterval(0.5)
            // Fix B — Settle loop: repeatedly snap to .bottom and watch the content
            // height until it stops changing (WKWebViews / MarkdownView heights have
            // all been reported) before lifting the curtain. A fixed delay is
            // inherently unreliable because async height callbacks can arrive at any
            // time; polling for stability is the only race-free approach.
            // The whole loop runs behind the opacity+blur curtain so the user never
            // sees any scroll movement — they are revealed already at the true bottom.
            Task { @MainActor in
                // Keep pump suppression armed for the full settle period.
                let settleDeadline = Date().addingTimeInterval(1.5) // hard cap 1.5 s
                _pumpRef.programmaticScrollUntil = settleDeadline
                _pumpRef.lastScrollTime = settleDeadline

                var lastHeight: CGFloat = 0
                var stableTickCount = 0
                let requiredStableTicks = 2  // 2 consecutive unchanged heights = settled
                let tickInterval: UInt64 = 80_000_000 // 80 ms per tick

                // ── Part B: Pre-warm parse cache for the initial window ──────
                // While behind the blur curtain, kick off background parsing for
                // every assistant message in the initial window. By the time the
                // curtain lifts, AssistantMessageContent gets a global cache hit
                // on the very first render — zero main-thread parse work at open.
                // This runs off-main inside the actor, piggybacking on idle time
                // while we're already waiting for layout to settle.
                let messages = viewModel.messages
                let windowStart = max(0, messages.count - windowSize)
                let windowMessages = Array(messages[windowStart...])
                let serverBase = viewModel.serverBaseURL
                Task(priority: .background) {
                    // Delay warmBatch by 300 ms so the initial Litext/MarkdownView
                    // layout burst (mounting the first window of rows) can complete
                    // before we consume any cooperative thread-pool slots. Without
                    // this delay, warmBatch competes with the main thread's first
                    // layout pass and makes early scrolling feel sluggish.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let contentsToParse: [String] = windowMessages.compactMap { msg -> String? in
                        guard msg.role == .assistant else { return nil }
                        // Replicate the same content resolution IsolatedAssistantMessage uses
                        // (non-streaming path: resolveRelativeURLs + preprocessCitations).
                        // Sources are empty at pre-warm time — that's fine, the cache key
                        // includes the full resolved string, and citations are stable once
                        // the message is loaded.
                        let raw = msg.content
                        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        let resolved = IsolatedAssistantMessage.resolveRelativeURLs(raw, baseURL: serverBase)
                        // Skip citation preprocessing here — sources may be empty and the
                        // resolved-only string is a different cache key than the cited version.
                        // The first real render will do a fast async miss→store for the cited
                        // variant, which is still off-main. The pre-warm covers the common
                        // case (messages without citations / no sources).
                        return resolved
                    }
                    await MessageParseCache.shared.warmBatch(contentsToParse)
                }

                // Initial snap — fires before the first layout pass so
                // .defaultScrollAnchor(.bottom) always has a partner snap.
                scrollPosition.scrollTo(edge: .bottom)

                while Date() < settleDeadline {
                    try? await Task.sleep(nanoseconds: tickInterval)
                    scrollPosition.scrollTo(edge: .bottom)
                    let currentHeight = viewState_contentHeight
                    if abs(currentHeight - lastHeight) < 1 && currentHeight > 0 {
                        stableTickCount += 1
                        if stableTickCount >= requiredStableTicks { break }
                    } else {
                        stableTickCount = 0
                        lastHeight = currentHeight
                    }
                }

                // One final authoritative snap after heights have stabilised.
                scrollPosition.scrollTo(edge: .bottom)
                // Lift the curtain — user sees the chat already at the true bottom.
                // Window remains at 8 rows — the scroll-up pagination handler in
                // scrollContent grows it on-demand as the user scrolls up, which
                // preserves scroll position correctly (prepends above viewport).
                isContentReady = true
            }
        } else {
            // New chat (no messages) — welcome screen, nothing to scroll.
            // Reveal immediately so the input field and hero appear instantly.
            isContentReady = true
        }
        await viewModel.fetchPinnedModels()
        await viewModel.fetchMessageRatingEnabled()
        // After fetchPinnedModels(), only rebuild prompts when they are still
        // empty (e.g. backendConfig wasn't ready on the first call) OR when the
        // selected model has per-model suggestion_prompts that differ from what
        // the pre-load resolve returned. This prevents the double-shuffle flicker
        // where the first resolve picks 4 random cards and this second resolve
        // immediately picks 4 *different* random cards, causing a left-to-right
        // slide animation as all card text changes at once.
        let newModelSuggestions = viewModel.selectedModel?.suggestionPrompts
        let hasModelSuggestions = !(newModelSuggestions?.isEmpty ?? true)
        // Only re-resolve if: prompts are empty (first-launch timing) OR the
        // model now has per-model suggestions (which override admin suggestions).
        if randomPrompts.isEmpty || hasModelSuggestions {
            let postLoadPrompts = Self.resolvePromptSuggestions(
                adminSuggestions: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions,
                modelSuggestions: newModelSuggestions,
                count: promptCardCount
            )
            withTransaction(\.animation, nil) { randomPrompts = postLoadPrompts }
        }
    }

    private func handleDisappear() {
        keyboard.stop()
        // Stop TTS playback and clear state when navigating away from chat
        if speakingMessageId != nil || ttsGeneratingMessageId != nil {
            dependencies.textToSpeechService.stop()
            speakingMessageId = nil
            ttsGeneratingMessageId = nil
        }
        NotificationService.shared.activeConversationId = nil
    }

    // MARK: - Dictation

    private func startDictation() {
        let service = dependencies.dictationService
        service.onTranscriptReady = { [weak viewModel] text in
            guard let vm = viewModel else { return }
            if vm.inputText.isEmpty {
                vm.inputText = text
            } else {
                vm.inputText += " " + text
            }
        }
        service.onError = { _ in
            Task { @MainActor in isDictating = false }
        }
        isDictating = true
        Task { await service.startDictation() }
    }

    private func stopDictation() {
        dependencies.dictationService.stopDictation()
        isDictating = false
    }

    private func cancelDictation() {
        dependencies.dictationService.cancelDictation()
        isDictating = false
    }

    private func toggleVoiceInput() {
        Haptics.play(.medium)
        let voiceCallVM = dependencies.makeVoiceCallViewModel()
        if let manager = dependencies.conversationManager {
            voiceCallVM.configure(
                conversationManager: manager,
                chatViewModel: viewModel,
                modelName: viewModel.selectedModel?.name ?? "AI Assistant"
            )
        }
        router.presentVoiceCall(viewModel: voiceCallVM)
    }

    private func toggleSpeech(for message: ChatMessage) {
        let tts = dependencies.textToSpeechService
        if speakingMessageId == message.id || ttsGeneratingMessageId == message.id {
            tts.stop()
            speakingMessageId = nil
            ttsGeneratingMessageId = nil
        } else {
            tts.stop()
            speakingMessageId = nil
            ttsGeneratingMessageId = nil
            let rate = UserDefaults.standard.double(forKey: "ttsSpeechRate")
            if rate > 0 { tts.speechRate = Float(rate) * AVSpeechUtteranceDefaultSpeechRate }
            let voiceId = UserDefaults.standard.string(forKey: "ttsVoiceIdentifier") ?? ""
            tts.voiceIdentifier = voiceId.isEmpty ? nil : voiceId
            let messageId = message.id
            tts.onStart = {
                speakingMessageId = messageId
                ttsGeneratingMessageId = nil
            }
            tts.onComplete = {
                speakingMessageId = nil
                ttsGeneratingMessageId = nil
            }

            let vIdx = activeVersionIndex[message.id] ?? -1
            let content: String = {
                if vIdx >= 0 && vIdx < message.versions.count { return message.versions[vIdx].content }
                return message.content
            }()
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ttsGeneratingMessageId = message.id
            tts.speak(content)
        }
    }

    // MARK: - Action Button Helpers

    /// Renders the icon for an action button.
    /// Handles three icon formats:
    ///  1. Base64 SVG data URI  (`data:image/svg+xml;base64,...`) — decoded inline.
    ///  2. Inline SVG string    (starts with `<svg`) — rendered directly.
    ///  3. HTTP/HTTPS URL       — fetched remotely by RemoteSVGIconView.
    ///  4. Everything else      — bolt.fill SF Symbol fallback.
    @ViewBuilder
    private func actionButtonIcon(action: AIModelAction) -> some View {
        if let iconStr = action.icon, !iconStr.isEmpty {
            if iconStr.hasPrefix("data:image/svg+xml;base64,"),
               let base64 = iconStr.components(separatedBy: ",").last,
               let svgData = Data(base64Encoded: base64),
               let svgString = String(data: svgData, encoding: .utf8) {
                // Base64-encoded SVG data URI
                SVGIconView(svgString: svgString)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            } else if iconStr.hasPrefix("<svg") || iconStr.hasPrefix("<?xml") {
                // Raw SVG string
                SVGIconView(svgString: iconStr)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            } else if iconStr.hasPrefix("http://") || iconStr.hasPrefix("https://") {
                // Remote URL (e.g., https://www.svgrepo.com/show/…/pdf-file.svg)
                RemoteSVGIconView(url: iconStr)
            } else {
                // Unknown format — fallback
                Image(systemName: "bolt.fill")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
        } else {
            Image(systemName: "bolt.fill")
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary.opacity(0.7))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
    }

    /// Invokes a function-based action button on an assistant message.
    ///
    /// Open WebUI action protocol:
    /// - POST `/api/chat/actions/{id}` is **plain JSON** (not SSE). The HTTP response
    ///   arrives only after the entire action finishes.
    /// - While the HTTP request is pending the server emits events via **Socket.IO**
    ///   on the `"events"` channel targeted at `session_id` (which must equal `socket.sid`):
    ///   - `__event_emitter__`: fire-and-forget status/notification/replace/message updates.
    ///   - `__event_call__`:    bidirectional call via `sio.call()` — carries a Socket.IO
    ///     ack ID. The client must respond via the ack callback to unblock the server.
    private func invokeActionButton(action: AIModelAction, message: ChatMessage) async {
        logger.info("🔵 [Action] invokeActionButton: action=\(action.id, privacy: .public) messageId=\(message.id, privacy: .public)")
        guard let apiClient = dependencies.apiClient else { return }

        // Show initial "Running…" status pill
        let statusUpdate = ChatStatusUpdate(action: action.name, description: "\(action.name)…", done: false)
        if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
            viewModel.conversation?.messages[idx].statusHistory.append(statusUpdate)
        }

        // Build request body. session_id MUST be socket.sid so the server can target
        // this Socket.IO session for __event_call__ and __event_emitter__ events.
        let messageArray: [[String: Any]] = viewModel.messages.map { msg in
            var dict: [String: Any] = [
                "role": msg.role.rawValue,
                "content": msg.content,
                "timestamp": Int(msg.timestamp.timeIntervalSince1970)
            ]
            if !msg.id.isEmpty { dict["id"] = msg.id }
            return dict
        }
        let modelItem: [String: Any] = viewModel.selectedModel?.rawModelItem ?? [:]
        var body: [String: Any] = [
            "model": viewModel.selectedModelId ?? "",
            "messages": messageArray,
            "id": message.id
        ]
        if let chatId = viewModel.conversationId ?? viewModel.conversation?.id {
            body["chat_id"] = chatId
        }

        // Ensure the Socket.IO connection is live before we commit a session_id to the
        // POST body. If the socket is not connected (e.g., after backgrounding), the
        // server cannot route __event_call__ / __event_emitter__ events back to us.
        let socket = dependencies.socketService
        if let socket {
            let initialState = socket.connectionState
            logger.info("🔵 [Action] Socket state before action: \(String(describing: initialState), privacy: .public), sid=\(socket.sid ?? "nil", privacy: .public)")
            if initialState != .connected {
                logger.info("🔵 [Action] Socket not connected — attempting ensureConnected...")
                let connected = await socket.ensureConnected(timeout: 5.0)
                logger.info("🔵 [Action] ensureConnected result: \(connected, privacy: .public), sid=\(socket.sid ?? "nil", privacy: .public)")
            }
        } else {
            logger.warning("⚠️ [Action] No socket service available — action events will not be received")
        }

        // Use socket.sid — must be captured AFTER ensureConnected so we have a live SID.
        let socketSid = socket?.sid
        let socketSessionId = socketSid ?? viewModel.sessionId
        body["session_id"] = socketSessionId
        if !modelItem.isEmpty { body["model_item"] = modelItem }

        logger.info("🔵 [Action] Using session_id=\(socketSessionId, privacy: .public) (socket.sid=\(socketSid ?? "nil", privacy: .public))")

        // Register Socket.IO handler BEFORE sending the POST so no events are missed.
        // Scope to session_id so only events destined for this action are delivered.
        let subscription = socket?.addChatEventHandler(sessionId: socketSessionId) { socketEvent, ack in
            Task { @MainActor in
                await self.handleActionSocketEvent(
                    socketEvent: socketEvent,
                    ack: ack,
                    action: action,
                    message: message
                )
            }
        }
        logger.info("🔵 [Action] Socket handler registered (subscription=\(subscription != nil, privacy: .public))")

        do {
            logger.info("🔵 [Action] Sending POST /api/chat/actions/\(action.id, privacy: .public)")
            // Plain JSON POST — not SSE. Blocks until the full action completes on the server.
            let actionResponse = try await apiClient.network.requestJSONOrVoid(
                path: "/api/chat/actions/\(action.id)",
                method: .post,
                body: body,
                authenticated: true,
                timeout: 300
            )
            logger.info("✅ [Action] POST completed successfully")
            viewModel.isStreaming = false

            // If the action returned a file result, download it in-app via the authenticated API.
            // e.g. PDF Export returns { "result": { "success": true, "filename": "…pdf" } }
            if let result = actionResponse["result"] as? [String: Any],
               (result["success"] as? Bool) == true,
               let filename = result["filename"] as? String, !filename.isEmpty {
                logger.info("📎 [Action] Result contains file: \(filename, privacy: .public) — fetching from server")
                isDownloadingFile = true
                let fileId = await resolveFileId(forFilename: filename, apiClient: apiClient)
                isDownloadingFile = false
                if let fileId {
                    await downloadAndShareFile(fileId: fileId)
                } else {
                    logger.warning("⚠️ [Action] Could not resolve file ID for '\(filename, privacy: .public)'")
                    downloadErrorMessage = "Could not find the generated file on the server."
                    showDownloadError = true
                }
            }

            await viewModel.reloadConversation()
        } catch {
            logger.error("❌ [Action] POST failed: \(error.localizedDescription, privacy: .public)")
            viewModel.errorMessage = error.localizedDescription
        }

        // Clean up socket handler
        subscription?.dispose()

        // Clear the running status pill
        if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
            viewModel.conversation?.messages[idx].statusHistory.removeAll {
                $0.action == action.name && $0.done != true
            }
        }
    }

    /// Processes a single Socket.IO `"events"` packet arriving during an action invocation.
    ///
    /// - `__event_emitter__` packets are dispatched immediately (no ack required).
    /// - `__event_call__` packets suspend until the user responds, then call `ack` so the
    ///   server's `await sio.call()` can resume.
    @MainActor
    private func handleActionSocketEvent(
        socketEvent: [String: Any],
        ack: ((Any?) -> Void)?,
        action: AIModelAction,
        message: ChatMessage
    ) async {
        // Open WebUI does NOT wrap events in "__event_emitter__" / "__event_call__" envelopes
        // at the socket event level. The actual event type lives at data.type (e.g. "status",
        // "input", "confirmation", "execute"). Whether the event requires an ack response is
        // determined by whether ack != nil (set by the server via sio.call vs sio.emit).
        let dataPayload = (socketEvent["data"] as? [String: Any]) ?? socketEvent
        let innerType = (dataPayload["data"] as? [String: Any])?["type"] as? String
            ?? dataPayload["type"] as? String ?? ""
        let inner = (dataPayload["data"] as? [String: Any]) ?? dataPayload

        logger.info("🎯 [Action] handleActionSocketEvent innerType=\(innerType, privacy: .public) ack=\(ack != nil, privacy: .public)")

        if ack == nil {
            // Fire-and-forget event from __event_emitter__ (status, notification, replace, message)
            switch innerType {
            case "status":
                let description = inner["description"] as? String ?? ""
                let done = inner["done"] as? Bool ?? false
                let name = inner["action"] as? String ?? action.name
                if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
                    if let existingIdx = viewModel.conversation?.messages[idx].statusHistory.firstIndex(where: { $0.action == name && $0.done != true }) {
                        viewModel.conversation?.messages[idx].statusHistory[existingIdx] = ChatStatusUpdate(action: name, description: description, done: done)
                    } else {
                        viewModel.conversation?.messages[idx].statusHistory.append(
                            ChatStatusUpdate(action: name, description: description, done: done)
                        )
                    }
                }
            case "notification":
                let msg = inner["content"] as? String ?? inner["message"] as? String ?? ""
                actionNotificationToast = msg
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    actionNotificationToast = nil
                }
            case "replace":
                let content = inner["content"] as? String ?? ""
                if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
                    viewModel.conversation?.messages[idx].content = content
                }
            case "message":
                let content = inner["content"] as? String ?? ""
                if let idx = viewModel.conversation?.messages.firstIndex(where: { $0.id == message.id }) {
                    viewModel.conversation?.messages[idx].content += content
                }
            default:
                break
            }
        } else {
            // Bidirectional call from __event_call__ (execute, input, confirmation) — must ack.
            // For "execute" we don't need user input — handle directly and ack.
            if innerType == "execute" {
                let code = inner["code"] as? String ?? inner["script"] as? String ?? ""
                let result = await handleExecuteEvent(code: code)
                let ackValue: Any?
                switch result {
                case .string(let s): ackValue = s
                case .bool(let b):   ackValue = b
                case .cancelled:     ackValue = false
                }
                ack?(ackValue)
                return
            }

            // For "input" / "confirmation" show a sheet, suspend until user responds,
            // then call the Socket.IO ack so the server's sio.call() can resume.
            let userResponse = await withCheckedContinuation { (continuation: CheckedContinuation<ActionCallResponse, Never>) in
                actionCallContinuation = continuation
                switch innerType {
                case "input":
                    let title   = inner["title"] as? String ?? "Input Required"
                    let msg     = inner["message"] as? String ?? inner["description"] as? String ?? ""
                    let placeholder = inner["placeholder"] as? String ?? ""
                    let defaultVal  = inner["value"] as? String ?? ""
                    actionInputText = defaultVal
                    actionInputRequest = ActionInputRequest(
                        title: title,
                        message: msg,
                        placeholder: placeholder,
                        defaultValue: defaultVal
                    )
                case "confirmation":
                    let title = inner["title"] as? String ?? "Confirm"
                    let msg   = inner["message"] as? String ?? inner["description"] as? String ?? "Are you sure?"
                    actionConfirmRequest = ActionConfirmRequest(title: title, message: msg)
                default:
                    // Unknown call type — resolve immediately so the server doesn't hang.
                    continuation.resume(returning: .bool(true))
                }
            }

            let ackValue: Any?
            switch userResponse {
            case .string(let s): ackValue = s
            case .bool(let b):   ackValue = b
            case .cancelled:     ackValue = false
            }
            ack?(ackValue)
        }
    }

    /// Resolves a file ID from a filename by querying the user's file list.
    /// Falls back to the most recently created file with the same extension if exact name not found.
    private func resolveFileId(forFilename filename: String, apiClient: APIClient) async -> String? {
        guard let files = try? await apiClient.getUserFiles(), !files.isEmpty else {
            logger.warning("⚠️ [Action] getUserFiles() returned nil or empty")
            return nil
        }
        logger.info("📂 [Action] getUserFiles returned \(files.count, privacy: .public) files")
        for f in files.prefix(5) {
            logger.info("  file id=\(f.id, privacy: .public) filename=\(f.filename ?? "nil", privacy: .public)")
        }

        // Exact match first
        if let exact = files.first(where: { $0.filename == filename }) {
            logger.info("✅ [Action] Exact file match: id=\(exact.id, privacy: .public)")
            return exact.id
        }

        // Fallback: match by extension, pick newest (highest createdAt)
        let ext = (filename as NSString).pathExtension.lowercased()
        let byExt = files.filter { ($0.filename as NSString?)?.pathExtension.lowercased() == ext }
        let newest = byExt.max(by: { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) })
        if let newest {
            logger.info("✅ [Action] Fallback to newest '\(ext, privacy: .public)' file: id=\(newest.id, privacy: .public) filename=\(newest.filename ?? "nil", privacy: .public)")
            return newest.id
        }

        return nil
    }

    /// Handles `__event_call__` `execute` events.
    /// Tries proven regex fast-paths first (instant, no WKWebView overhead).
    /// Falls back to ActionJSExecutor (hidden WKWebView) for unknown JS patterns.
    private func handleExecuteEvent(code: String) async -> ActionCallResponse {
        logger.info("🟡 [Execute] code length=\(code.count, privacy: .public)")

        // ── Fast path 1: server file download URL (/api/v1/files/{id}) ──────────────
        let serverBase = viewModel.serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filesUrlPattern = #"['"]((https?://[^\s'"]+/api/v1/files/[^\s'"]+|/api/v1/files/[^\s'"]+))['"]"#
        if let regex = try? NSRegularExpression(pattern: filesUrlPattern),
           let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
           let urlRange = Range(match.range(at: 1), in: code) {
            let urlStr = String(code[urlRange])
            let fullURL = urlStr.hasPrefix("/") ? "\(serverBase)\(urlStr)" : urlStr
            let parts = fullURL.split(separator: "/")
            if let filesIdx = parts.firstIndex(of: "files"), filesIdx + 1 < parts.count {
                let fileId = String(parts[filesIdx + 1])
                logger.info("🟡 [Execute] Fast-path 1: server file id=\(fileId, privacy: .public)")
                isDownloadingFile = true
                await downloadAndShareFile(fileId: fileId)
                isDownloadingFile = false
                return .bool(true)
            }
        }

        // Extract filename from JS for use in fast paths 2 & 3
        var fileName = "export.pdf"
        let filenamePatterns = [
            #"(?:fileName|filename|name)\s*=\s*['"]([^'"]+\.[a-zA-Z0-9]+)['"]"#,
            #"saveAs\([^,]+,\s*['"]([^'"]+\.[a-zA-Z0-9]+)['"]\)"#,
            #"download\s*=\s*['"]([^'"]+\.[a-zA-Z0-9]+)['"]"#,
        ]
        for pattern in filenamePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
               let fnRange = Range(match.range(at: 1), in: code) {
                fileName = String(code[fnRange])
                logger.info("🟡 [Execute] Extracted filename: \(fileName, privacy: .public)")
                break
            }
        }

        // ── Fast path 2: `const base64 = "..."` / `base64 = "..."` ──────────────────
        // Open WebUI PDF export embeds the file as a base64 variable in the execute JS.
        let base64VarPattern = #"(?:const\s+|let\s+|var\s+)?base64\s*=\s*['"]([A-Za-z0-9+/=\r\n]{20,})['"]"#
        if let regex = try? NSRegularExpression(pattern: base64VarPattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
           let b64Range = Range(match.range(at: 1), in: code) {
            let rawB64 = String(code[b64Range])
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            if let data = Data(base64Encoded: rawB64), !data.isEmpty {
                logger.info("✅ [Execute] Fast-path 2: base64 var → \(data.count, privacy: .public) bytes as \(fileName, privacy: .public)")
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try? data.write(to: tempFile)
                downloadedFileURL = tempFile
                return .bool(true)
            }
        }

        // ── Fast path 3: atob("...") call ────────────────────────────────────────────
        let atobPattern = #"atob\(['"]([A-Za-z0-9+/=]{20,})['"]\)"#
        if let regex = try? NSRegularExpression(pattern: atobPattern),
           let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
           let b64Range = Range(match.range(at: 1), in: code) {
            let b64 = String(code[b64Range])
            if let data = Data(base64Encoded: b64), !data.isEmpty {
                logger.info("✅ [Execute] Fast-path 3: atob → \(data.count, privacy: .public) bytes as \(fileName, privacy: .public)")
                let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try? data.write(to: tempFile)
                downloadedFileURL = tempFile
                return .bool(true)
            }
        }

        // ── Fallback: WKWebView execution (catches unknown patterns) ─────────────────
        // Skip scripts that are clearly browser-only (CDN imports, html2canvas, etc.)
        let isBrowserOnlyScript = code.contains("import(") || code.contains("html2canvas") || code.contains("cdn.jsdelivr")
        guard !isBrowserOnlyScript, let baseURL = URL(string: serverBase) else {
            logger.info("🟡 [Execute] Skipping browser-only or unparseable script, unblocking server")
            return .bool(true)
        }

        logger.info("🟡 [Execute] No regex match — delegating to ActionJSExecutor")
        isDownloadingFile = true
        let download = await ActionJSExecutor.shared.execute(code: code, baseURL: baseURL)
        isDownloadingFile = false

        if let download {
            logger.info("✅ [Execute] ActionJSExecutor captured: \(download.filename, privacy: .public) \(download.data.count, privacy: .public) bytes")
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(download.filename)
            try? download.data.write(to: tempFile)
            downloadedFileURL = tempFile
        } else {
            logger.warning("⚠️ [Execute] ActionJSExecutor returned nil (timeout or error)")
        }

        return .bool(true)
    }

    private func copyMessage(_ message: ChatMessage) {
        var clean = message.content
        if let re = try? NSRegularExpression(pattern: #"<details[^>]*>.*?</details>"#, options: [.dotMatchesLineSeparators]) {
            clean = re.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "")
        }
        clean = clean
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.sources.isEmpty {
            clean += "\n\nSources:"
            for (i, src) in message.sources.enumerated() {
                clean += "\n[\(i+1)] \(src.resolvedURL ?? src.title ?? "Source \(i+1)")"
            }
        }
        UIPasteboard.general.string = clean
        Haptics.notify(.success)
        withAnimation(MicroAnimation.gentle) { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(MicroAnimation.gentle) { showCopiedToast = false }
        }
    }

    // MARK: - Attachment Processing

private func processSelectedPhotos(_ items: [PhotosPickerItem]) async {
for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let image = UIImage(data: data)
                    let thumbnail = image.map { Image(uiImage: $0) }
                    // Downsample to ≤ 2 MP to stay under the API's 5 MB base64 limit
                    let resized = FileAttachmentService.downsampleForUpload(data: data, image: image)
                    let attachment = ChatAttachment(
                        type: .image, name: "Photo_\(Int(Date.now.timeIntervalSince1970)).jpg",
                        thumbnail: thumbnail, data: resized
                    )
                    viewModel.attachments.append(attachment)
                    // Start uploading immediately so it's ready by send time
                    viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
                }
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func processFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            viewModel.errorMessage = "Failed to read file."
            return
        }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        if isImage {
            // Downsample to ≤ 2 MP to stay under the API's 5 MB base64 limit
            let resized = FileAttachmentService.downsampleForUpload(data: data)
            let thumbnail: Image? = UIImage(data: resized).map { Image(uiImage: $0) }
            let attachment = ChatAttachment(
                type: .image, name: url.lastPathComponent,
                thumbnail: thumbnail, data: resized
            )
            viewModel.attachments.append(attachment)
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        } else {
            let attachment = ChatAttachment(
                type: .file, name: url.lastPathComponent,
                thumbnail: nil, data: data
            )
            viewModel.attachments.append(attachment)
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        }
    }

    private func processCameraImage(_ image: UIImage?) {
        guard let image else { return }
        // Downsample to ≤ 2 MP to stay under the API's 5 MB base64 limit
        let data = FileAttachmentService.downsampleForUpload(image: image)
        guard !data.isEmpty else { return }
        let attachment = ChatAttachment(
            type: .image, name: "Camera_\(Int(Date.now.timeIntervalSince1970)).jpg",
            thumbnail: Image(uiImage: image), data: data
        )
        viewModel.attachments.append(attachment)
        viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
    }

    private func processAudioFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            viewModel.errorMessage = "Failed to read audio file."
            return
        }
        let attachment = ChatAttachment(type: .audio, name: url.lastPathComponent, thumbnail: nil, data: data)
        viewModel.attachments.append(attachment)

        // Route to the user-selected transcription engine.
        // "device" and "server" are live-speech engines, not file transcription — skip ML for those.
        // Route based on the audio file transcription mode setting.
        // "server" (default): upload the audio file to the server via the files API —
        //   the server handles transcription/processing automatically (?process=true).
        //   No on-device work needed; the user can navigate away freely.
        // "device": use on-device Parakeet/Qwen3 ASR (existing behavior).
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        if audioFileMode == "server" {
            // Treat audio exactly like any other file attachment — upload immediately.
            // The server processes the audio via ?process=true and handles transcription.
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        } else {
            // On-device mode: delegate to ViewModel so the Task survives navigation.
            viewModel.transcribeAudioAttachment(attachmentId: attachment.id, audioData: data, fileName: url.lastPathComponent)
        }
    }

    /// Opens a file in an in-app QuickLook preview.
    /// Uses a local cache keyed by file ID so files that were just uploaded
    /// don't need to be re-downloaded from the server.
    private func previewFileInApp(fileId: String, fileName: String) async {
        // Check cache first — if we already have this file locally, show it instantly
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let cachedFile = cacheDir.appendingPathComponent("\(fileId)_\(fileName)")
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            previewFileURL = cachedFile
            return
        }

        // Not cached — download from server
        guard let apiClient = dependencies.apiClient else { return }
        withAnimation { isDownloadingFile = true }

        do {
            let (data, _) = try await apiClient.getFileContent(id: fileId)
            try data.write(to: cachedFile)
            withAnimation { isDownloadingFile = false }
            previewFileURL = cachedFile
        } catch {
            withAnimation { isDownloadingFile = false }
            downloadErrorMessage = "Failed to load file: \(error.localizedDescription)"
            showDownloadError = true
        }
    }

    /// Downloads a file from the server using the authenticated API client,
    /// saves it to a temp directory, and presents the iOS share sheet.
    private func downloadAndShareFile(fileId: String) async {
        guard let apiClient = dependencies.apiClient else {
            downloadErrorMessage = "Not connected to server."
            showDownloadError = true
            return
        }

        withAnimation { isDownloadingFile = true }

        do {
            let (data, contentType) = try await apiClient.getFileContent(id: fileId)

            // Try to get the file name from file info
            var fileName = "download"
            if let info = try? await apiClient.getFileInfo(id: fileId) {
                if let meta = info["meta"] as? [String: Any], let name = meta["name"] as? String {
                    fileName = name
                } else if let name = info["filename"] as? String {
                    fileName = name
                } else if let name = info["name"] as? String {
                    fileName = name
                }
            }

            // If no extension, try to infer from content type
            if (fileName as NSString).pathExtension.isEmpty {
                let ext: String
                switch contentType {
                case let ct where ct.contains("pdf"): ext = "pdf"
                case let ct where ct.contains("word") || ct.contains("docx"): ext = "docx"
                case let ct where ct.contains("spreadsheet") || ct.contains("xlsx"): ext = "xlsx"
                case let ct where ct.contains("presentation") || ct.contains("pptx"): ext = "pptx"
                case let ct where ct.contains("plain"): ext = "txt"
                case let ct where ct.contains("json"): ext = "json"
                case let ct where ct.contains("png"): ext = "png"
                case let ct where ct.contains("jpeg") || ct.contains("jpg"): ext = "jpg"
                default: ext = "bin"
                }
                fileName = "\(fileName).\(ext)"
            }

            // Save to temp directory
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(fileName)
            try data.write(to: tempFile)

            withAnimation { isDownloadingFile = false }

            // Present share sheet
            downloadedFileURL = tempFile

        } catch {
            withAnimation { isDownloadingFile = false }
            downloadErrorMessage = "Failed to download: \(error.localizedDescription)"
            showDownloadError = true
        }
    }

    /// Downloads any server-hosted file via an authenticated raw GET request,
    /// saves it to a temp directory, and presents the iOS share sheet.
    /// Used for non-/api/v1/files/ server URLs (e.g. /cache/files/…, /uploads/…).
    private func downloadAndShareArbitraryURL(_ url: URL) async {
        guard let apiClient = dependencies.apiClient else {
            downloadErrorMessage = "Not connected to server."
            showDownloadError = true
            return
        }
        withAnimation { isDownloadingFile = true }
        do {
            let (data, response) = try await apiClient.network.requestRawAbsoluteURL(url)
            var fileName = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            if (fileName as NSString).pathExtension.isEmpty {
                let ext: String
                switch contentType {
                case let ct where ct.contains("pdf"): ext = "pdf"
                case let ct where ct.contains("pptx") || ct.contains("presentation"): ext = "pptx"
                case let ct where ct.contains("docx") || ct.contains("word"): ext = "docx"
                case let ct where ct.contains("xlsx") || ct.contains("spreadsheet"): ext = "xlsx"
                case let ct where ct.contains("plain"): ext = "txt"
                case let ct where ct.contains("json"): ext = "json"
                case let ct where ct.contains("png"): ext = "png"
                case let ct where ct.contains("jpeg") || ct.contains("jpg"): ext = "jpg"
                default: ext = "bin"
                }
                fileName = "\(fileName).\(ext)"
            }
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: tempFile)
            withAnimation { isDownloadingFile = false }
            downloadedFileURL = tempFile
        } catch {
            withAnimation { isDownloadingFile = false }
            downloadErrorMessage = "Failed to download: \(error.localizedDescription)"
            showDownloadError = true
        }
    }

    // MARK: - #URL Suggestion Pill

    /// Floating pill shown when the user types `#https://...` in the input field.
    /// Tapping the pill triggers the web scraping pipeline and strips the `#URL`
    /// token from the input text. Dismissing (deleting the `#`) hides the pill
    /// and leaves the text as-is.
    private func webURLSuggestionPill(url: String) -> some View {
        Button {
            // 1. Strip the #URL token from the input text
            let token = "#\(url)"
            if let range = viewModel.inputText.range(of: token) {
                viewModel.inputText.removeSubrange(range)
                viewModel.inputText = viewModel.inputText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // 2. Trigger the web scraping → upload → file attachment pipeline
            viewModel.processWebURL(urlString: url)
            // 3. Clear the suggestion state
            withAnimation(.easeOut(duration: 0.15)) {
                detectedWebURL = nil
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "globe")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
                Text(url)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.85 : 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.brandPrimary.opacity(0.3), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.sm)
    }

    private func processWebURL() {
        let urlString = webURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }
        viewModel.processWebURL(urlString: urlString)
        webURLInput = ""
    }
}

// MARK: - Isolated Streaming Status (Observation Isolation)

/// Isolates streaming status reads into its own view body so that
/// `StreamingContentStore` property accesses (streamingStatusHistory,
/// streamingContent, isActive) are attributed to THIS struct's body —
/// not to ChatDetailView.body. Without this, every token arrival would
/// re-evaluate the entire 800+ line ChatDetailView.
private struct IsolatedStreamingStatus: View {
    let streamingStore: StreamingContentStore
    let message: ChatMessage
    /// Bug 13: pre-computed in the parent so non-active instances never read
    /// streamingStore properties in body → zero observation subscription overhead.
    let isActiveStore: Bool

    var body: some View {
        let effectiveStatusHistory = isActiveStore
            ? streamingStore.streamingStatusHistory
            : message.statusHistory
        // Single source of truth: only the live streaming store gates streaming UI.
        // message.isStreaming is a server/persistence flag — using it here created
        // a second "streaming" path when navigating back to a chat mid-stream,
        // showing stale/partial statusHistory from the server instead of the
        // live store's real-time history.
        let effectiveIsStreaming = isActiveStore

        if !effectiveStatusHistory.isEmpty {
            let visible = effectiveStatusHistory.filter { $0.hidden != true }
            if !visible.isEmpty {
                let hasPending = visible.contains { $0.done != true }
                StreamingStatusView(
                    statusHistory: effectiveStatusHistory,
                    isStreaming: effectiveIsStreaming && hasPending
                )
                .padding(.bottom, Spacing.xs)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Isolated Assistant Message (Observation Isolation)

/// Isolates ALL streaming store reads for assistant message content into
/// its own view body. This is the single most impactful performance fix:
///
/// **Before:** `streamingStore.streamingContent` was read inside
/// `ChatDetailView.messageContent()` which is called from `body`.
/// Swift's @Observable macro attributes that read to ChatDetailView,
/// causing the ENTIRE view (800+ lines, all messages, toolbar, input)
/// to re-evaluate on every token (~15-20x/sec).
///
/// **After:** Only this small struct re-evaluates per token. All other
/// message views, the toolbar, input field, and scroll infrastructure
/// remain completely inert during streaming.
///
/// ## Fixed-Height Streaming Container (VStack Re-layout Fix)
/// During active streaming, the content is wrapped in a fixed-height
/// (400pt) container with internal scrolling. This prevents the parent
/// VStack from re-measuring ALL sibling message rows when the streaming
/// content grows in height. When streaming completes, the fixed height
/// is removed and full content renders at its natural height.
private struct IsolatedAssistantMessage: View {
    let streamingStore: StreamingContentStore
    let message: ChatMessage
    let activeVersionIndex: Int
    /// When set, overrides all other content resolution (used when showing an older user message edit version).
    var contentOverride: String? = nil
    let serverBaseURL: String
    /// Auth token passed down to Rich UI embed webviews for localStorage injection.
    var authToken: String? = nil
    /// APIClient for rendering inline images via AuthenticatedImageView.
    var apiClient: APIClient? = nil

    @AppStorage("renderAssistantMarkdown") private var renderAssistantMarkdown: Bool = true

    var body: some View {
        let isActivelyStreaming = streamingStore.streamingMessageId == message.id
            && streamingStore.isActive

        let vIdx = activeVersionIndex
        let rawContent: String = {
            if isActivelyStreaming { return streamingStore.displayContent }
            if let override = contentOverride { return override }
            if vIdx >= 0 && vIdx < message.versions.count { return message.versions[vIdx].content }
            return message.content
        }()

        // Use streaming sources if actively streaming.
        // After streaming finishes, message.sources may not have propagated yet —
        // fall back to the store's sources (they persist until beginStreaming() is
        // called for the next message) so citations render immediately on completion.
        let effectiveSources: [ChatSourceReference] = {
            if isActivelyStreaming { return streamingStore.streamingSources }
            if !message.sources.isEmpty { return message.sources }
            // Brief post-stream window: message not yet committed — use last streaming sources
            return streamingStore.streamingSources
        }()

        let preferDomain = UserDefaults.standard.object(forKey: "citationShowDomain") as? Bool ?? true

        let displayContent: String = {
            if isActivelyStreaming { return rawContent }
            let resolved = Self.resolveRelativeURLs(rawContent, baseURL: serverBaseURL)
            return Self.preprocessCitations(resolved, sources: effectiveSources, preferDomain: preferDomain)
        }()

        // Single source of truth: ONLY the live StreamingPipeline gates streaming
        // display. `message.isStreaming` is a server/persistence flag and must NOT
        // be used as a display-path selector — doing so creates a second competing
        // render path when the user navigates away and back mid-stream.
        let effectiveIsStreaming = isActivelyStreaming

        if effectiveIsStreaming && rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Wrap in HStack+Spacer to pin the indicator to the leading edge.
            // Without this, the infinity-width assistant content frame can
            // misplace or stretch the fixed view.
            // minHeight: 44 ensures the new message row has enough natural height
            // from the first frame so the minHeight-VStack scroll anchor doesn't
            // position the indicator above/overlapping the row header.
            HStack(spacing: 0) {
                BlinkingCursorIndicator()
                Spacer()
            }
            .frame(minHeight: 44)
        } else {
            // ── Unified stable render path ────────────────────────────────────
            //
            // AssistantMessageContent is ALWAYS child-0 of the outer VStack.
            // This gives it a stable SwiftUI view identity across every render
            // mode — streaming split, pure-prose split, and the final merged
            // state — so SwiftUI diffs the content in place rather than tearing
            // down the subtree when streaming ends.  The previous 3-way
            // if/else-if/else produced different top-level view types (VStack vs
            // bare AssistantMessageContent), causing a one-frame blank flash and
            // a height re-rounding that nudged the scroll position.
            //
            // Split-render modes: use frozenBoundary or pureFrozenProse as the
            // primary content (stable prefix, ParseCache hits every frame) and
            // append the tiny live tail as a transient second child.  When
            // streaming ends both useSplit* flags go false, the tail child is
            // simply removed, and child-0's content transitions to the full
            // displayContent — a pure prop update with no structural change.

            // useSplitTool: frozen tool/reasoning prefix + live tail.
            let useSplitTool = isActivelyStreaming && streamingStore.frozenBoundary > 0
            // useSplitProse: pure-prose frozen prefix + live prose tail.
            let useSplitProse = isActivelyStreaming && !streamingStore.pureFrozenProse.isEmpty

            // Primary content: stable frozen prefix during streaming, full
            // displayContent otherwise.  Always fed to AssistantMessageContent.
            let primaryContent: String = {
                if useSplitTool  { return streamingStore.frozenContent }
                if useSplitProse { return streamingStore.pureFrozenProse }
                return displayContent
            }()
            // Primary is never marked streaming — the live tail carries that role.
            // For short / non-split messages the regular effectiveIsStreaming applies.
            let primaryIsStreaming = !(useSplitTool || useSplitProse) && effectiveIsStreaming

            if renderAssistantMarkdown {
                VStack(alignment: .leading, spacing: 0) {
                    AssistantMessageContent(
                        content: primaryContent,
                        isStreaming: primaryIsStreaming,
                        messageEmbeds: message.embeds,
                        authToken: authToken,
                        serverBaseURL: serverBaseURL,
                        apiClient: apiClient
                    )
                    // ── Live tail: transient streaming-only second child ───────
                    // Appended during split-render; removed atomically when
                    // streaming ends.  Child-0 identity is unaffected.
                    if useSplitTool {
                        let liveTailStr = streamingStore.liveTail
                        // An unclosed <details> block must disable streaming so
                        // the raw HTML tag text doesn't flash before the block
                        // completes.
                        // A VIZ block must still stream so InlineVisualizerView
                        // receives isStreaming: true and uses its reconcileContent
                        // path instead of finalizeContent (which fails on partial HTML).
                        // NOTE: We no longer disable streaming for unclosed <details> blocks.
                        // The pipeline freeze was removed — ToolCallParser.findDetailsBlocks()
                        // skips incomplete blocks, so partial <details> in the live tail
                        // are invisible to the user and always safe to stream through.
                        let liveTailHasViz = liveTailStr.contains("@@@VIZ-START")

                        if !liveTailStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if !liveTailHasViz && !streamingStore.liveTailFrozenProse.isEmpty {
                                // Further split at prose boundary within the live tail.
                                // The live segment starts on a new paragraph boundary,
                                // so we add 16pt to match the CommonMark paragraphSpacing
                                // that CoreText drops on the last paragraph of a view.
                                StreamingMarkdownView(content: streamingStore.liveTailFrozenProse, isStreaming: false)
                                if !streamingStore.liveTailLiveProse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    StreamingMarkdownView(content: streamingStore.liveTailLiveProse, isStreaming: true)
                                        .padding(.top, 16)
                                }
                            } else {
                                // Stream live tail — VIZ content and plain text both stream.
                                StreamingMarkdownView(content: liveTailStr, isStreaming: true)
                            }
                        }
                    } else if useSplitProse {
                        // Pure-prose live tail.  No tool/reasoning blocks.
                        // Pipeline pre-slices at paragraph boundary; pureFrozenProse
                        // is stable until the boundary advances (~every 400 chars).
                        if !streamingStore.pureLiveProse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // The live prose starts on a new paragraph boundary.
                            // Add 16pt top padding to match CommonMark's paragraphSpacing
                            // (which CoreText drops on the final paragraph of a view).
                            // Without this, the two segments render flush against each other.
                            StreamingMarkdownView(content: streamingStore.pureLiveProse, isStreaming: true)
                                .padding(.top, 16)
                        }
                    }
                    // No tail added for non-split / final messages — VStack contains
                    // only AssistantMessageContent, identical to the old fallback.
                }
                .transaction { $0.animation = nil }
            } else {
                // Plain text (markdown rendering disabled).
                // All states use the same Text view type — no structural change.
                Text(isActivelyStreaming ? streamingStore.displayContent : displayContent)
                    .scaledFont(size: 15, context: .content)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transaction { $0.animation = nil }
            }
        }
    }

    // MARK: - Static Preprocessing (no ChatDetailView dependency)

    /// Strips all `<details type="tool_calls" ...>...</details>` blocks from `text`.
    ///
    /// The Open WebUI server embeds a 100KB+ HTML blob in the `embeds` attribute of
    /// these blocks (the web UI's iframe-based visualization renderer). On iOS we don't
    /// use those embeds — we render natively — so processing this giant string on every
    /// streaming frame is pure waste and causes UI lag.
    ///
    /// Critically, the embeds blob contains a fake `@@@VIZ-START` marker that was
    /// triggering false-positive VIZ detection and causing the wrong render branch to
    /// be selected during streaming. Stripping the entire block eliminates both problems.
    ///
    /// This runs in a single O(n) scan and avoids any regex overhead.
    static func stripToolCallDetails(_ text: String) -> String {
        let openTag = "<details type=\"tool_calls\""
        let closeTag = "</details>"
        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let open = result.range(of: openTag, range: searchStart..<result.endIndex) {
            if let close = result.range(of: closeTag, range: open.lowerBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
                searchStart = open.lowerBound
            } else {
                // Unclosed block — strip from the open tag to the end of string
                result = String(result[..<open.lowerBound])
                break
            }
        }
        return result
    }

    static func preprocessCitations(_ content: String, sources: [ChatSourceReference], preferDomain: Bool = true) -> String {
        guard !sources.isEmpty else { return content }

        // --- Pass 1: expand [1, 2, 3] → [1][2][3] so the single-number pass handles them ---
        var expanded = content
        let multiPattern = #"\[(\d+(?:\s*,\s*\d+)+)\](?!\()"#
        if let multiRegex = try? NSRegularExpression(pattern: multiPattern) {
            let nsExpanded = expanded as NSString
            let multiMatches = multiRegex.matches(in: expanded, range: NSRange(location: 0, length: nsExpanded.length))
            // Process in reverse to preserve indices
            for match in multiMatches.reversed() {
                guard let innerRange = Range(match.range(at: 1), in: expanded) else { continue }
                let numbers = expanded[innerRange]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let replacement = numbers.map { "[\($0)]" }.joined()
                if let fullRange = Range(match.range, in: expanded) {
                    expanded.replaceSubrange(fullRange, with: replacement)
                }
            }
        }

        // --- Pass 2: replace each [N] with a pill markdown link ---
        let pattern = #"\[(\d+)\](?!\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return expanded }
        var result = ""
        var searchStart = expanded.startIndex
        let nsContent = expanded as NSString
        let matches = regex.matches(in: expanded, range: NSRange(location: 0, length: nsContent.length))
        for match in matches {
            guard let fullRange = Range(match.range, in: expanded),
                  let numberRange = Range(match.range(at: 1), in: expanded) else { continue }
            guard let index = Int(expanded[numberRange]) else { continue }
            result += expanded[searchStart..<fullRange.lowerBound]
            let sourceIdx = index - 1
            if sourceIdx >= 0 && sourceIdx < sources.count,
               let url = sources[sourceIdx].resolvedURL, !url.isEmpty {
                let label = sources[sourceIdx].displayLabel(preferDomain: preferDomain) ?? "\(index)"
                result += " [\(label)](\(url)#cite) "
            } else {
                result += expanded[fullRange]
            }
            searchStart = fullRange.upperBound
        }
        result += expanded[searchStart...]
        return result
    }

    // Keep old signature body intact but redirect to the new implementation above
    private static func _preprocessCitationsOld(_ content: String, sources: [ChatSourceReference], preferDomain: Bool = true) -> String {
        guard !sources.isEmpty else { return content }
        let pattern = #"\[(\d+)\](?!\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        var result = ""
        var searchStart = content.startIndex
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        for match in matches {
            guard let fullRange = Range(match.range, in: content),
                  let numberRange = Range(match.range(at: 1), in: content) else { continue }
            guard let index = Int(content[numberRange]) else { continue }
            result += content[searchStart..<fullRange.lowerBound]
            let sourceIdx = index - 1
            if sourceIdx >= 0 && sourceIdx < sources.count,
               let url = sources[sourceIdx].resolvedURL, !url.isEmpty {
                let label = sources[sourceIdx].displayLabel(preferDomain: preferDomain) ?? "\(index)"
                // #cite suffix triggers small pill badge rendering in MarkdownView
                result += " [\(label)](\(url)#cite) "
            } else {
                result += content[fullRange]
            }
            searchStart = fullRange.upperBound
        }
        result += content[searchStart...]
        return result
    }

    static func resolveRelativeURLs(_ content: String, baseURL: String) -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return content }
        // Match any markdown link target that starts with a single "/" (server-relative path)
        // but NOT "//" (protocol-relative) and NOT already-absolute URLs (containing "://").
        let pattern = #"(\]\()(\/(?!\/)[^\s\)]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        guard !matches.isEmpty else { return content }
        var result = ""
        var currentIndex = 0
        for match in matches {
            let fullRange = match.range
            if fullRange.location > currentIndex {
                result += nsContent.substring(with: NSRange(location: currentIndex, length: fullRange.location - currentIndex))
            }
            let prefixRange = match.range(at: 1)
            let prefix = nsContent.substring(with: prefixRange)
            let pathRange = match.range(at: 2)
            let relativePath = nsContent.substring(with: pathRange)
            // Skip if the path already contains "://" (already absolute, shouldn't happen but be safe)
            guard !relativePath.contains("://") else {
                result += "\(prefix)\(relativePath)"
                currentIndex = fullRange.location + fullRange.length
                continue
            }
            result += "\(prefix)\(base)\(relativePath)"
            currentIndex = fullRange.location + fullRange.length
        }
        if currentIndex < nsContent.length {
            result += nsContent.substring(from: currentIndex)
        }
        return result
    }

}

// MARK: - Superscript Number Helper

/// Converts an integer to its Unicode superscript representation.
/// e.g., 1 → "¹", 12 → "¹²", 9 → "⁹"
private func superscriptNumber(_ n: Int) -> String {
    let superDigits: [Character] = ["\u{2070}", "\u{00B9}", "\u{00B2}", "\u{00B3}", "\u{2074}", "\u{2075}", "\u{2076}", "\u{2077}", "\u{2078}", "\u{2079}"]
    return String(String(n).compactMap { c in
        guard let digit = c.wholeNumberValue, digit < superDigits.count else { return nil }
        return superDigits[digit]
    })
}

// MARK: - User Message Content View

/// Renders a user message, parsing `<$slug|slug>` skill tags as inline
/// styled chips and displaying the surrounding plain text normally.
///
/// The web UI stores skill references in message content as `<$slug|slug>`
/// (e.g. `<$sde|sde>`). This view splits the content into alternating
/// plain-text and skill-tag segments, then renders each chip with the
/// same accent styling used in the input field's skill chips.
struct UserMessageContentView: View {
    let content: String
    @Environment(\.theme) private var theme
    @AppStorage("renderUserMarkdown") private var renderUserMarkdown: Bool = false

    /// Parses `content` into alternating text / skill segments.
    /// Pattern: `<$slug|slug>` — captures the slug before `|`.
    private var segments: [UserMessageContentView_SegmentType] {
        let pattern = #"<\$([^|>]+)\|[^>]+>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(content)]
        }
        var result: [UserMessageContentView_SegmentType] = []
        var searchStart = content.startIndex
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        for match in matches {
            guard let fullRange = Range(match.range, in: content),
                  let slugRange = Range(match.range(at: 1), in: content) else { continue }
            let prefix = String(content[searchStart..<fullRange.lowerBound])
            if !prefix.isEmpty { result.append(.text(prefix)) }
            result.append(.skill(slug: String(content[slugRange])))
            searchStart = fullRange.upperBound
        }
        let suffix = String(content[searchStart...])
        if !suffix.isEmpty { result.append(.text(suffix)) }
        return result.isEmpty ? [.text(content)] : result
    }

    var body: some View {
        if renderUserMarkdown {
            let segs = segments
            let hasChips = segs.contains { if case .skill = $0 { return true }; return false }
            if !hasChips {
                Text(content)
                    .scaledFont(size: 15, context: .content)
            } else {
                SkillTaggedTextView(segments: segs)
            }
        } else {
            Text(content)
                .scaledFont(size: 15, context: .content)
        }
    }
}

/// Renders a mix of text and skill chips in a flowing layout.
/// Uses `Layout` to flow content left-to-right, wrapping as needed.
private struct SkillTaggedTextView: View {
    let segments: [UserMessageContentView_Segment]
    @Environment(\.theme) private var theme

    var body: some View {
        // Build one or more lines. We use a simple VStack + HStack wrap
        // by splitting on newlines first, then rendering each line's chips inline.
        let lines = buildLines()
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                FlowRow(segments: line, theme: theme)
            }
        }
    }

    /// Splits segments into lines (splitting on newlines in text segments).
    private func buildLines() -> [[UserMessageContentView_Segment]] {
        var lines: [[UserMessageContentView_Segment]] = [[]]
        for seg in segments {
            switch seg {
            case .skill:
                lines[lines.count - 1].append(seg)
            case .text(let str):
                let parts = str.components(separatedBy: "\n")
                for (i, part) in parts.enumerated() {
                    if i > 0 { lines.append([]) }
                    if !part.isEmpty {
                        lines[lines.count - 1].append(.text(part))
                    }
                }
            }
        }
        return lines.filter { !$0.isEmpty }
    }
}

// Type alias to share the enum with SkillTaggedTextView
private typealias UserMessageContentView_Segment = UserMessageContentView_SegmentType

enum UserMessageContentView_SegmentType {
    case text(String)
    case skill(slug: String)
}

/// A single row of mixed text + skill chips, wrapping as needed.
private struct FlowRow: View {
    let segments: [UserMessageContentView_Segment]
    let theme: AppTheme

    var body: some View {
        // Concatenate text and chip views in an HStack that wraps.
        // We use ViewThatFits + LazyHStack fallback for wrapping behavior.
        // For simplicity, render as a single HStack (most messages are short).
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let str):
                    Text(str)
                        .scaledFont(size: 15, context: .content)
                        .fixedSize(horizontal: false, vertical: true)
                case .skill(let slug):
                    SkillChipView(slug: slug, theme: theme)
                }
            }
        }
    }
}

/// A single skill chip rendered in the user bubble.
/// Styled as a small rounded badge matching the web UI's `$slug` pill.
private struct SkillChipView: View {
    let slug: String
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 3) {
            Text("$")
                .scaledFont(size: 12, weight: .bold)
            Text(slug)
                .scaledFont(size: 12, weight: .semibold)
        }
        .foregroundStyle(theme.chatBubbleUserText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(theme.chatBubbleUserText.opacity(0.18))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(theme.chatBubbleUserText.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Prompt Card Button Style

struct PromptCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Document Picker (UIKit Wrapper)

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .pdf, .plainText, .text, .json, .image, .png, .jpeg,
            .spreadsheet, .presentation, .audio, .mp3, .wav, .aiff, .data
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - Camera Picker (UIKit Wrapper)

struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, dismiss: dismiss) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        let dismiss: DismissAction
        init(onCapture: @escaping (UIImage?) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture; self.dismiss = dismiss
        }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
            dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}

// MARK: - Share Sheet (UIKit Wrapper)

/// Wraps UIActivityViewController for presenting the iOS share sheet.
struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - ScrollView Horizontal Lock

/// A zero-size `UIViewRepresentable` that finds the enclosing `UIScrollView`
/// and installs a KVO observer on `contentOffset` to continuously snap
/// `contentOffset.x` back to 0. This is the nuclear option for preventing
/// horizontal panning — no matter what triggers it (animated insertions,
/// transient layout overflow, MarkdownView intrinsic size, etc.), the
/// horizontal offset is immediately corrected on the very next frame.
///
/// Also sets `alwaysBounceHorizontal = false` and `isDirectionalLockEnabled = true`
/// as static configuration, and uses a pan gesture recognizer delegate to
/// prevent horizontal pan recognition entirely.
private struct ScrollViewHorizontalLock: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Bug 14: guard with isAttachPending so a rapid second updateUIView call
        // (which also passes the nil-check) cannot schedule a second attach() and
        // install duplicate KVO observers + gesture recognizers.
        if context.coordinator.observedScrollView == nil && !context.coordinator.isAttachPending {
            context.coordinator.isAttachPending = true
            DispatchQueue.main.async {
                context.coordinator.attach(to: uiView)
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var observation: NSKeyValueObservation?
        weak var observedScrollView: UIScrollView?
        private var panBlocker: UIPanGestureRecognizer?
        /// Bug 14: set to true synchronously in updateUIView before the async
        /// dispatch so a concurrent updateUIView cannot schedule a second attach().
        var isAttachPending: Bool = false

        func attach(to view: UIView) {
            isAttachPending = false
            guard observedScrollView == nil else { return }
            var current: UIView? = view.superview
            while let sv = current {
                if let scrollView = sv as? UIScrollView {
                    observedScrollView = scrollView

                    // Static configuration
                    scrollView.alwaysBounceHorizontal = false
                    scrollView.showsHorizontalScrollIndicator = false
                    scrollView.isDirectionalLockEnabled = true

                    // iOS 26: disable the Liquid Glass scroll-edge effect (frosty blur
                    // that appears at the top when content scrolls under the nav bar).
                    // iOS 26 "Liquid Glass" frosty blur at scroll edges.
                    // edgeEffectEnabled is not yet in the public SDK headers,
                    // so we use KVC to set it at runtime.
                    scrollView.setValue(false, forKey: "edgeEffectEnabled")

                    // Bug 3: KVO snaps contentOffset.x to 0.
                    // Threshold raised from 0.5 pt to 2 pt to avoid false positives
                    // from floating-point rounding during programmatic scroll animations.
                    observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, change in
                        guard self != nil, let offset = change.newValue else { return }
                        if abs(offset.x) > 2 {
                            sv.contentOffset = CGPoint(x: 0, y: offset.y)
                        }
                    }

                    // Add a pan gesture recognizer that blocks horizontal panning
                    let blocker = UIPanGestureRecognizer(target: nil, action: nil)
                    blocker.delegate = self
                    blocker.cancelsTouchesInView = false
                    scrollView.addGestureRecognizer(blocker)
                    panBlocker = blocker

                    break
                }
                current = sv.superview
            }
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            if let blocker = panBlocker, let sv = observedScrollView {
                sv.removeGestureRecognizer(blocker)
            }
            panBlocker = nil
            observedScrollView = nil
        }

        // MARK: UIGestureRecognizerDelegate

        /// Allow our blocker to recognize simultaneously with all other gestures
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        /// Block any pan gesture that is primarily horizontal
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            // Only block if it's our custom blocker AND the pan is horizontal
            if pan === panBlocker {
                return false // never let our blocker actually begin
            }
            return true
        }
    }
}

// MARK: - Action Event Modifiers (Type-Checker Relief)

/// Extracted into a View extension to reduce the expression complexity of
/// ChatDetailView.body. Applying these three modifiers inline in body
/// pushed the expression past the Swift type-checker limit.
private extension View {
    func applyActionEventModifiers(
        actionInputRequest: Binding<ActionInputRequest?>,
        actionConfirmRequest: Binding<ActionConfirmRequest?>,
        actionNotificationToast: Binding<String?>,
        actionCallContinuation: Binding<CheckedContinuation<ActionCallResponse, Never>?>,
        actionInputText: Binding<String>
    ) -> some View {
        self
            // MARK: __event_call__ — input dialog (presented as a sheet for reliability)
            .sheet(isPresented: Binding(
                get: { actionInputRequest.wrappedValue != nil },
                set: { if !$0 { } }
            )) {
                ActionInputSheet(
                    request: actionInputRequest.wrappedValue!,
                    text: actionInputText,
                    onConfirm: {
                        actionCallContinuation.wrappedValue?.resume(returning: .string(actionInputText.wrappedValue))
                        actionCallContinuation.wrappedValue = nil
                        actionInputRequest.wrappedValue = nil
                        actionInputText.wrappedValue = ""
                    },
                    onCancel: {
                        actionCallContinuation.wrappedValue?.resume(returning: .cancelled)
                        actionCallContinuation.wrappedValue = nil
                        actionInputRequest.wrappedValue = nil
                        actionInputText.wrappedValue = ""
                    }
                )
                .presentationDetents([.height(240)])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
            }
            // MARK: __event_call__ — confirmation dialog
            .confirmationDialog(
                actionConfirmRequest.wrappedValue?.title ?? "Confirm",
                isPresented: Binding(
                    get: { actionConfirmRequest.wrappedValue != nil },
                    set: { if !$0 { } }
                ),
                titleVisibility: .visible
            ) {
                Button("Confirm") {
                    actionCallContinuation.wrappedValue?.resume(returning: .bool(true))
                    actionCallContinuation.wrappedValue = nil
                    actionConfirmRequest.wrappedValue = nil
                }
                Button("Cancel", role: .cancel) {
                    actionCallContinuation.wrappedValue?.resume(returning: .bool(false))
                    actionCallContinuation.wrappedValue = nil
                    actionConfirmRequest.wrappedValue = nil
                }
            } message: {
                if let req = actionConfirmRequest.wrappedValue { Text(req.message) }
            }
            // MARK: __event_emitter__ — notification toast
            .overlay(alignment: .top) {
                if let toastMsg = actionNotificationToast.wrappedValue {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill").font(.system(size: 11, weight: .medium))
                        Text(toastMsg).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color(.systemBackground))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.label).opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.top, 14 + 44) // clear navigation bar
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Delete Chat Confirmation (Type-Checker Relief)

private extension View {
    func applyDeleteChatConfirmation(
        isPresented: Binding<Bool>,
        onDelete: @escaping () -> Void
    ) -> some View {
        self.confirmationDialog(
            "Delete this chat?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This conversation will be permanently deleted.")
        }
    }
}

// MARK: - Widget & Picker Notification Handlers (Type-Checker Relief)

/// Extracted into a View extension to reduce the expression complexity of
/// ChatDetailView.body, which was hitting the Swift type-checker limit.
private extension View {
    func applyWidgetAndPickerHandlers(
        showCameraPicker: Binding<Bool>,
        showPhotosPicker: Binding<Bool>,
        showFilePicker: Binding<Bool>,
        selectedPhotos: Binding<[PhotosPickerItem]>,
        codePreviewCode: Binding<String?>,
        codePreviewLanguage: Binding<String>,
        onDismissOverlays: @escaping () -> Void
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .markdownCodePreview)) { notification in
                if let code = notification.userInfo?["code"] as? String {
                    codePreviewLanguage.wrappedValue = notification.userInfo?["language"] as? String ?? ""
                    codePreviewCode.wrappedValue = code
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIDismissOverlays)) { _ in
                onDismissOverlays()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUICameraChat)) { _ in
                showCameraPicker.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIPhotosChat)) { _ in
                showPhotosPicker.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIFileChat)) { _ in
                showFilePicker.wrappedValue = true
            }
            .photosPicker(
                isPresented: showPhotosPicker,
                selection: selectedPhotos,
                maxSelectionCount: 5,
                matching: .images,
                photoLibrary: .shared()
            )
            .sheet(item: codePreviewCode) { code in
                FullCodeView(code: code, language: codePreviewLanguage.wrappedValue)
            }
    }
}

// MARK: - Share Extension Handlers (Type-Checker Relief)

/// Handles plain-text pre-fill, web-scraping URL pipeline, model override,
/// and auto-send from the Share Extension and URL scheme deep-links.
/// Extracted from body so the Swift type-checker doesn't have to resolve
/// these `.onChange` closures inline.
private extension View {
    func applyShareExtensionHandlers(
        dependencies: AppDependencyContainer,
        viewModel: ChatViewModel
    ) -> some View {
        self
            // --- Plain-text pre-fill (Share Extension + openui://new-chat?prompt=) ---
            .onChange(of: dependencies.pendingIncomingTextVersion) { _, _ in
                if let text = dependencies.pendingIncomingText, !text.isEmpty {
                    viewModel.inputText = text
                    dependencies.pendingIncomingText = nil
                }
            }
            // --- Web-scraping URL pipeline (Share Extension) ---
            .onChange(of: dependencies.pendingIncomingWebURLsVersion) { _, _ in
                let urls = dependencies.pendingIncomingWebURLs
                if !urls.isEmpty {
                    dependencies.pendingIncomingWebURLs = []
                    for urlString in urls {
                        viewModel.processWebURL(urlString: urlString)
                    }
                }
            }
            // --- Model override (openui://new-chat?model=) ---
            // Only applied on new chats (initialConversationId == nil) so the URL
            // scheme can't silently hijack an existing conversation's model.
            .onChange(of: dependencies.pendingIncomingModelVersion) { _, _ in
                if let modelId = dependencies.pendingIncomingModelId, !modelId.isEmpty {
                    dependencies.pendingIncomingModelId = nil
                    // Validate against the available models list; fall back silently
                    // if the requested model doesn't exist on this server.
                    if viewModel.availableModels.contains(where: { $0.id == modelId }) {
                        viewModel.selectedModelId = modelId
                    }
                    // If models haven't loaded yet, wait for them and retry once.
                    else if viewModel.availableModels.isEmpty {
                        Task { @MainActor in
                            // Give the model list up to 3 s to populate, then apply.
                            for _ in 0..<30 {
                                try? await Task.sleep(for: .milliseconds(100))
                                if viewModel.availableModels.contains(where: { $0.id == modelId }) {
                                    viewModel.selectedModelId = modelId
                                    break
                                }
                            }
                        }
                    }
                }
            }
            // --- Auto-send (openui://new-chat?send=true) ---
            // Fires after `pendingIncomingTextVersion` has already pre-filled the input.
            // A short delay ensures the input text is committed before sendMessage() reads it.
            .onChange(of: dependencies.pendingAutoSendVersion) { _, _ in
                guard dependencies.pendingAutoSend else { return }
                dependencies.pendingAutoSend = false
                // Only send if there is actually something to send.
                guard !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                // Brief delay so the text field renders the pre-fill before sending.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    Task { await viewModel.sendMessage() }
                }
            }
    }
}

// MARK: - Link Tap & vizSendPrompt Handlers (Type-Checker Relief)

/// Handles `.markdownLinkTapped` (authenticated file download) and `.vizSendPrompt`
/// (InlineVisualizerView prompt bridge). Extracted from body so the Swift type-checker
/// doesn't have to resolve these closures inline.
private extension View {
    func applyLinkAndPromptHandlers(
        viewModel: ChatViewModel,
        downloadAndShare: @escaping (String) -> Void,
        downloadAndShareURL: @escaping (URL) -> Void
    ) -> some View {
        self
            // Intercept link taps from MarkdownView: download server file URLs
            // with auth instead of opening Safari.
            .onReceive(NotificationCenter.default.publisher(for: .markdownLinkTapped)) { notification in
                guard let url = notification.userInfo?["url"] as? URL else { return }
                let urlString = url.absoluteString
                let base = viewModel.serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                // Check if this URL belongs to the server
                let isServerURL = !base.isEmpty && urlString.hasPrefix(base)

                if isServerURL {
                    // Known files API pattern: use existing fileId-based download
                    if urlString.contains("/api/v1/files/"), urlString.hasSuffix("/content") {
                        let parts = urlString.split(separator: "/")
                        if let filesIdx = parts.firstIndex(of: "files"),
                           filesIdx + 1 < parts.count {
                            let fileId = String(parts[filesIdx + 1])
                            downloadAndShare(fileId)
                            return
                        }
                    }
                    // All other server-hosted URLs (e.g. /cache/files/…, /uploads/…):
                    // download via authenticated raw GET so the user gets the file
                    // with credentials injected, not a Safari 401.
                    downloadAndShareURL(url)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            // Handle sendPrompt bridge calls from InlineVisualizerView.
            .onReceive(NotificationCenter.default.publisher(for: .vizSendPrompt)) { notification in
                guard let text = notification.userInfo?["text"] as? String, !text.isEmpty else { return }
                if viewModel.isStreaming {
                    viewModel.inputText = text
                } else {
                    viewModel.inputText = text
                    Task { await viewModel.sendMessage() }
                }
            }
    }
}

// MARK: - Text Selection Handlers (Type-Checker Relief)

/// Handles "Ask" / "Explain" taps from the LTXLabel text selection menu in
/// assistant messages. Extracted from body so the Swift type-checker doesn't
/// have to resolve these two `.onReceive` closures inline.
private extension View {
    func applyTextSelectionHandlers(viewModel: ChatViewModel) -> some View {
        self
            // "Ask": quote the selected text into the input box so the user can
            // type a follow-up question (cursor placed after the quote), then
            // signal the ViewModel to request keyboard focus. The actual
            // FocusState mutation happens in .onChange(of: viewModel.shouldFocusInput)
            // in the body — that indirect path avoids racing with LTXLabel's
            // resignFirstResponder() call during clearSelection().
            .onReceive(NotificationCenter.default.publisher(for: .ltxLabelAskSelection)) { notification in
                guard let selected = notification.userInfo?["selectedText"] as? String,
                      !selected.isEmpty else { return }
                viewModel.inputText = "\"\(selected)\"\n"
                viewModel.shouldFocusInput = true
            }
            // "Explain": pre-fill "Explain: [text]" ready to send (no keyboard needed).
            .onReceive(NotificationCenter.default.publisher(for: .ltxLabelExplainSelection)) { notification in
                guard let selected = notification.userInfo?["selectedText"] as? String,
                      !selected.isEmpty else { return }
                viewModel.inputText = "Explain: \"\(selected)\""
            }
    }
}

// MARK: - URL Identifiable

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Action Event UI Models

/// Carries the data for a pending `__event_call__` input prompt.
/// Setting this on `@State` triggers the `.alert` modifier in the view body.
struct ActionInputRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let placeholder: String
    let defaultValue: String
}

/// Carries the data for a pending `__event_call__` confirmation dialog.
/// Setting this on `@State` triggers the `.confirmationDialog` modifier in the view body.
struct ActionConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - SubagentResultSheet

/// A sheet that shows the full content of a background sub-agent completion message.
/// Presented when the user taps the "Background sub-agent finished" banner in the chat.
struct SubagentResultSheet: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Delegation ID badge
                    if let delegId = message.subagentDelegationId, !delegId.isEmpty {
                        Text(delegId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Full content rendered as markdown
                    AssistantMessageContent(
                        content: message.content,
                        isStreaming: false,
                        messageEmbeds: message.embeds,
                        authToken: nil,
                        serverBaseURL: "",
                        apiClient: nil
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Sub-agent Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - AssistantEditSheet

/// A bottom sheet for editing an assistant message content in-place.
/// Mirrors WebUI's `editMessage(id, { content }, false)` — saves the edited
/// text directly to the history tree + server without creating a new branch
/// or triggering AI regeneration.
struct AssistantEditSheet: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Button(action: onCancel) {
                    Text("Cancel")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Edit Response")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                Spacer()

                Button(action: onSave) {
                    Text("Save")
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(
                            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? theme.textTertiary
                                : theme.brandPrimary
                        )
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            // Text editor
            TextEditor(text: $text)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .tint(theme.brandPrimary)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .background(theme.background)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.background.ignoresSafeArea())
        .onAppear {
            // Auto-focus the editor when the sheet opens
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }
}

// MARK: - ActionInputSheet

/// A bottom sheet that prompts the user for text input in response to a `__event_call__` input event.
/// Shown in place of a `.alert`-based dialog because SwiftUI alerts with TextFields are unreliable.
struct ActionInputSheet: View {
    let request: ActionInputRequest
    @Binding var text: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Drag handle is shown via .presentationDragIndicator(.visible)

            Text(request.title)
                .font(.headline)
                .foregroundStyle(.primary)

            if !request.message.isEmpty {
                Text(request.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField(request.placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text("Confirm")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.primary)
                        .foregroundStyle(Color(.systemBackground))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}
