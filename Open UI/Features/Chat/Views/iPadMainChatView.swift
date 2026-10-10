import SwiftUI

// MARK: - iPad Main Chat View
//
// Built on a native `NavigationSplitView` (sidebar + chat) with the terminal file
// browser as a native trailing `.inspector`. Two sidebar modes, controlled by the
// "ipad_sidebar_always_shown" AppStorage key:
//
// • Auto-hide (default): `.prominentDetail` — the sidebar slides over the chat
//   (hamburger, swipe right, or ⌘⌃S) and dismisses on selection or a tap outside.
//
// • Always shown: `.balanced` — the sidebar is a persistent column beside the chat.
//   The hamburger collapses/expands it.
//
// Column animations are performed by UIKit, so the chat is laid out at its final
// width once rather than re-flowing every frame (no stutter on large iPads).
//
// The preference is toggled from Settings → Appearance (iPad only) and persists
// across app restarts via AppStorage.

/// Applies the split-view style for the current sidebar mode.
private struct iPadSplitStyleModifier: ViewModifier {
    let alwaysShown: Bool

    func body(content: Content) -> some View {
        if alwaysShown {
            content.navigationSplitViewStyle(.balanced)
        } else {
            content.navigationSplitViewStyle(.prominentDetail)
        }
    }
}

struct iPadMainChatView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

    // MARK: State

    /// The conversation currently being viewed. `nil` = new chat.
    @State private var activeConversationId: String?

    /// Monotonically increasing counter to force new-chat view recreation.
    @State private var newChatGeneration: Int = 0

    /// Conversation list view model (shared with sidebar).
    @State private var listViewModel = ChatListViewModel()

    /// Whether the "create folder" sheet is visible.
    @State private var showCreateFolderSheet = false

    /// Whether the settings sheet is visible.
    @State private var showSettings = false

    /// Whether the notes sheet is visible.
    @State private var showNotes = false

    /// Whether the workspace sheet is visible.
    @State private var showWorkspace = false
    @State private var showLibrarySearch = false

    /// Whether the memories sheet is visible.
    @State private var showMemories = false

    /// Whether the calendar sheet is visible.
    @State private var showCalendar = false

    /// Whether the automations sheet is visible.
    @State private var showAutomations = false

    /// Controls the My Defaults sheet presentation.
    @State private var showUserSettings = false

    /// Sidebar column visibility for the native `NavigationSplitView`.
    /// Always-shown mode starts with the sidebar open; auto-hide starts closed.
    @State private var columnVisibility: NavigationSplitViewVisibility =
        UserDefaults.standard.bool(forKey: "ipad_sidebar_always_shown") ? .all : .detailOnly

    /// Latches once a swipe-to-open-sidebar gesture has fired, so a single drag
    /// opens the sidebar exactly once.
    @State private var sidebarSwipeTriggered = false

    /// Same latch for the trailing-edge swipe that opens the terminal panel.
    @State private var terminalSwipeTriggered = false

    /// Whether socket reconnect handler has been registered.
    @State private var hasRegisteredSocketHandlers = false

    /// The channel currently being viewed. When set, replaces detail with ChannelDetailView.
    @State private var activeChannelId: String?

    /// When set, the detail area shows a folder workspace view so new chats
    /// are created inside this folder (mirrors MainChatView behaviour).
    @State private var activeFolderWorkspaceId: String?

    /// The folder object for the current workspace — captured synchronously at
    /// selection time so the background image is available on the FIRST render,
    /// before `setActiveFolder`'s async detail fetch completes.
    @State private var activeFolderForWorkspace: ChatFolder?

    /// Channel list view model for sidebar display.
    @State private var channelListVM = ChannelListViewModel()

    /// Whether the "create channel" sheet is visible.
    @State private var showCreateChannel = false

    /// Controls the archived chats sheet presentation.
    @State private var showArchivedChats = false

    /// Controls the shared chats sheet presentation.
    @State private var showSharedChats = false

    /// Controls the admin console sheet presentation (admin users only).
    @State private var showAdminConsole = false

    /// Controls the on-device TTS model download sheet before entering a voice call.
    @State private var showModelDownloadSheet = false

    /// Stores the voice call action to fire once the model finishes downloading.
    @State private var pendingVoiceCallAction: (() -> Void)?

    /// Rename conversation state.
    @State private var renamingConversation: Conversation?
    @State private var renameText = ""
    @State private var isGeneratingTitle = false

    /// Export state.
    @State private var exportFileURL: URL?
    @State private var showExportShareSheet = false
    @State private var isExporting = false
    @State private var exportError: String?

    /// Softens the detail column for a moment when the open chat changes, so the
    /// swap reads as a quick frosted reveal instead of a hard cut (mirrors iPhone).
    @State private var contentTransitionBlur: CGFloat = 0

    // MARK: Photo picker (window-level)
    // Owned here so AnimatedPhotoPicker renders outside ChatDetailView's
    // safeAreaInset-shrunk ZStack and can truly cover the full screen.
    @State private var showAnimatedPhotoPicker = false

    /// Share chat sheet state.
    @State private var sharingConversation: Conversation?

    /// Deletion confirmation dialogs.
    @State private var showDeleteAllConfirmation = false
    @State private var showDeleteSelectedConfirmation = false
    /// Single-conversation delete confirmation (from context menu or folder).
    @State private var deletingConversation: Conversation?
    /// Channel delete confirmation.
    @State private var deletingChannelId: String?

    /// Terminal file browser (trailing column).
    @State private var terminalBrowserVM = TerminalBrowserViewModel()

    /// Whether the terminal file browser panel is visible (independent of terminal being enabled).
    /// Opens automatically when the terminal is turned on (see `terminalConfigKey`).
    @State private var showTerminalBrowser: Bool = false

    // MARK: - Sidebar Layout Preference (iPad-only)

    /// When `true`, the sidebar is shown as a persistent left column instead of a slide-out drawer.
    /// Persisted via AppStorage so the preference survives app restarts.
    @AppStorage("ipad_sidebar_always_shown") private var sidebarAlwaysShown: Bool = false

    /// Distance (pt) a swipe must travel before it opens the sidebar / terminal panel.
    private let panelSwipeThreshold: CGFloat = 48

    /// Whether the sidebar column is currently on screen.
    private var isSidebarVisible: Bool { columnVisibility != .detailOnly }

    /// Identifies the terminal context of the visible chat so the panel can react
    /// to chat switches and terminal on/off toggles in a single, ordered handler.
    private struct TerminalContextKey: Equatable {
        let chatId: String?
        let isActive: Bool
    }

    // MARK: - Body

    var body: some View {
        @Bindable var bindableRouter = router
        rootLayout(voiceCallBinding: $bindableRouter.isVoiceCallPresented)
            .applySheets(
            showSettings: $showSettings,
            showNotes: $showNotes,
            showCreateFolderSheet: $showCreateFolderSheet,
            sharingConversation: $sharingConversation,
            renamingConversation: $renamingConversation,
            renameText: $renameText,
            isGeneratingTitle: $isGeneratingTitle,
            exportFileURL: $exportFileURL,
            showExportShareSheet: $showExportShareSheet,
            showDeleteAllConfirmation: $showDeleteAllConfirmation,
            showDeleteSelectedConfirmation: $showDeleteSelectedConfirmation,
            showArchivedChats: $showArchivedChats,
            showSharedChats: $showSharedChats,
            listViewModel: listViewModel,
            activeConversationId: $activeConversationId,
            voiceCallBinding: $bindableRouter.isVoiceCallPresented,
            systemColorScheme: systemColorScheme,
            dependencies: dependencies,
            router: router,
            onExport: { conv, format in Task { await exportChat(conv, format: format) } },
            onGenerateTitle: { conv in Task { await generateTitleForRename(conv) } }
        )
        .applyAlerts(
            showDeleteAllConfirmation: $showDeleteAllConfirmation,
            showDeleteSelectedConfirmation: $showDeleteSelectedConfirmation,
            deletingConversation: $deletingConversation,
            deletingChannelId: $deletingChannelId,
            exportError: $exportError,
            listViewModel: listViewModel,
            activeConversationId: $activeConversationId,
            activeChannelId: $activeChannelId,
            channelListVM: channelListVM,
            dependencies: dependencies,
            onStartNewChat: { startNewChat() }
        )
        .applyLifecycle(
            listViewModel: listViewModel,
            dependencies: dependencies,
            scenePhase: scenePhase,
            activeConversationId: $activeConversationId,
            activeChannelId: $activeChannelId,
            activeFolderWorkspaceId: $activeFolderWorkspaceId,
            newChatGeneration: $newChatGeneration,
            channelListVM: channelListVM,
            hasRegisteredSocketHandlers: $hasRegisteredSocketHandlers,
            showCreateChannel: $showCreateChannel,
            showSettings: $showSettings,
            showNotes: $showNotes,
            showCreateFolderSheet: $showCreateFolderSheet,
            showExportShareSheet: $showExportShareSheet,
            onSocketSetup: { registerSocketReconnectHandler() }
        )
        // Reset swipe latches on foreground (prevents a stale latch blocking the next swipe)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                sidebarSwipeTriggered = false
                terminalSwipeTriggered = false
            }
        }
        // Switching layout mode in Settings: show the column for always-shown, hide for auto-hide.
        .onChange(of: sidebarAlwaysShown) { _, alwaysShown in
            columnVisibility = alwaysShown ? .all : .detailOnly
        }
        // Refresh sidebar lists whenever it is revealed (button, swipe, or keyboard shortcut).
        .onChange(of: isSidebarVisible) { _, visible in
            guard visible else { return }
            refreshSidebarLists()
        }
        // Terminal panel follows the chat: closes + resets on chat switch, opens when the
        // terminal is turned on and closes when it is turned off (mirrors MainChatView).
        .onChange(of: TerminalContextKey(chatId: activeConversationId,
                                         isActive: isTerminalActiveInCurrentChat)) { old, new in
            if old.chatId != new.chatId {
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) { showTerminalBrowser = false }
                terminalBrowserVM.reset()
                return
            }
            if new.isActive && !old.isActive {
                openTerminalBrowser()
            } else if !new.isActive && old.isActive {
                closeTerminalBrowser()
            }
        }
        // Terminal WebSocket lifecycle — disconnect on background, reconnect on foreground
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active && oldPhase != .active {
                terminalBrowserVM.handleAppForeground()
            } else if newPhase == .background || newPhase == .inactive {
                terminalBrowserVM.handleAppBackground()
            }
        }
        // Model tool events: open displayed files in the panel and refresh the listing.
        .onReceive(NotificationCenter.default.publisher(for: .terminalFileEvent)) { note in
            handleTerminalFileEvent(note)
        }
        // Channel-specific lifecycle wiring
        .task {
            // Configure and load channels — must pass currentUserId for DM participant filtering
            if let apiClient = dependencies.apiClient {
                var userId = dependencies.authViewModel.currentUser?.id
                if userId == nil || userId?.isEmpty == true {
                    userId = try? await apiClient.getCurrentUser().id
                }
                channelListVM.configure(apiClient: apiClient, socket: dependencies.socketService, currentUserId: userId)
            }
            await channelListVM.loadChannels()
            // Wire up channel notification tap → navigate to that channel
            NotificationService.shared.onOpenChannel = { channelId in
                dependencies.requestOpenChannel(channelId)
            }
            // openui://channel/{id} that launched the app before this view mounted.
            if let channelId = dependencies.consumePendingChannel() {
                openChannelFromLink(channelId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToChannel)) { notification in
            if let channelId = notification.object as? String {
                _ = dependencies.consumePendingChannel()
                openChannelFromLink(channelId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openUINewChatWithFocus)) { _ in
            // Widget "Ask Open Relay" bar — start new chat and auto-focus keyboard
            showNotes = false
            startNewChat()
            // Give the view time to settle before requesting keyboard focus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openUIWidgetVoiceCall)) { _ in
            // Widget mic button — start a voice call with full configuration
            // (mirrors ChatDetailView's startVoiceCall pattern)
            let voiceCallVM = dependencies.makeVoiceCallViewModel()
            let chatVM = dependencies.activeChatStore.viewModel(for: nil)
            if let manager = dependencies.conversationManager {
                let modelName = dependencies.activeChatStore.cachedModels
                    .first(where: { $0.id == dependencies.activeChatStore.cachedSelectedModelId })?.name
                    ?? "AI Assistant"
                voiceCallVM.configure(
                    conversationManager: manager,
                    chatViewModel: chatVM,
                    modelName: modelName
                )
            }
            // Intercept: show download sheet if on-device model not yet ready
            if dependencies.textToSpeechService.needsOnDeviceModelDownload {
                pendingVoiceCallAction = { router.presentVoiceCall(viewModel: voiceCallVM) }
                showModelDownloadSheet = true
            } else {
                router.presentVoiceCall(viewModel: voiceCallVM)
            }
        }
        // Open-chat tracking for unread dots now lives in ChatDetailView (real chat ID).
        .onChange(of: activeChannelId) { _, newId in
            // When entering a channel, the server marks it as read via GET /channels/{id}.
            // Refresh the channel list after a short delay to clear the unread badge.
            if newId != nil {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    await channelListVM.refreshChannels()
                }
            }
        }
        .sheet(isPresented: $showCreateChannel) {
            CreateChannelSheet(
                onCreate: { name, description, type, isPrivate, memberIds in
                    Task {
                        let channelName = name.isEmpty ? "new-channel" : name
                        if let channel = await channelListVM.createChannel(
                            name: channelName, description: description, type: type,
                            isPrivate: type == .dm ? true : isPrivate
                        ) {
                            if !memberIds.isEmpty {
                                try? await dependencies.apiClient?.addChannelMembers(
                                    id: channel.id, userIds: memberIds
                                )
                            }
                            activeChannelId = channel.id
                            activeConversationId = nil
                        }
                    }
                },
                apiClient: dependencies.apiClient,
                allUsers: channelListVM.allServerUsers
            )
        }
        // A chat was copied (Admin Console "Copy to My Chats", or a fork): close the sheets
        // and open it. Lives here because this view owns the sheets that must close.
        .onReceive(NotificationCenter.default.publisher(for: .adminClonedChat)) { note in
            if let id = note.object as? String { openCopiedChat(id) }
        }
        // Admin Console sheet (admin-only)
        .sheet(isPresented: $showAdminConsole) {
            NavigationStack {
                AdminConsoleView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close", systemImage: "xmark") {
                                showAdminConsole = false
                            }
                            .labelStyle(.iconOnly)
                            .tint(.secondary)
                        }
                    }
            }
            .environment(dependencies)
            .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            .presentationCornerRadius(20)
        }
        .fullScreenCover(isPresented: $showLibrarySearch) {
            if let api = dependencies.apiClient {
                LibrarySearchView(api: api, onSelectChat: openSearchChat, onSelectFolder: openFolder)
                    .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                    .preferredColorScheme(dependencies.appearanceManager.resolvedColorScheme ?? systemColorScheme)
            }
        }
        // Workspace sheet
        .sheet(isPresented: $showWorkspace) {
            WorkspaceView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
        }
        // Memories sheet
        .sheet(isPresented: $showMemories) {
            NavigationStack {
                MemoriesView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close", systemImage: "xmark") {
                                showMemories = false
                            }
                            .labelStyle(.iconOnly)
                            .tint(.secondary)
                        }
                    }
            }
            .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
        }
        // Calendar sheet
        .sheet(isPresented: $showCalendar) {
            CalendarView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
        }
        // Automations sheet
        .sheet(isPresented: $showAutomations) {
            AutomationsListView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
        }
        // My Defaults sheet
        .sheet(isPresented: $showUserSettings) {
            UserSettingsView()
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
        }
        // On-device TTS model download sheet (shown before voice call when model not yet ready)
        .sheet(isPresented: $showModelDownloadSheet, onDismiss: {
            pendingVoiceCallAction = nil
        }) {
            modelDownloadSheetContent()
        }
        .overlay {
            if isExporting {
                exportingOverlay
            }
            if listViewModel.isDeletingBulk {
                deletingOverlay
            }
        }
        .animation(MicroAnimation.fade, value: isExporting)
        .animation(MicroAnimation.fade, value: listViewModel.isDeletingBulk)
    }

    // MARK: - Root Layout — native split view (both sidebar modes)
    //
    // Both layout modes use one `NavigationSplitView`; only the style and the
    // initial column visibility differ:
    //  • Always shown → `.balanced`: the sidebar sits beside the chat.
    //  • Auto-hide    → `.prominentDetail`: the sidebar slides over the chat and
    //    dismisses on selection or a tap outside.
    // Column animations are driven by UIKit (UISplitViewController), so the chat
    // is laid out once at its final width instead of re-flowing every frame.
    // The terminal file browser is a native trailing inspector column.

    @ViewBuilder
    private func rootLayout(voiceCallBinding: Binding<Bool>) -> some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                drawerPanel
                    .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
                    .toolbar(removing: .sidebarToggle)
                    .background(theme.sidebarBackground.ignoresSafeArea())
            } detail: {
                detailColumn
            }
            .modifier(iPadSplitStyleModifier(alwaysShown: sidebarAlwaysShown))

            // ── AnimatedPhotoPicker at window level ──────────────────────────
            AnimatedPhotoPicker(
                isPresented: showAnimatedPhotoPicker,
                onConfirm: { assets in
                    NotificationCenter.default.post(
                        name: .openUIPhotoPickerConfirm,
                        object: nil,
                        userInfo: ["assets": assets]
                    )
                    showAnimatedPhotoPicker = false
                },
                onDismiss: {
                    showAnimatedPhotoPicker = false
                }
            )
        }
    }

    // MARK: - Detail Column

    /// Chat/channel detail plus the terminal inspector. The view structure is the
    /// same whether or not the terminal is active, so toggling the terminal never
    /// rebuilds the chat (which previously caused composer taps to hitch).
    private var detailColumn: some View {
        NavigationStack {
            chatDetailContent
                .disabled(showNotes)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        // The split view already sizes this column to the space above the keyboard,
        // so the chat respects the keyboard safe area normally (as on iPhone): the
        // composer sits on the keyboard and the top bar stays put. Ignoring the
        // keyboard here made the chat taller than its column, which centred it and
        // pushed the top bar down.
        // Swipe right anywhere (that isn't a control, message, or scrollable code) → sidebar.
        .gesture(sidebarSwipeGesture)
        // Swipe left from the trailing edge → terminal file browser.
        .gesture(terminalSwipeGesture)
        .blur(radius: contentTransitionBlur)
        .inspector(isPresented: terminalInspectorBinding) {
            TerminalBrowserView(
                viewModel: terminalBrowserVM,
                onDismiss: { closeTerminalBrowser() }
            )
            .background(theme.background.ignoresSafeArea())
            .inspectorColumnWidth(min: 320, ideal: terminalPanelWidth, max: 480)
        }
    }

    /// Presented only while the current chat has an active terminal.
    private var terminalInspectorBinding: Binding<Bool> {
        Binding(
            get: { showTerminalBrowser && isTerminalActiveInCurrentChat },
            set: { isPresented in
                if !isPresented && showTerminalBrowser { closeTerminalBrowser() }
            }
        )
    }

    /// Direction-locked pan that opens the sidebar. Yields to controls, text
    /// selection, message swipe-to-reply, and horizontally scrollable content.
    private var sidebarSwipeGesture: SidebarOpeningGesture {
        SidebarOpeningGesture(
            isEnabled: !isSidebarVisible,
            onChanged: { horizontal in
                guard !sidebarSwipeTriggered, horizontal > panelSwipeThreshold else { return }
                sidebarSwipeTriggered = true
                showSidebar()
            },
            onEnded: { horizontal, velocity, cancelled in
                defer { sidebarSwipeTriggered = false }
                guard !cancelled, !sidebarSwipeTriggered, horizontal > 12, velocity > 300 else { return }
                showSidebar()
            }
        )
    }

    /// Trailing-edge pan that opens the terminal panel (only when the terminal is on).
    private var terminalSwipeGesture: SidebarOpeningGesture {
        SidebarOpeningGesture(
            isEnabled: isTerminalActiveInCurrentChat && !showTerminalBrowser,
            direction: .leftward,
            edgeWidth: 32,
            onChanged: { horizontal in
                guard !terminalSwipeTriggered, horizontal < -panelSwipeThreshold else { return }
                terminalSwipeTriggered = true
                openTerminalBrowser()
            },
            onEnded: { horizontal, velocity, cancelled in
                defer { terminalSwipeTriggered = false }
                guard !cancelled, !terminalSwipeTriggered, horizontal < -12, velocity < -300 else { return }
                openTerminalBrowser()
            }
        )
    }

    // MARK: - Drawer Panel

    private var drawerPanel: some View {
        iPadSidebarContent(
            // NavigationSplitView draws its own column separator.
            showsTrailingDivider: false,
            listViewModel: listViewModel,
            channelListVM: channelListVM,
            activeConversationId: $activeConversationId,
            activeChannelId: $activeChannelId,
            activeFolderWorkspaceId: $activeFolderWorkspaceId,
            showCreateFolderSheet: $showCreateFolderSheet,
            showCreateChannel: $showCreateChannel,
            showSettings: $showSettings,
            showNotes: $showNotes,
            showWorkspace: $showWorkspace,
            showMemories: $showMemories,
            showCalendar: $showCalendar,
            showAutomations: $showAutomations,
            showUserSettings: $showUserSettings,
            showAdminConsole: $showAdminConsole,
            showDeleteAllConfirmation: $showDeleteAllConfirmation,
            showDeleteSelectedConfirmation: $showDeleteSelectedConfirmation,
            deletingConversation: $deletingConversation,
            deletingChannelId: $deletingChannelId,
            sharingConversation: $sharingConversation,
            renamingConversation: $renamingConversation,
            renameText: $renameText,
            dependencies: dependencies,
            onSearch: { showLibrarySearch = true },
            onNewChat: {
                startNewChat()
                dismissSidebarIfOverlay()
            },
            onSelectFolder: openFolder,
            onExport: { conv, format in Task { await exportChat(conv, format: format) } },
            onShowArchivedChats: { showArchivedChats = true },
            onShowSharedChats: { showSharedChats = true },
            onCloseDrawer: sidebarAlwaysShown ? nil : { dismissSidebarIfOverlay() },
            onChatSwitching: { softenChatSwitch() }
        )
    }

    /// Starts the new chat softly blurred, then clears the blur over a moment.
    private func softenChatSwitch() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { contentTransitionBlur = 8 }
        withAnimation(.easeOut(duration: 0.28)) { contentTransitionBlur = 0 }
    }

    /// A chat was copied (Admin Console "Copy to My Chats", or a fork): close every sheet
    /// that could be covering the app in one step, then open the copy with a soft blur.
    private func openCopiedChat(_ conversationId: String) {
        showSettings = false
        showAdminConsole = false
        withAnimation(.easeOut(duration: 0.15)) { contentTransitionBlur = 10 }
        Task { @MainActor in
            // Let the sheets finish dismissing so the switch is seen, not hidden.
            try? await Task.sleep(for: .seconds(0.35))
            dependencies.activeChatStore.prewarm(conversationId: conversationId, using: dependencies)
            activeConversationId = conversationId
            activeChannelId = nil
            activeFolderWorkspaceId = nil
            SharedDataService.shared.saveLastActiveConversationId(conversationId)
            withAnimation(.easeIn(duration: 0.22)) { contentTransitionBlur = 0 }
        }
    }

    private func openSearchChat(_ id: String) {
        activeConversationId = id
        activeChannelId = nil
        activeFolderWorkspaceId = nil
        activeFolderForWorkspace = nil
        SharedDataService.shared.saveLastActiveConversationId(id)
        dismissSidebarIfOverlay()
    }

    private func openFolder(_ folderId: String) {
        let folderVM = listViewModel.folderViewModel
        activeFolderWorkspaceId = folderId
        activeConversationId = nil
        activeChannelId = nil
        dependencies.activeChatStore.remove(nil)
        newChatGeneration += 1
        // Set immediate placeholder from the flat list (may lack meta)
        activeFolderForWorkspace = folderVM.folders.first { $0.id == folderId }
        Task {
            // Fetch full detail (background image URL, system prompt, models)
            await folderVM.setActiveFolder(folderId)
            // Pre-warm the folder background image so ChatDetailView has
            // an instant cache hit and shows no layout shift.
            if let bgUrl = folderVM.activeFolderDetail?.backgroundImageUrl,
               !bgUrl.isEmpty, !bgUrl.hasPrefix("data:"),
               let api = dependencies.apiClient {
                let resolvedURL: URL?
                if bgUrl.hasPrefix("http") {
                    resolvedURL = URL(string: bgUrl)
                } else {
                    resolvedURL = URL(string: api.baseURL + bgUrl)
                }
                if let imgURL = resolvedURL {
                    Task(priority: .userInitiated) {
                        _ = await ImageCacheService.shared.loadImage(
                            from: imgURL,
                            authToken: api.network.authToken,
                            targetPixelSize: Int(UIScreen.main.bounds.width * UIScreen.main.scale)
                        )
                    }
                }
            }
            // Load chats — they're fetched lazily and may be empty
            // if the folder was never expanded in the sidebar.
            if var flatFolder = folderVM.folders.first(where: { $0.id == folderId }) {
                flatFolder.isExpanded = true   // satisfy the isExpanded guard in loadChatsIfNeeded
                await folderVM.loadChatsIfNeeded(for: flatFolder)
            }
            // Merge: full detail has meta/background, flat list now has chats
            if let detail = folderVM.activeFolderDetail {
                var merged = detail
                if merged.chats.isEmpty,
                   let flatFolder = folderVM.folders.first(where: { $0.id == folderId }),
                   !flatFolder.chats.isEmpty {
                    merged.chats = flatFolder.chats
                }
                activeFolderForWorkspace = merged
            }
        }
        dismissSidebarIfOverlay()
    }

    // MARK: - Sidebar Visibility

    /// Shows the sidebar column (both modes) and refreshes its lists via `onChange(of: isSidebarVisible)`.
    private func showSidebar() {
        guard !isSidebarVisible else { return }
        // Dismiss the keyboard first so its slide-out doesn't re-layout the chat mid-animation.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(MicroAnimation.panelOpen) { columnVisibility = .all }
        Haptics.play(.light)
    }

    /// Hides the sidebar column (both modes).
    private func hideSidebar() {
        guard isSidebarVisible else { return }
        withAnimation(MicroAnimation.panelClose) { columnVisibility = .detailOnly }
        Haptics.play(.soft)
    }

    /// Hamburger action: toggles the sidebar column.
    private func toggleSidebar() {
        if isSidebarVisible { hideSidebar() } else { showSidebar() }
    }

    /// Auto-hide mode: the overlay sidebar dismisses after a selection.
    /// Always-shown mode keeps the column in place.
    private func dismissSidebarIfOverlay() {
        guard !sidebarAlwaysShown else { return }
        hideSidebar()
    }

    /// Refreshes everything the sidebar shows (mirrors MainChatView.openDrawerAnimated).
    private func refreshSidebarLists() {
        let chatVM = dependencies.activeChatStore.viewModel(for: activeConversationId)
        let lvm = listViewModel
        let cvm = channelListVM
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await lvm.refreshConversations() }
                group.addTask { await lvm.folderViewModel.refreshFolders() }
                group.addTask { await cvm.refreshChannels() }
                group.addTask { await chatVM.fetchPinnedModels() }
            }
        }
    }

    // MARK: - Terminal Panel

    /// Opens the terminal file browser inspector (configures + loads the listing).
    private func openTerminalBrowser() {
        guard isTerminalActiveInCurrentChat, !showTerminalBrowser else { return }
        configureTerminalBrowserIfNeeded()
        withAnimation(MicroAnimation.panelOpen) { showTerminalBrowser = true }
        terminalBrowserVM.handlePanelOpened()
        terminalBrowserVM.refresh()
        Haptics.play(.light)
    }

    /// Closes the terminal file browser inspector and disconnects its socket.
    private func closeTerminalBrowser() {
        guard showTerminalBrowser else { return }
        withAnimation(MicroAnimation.panelClose) { showTerminalBrowser = false }
        terminalBrowserVM.handlePanelClosed()
    }

    private func toggleTerminalBrowser() {
        if showTerminalBrowser { closeTerminalBrowser() } else { openTerminalBrowser() }
    }

    // MARK: - Detail

    @ViewBuilder
    private var chatDetailContent: some View {
        // Hamburger toggles the sidebar column in both modes (auto-hide: overlay,
        // always shown: side-by-side column).
        let toggleDrawerAction: () -> Void = { toggleSidebar() }
        // Files button in the chat top bar + "Browse Files" in the composer terminal menu.
        let terminalActive = isTerminalActiveInCurrentChat
        let filesState = ChatDetailView.FilesButtonState(isVisible: terminalActive, isOpen: showTerminalBrowser)

        if let channelId = activeChannelId {
            ChannelDetailView(channelId: channelId, channelListVM: channelListVM)
                .onToggleDrawer(toggleDrawerAction)
                .id("channel-\(channelId)")
        } else if let conversationId = activeConversationId {
            // If this conversation belongs to the active folder workspace, pass the folder
            // so the background image and folder context persists while viewing the chat.
            let folderForConversation: ChatFolder? = {
                guard let fwId = activeFolderWorkspaceId else { return nil }
                return listViewModel.folderViewModel.folders.first { $0.id == fwId }
                    ?? listViewModel.folderViewModel.activeFolderDetail
            }()
            ChatDetailView(
                conversationId: conversationId,
                viewModel: dependencies.activeChatStore.viewModel(for: conversationId),
                folderWorkspace: folderForConversation
            )
            .onDeleteChat { startNewChat() }
            .onNewChat { startNewChat() }
            .onToggleDrawer(toggleDrawerAction)
            .onOpenFileBrowser { openTerminalBrowser() }
            .filesButton(filesState) { toggleTerminalBrowser() }
            .onPhotoPickerRequest { showAnimatedPhotoPicker = true }
            .id(conversationId)
        } else if let folderWorkspaceId = activeFolderWorkspaceId {
            let vm = dependencies.activeChatStore.viewModel(for: nil)
            let folder = listViewModel.folderViewModel.folders.first { $0.id == folderWorkspaceId }
                ?? listViewModel.folderViewModel.activeFolderDetail
            ChatDetailView(viewModel: vm, folderWorkspace: folder)
                .onNewChat { startNewChat() }
                .onToggleDrawer(toggleDrawerAction)
                .onOpenFileBrowser { openTerminalBrowser() }
                .filesButton(filesState) { toggleTerminalBrowser() }
                .onPhotoPickerRequest { showAnimatedPhotoPicker = true }
                .id("folder-workspace-\(folderWorkspaceId)-\(newChatGeneration)")
                .onAppear {
                    let folderDetail = listViewModel.folderViewModel.activeFolderDetail
                    vm.setFolderContext(
                        folderId: folderWorkspaceId,
                        systemPrompt: folderDetail?.systemPrompt ?? folder?.systemPrompt,
                        modelIds: folderDetail?.modelIds ?? folder?.modelIds ?? []
                    )
                }
        } else {
            ChatDetailView(viewModel: dependencies.activeChatStore.viewModel(for: nil))
                .onNewChat { startNewChat() }
                .onToggleDrawer(toggleDrawerAction)
                .onOpenFileBrowser { openTerminalBrowser() }
                .filesButton(filesState) { toggleTerminalBrowser() }
                .onPhotoPickerRequest { showAnimatedPhotoPicker = true }
                .id("new-chat-\(newChatGeneration)")
        }
    }

    // MARK: - Overlays

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Preparing export…")
                    .scaledFont(size: 16)
                    .foregroundStyle(.white)
            }
            .padding(Spacing.xl)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }

    // MARK: - Model Download Sheet Content (extracted to avoid type-check timeout)
    @ViewBuilder
    private func modelDownloadSheetContent() -> some View {
        VoiceCallModelDownloadSheet(
            ttsService: dependencies.textToSpeechService,
            onReady: {
                showModelDownloadSheet = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    pendingVoiceCallAction?()
                    pendingVoiceCallAction = nil
                }
            },
            onCancel: {
                showModelDownloadSheet = false
                pendingVoiceCallAction = nil
            }
        )
        .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(24)
    }

    private var deletingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Deleting…")
                    .scaledFont(size: 16)
                    .foregroundStyle(.white)
            }
            .padding(Spacing.xl)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }

    // MARK: - Computed Helpers

    private var isTerminalActiveInCurrentChat: Bool {
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        return vm.terminalEnabled && vm.selectedTerminalServer != nil
    }

    // MARK: - Terminal Configuration

    /// Width of the trailing terminal/files column.
    private var terminalPanelWidth: CGFloat { 380 }

    /// Handles `terminal:*` tool events for the active chat (see MainChatView).
    private func handleTerminalFileEvent(_ note: Notification) {
        guard let type = note.userInfo?["type"] as? String,
              let chatId = note.userInfo?["chatId"] as? String else { return }
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        guard (vm.conversationId ?? vm.conversation?.id) == chatId, isTerminalActiveInCurrentChat else { return }
        configureTerminalBrowserIfNeeded()
        if type == "terminal:display_file" && !showTerminalBrowser {
            openTerminalBrowser()
        }
        terminalBrowserVM.handleChatEvent(type: type, path: note.userInfo?["path"] as? String)
    }

    private func configureTerminalBrowserIfNeeded() {
        guard let apiClient = dependencies.apiClient else { return }
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        guard vm.terminalEnabled, let server = vm.selectedTerminalServer else { return }
        terminalBrowserVM.configure(apiClient: apiClient, server: server,
                                    chatId: vm.conversationId ?? vm.conversation?.id)
    }

    // MARK: - Actions

    /// Opens a channel requested by a deep link (`openui://channel/{id}`) or a
    /// channel notification tap. Mirrors `MainChatView.openChannelFromLink`.
    private func openChannelFromLink(_ channelId: String) {
        showNotes = false
        activeFolderWorkspaceId = nil
        activeFolderForWorkspace = nil
        activeConversationId = nil
        activeChannelId = channelId
        dismissSidebarIfOverlay()
        Haptics.play(.light)
    }

    private func startNewChat() {
        let currentNewVM = dependencies.activeChatStore.viewModel(for: nil)

        // If a transcription is running on the new-chat VM, stay put regardless
        // of whether we're already on the new-chat screen.
        if currentNewVM.hasActiveTranscriptions {
            return
        }

        // The navbar "new chat" button always navigates to a plain new chat —
        // never inside a folder workspace, regardless of the current context.
        // Always remove + recreate the VM so derived state (random prompt cards,
        // terminal status, model avatar, etc.) refreshes correctly. The view
        // identity bump (.id change) is what drives those @State resets.
        // All state mutations are wrapped in a non-animating transaction so the
        // swap is an instant replacement with no slide/fade animation.
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            dependencies.activeChatStore.remove(nil)
            activeConversationId = nil
            activeChannelId = nil
            activeFolderWorkspaceId = nil
            newChatGeneration += 1
        }

        // Clear the persisted last-active conversation so a cold launch after
        // this explicit new-chat navigation does not restore the old chat.
        SharedDataService.shared.saveLastActiveConversationId(nil)
        // Reset the terminal panel so the fresh chat starts clean (mirrors MainChatView).
        withTransaction(txn) { showTerminalBrowser = false }
        terminalBrowserVM.reset()
        Haptics.play(.light)
    }

    private func generateTitleForRename(_ conversation: Conversation) async {
        guard let api = dependencies.apiClient,
              let manager = dependencies.conversationManager else { return }
        isGeneratingTitle = true
        do {
            let fullConv = try await manager.fetchConversation(id: conversation.id)
            let messages: [[String: Any]] = fullConv.messages.map { msg in
                ["role": msg.role.rawValue, "content": msg.content]
            }
            let model = fullConv.model ?? dependencies.activeChatStore.cachedSelectedModelId ?? ""
            if let title = try await api.generateTitle(model: model, messages: messages, chatId: conversation.id) {
                renameText = title
            }
        } catch {}
        isGeneratingTitle = false
    }

    enum ExportFormat { case json, txt, pdf }

    private func exportChat(_ conversation: Conversation, format: ExportFormat) async {
        guard let manager = dependencies.conversationManager else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let fullConversation = try await manager.fetchConversation(id: conversation.id)
            let title = fullConversation.title
            let messages = fullConversation.messages
            let tmpDir = FileManager.default.temporaryDirectory

            switch format {
            case .json:
                let payload: [[String: Any]] = messages.map { msg in
                    ["role": msg.role.rawValue, "content": msg.content, "timestamp": msg.timestamp.timeIntervalSince1970]
                }
                let wrapper: [String: Any] = ["title": title, "messages": payload]
                let data = try JSONSerialization.data(withJSONObject: wrapper, options: .prettyPrinted)
                let url = tmpDir.appendingPathComponent("\(title).json")
                try data.write(to: url)
                exportFileURL = url
                showExportShareSheet = true
            case .txt:
                var text = "# \(title)\n\n"
                for msg in messages {
                    let role = msg.role == .user ? "User" : (msg.role == .assistant ? "Assistant" : msg.role.rawValue)
                    text += "[\(role)]\n\(msg.content)\n\n"
                }
                let url = tmpDir.appendingPathComponent("\(title).txt")
                try text.write(to: url, atomically: true, encoding: .utf8)
                exportFileURL = url
                showExportShareSheet = true
            case .pdf:
                exportFileURL = try await ChatPDFExporter.export(title: title, messages: messages)
                showExportShareSheet = true
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func registerSocketReconnectHandler() {
        guard !hasRegisteredSocketHandlers else { return }
        hasRegisteredSocketHandlers = true

        dependencies.socketService?.onReconnect = { [self] in
            Task { @MainActor in
                await dependencies.authViewModel.refreshBackendConfig()
                // Fill in anything this device's own in-progress replies missed while the
                // socket was down (catch-up skips self-initiated streams).
                await dependencies.activeChatStore.recoverStreamsAfterSocketReconnect()
                if let activeId = activeConversationId {
                    let vm = dependencies.activeChatStore.viewModel(for: activeId)
                    await vm.catchUpWithServer(reason: .socketReconnect)
                }
            }
        }

        dependencies.socketService?.onConnect = { [self] in
            Task { @MainActor in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await ChatReadState.shared.verifyGeneratingNow() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                    group.addTask { await channelListVM.refreshChannels() }
                }
            }
        }
    }
}

// MARK: - iPad Sidebar Content

struct iPadSidebarContent: View {
    var showsTrailingDivider: Bool
    @Bindable var listViewModel: ChatListViewModel
    var channelListVM: ChannelListViewModel
    @Binding var activeConversationId: String?
    @Binding var activeChannelId: String?
    @Binding var activeFolderWorkspaceId: String?
    @Binding var showCreateFolderSheet: Bool
    @Binding var showCreateChannel: Bool
    @Binding var showSettings: Bool
    @Binding var showNotes: Bool
    @Binding var showWorkspace: Bool
    @Binding var showMemories: Bool
    @Binding var showCalendar: Bool
    @Binding var showAutomations: Bool
    @Binding var showUserSettings: Bool
    @Binding var showAdminConsole: Bool
    @Binding var showDeleteAllConfirmation: Bool
    @Binding var showDeleteSelectedConfirmation: Bool
    @Binding var deletingConversation: Conversation?
    @Binding var deletingChannelId: String?
    @Binding var sharingConversation: Conversation?
    @Binding var renamingConversation: Conversation?
    @Binding var renameText: String
    let dependencies: AppDependencyContainer
    let onSearch: () -> Void
    let onNewChat: () -> Void
    /// Called when the folder name/icon is tapped — opens folder workspace in the detail pane.
    var onSelectFolder: ((String) -> Void)?
    let onExport: (Conversation, iPadMainChatView.ExportFormat) -> Void
    var onShowArchivedChats: (() -> Void)? = nil
    var onShowSharedChats: (() -> Void)? = nil
    /// Called when a conversation/channel is selected — closes the drawer on iPad.
    var onCloseDrawer: (() -> Void)? = nil
    /// Called just before the open chat changes, so the detail pane can crossfade.
    var onChatSwitching: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var drawerChatsDropActive = false
    @State private var showMoveSelectedToFolderSheet = false
    @State private var showUpdateSheet = false

    /// Controls the on-device TTS model download sheet shown before opening a voice call.
    @State private var showModelDownloadSheet = false
    /// Pending voice call action stored while the model download sheet is visible.
    @State private var pendingVoiceCallAction: (() -> Void)?

    /// Top-level section collapse states (shared with iPhone via same AppStorage keys).
    @AppStorage("sidebar_models_expanded") private var modelsExpanded: Bool = true
    @AppStorage("sidebar_folders_expanded") private var foldersExpanded: Bool = true
    @AppStorage("sidebar_shared_folders_expanded") private var sharedFoldersExpanded: Bool = true
    @AppStorage("sidebar_channels_expanded") private var channelsExpanded: Bool = true
    @AppStorage("sidebar_chats_expanded") private var chatsExpanded: Bool = true
    /// Tracks which time-group sub-sections are collapsed (e.g. "Pinned", "Today").
    @AppStorage("sidebar_collapsed_sections") private var collapsedSectionsRaw: String = ""

    private var collapsedSections: Set<String> {
        get {
            let keys = collapsedSectionsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            return Set(keys)
        }
        set {
            collapsedSectionsRaw = newValue.sorted().joined(separator: ",")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search / selection header
            if listViewModel.isSelectionMode {
                selectionModeHeader
            } else {
                sidebarHeader
            }

            // Conversation list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let folderVM = listViewModel.folderViewModel

                    // Pinned models section (quick-switch shortcuts)
                    pinnedModelsSection

                    // Folders section
                    let foldersEnabled = dependencies.authViewModel.featurePermissions.folders
                    let hasFolderSections = foldersEnabled && (!folderVM.featureDisabled || !folderVM.sharedFolders.isEmpty)
                    if foldersEnabled && !folderVM.featureDisabled {
                        foldersSection(folderVM: folderVM)
                    }

                    // Shared with me section
                    if foldersEnabled && !folderVM.sharedFolders.isEmpty {
                        sharedFoldersSection(folderVM: folderVM)
                    }

                    // Divider between folders and channels
                    let channelsEnabled = dependencies.authViewModel.featurePermissions.channels
                        && (dependencies.authViewModel.backendConfig?.features?.enableChannels ?? true)
                    if hasFolderSections && channelsEnabled {
                        sidebarDivider
                    }

                    // Channels section (shown only when enabled on server)
                    if channelsEnabled {
                        channelsSection
                    }

                    // Chats section
                    let hasAnyChats = !listViewModel.pinnedConversations.isEmpty
                        || !listViewModel.groupedConversations.isEmpty

                    if hasAnyChats || !folderVM.folders.isEmpty {
                        // Divider between the sections above and chats
                        if hasFolderSections || channelsEnabled {
                            sidebarDivider
                        }
                        chatsSection(folderVM: folderVM)
                    }
                }
                .padding(.bottom, Spacing.md)
            }

            if listViewModel.isSelectionMode {
                selectionBottomBar
            } else {
                sidebarBottomBar
            }
        }
        .background(theme.sidebarBackground)
        .overlay(alignment: .trailing) {
            if showsTrailingDivider {
                Rectangle()
                    .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                    .frame(width: 0.5)
                    .ignoresSafeArea()
            }
        }
        // Sidebar has no text inputs that need keyboard avoidance — ignore
        // keyboard safe area so the sidebar layout doesn't shift when a
        // floating keyboard appears/disappears or changes size on iPad.
        .ignoresSafeArea(.keyboard)
        // No system title bar: the header row below matches the iPhone drawer.
        .toolbar(.hidden, for: .navigationBar)
        // Bridge folderVM.showCreateSheet → showCreateFolderSheet (mirrors MainChatView)
        .onChange(of: listViewModel.folderViewModel.showCreateSheet) { _, show in
            if show {
                listViewModel.folderViewModel.showCreateSheet = false
                showCreateFolderSheet = true
            }
        }
    }

    // MARK: - Sidebar Header (matches the iPhone drawer header)

    private var sidebarHeader: some View {
        VStack(spacing: 0) {
            // Action row: server icon (left), chat-management menu + search (right)
            HStack(spacing: 8) {
                // Server favicon — tapping opens Settings
                Button {
                    showSettings = true
                } label: {
                    serverFaviconView
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Server Settings")

                Spacer()

                // Chat management menu (select, archive, delete, archived/shared chats)
                Menu {
                    if !listViewModel.conversations.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { listViewModel.toggleSelectionMode() }
                        } label: {
                            Label("Select Chats", systemImage: "checkmark.circle")
                        }
                        Button {
                            listViewModel.showArchiveAllConfirmation = true
                        } label: {
                            Label("Archive All", systemImage: "archivebox")
                        }
                        Button(role: .destructive) {
                            showDeleteAllConfirmation = true
                        } label: {
                            Label("Delete All", systemImage: "trash")
                        }
                        Divider()
                    }
                    Button {
                        onShowArchivedChats?()
                    } label: {
                        Label("Archived Chats", systemImage: "archivebox")
                    }
                    Button {
                        onShowSharedChats?()
                    } label: {
                        Label("Shared Chats", systemImage: "link.circle")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Chat actions")

                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Search library")
                .disabled(dependencies.apiClient == nil)
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: 40)
            .padding(.top, Spacing.sm)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Server Favicon View

    @ViewBuilder
    private var serverFaviconView: some View {
        let baseURL = dependencies.apiClient?.baseURL ?? ""

        Group {
            if !baseURL.isEmpty,
               let faviconURL = URL(string: "\(baseURL)/favicon.ico") {
                AsyncImage(url: faviconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image("AppIconImage")
                            .resizable()
                            .scaledToFill()
                    }
                }
            } else {
                Image("AppIconImage")
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Sidebar Divider

    private var sidebarDivider: some View {
        Rectangle()
            .fill(theme.textTertiary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 6)
    }

    // MARK: - Section Label (same as the iPhone drawer's `drawerSectionLabel`)

    @ViewBuilder
    private func drawerSectionLabel(
        title: String,
        icon: String,
        isExpanded: Bool,
        tintOverride: Color? = nil,
        trailingButton: (() -> AnyView)? = nil
    ) -> some View {
        let labelColor = tintOverride ?? theme.textTertiary
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .scaledFont(size: 9, weight: .bold, context: .list)
                .foregroundStyle(labelColor)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .animation(MicroAnimation.snappy, value: isExpanded)

            Image(systemName: icon)
                .scaledFont(size: 10, weight: .semibold, context: .list)
                .foregroundStyle(labelColor)

            Text(title)
                .scaledFont(size: 11, weight: .bold, context: .list)
                .foregroundStyle(labelColor)
                .textCase(.uppercase)
                .tracking(0.6)

            Spacer()

            if let trailingButton {
                trailingButton()
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }

    // MARK: - Selection Mode Header

    private var selectionModeHeader: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    listViewModel.exitSelectionMode()
                }
            } label: {
                Text("Cancel")
                    .scaledFont(size: 16, context: .list)
                    .foregroundStyle(theme.brandPrimary)
            }

            Spacer()

            Text("\(listViewModel.selectedCount) selected")
                .scaledFont(size: 14, weight: .medium, context: .list)
                .fontWeight(.semibold)
                .foregroundStyle(theme.textPrimary)

            Spacer()

            Button {
                if listViewModel.selectedCount == listViewModel.filteredConversations.count {
                    listViewModel.selectedConversationIds.removeAll()
                } else {
                    listViewModel.selectAll()
                }
            } label: {
                Text(listViewModel.selectedCount == listViewModel.filteredConversations.count ? "Deselect All" : "Select All")
                    .scaledFont(size: 12, weight: .medium, context: .list)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Pinned Models Section

    /// Shows pinned models as quick-switch shortcuts in the sidebar,
    /// matching the web UI's "Models" section above folders.
    @ViewBuilder
    private var pinnedModelsSection: some View {
        // Always use the new-chat VM (nil) for pinned models — it's a global user preference,
        // not per-conversation. Using activeConversationId here caused the section to collapse
        // and re-expand every time a chat was tapped (new VM's availableModels starts empty,
        // then loads async), which was the root cause of the sidebar bounce.
        let vm = dependencies.activeChatStore.viewModel(for: nil)
        let pinnedIds = vm.pinnedModelIds
        let models = vm.availableModels
        let pinnedModels = pinnedIds.compactMap { id in models.first(where: { $0.id == id }) }

        if !pinnedModels.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Collapsible section header
                Button {
                    withAnimation(MicroAnimation.snappy) {
                        modelsExpanded.toggle()
                    }
                    Haptics.play(.light)
                } label: {
                    drawerSectionLabel(title: "Models", icon: "cpu", isExpanded: modelsExpanded)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Models")
                .accessibilityValue(modelsExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("sidebar-models-header")

                // Pinned model rows
                if modelsExpanded {
                    ForEach(pinnedModels) { model in
                        let isSelected = model.id == vm.selectedModelId
                        Button {
                            let modelId = model.id
                            onNewChat()
                            let newVM = dependencies.activeChatStore.viewModel(for: nil)
                            newVM.selectModel(modelId)
                        } label: {
                            HStack(spacing: 8) {
                                ModelAvatar(
                                    size: 22,
                                    imageURL: vm.resolvedImageURL(for: model),
                                    label: model.shortName,
                                    authToken: vm.serverAuthToken
                                )
                                Text(model.shortName)
                                    .scaledFont(size: 14, context: .list)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                                // Always render checkmark to avoid layout shifts on insertion/removal
                                Image(systemName: "checkmark")
                                    .scaledFont(size: 11, weight: .semibold, context: .list)
                                    .foregroundStyle(theme.brandPrimary)
                                    .opacity(isSelected ? 1 : 0)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, 7)
                            .background(isSelected ? theme.brandPrimary.opacity(0.1) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transaction { $0.animation = nil }
                        .contextMenu {
                            Button(role: .destructive) {
                                vm.togglePinModel(model.id)
                                Haptics.play(.medium)
                            } label: {
                                Label("Unpin", systemImage: "pin.slash")
                            }
                        }
                    }
                }
            }

            // Divider below models
            Rectangle()
                .fill(theme.textTertiary.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
        }
    }

    // MARK: - Folders Section

    @ViewBuilder
    private func foldersSection(folderVM: FolderListViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsible header
            Button {
                withAnimation(MicroAnimation.snappy) {
                    foldersExpanded.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 8, weight: .bold, context: .list)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(foldersExpanded ? 0 : -90))
                        .animation(MicroAnimation.snappy, value: foldersExpanded)

                    Image(systemName: "folder")
                        .scaledFont(size: 10, weight: .semibold, context: .list)
                        .foregroundStyle(theme.textTertiary)
                    Text("Folders")
                        .scaledFont(size: 12, weight: .medium, context: .list)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Button { showCreateFolderSheet = true } label: {
                        Image(systemName: "folder.badge.plus")
                            .scaledFont(size: 13, context: .list)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Use rootFolders (tree with childFolders populated) for proper subfolder nesting
            if foldersExpanded {
                ForEach(folderVM.rootFolders) { folder in
                    DrawerFolderRow(
                        folder: folder,
                        folderVM: folderVM,
                        allConversations: listViewModel.conversations,
                        activeConversationId: activeConversationId,
                        activeFolderWorkspaceId: activeFolderWorkspaceId,
                        onSelectChat: { chatId in
                            activeConversationId = chatId
                            activeFolderWorkspaceId = nil
                            SharedDataService.shared.saveLastActiveConversationId(chatId)
                            // No drawer to close on iPad — sidebar stays visible
                        },
                        onSelectFolder: onSelectFolder,
                        onChatMoved: { chatId, targetFolderId in
                            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == chatId }) {
                                listViewModel.conversations[idx].folderId = targetFolderId
                            } else if targetFolderId == nil {
                                let folderChats = folderVM.folders.flatMap(\.chats)
                                if var conv = folderChats.first(where: { $0.id == chatId }) {
                                    conv.folderId = nil
                                    listViewModel.conversations.insert(conv, at: 0)
                                }
                            }
                        },
                        onDeleteChat: { chatId in
                            Task {
                                await listViewModel.deleteConversation(id: chatId)
                                // Clear from all folders (root + subfolders) to avoid stale UI
                                for fIdx in folderVM.folders.indices {
                                    folderVM.folders[fIdx].chats.removeAll { $0.id == chatId }
                                }
                                if activeConversationId == chatId { onNewChat() }
                            }
                        },
                        onTogglePin: { conversation in
                            Task { await listViewModel.togglePin(conversation: conversation) }
                        },
                        onDeleteConversation: { chatId in
                            await listViewModel.deleteConversation(id: chatId)
                            for fIdx in folderVM.folders.indices {
                                folderVM.folders[fIdx].chats.removeAll { $0.id == chatId }
                            }
                            if activeConversationId == chatId { onNewChat() }
                        },
                        onShareChat: { conversation in
                            sharingConversation = conversation
                        },
                        onExportChat: { conversation, format in
                            let ipadFormat: iPadMainChatView.ExportFormat
                            switch format {
                            case .json: ipadFormat = .json
                            case .txt: ipadFormat = .txt
                            case .pdf: ipadFormat = .pdf
                            }
                            onExport(conversation, ipadFormat)
                        },
                        onRenameChat: { conversation in
                            renamingConversation = conversation
                            renameText = conversation.title
                        },
                        onCloneChat: { conversation in
                            Task {
                                guard let manager = dependencies.conversationManager else { return }
                                let cloned = try? await manager.cloneConversation(id: conversation.id)
                                if let cloned {
                                    await listViewModel.refreshConversations()
                                    activeConversationId = cloned.id
                                }
                            }
                        },
                        onArchiveChat: { conversation in
                            Task {
                                await listViewModel.toggleArchive(conversation: conversation)
                                if !conversation.archived && activeConversationId == conversation.id {
                                    activeConversationId = nil
                                    onNewChat()
                                }
                            }
                        },
                        onShareFolder: { folder in
                            Task { await folderVM.beginEdit(folder: folder) }
                        }
                    )
                    .padding(.horizontal, Spacing.sm)
                }
            }
        }
        .animation(.easeInOut(duration: AnimDuration.medium), value: folderVM.folders.map(\.id))
    }

    // MARK: - Shared Folders Section

    @ViewBuilder
    private func sharedFoldersSection(folderVM: FolderListViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(MicroAnimation.snappy) {
                    sharedFoldersExpanded.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 8, weight: .bold, context: .list)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(sharedFoldersExpanded ? 0 : -90))
                        .animation(MicroAnimation.snappy, value: sharedFoldersExpanded)

                    Image(systemName: "person.2.fill")
                        .scaledFont(size: 10, weight: .semibold, context: .list)
                        .foregroundStyle(theme.textTertiary)

                    Text("Shared with Me")
                        .scaledFont(size: 12, weight: .medium, context: .list)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if sharedFoldersExpanded {
                ForEach(folderVM.sharedFolders) { folder in
                    sharedFolderRow(folder: folder, folderVM: folderVM)
                        .padding(.horizontal, Spacing.sm)
                }
            }
        }
        .animation(.easeInOut(duration: AnimDuration.medium), value: folderVM.sharedFolders.map(\.id))
    }

    @ViewBuilder
    private func sharedFolderRow(folder: ChatFolder, folderVM: FolderListViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await folderVM.toggleSharedFolderExpanded(folder: folder) }
                Haptics.play(.light)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 8, weight: .bold, context: .list)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                        .animation(MicroAnimation.snappy, value: folder.isExpanded)

                    Image(systemName: "folder.fill.badge.person.crop")
                        .scaledFont(size: 13, context: .list)
                        .foregroundStyle(theme.brandPrimary.opacity(0.8))

                    Text(folder.name)
                        .scaledFont(size: 14, context: .list)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    if folder.readonly {
                        Image(systemName: "eye")
                            .scaledFont(size: 10, context: .list)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if folder.isExpanded {
                if folder.chats.isEmpty {
                    Text("No chats")
                        .scaledFont(size: 13, context: .list)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.md + 20)
                        .padding(.vertical, 4)
                } else {
                    ForEach(folder.chats) { chat in
                        Button {
                            activeConversationId = chat.id
                            activeFolderWorkspaceId = nil
                            SharedDataService.shared.saveLastActiveConversationId(chat.id)
                        } label: {
                            HStack {
                                Text(chat.title)
                                    .scaledFont(size: 13, context: .list)
                                    .fontWeight(activeConversationId == chat.id ? .semibold : .regular)
                                    .foregroundStyle(
                                        activeConversationId == chat.id ? theme.textPrimary : theme.textSecondary
                                    )
                                    .lineLimit(1)
                                Spacer()
                                if folder.readonly {
                                    Image(systemName: "lock.fill")
                                        .scaledFont(size: 9, context: .list)
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }
                            .padding(.leading, Spacing.md + 20)
                            .padding(.trailing, Spacing.md)
                            .padding(.vertical, 6)
                            .background(
                                activeConversationId == chat.id
                                    ? theme.brandPrimary.opacity(0.08)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transaction { $0.animation = nil }
                    }
                }
            }
        }
    }

    // MARK: - Channels Section

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsible header
            Button {
                withAnimation(MicroAnimation.snappy) {
                    channelsExpanded.toggle()
                }
                Haptics.play(.light)
            } label: {
                drawerSectionLabel(
                    title: "Channels",
                    icon: "bubble.left.and.bubble.right",
                    isExpanded: channelsExpanded,
                    trailingButton: {
                        AnyView(
                            Button {
                                showCreateChannel = true
                            } label: {
                                Image(systemName: "plus")
                                    .scaledFont(size: 11, weight: .semibold, context: .list)
                                    .foregroundStyle(theme.textTertiary)
                                    .frame(width: 22, height: 22)
                                    .background(theme.surfaceContainer)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        )
                    }
                )
            }
            .buttonStyle(.plain)

            if channelsExpanded {
                if channelListVM.channels.isEmpty {
                    Text("No channels yet")
                        .scaledFont(size: 13, context: .list)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 4)
                } else {
                    // DMs first
                    if !channelListVM.dmChannels.isEmpty {
                        channelGroupLabel("Direct Messages", icon: "person.crop.circle")
                        ForEach(channelListVM.dmChannels) { channel in
                            channelRow(channel)
                        }
                    }
                    // Groups
                    if !channelListVM.groupChannels.isEmpty {
                        channelGroupLabel("Groups", icon: "person.3")
                        ForEach(channelListVM.groupChannels) { channel in
                            channelRow(channel)
                        }
                    }
                    // Standard channels
                    if !channelListVM.standardChannels.isEmpty {
                        channelGroupLabel("Channels", icon: "number")
                        ForEach(channelListVM.standardChannels) { channel in
                            channelRow(channel)
                        }
                    }
                }
            }
        }
    }

    /// Small sub-group label inside the channels section (mirrors iPhone drawer).
    @ViewBuilder
    private func channelGroupLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .scaledFont(size: 9, weight: .medium, context: .list)
                .foregroundStyle(theme.textTertiary.opacity(0.7))
            Text(title)
                .scaledFont(size: 10, weight: .medium, context: .list)
                .foregroundStyle(theme.textTertiary.opacity(0.7))
                .textCase(.uppercase)
                .tracking(0.4)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// A single channel row in the sidebar (with context menu for hide/delete).
    @ViewBuilder
    private func channelRow(_ channel: Channel) -> some View {
        Button {
            activeChannelId = channel.id
            activeConversationId = nil
            onCloseDrawer?()
        } label: {
            ChannelSidebarRowLabel(
                channel: channel,
                isActive: activeChannelId == channel.id,
                serverBaseURL: dependencies.apiClient?.baseURL ?? "",
                authToken: dependencies.apiClient?.network.authToken
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = "openui://channel/\(channel.id)"
                Haptics.play(.light)
            } label: {
                Label("Copy Channel Link", systemImage: "link")
            }
            if channel.type == .dm {
                Button {
                    channelListVM.hideDM(channelId: channel.id)
                    Haptics.play(.light)
                } label: {
                    Label("Hide Conversation", systemImage: "eye.slash")
                }
            } else if dependencies.authViewModel.currentUser?.role == .admin
                        || channel.userId == dependencies.authViewModel.currentUser?.id {
                // Web parity (ChannelItem.svelte): only admins or the channel owner can manage it.
                Button(role: .destructive) {
                    deletingChannelId = channel.id
                } label: {
                    Label("Delete Channel", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Chats Section

    @ViewBuilder
    private func chatsSection(folderVM: FolderListViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsible header
            Button {
                withAnimation(MicroAnimation.snappy) {
                    chatsExpanded.toggle()
                }
                Haptics.play(.light)
            } label: {
                drawerSectionLabel(
                    title: drawerChatsDropActive ? "Drop here" : "Chats",
                    icon: "bubble.left.and.text.bubble.right",
                    isExpanded: chatsExpanded,
                    tintOverride: drawerChatsDropActive ? theme.brandPrimary : nil
                )
            }
            .buttonStyle(.plain)
            // Web Sidebar: Chats header "More" menu → Mark all as read.
            .overlay(alignment: .trailing) {
                ChatsHeaderMoreMenu(
                    conversations: listViewModel.conversations + listViewModel.pinnedConversations,
                    folders: folderVM.folders,
                    apiClient: dependencies.apiClient)
                    .padding(.trailing, Spacing.sm)
            }

            if chatsExpanded {
                // LazyVStack so only visible rows are created.
                // Section headers are inlined as direct children
                // so they don't prevent lazy row creation.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    // ── Pinned sub-section ────────────────────
                    if !listViewModel.pinnedConversations.isEmpty {
                        sidebarSubSectionHeader(title: "Pinned", sectionKey: "Pinned")

                        if !collapsedSections.contains("Pinned") {
                            ForEach(listViewModel.pinnedConversations) { conversation in
                                conversationRow(conversation)
                                    .frame(minHeight: 36)
                                    .transition(.opacity)
                            }
                        }
                    }

                    // ── Time-grouped sub-sections ─────────────
                    ForEach(listViewModel.groupedConversations, id: \.0) { group in
                        let sectionKey = group.0
                        let isCollapsed = collapsedSections.contains(sectionKey)

                        sidebarSubSectionHeader(
                            title: sectionKey,
                            count: group.1.count,
                            sectionKey: sectionKey
                        )

                        if !isCollapsed {
                            ForEach(group.1) { conversation in
                                conversationRow(conversation)
                                    .frame(minHeight: 36)
                                    .transition(.opacity)
                            }
                        }
                    }
                }
            }
        }
        .background(drawerChatsDropActive ? theme.brandPrimary.opacity(0.05) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .stroke(theme.brandPrimary, lineWidth: drawerChatsDropActive ? 1.5 : 0)
                .padding(.horizontal, 2)
        )
        .animation(.easeInOut(duration: AnimDuration.fast), value: drawerChatsDropActive)
        .dropDestination(for: DraggableChat.self) { items, _ in
            guard let item = items.first, item.currentFolderId != nil else { return false }
            let chatId = item.conversationId
            let folderChats = folderVM.folders.flatMap(\.chats)
            let conversation = folderChats.first(where: { $0.id == chatId })
                ?? listViewModel.conversations.first(where: { $0.id == chatId })
            guard let conversation else { return false }
            withAnimation(MicroAnimation.snappy) { drawerChatsDropActive = false; folderVM.dragCompleted() }
            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == chatId }) {
                listViewModel.conversations[idx].folderId = nil
            } else {
                var conv = conversation; conv.folderId = nil
                listViewModel.conversations.insert(conv, at: 0)
            }
            Task { await folderVM.moveChat(conversation: conversation, to: nil) }
            return true
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: AnimDuration.fast)) { drawerChatsDropActive = isTargeted }
        }
    }

    // MARK: - Sidebar Sub-Section Header (for LazyVStack chat groups)

    @ViewBuilder
    private func sidebarSubSectionHeader(title: String, count: Int? = nil, sectionKey: String) -> some View {
        let isCollapsed = collapsedSections.contains(sectionKey)
        Button {
            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                var keys = collapsedSectionsRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
                if isCollapsed {
                    keys.removeAll { $0 == sectionKey }
                } else {
                    if !keys.contains(sectionKey) { keys.append(sectionKey) }
                }
                collapsedSectionsRaw = keys.sorted().joined(separator: ",")
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .scaledFont(size: 8, weight: .bold, context: .list)
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .animation(.easeInOut(duration: AnimDuration.fast), value: isCollapsed)
                Text(title)
                    .scaledFont(size: 12, weight: .medium, context: .list)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                if let count {
                    Text("\(count)")
                        .scaledFont(size: 10, weight: .medium, context: .list)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.surfaceContainer).clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.md).padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Conversation Row

    @ViewBuilder
    private func conversationRow(_ conversation: Conversation) -> some View {
        if listViewModel.isSelectionMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        listViewModel.toggleSelection(for: conversation.id)
                    }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: listViewModel.isSelected(conversation.id)
                            ? "checkmark.circle.fill" : "circle")
                            .scaledFont(size: 18, context: .list)
                            .foregroundStyle(listViewModel.isSelected(conversation.id)
                                ? theme.brandPrimary : theme.textTertiary)
                        Text(conversation.title)
                            .scaledFont(size: 14, context: .list)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 7)
                    .background(listViewModel.isSelected(conversation.id)
                        ? theme.brandPrimary.opacity(0.1) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
        } else {
                Button {
                    let targetId = conversation.id
                    guard targetId != activeConversationId else {
                        // Already on this chat — just close the drawer
                        onCloseDrawer?()
                        return
                    }
                    dependencies.activeChatStore.prewarm(conversationId: targetId, using: dependencies)
                    onChatSwitching?()
                    activeConversationId = targetId
                    activeChannelId = nil
                    activeFolderWorkspaceId = nil
                    SharedDataService.shared.saveLastActiveConversationId(targetId)
                    onCloseDrawer?()
                    Haptics.play(.light)
                } label: {
                    let isActive = activeConversationId == conversation.id
                    HStack {
                        ChatUnreadDot(conversation: conversation, activeChatStore: dependencies.activeChatStore)
                        Text(conversation.title)
                            .scaledFont(size: 14, context: .list)
                            .fontWeight(isActive ? .semibold : .regular)
                            .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        // Dedicated child view so @Observable tracks the replying set reactively.
                        // Falls back to the active dot when not streaming.
                        iPadConversationTrailingIndicator(
                            conversationId: conversation.id,
                            activeChatStore: dependencies.activeChatStore,
                            isActive: isActive,
                            tint: theme.brandPrimary
                        )
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 7)
                    .background(
                        isActive
                            ? theme.brandPrimary.opacity(0.08)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sidebarRow)
                // Suppress implicit animations on selection state change to prevent sidebar bounce
                .transaction { $0.animation = nil }
                .draggable(DraggableChat(
                    conversationId: conversation.id,
                    currentFolderId: conversation.folderId
                )) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "bubble.left").scaledFont(size: 12, context: .list)
                        Text(conversation.title)
                            .scaledFont(size: 12, weight: .medium, context: .list)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .contextMenu {
                    iPadConversationContextMenu(
                        conversation: conversation,
                        listViewModel: listViewModel,
                        dependencies: dependencies,
                        activeConversationId: $activeConversationId,
                        sharingConversation: $sharingConversation,
                        renamingConversation: $renamingConversation,
                        renameText: $renameText,
                        deletingConversation: $deletingConversation,
                        onExport: onExport
                    )
                }
        }
    }

    // MARK: - Bottom Bars

    private var selectionBottomBar: some View {
        VStack(spacing: Spacing.sm) {
            // Move to Folder button
            Button {
                showMoveSelectedToFolderSheet = true
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "folder.badge.plus")
                    Text("Move to Folder (\(listViewModel.selectedCount))")
                }
                .scaledFont(size: 14, weight: .medium, context: .list)
                .fontWeight(.semibold)
                .foregroundStyle(listViewModel.selectedCount > 0 ? theme.brandPrimary : theme.brandPrimary.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    listViewModel.selectedCount > 0
                        ? theme.brandPrimary.opacity(0.12)
                        : theme.brandPrimary.opacity(0.05)
                )
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            }
            .disabled(listViewModel.selectedCount == 0)

            // Delete button
            Button(role: .destructive) {
                showDeleteSelectedConfirmation = true
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "trash")
                    Text("Delete Selected (\(listViewModel.selectedCount))")
                }
                .scaledFont(size: 14, weight: .medium, context: .list)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(listViewModel.selectedCount > 0 ? Color.red : Color.red.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            }
            .disabled(listViewModel.selectedCount == 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
        .background(theme.surfaceContainer.opacity(0.3))
        .sheet(isPresented: $showMoveSelectedToFolderSheet) {
            MoveToFolderSheet(
                folders: listViewModel.folderViewModel.folders,
                selectedCount: listViewModel.selectedCount
            ) { targetFolderId in
                let selectedIds = listViewModel.selectedConversationIds
                let folderVM = listViewModel.folderViewModel
                Task {
                    for id in selectedIds {
                        if let conversation = listViewModel.conversations.first(where: { $0.id == id }) {
                            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == id }) {
                                listViewModel.conversations[idx].folderId = targetFolderId
                            }
                            await folderVM.moveChat(conversation: conversation, to: targetFolderId)
                        }
                    }
                }
                listViewModel.exitSelectionMode()
            }
        }
    }

    private var sidebarBottomBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                // Real user avatar + full name — tap → Settings, long-press → Account Picker
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        UserAvatar(
                            size: 32,
                            imageURL: {
                                guard let userId = dependencies.authViewModel.currentUser?.id,
                                      let baseURL = dependencies.apiClient?.baseURL,
                                      !userId.isEmpty, !baseURL.isEmpty else { return nil }
                                let v = dependencies.authViewModel.profileImageVersion
                                return URL(string: "\(baseURL)/api/v1/users/\(userId)/profile/image?v=\(v)")
                            }(),
                            name: dependencies.authViewModel.currentUser?.displayName ?? "User",
                            authToken: dependencies.apiClient?.network.authToken,
                            dataURIString: dependencies.authViewModel.currentUser?.profileImageURL
                        )

                    }
                    Text(dependencies.authViewModel.currentUser?.displayName ?? "User")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) {
                    Haptics.play(.medium)
                    dependencies.authViewModel.showAccountPicker = true
                }
                .simultaneousGesture(TapGesture().onEnded {
                    showSettings = true
                })

                Spacer()

                // Update available icon — visible when app or server update is pending
                if dependencies.updateChecker.pendingUpdate != nil || dependencies.serverUpdateChecker.pendingUpdate != nil {
                    Button {
                        showUpdateSheet = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "arrow.down.circle.fill")
                                .scaledFont(size: 16, weight: .medium)
                                .foregroundStyle(.tint)
                            // Extra dot badge when both updates are pending
                            if dependencies.updateChecker.pendingUpdate != nil && dependencies.serverUpdateChecker.pendingUpdate != nil {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 2, y: -2)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Update Available")
                    .transition(.scale.combined(with: .opacity))
                    .sheet(isPresented: $showUpdateSheet) {
                        CombinedUpdateSheet(
                            appUpdate: dependencies.updateChecker.pendingUpdate,
                            serverUpdate: dependencies.serverUpdateChecker.pendingUpdate,
                            onDismiss: {
                                dependencies.updateChecker.dismissUpdate()
                                dependencies.serverUpdateChecker.dismissUpdate()
                            }
                        )
                        .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                    }
                }

                // New Chat — primary action, always visible
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("New Chat")

                // More menu — secondary actions tucked away cleanly
                Menu {
                    if dependencies.authViewModel.featurePermissions.memories {
                        Button { showMemories = true } label: {
                            Label("Memories", systemImage: "brain.head.profile")
                        }
                    }
                    if dependencies.authViewModel.hasAnyWorkspaceAccess {
                        Button { showWorkspace = true } label: {
                            Label("Workspace", systemImage: "square.grid.2x2")
                        }
                    }

                    if dependencies.authViewModel.featurePermissions.notes
                        && (dependencies.authViewModel.backendConfig?.features?.enableNotes ?? true) {
                        Button { showNotes = true } label: {
                            Label("Notes", systemImage: "note.text")
                        }
                    }

                    if dependencies.authViewModel.featurePermissions.calendar {
                        Button { showCalendar = true } label: {
                            Label("Calendar", systemImage: "calendar")
                        }
                    }

                    if dependencies.authViewModel.featurePermissions.automations
                        && (dependencies.authViewModel.backendConfig?.features?.enableAutomations ?? true) {
                        Button { showAutomations = true } label: {
                            Label("Automations", systemImage: "clock.arrow.circlepath")
                        }
                    }

                    Button { showUserSettings = true } label: {
                        Label("My Defaults", systemImage: "slider.horizontal.3")
                    }

                    Divider()

                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

                    if dependencies.authViewModel.currentUser?.role == .admin {
                        Button { showAdminConsole = true } label: {
                            Label("Admin Console", systemImage: "shield.lefthalf.filled")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .scaledFont(size: 18, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
        }
        .background(theme.sidebarBackground)
    }
}

// MARK: - Context Menu (iPad Sidebar)

private struct iPadConversationTrailingIndicator: View {
    let conversationId: String
    let activeChatStore: ActiveChatStore
    let isActive: Bool
    let tint: Color

    private var isStreaming: Bool {
        // Replying on this device, or being generated by another device.
        activeChatStore.isStreaming(conversationId)
            || ChatReadState.shared.generatingElsewhere.contains(conversationId)
    }

    var body: some View {
        // Same as the iPhone drawer: a spinner while streaming, nothing otherwise
        // (the row's highlight already marks the open chat).
        if isStreaming {
            ProgressView()
                .controlSize(.mini)
                .tint(tint)
                .transition(.opacity.combined(with: .scale))
                .animation(MicroAnimation.quick, value: isStreaming)
        }
    }
}

private struct iPadConversationContextMenu: View {
    let conversation: Conversation
    let listViewModel: ChatListViewModel
    let dependencies: AppDependencyContainer
    @Binding var activeConversationId: String?
    @Binding var sharingConversation: Conversation?
    @Binding var renamingConversation: Conversation?
    @Binding var renameText: String
    @Binding var deletingConversation: Conversation?
    let onExport: (Conversation, iPadMainChatView.ExportFormat) -> Void

    var body: some View {
        // Share
        Button {
            sharingConversation = conversation
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        // Download submenu (matching WebUI)
        Menu {
            Button { onExport(conversation, .json) } label: {
                Label("Export chat (.json)", systemImage: "doc")
            }
            Button { onExport(conversation, .txt) } label: {
                Label("Plain text (.txt)", systemImage: "doc.plaintext")
            }
            Button { onExport(conversation, .pdf) } label: {
                Label("PDF document (.pdf)", systemImage: "doc.richtext")
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }

        Divider()

        // Rename
        Button {
            renamingConversation = conversation
            renameText = conversation.title
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        // Pin
        Button {
            Task { await listViewModel.togglePin(conversation: conversation) }
        } label: {
            Label(conversation.pinned ? "Unpin" : "Pin",
                  systemImage: conversation.pinned ? "pin.slash" : "pin")
        }

        // Mark as Unread (web ChatMenu)
        MarkUnreadMenuItem(conversation: conversation, apiClient: dependencies.apiClient,
                           isOpen: activeConversationId == conversation.id)

        // Clone
        Button {
            Task {
                guard let manager = dependencies.conversationManager else { return }
                if let cloned = try? await manager.cloneConversation(id: conversation.id) {
                    await listViewModel.refreshConversations()
                    activeConversationId = cloned.id
                }
            }
        } label: {
            Label("Clone", systemImage: "doc.on.doc")
        }

        // Archive
        Button {
            Task {
                await listViewModel.toggleArchive(conversation: conversation)
                if !conversation.archived && activeConversationId == conversation.id {
                    activeConversationId = nil
                }
            }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }

        // Move to folder submenu
        let folders = listViewModel.folderViewModel.folders
        if !folders.isEmpty {
            Menu("Move to Folder") {
                // Remove from folder option when the chat is currently in one
                if conversation.folderId != nil {
                    Button {
                        let conv = conversation
                        Task {
                            await listViewModel.folderViewModel.moveChat(conversation: conv, to: nil)
                            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == conv.id }) {
                                listViewModel.conversations[idx].folderId = nil
                            }
                        }
                    } label: {
                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                    }
                }
                ForEach(folders) { folder in
                    Button {
                        let conv = conversation
                        Task {
                            await listViewModel.folderViewModel.moveChat(conversation: conv, to: folder.id)
                            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == conv.id }) {
                                listViewModel.conversations[idx].folderId = folder.id
                            }
                        }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                    .disabled(folder.id == conversation.folderId)
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            Haptics.notify(.warning)
            deletingConversation = conversation
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - View Modifier Helpers

private extension View {
    func applySheets(
        showSettings: Binding<Bool>,
        showNotes: Binding<Bool>,
        showCreateFolderSheet: Binding<Bool>,
        sharingConversation: Binding<Conversation?>,
        renamingConversation: Binding<Conversation?>,
        renameText: Binding<String>,
        isGeneratingTitle: Binding<Bool>,
        exportFileURL: Binding<URL?>,
        showExportShareSheet: Binding<Bool>,
        showDeleteAllConfirmation: Binding<Bool>,
        showDeleteSelectedConfirmation: Binding<Bool>,
        showArchivedChats: Binding<Bool>,
        showSharedChats: Binding<Bool>,
        listViewModel: ChatListViewModel,
        activeConversationId: Binding<String?>,
        voiceCallBinding: Binding<Bool>,
        systemColorScheme: ColorScheme,
        dependencies: AppDependencyContainer,
        router: AppRouter,
        onExport: @escaping (Conversation, iPadMainChatView.ExportFormat) -> Void,
        onGenerateTitle: @escaping (Conversation) -> Void
    ) -> some View {
        self
            .sheet(isPresented: showSettings) {
                SettingsView(
                    viewModel: dependencies.authViewModel,
                    appearanceManager: dependencies.appearanceManager
                )
                .preferredColorScheme(dependencies.appearanceManager.resolvedColorScheme ?? systemColorScheme)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                .presentationCornerRadius(20)
            }
            .sheet(isPresented: showNotes) {
                NavigationStack {
                    NotesListView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Close", systemImage: "xmark") {
                                    showNotes.wrappedValue = false
                                }
                                .labelStyle(.iconOnly)
                                .tint(.secondary)
                            }
                        }
                }
                .presentationCornerRadius(20)
            }
            .sheet(isPresented: voiceCallBinding, onDismiss: {
                // Dragging the sheet down counts as minimizing if the call is still active.
                if !router.isVoiceCallMinimized, router.voiceCallViewModel != nil {
                    router.minimizeVoiceCall()
                }
            }) {
                if let voiceCallVM = router.voiceCallViewModel {
                    VoiceCallView(
                        viewModel: voiceCallVM,
                        onMinimize: { router.minimizeVoiceCall() },
                        onDismiss: { router.dismissVoiceCall() }
                    )
                        .environment(dependencies)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.hidden)
                        .presentationCornerRadius(24)
                        .presentationBackground(.ultraThinMaterial)
                        .interactiveDismissDisabled(false)
                }
            }
            .onChange(of: router.isVoiceCallPresented) { _, isPresented in
                if !isPresented && !router.isVoiceCallMinimized { router.voiceCallViewModel = nil }
            }
            .sheet(isPresented: showCreateFolderSheet) {
                CreateFolderSheet(apiClient: dependencies.apiClient) { name, data, meta in
                    let parentId = listViewModel.folderViewModel.createSubfolderParentId
                    listViewModel.folderViewModel.createSubfolderParentId = nil
                    Task {
                        await listViewModel.folderViewModel.createFolder(
                            name: name, parentId: parentId, data: data, meta: meta
                        )
                    }
                }
            }
            // Edit folder sheet — allows changing name, system prompt, knowledge
            .sheet(item: Binding(
                get: { listViewModel.folderViewModel.editingFolder },
                set: { listViewModel.folderViewModel.editingFolder = $0 }
            )) { folder in
                EditFolderSheet(
                    folder: folder,
                    apiClient: dependencies.apiClient
                ) { name, data, meta in
                    Task {
                        await listViewModel.folderViewModel.updateFolderSettings(
                            id: folder.id,
                            name: name,
                            data: data,
                            meta: meta
                        )
                    }
                }
            }
            .alert("Rename Folder", isPresented: .init(
                get: { listViewModel.folderViewModel.renamingFolder != nil },
                set: { if !$0 { listViewModel.folderViewModel.renamingFolder = nil } }
            )) {
                TextField("Folder Name", text: Bindable(listViewModel.folderViewModel).renameText)
                Button("Cancel", role: .cancel) { listViewModel.folderViewModel.renamingFolder = nil }
                Button("Rename") { Task { await listViewModel.folderViewModel.commitRename() } }
            }
            .sheet(item: renamingConversation) { conv in
                iPadRenameSheet(
                    conversation: conv,
                    renameText: renameText,
                    isGeneratingTitle: isGeneratingTitle,
                    listViewModel: listViewModel,
                    activeConversationId: activeConversationId,
                    onGenerateTitle: onGenerateTitle
                )
            }
            .sheet(isPresented: showExportShareSheet, onDismiss: {
                if let url = exportFileURL.wrappedValue {
                    try? FileManager.default.removeItem(at: url)
                    exportFileURL.wrappedValue = nil
                }
            }) {
                if let url = exportFileURL.wrappedValue {
                    ShareSheet(items: [url])
                }
            }
            // Share chat sheet (matching iPhone)
            .sheet(item: sharingConversation) { conversation in
                if let apiClient = dependencies.apiClient {
                    ShareChatSheet(
                        conversation: conversation,
                        apiClient: apiClient,
                        serverBaseURL: apiClient.baseURL,
                        onShareIdUpdated: { shareId in
                            listViewModel.updateShareId(for: conversation.id, shareId: shareId)
                        },
                        onClone: { cloned in
                            activeConversationId.wrappedValue = cloned.id
                            SharedDataService.shared.saveLastActiveConversationId(cloned.id)
                        }
                    )
                    .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                }
            }
            // Archived chats sheet
            .sheet(isPresented: showArchivedChats) {
                ArchivedChatsView()
                    .environment(dependencies)
                    .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            }
            // Shared chats sheet
            .sheet(isPresented: showSharedChats) {
                SharedChatsView()
                    .environment(dependencies)
                    .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            }
            // Account picker sheet (multi-account per server)
            .sheet(isPresented: Bindable(dependencies.authViewModel).showAccountPicker) {
                AccountPickerSheet(
                    viewModel: dependencies.authViewModel,
                    onDismiss: { dependencies.authViewModel.showAccountPicker = false }
                )
                .environment(dependencies)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            }
    }

    func applyAlerts(
        showDeleteAllConfirmation: Binding<Bool>,
        showDeleteSelectedConfirmation: Binding<Bool>,
        deletingConversation: Binding<Conversation?>,
        deletingChannelId: Binding<String?>,
        exportError: Binding<String?>,
        listViewModel: ChatListViewModel,
        activeConversationId: Binding<String?>,
        activeChannelId: Binding<String?>,
        channelListVM: ChannelListViewModel,
        dependencies: AppDependencyContainer,
        onStartNewChat: @escaping () -> Void
    ) -> some View {
        self
            .confirmationDialog("Archive All Chats",
                isPresented: .constant(listViewModel.showArchiveAllConfirmation),
                titleVisibility: .visible) {
                Button("Archive All", role: .destructive) {
                    Task {
                        await listViewModel.archiveAllConversations()
                        activeConversationId.wrappedValue = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will archive all your conversations. You can unarchive them later from the web interface.")
            }
            .confirmationDialog("Delete All Chats",
                isPresented: showDeleteAllConfirmation,
                titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    Task {
                        await listViewModel.deleteAllConversations()
                        onStartNewChat()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all your conversations. This action cannot be undone.")
            }
            .confirmationDialog("Delete Selected Chats",
                isPresented: showDeleteSelectedConfirmation,
                titleVisibility: .visible) {
                Button("Delete \(listViewModel.selectedCount) Chat\(listViewModel.selectedCount == 1 ? "" : "s")", role: .destructive) {
                    let shouldResetToNewChat = activeConversationId.wrappedValue.map { listViewModel.selectedConversationIds.contains($0) } ?? false
                    Task {
                        await listViewModel.deleteSelectedConversations()
                        if shouldResetToNewChat { onStartNewChat() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete \(listViewModel.selectedCount) selected conversation\(listViewModel.selectedCount == 1 ? "" : "s"). This action cannot be undone.")
            }
            // Single-conversation delete confirmation
            .confirmationDialog(
                "Delete \"\(deletingConversation.wrappedValue?.title ?? "")\"?",
                isPresented: .init(
                    get: { deletingConversation.wrappedValue != nil },
                    set: { if !$0 { deletingConversation.wrappedValue = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let conversation = deletingConversation.wrappedValue {
                        let deletedId = conversation.id
                        deletingConversation.wrappedValue = nil
                        Task {
                            await listViewModel.deleteConversation(id: deletedId)
                            if activeConversationId.wrappedValue == deletedId {
                                onStartNewChat()
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    deletingConversation.wrappedValue = nil
                }
            } message: {
                Text("This action cannot be undone.")
            }
            // Channel delete confirmation
            .confirmationDialog(
                "Delete Channel?",
                isPresented: .init(
                    get: { deletingChannelId.wrappedValue != nil },
                    set: { if !$0 { deletingChannelId.wrappedValue = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Channel", role: .destructive) {
                    if let channelId = deletingChannelId.wrappedValue {
                        let wasActive = activeChannelId.wrappedValue == channelId
                        deletingChannelId.wrappedValue = nil
                        Task {
                            try? await dependencies.apiClient?.deleteChannel(id: channelId)
                            await channelListVM.refreshChannels()
                            if wasActive { onStartNewChat() }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    deletingChannelId.wrappedValue = nil
                }
            } message: {
                Text("This will permanently delete this channel and all its messages.")
            }
            .alert("Export Failed",
                   isPresented: .init(get: { exportError.wrappedValue != nil },
                                      set: { if !$0 { exportError.wrappedValue = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportError.wrappedValue ?? "") }
    }

    func applyLifecycle(
        listViewModel: ChatListViewModel,
        dependencies: AppDependencyContainer,
        scenePhase: ScenePhase,
        activeConversationId: Binding<String?>,
        activeChannelId: Binding<String?> = .constant(nil),
        activeFolderWorkspaceId: Binding<String?> = .constant(nil),
        newChatGeneration: Binding<Int> = .constant(0),
        channelListVM: ChannelListViewModel? = nil,
        hasRegisteredSocketHandlers: Binding<Bool>,
        showCreateChannel: Binding<Bool> = .constant(false),
        showSettings: Binding<Bool> = .constant(false),
        showNotes: Binding<Bool> = .constant(false),
        showCreateFolderSheet: Binding<Bool> = .constant(false),
        showExportShareSheet: Binding<Bool> = .constant(false),
        onSocketSetup: @escaping () -> Void
    ) -> some View {
        self
            .task {
                if let manager = dependencies.conversationManager {
                    listViewModel.configure(with: manager)
                }
                if let folderManager = dependencies.folderManager {
                    listViewModel.folderViewModel.configure(with: folderManager)
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.loadConversations() }
                    group.addTask { await listViewModel.folderViewModel.loadFolders() }
                    group.addTask { await dependencies.fetchTaskConfig() }
                }
                // Restore the last active conversation after a cold launch or process kill.
                // activeConversationId is @State and resets to nil on every process restart.
                // SharedDataService persists the last-opened ID across kills so we can
                // land the user back in their chat instead of the blank new-chat screen.
                // Only restore if the conversation still exists in the loaded list — this
                // guards against navigating to a deleted or archived chat.
                if activeConversationId.wrappedValue == nil,
                   let lastId = SharedDataService.shared.lastActiveConversationId,
                   listViewModel.conversations.contains(where: { $0.id == lastId }) {
                    activeConversationId.wrappedValue = lastId
                }
                onSocketSetup()
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                guard newPhase == .active && oldPhase != .active else { return }
                let chatVM = dependencies.activeChatStore.viewModel(for: activeConversationId.wrappedValue)
                let lvm = listViewModel
                let deps = dependencies
                let cvm = channelListVM
                Task {
                    if let socket = deps.socketService, !socket.isConnected, !socket.isConnecting {
                        socket.connect()
                    }
                    // If backendConfig failed to load (e.g. app started offline), fetch it now.
                    // backendConfig drives feature flags, starter prompts, and model suggestions.
                    if deps.authViewModel.backendConfig == nil {
                        await deps.authViewModel.fetchBackendConfigIfNeeded()
                    }
                    // Let the first frames of the return land before the list refresh.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await lvm.refreshIfStale() }
                        group.addTask { await ChatReadState.shared.verifyGeneratingNow() }
                        group.addTask { await lvm.folderViewModel.refreshFolders() }
                        if let cvm { group.addTask { await cvm.refreshChannels() } }
                        group.addTask { await chatVM.fetchPinnedModels() }
                        group.addTask { await deps.fetchTaskConfig() }
                    }
                    // If models failed to load while offline, reload them now so starter
                    // prompts and the model picker populate correctly.
                    let newChatVM = deps.activeChatStore.viewModel(for: nil)
                    if newChatVM.availableModels.isEmpty {
                        await newChatVM.loadModels()
                    }
                    deps.updateWidgetData(conversations: lvm.conversations)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationTitleUpdated)) { notification in
                guard let userInfo = notification.userInfo,
                      let conversationId = userInfo["conversationId"] as? String,
                      let title = userInfo["title"] as? String else { return }
                listViewModel.updateTitle(for: conversationId, title: title)
                let folderVM = listViewModel.folderViewModel
                for idx in folderVM.folders.indices {
                    if let chatIdx = folderVM.folders[idx].chats.firstIndex(where: { $0.id == conversationId }) {
                        folderVM.folders[idx].chats[chatIdx].title = title
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationListNeedsRefresh)) { _ in
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await listViewModel.refreshConversations() }
                        group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                        if let channelListVM {
                            group.addTask { await channelListVM.refreshChannels() }
                        }
                    }
                    // If a folder workspace is active, reload its chats so that any new
                    // conversation created inside the folder appears under the folder
                    // instead of appearing stale or under normal chats.
                    if let folderId = activeFolderWorkspaceId.wrappedValue {
                        let folderVM = listViewModel.folderViewModel
                        if let idx = folderVM.folders.firstIndex(where: { $0.id == folderId }) {
                            folderVM.folders[idx].isExpanded = true
                            await folderVM.loadChatsIfNeeded(for: folderVM.folders[idx])
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUINavigateToChat)) { notification in
                // openui://chat/<id> deep link — select the requested conversation.
                // Works both on warm launch (app running) and after cold-start restore
                // (SharedDataService was already updated before this notification fired).
                if let conversationId = notification.object as? String {
                    showNotes.wrappedValue = false
                    activeConversationId.wrappedValue = conversationId
                    activeChannelId.wrappedValue = nil
                    SharedDataService.shared.saveLastActiveConversationId(conversationId)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIDismissOverlays)) { _ in
                // Quick action requested — dismiss any active sheet/cover so
                // the new action doesn't stack on top of the old one.
                showSettings.wrappedValue = false
                showNotes.wrappedValue = false
                showCreateChannel.wrappedValue = false
                showCreateFolderSheet.wrappedValue = false
                showExportShareSheet.wrappedValue = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUINewChannel)) { _ in
                // Widget "Channel" button — open the create-channel sheet
                showCreateChannel.wrappedValue = true
            }
            // Folder workspace chat list row tapped — open that conversation while
            // keeping the folder context (background image) intact.
            .onReceive(NotificationCenter.default.publisher(for: .folderWorkspaceChatSelected)) { notification in
                guard let chatId = notification.object as? String else { return }
                activeConversationId.wrappedValue = chatId
                // Keep activeFolderWorkspaceId set so the background image persists
                SharedDataService.shared.saveLastActiveConversationId(chatId)
            }
            .onChange(of: listViewModel.folderViewModel.activeFolderDetail) { _, detail in
                guard let detail,
                      detail.id == activeFolderWorkspaceId.wrappedValue else { return }
                // Merge: use the full detail's meta/data (backgroundImageUrl, icon, systemPrompt,
                // modelIds) but preserve the chats from the flat list folder so both the
                // background image AND the recent-chats list are always visible together.
                var merged = detail
                if merged.chats.isEmpty,
                   let flatFolder = listViewModel.folderViewModel.folders.first(where: { $0.id == detail.id }),
                   !flatFolder.chats.isEmpty {
                    merged.chats = flatFolder.chats
                }
                // Note: iPadMainChatView uses activeFolderWorkspaceId binding from parent;
                // the activeFolderForWorkspace @State is in iPadMainChatView itself — post
                // a notification so iPadMainChatView can update it.
                // Actually we update it directly via the drawerPanel's onSelectFolder callback
                // which is already wired. Here we just need to trigger the folder workspace
                // to rebuild by refreshing the folderVM. The actual activeFolderForWorkspace
                // update happens in iPadMainChatView.drawerPanel.onSelectFolder reactive path.
            }
            .onChange(of: dependencies.authViewModel.accountSwitchCount) {
                // Account was switched — perform a full reset so the new account's
                // conversations, folders, channels, and model selector all load fresh.
                // 1. Clear navigation state so no stale conversation/channel is shown.
                activeConversationId.wrappedValue = nil
                activeChannelId.wrappedValue = nil
                activeFolderWorkspaceId.wrappedValue = nil
                // 2. Clear the conversation/folder list immediately so stale chats vanish.
                listViewModel.clearAll()
                // 3. Purge all cached ChatViewModels (holds old account's messages/models).
                dependencies.activeChatStore.clear()
                // 4. Force the new-chat view to recreate so it picks up the new account's
                //    default model (cachedSelectedModelId was cleared by activeChatStore.clear()).
                newChatGeneration.wrappedValue += 1
                // 5. Reload all lists from the server for the new account.
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await listViewModel.refreshConversations() }
                        group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                        if let channelListVM {
                            group.addTask { await channelListVM.refreshChannels() }
                        }
                    }
                }
            }
    }
}

// MARK: - Rename Sheet (iPad)

private struct iPadRenameSheet: View {
    let conversation: Conversation
    @Binding var renameText: String
    @Binding var isGeneratingTitle: Bool
    let listViewModel: ChatListViewModel
    @Binding var activeConversationId: String?
    let onGenerateTitle: (Conversation) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                TextField("Chat title", text: $renameText)
                    .scaledFont(size: 16)
                    .padding(Spacing.md)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

                Button {
                    onGenerateTitle(conversation)
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if isGeneratingTitle {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGeneratingTitle ? "Generating..." : "Generate Title")
                    }
                    .scaledFont(size: 14, weight: .medium)
                    .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(theme.brandPrimary)
                .disabled(isGeneratingTitle)

                Spacer()
            }
            .padding(Spacing.lg)
            .navigationTitle("Rename Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !newTitle.isEmpty else { return }
                        listViewModel.renamingConversation = conversation
                        listViewModel.renameText = newTitle
                        Task { await listViewModel.commitRename() }
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }
}
