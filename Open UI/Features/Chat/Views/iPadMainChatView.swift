import SwiftUI

// MARK: - iPad Main Chat View
//
// Supports two layout modes controlled by the "ipad_sidebar_always_shown" AppStorage key:
//
// • Auto-hide (default): iPhone-style slide-out drawer — identical push/scale/blur
//   behaviour to MainChatView. The sidebar slides in from the left and pushes the
//   content card right, with scale/blur/corner-radius animation.
//
// • Always shown: Split-view layout — sidebar is a fixed left column (drawerWidth)
//   and the chat content fills the remaining space. No overlay, no push animation.
//   The hamburger button in ChatDetailView is hidden since there's no drawer to open.
//
// The preference is toggled from Settings → Appearance (iPad only) and persists
// across app restarts via AppStorage.

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

    /// Whether the memories sheet is visible.
    @State private var showMemories = false

    /// Whether the calendar sheet is visible.
    @State private var showCalendar = false

    /// Whether the automations sheet is visible.
    @State private var showAutomations = false

    /// Controls the My Defaults sheet presentation.
    @State private var showUserSettings = false

    /// Controls the drawer visibility (mirrors MainChatView).
    @State private var showDrawer = false

    /// Live drag offset for interactive drawer sliding.
    @State private var dragOffset: CGFloat = 0

    /// Whether a drawer drag is in progress (prevents animation fighting).
    @State private var isDraggingDrawer = false

    /// Cached container width from GeometryReader (avoids deprecated UIScreen.main).
    @State private var containerWidth: CGFloat = 768

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
    @State private var showTerminalBrowser: Bool = true

    // MARK: - Sidebar Layout Preference (iPad-only)

    /// When `true`, the sidebar is shown as a persistent left column instead of a slide-out drawer.
    /// Persisted via AppStorage so the preference survives app restarts.
    @AppStorage("ipad_sidebar_always_shown") private var sidebarAlwaysShown: Bool = false

    /// In always-shown mode, tracks whether the user has the sidebar column visible.
    /// Starts open but can be collapsed/expanded independently of the setting.
    @State private var splitSidebarVisible: Bool = true

    /// Live drag offset for the terminal browser trailing-edge swipe in always-shown mode.
    @State private var terminalDragOffset: CGFloat = 0
    /// Whether a terminal drag is in progress in always-shown mode.
    @State private var isDraggingTerminal: Bool = false

    // MARK: - Drawer Geometry (mirrors MainChatView)

    /// Drawer width — wider on iPad for comfortable reading (capped at 360pt).
    private var drawerWidth: CGFloat {
        min(containerWidth * 0.40, 360)
    }

    /// Effective drawer X offset (0 = fully open, -drawerWidth = fully closed).
    private var effectiveDrawerX: CGFloat {
        let base: CGFloat = showDrawer ? 0 : -drawerWidth
        let combined = base + dragOffset
        return min(0, max(-drawerWidth, combined))
    }

    /// Open fraction 0→1 — drives push animation on main content.
    private var drawerFraction: CGFloat {
        let fraction = (effectiveDrawerX + drawerWidth) / drawerWidth
        return min(1, max(0, fraction))
    }

    /// How far the main content card is pushed right.
    private var mainContentOffset: CGFloat { drawerFraction * drawerWidth }

    // MARK: - Body

    var body: some View {
        @Bindable var bindableRouter = router
        rootLayout(voiceCallBinding: $bindableRouter.isVoiceCallPresented)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                if abs(containerWidth - newWidth) > 1 {
                    containerWidth = newWidth
                }
            }
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
        // Reset drag state on background (prevents stale offset blocking hits on foreground)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                dragOffset = 0
                isDraggingDrawer = false
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
                NotificationCenter.default.post(name: .navigateToChannel, object: channelId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToChannel)) { notification in
            if let channelId = notification.object as? String {
                activeChannelId = channelId
                activeConversationId = nil
                Haptics.play(.light)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openUINewChatWithFocus)) { _ in
            // Widget "Ask Open Relay" bar — start new chat and auto-focus keyboard
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
        // Admin Console sheet (admin-only)
        .sheet(isPresented: $showAdminConsole) {
            NavigationStack {
                AdminConsoleView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                showAdminConsole = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.secondary)
                                    .frame(width: 32, height: 32)
                                    .background(Color(uiColor: .systemGray5).opacity(0.6))
                                    .clipShape(Circle())
                            }
                        }
                    }
            }
            .environment(dependencies)
            .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            .presentationCornerRadius(20)
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
                            Button {
                                showMemories = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.secondary)
                                    .frame(width: 32, height: 32)
                                    .background(Color(uiColor: .systemGray5).opacity(0.6))
                                    .clipShape(Circle())
                            }
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
    }

    // MARK: - Root Layout — branches between always-shown split and auto-hide drawer

    @ViewBuilder
    private func rootLayout(voiceCallBinding: Binding<Bool>) -> some View {
        if sidebarAlwaysShown {
            alwaysShownSplitLayout(voiceCallBinding: voiceCallBinding)
        } else {
            mainZStack(voiceCallBinding: voiceCallBinding)
        }
    }

    // MARK: - Always-Shown Split Layout

    /// Persistent split layout: collapsible sidebar column on the left, chat detail fills the rest.
    /// The terminal browser overlays from the trailing edge (same as auto-hide mode).
    /// The sidebar can be hidden/shown by the user independently of the always-shown setting.
    @ViewBuilder
    private func alwaysShownSplitLayout(voiceCallBinding: Binding<Bool>) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                // Sidebar column — animated in/out
                if splitSidebarVisible {
                    NavigationStack {
                        drawerPanel
                    }
                    .frame(width: drawerWidth)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(theme.textTertiary.opacity(0.15))
                            .frame(width: 0.5)
                            .ignoresSafeArea()
                    }
                    .transition(.move(edge: .leading))
                }

                // Chat/channel detail with terminal overlay
                ZStack(alignment: .trailing) {
                    NavigationStack {
                        chatDetailContent
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(.hidden, for: .navigationBar)
                    }
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .frame(maxWidth: .infinity)

                    // Terminal browser — slide-in overlay from trailing edge
                    if isTerminalActiveInCurrentChat && showTerminalBrowser {
                        HStack(spacing: 0) {
                            Spacer()
                            TerminalBrowserView(
                                viewModel: terminalBrowserVM,
                                onDismiss: {
                                    withAnimation(MicroAnimation.panelClose) {
                                        showTerminalBrowser = false
                                        terminalDragOffset = 0
                                    }
                                    terminalBrowserVM.handlePanelClosed()
                                }
                            )
                            .frame(width: 340)
                            .background(theme.background)
                            .shadow(color: .black.opacity(0.12), radius: 16, x: -4)
                            .offset(x: max(0, terminalDragOffset))
                            .gesture(
                                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                                    .onChanged { value in
                                        let h = value.translation.width
                                        guard h > 0 else { return }
                                        isDraggingTerminal = true
                                        terminalDragOffset = h
                                    }
                                    .onEnded { value in
                                        guard isDraggingTerminal else { return }
                                        isDraggingTerminal = false
                                        let h = value.translation.width
                                        let v = value.velocity.width
                                        if h > 100 || v > 400 {
                                            withAnimation(MicroAnimation.panelClose) {
                                                showTerminalBrowser = false
                                                terminalDragOffset = 0
                                            }
                                            terminalBrowserVM.handlePanelClosed()
                                        } else {
                                            withAnimation(MicroAnimation.panelClose) {
                                                terminalDragOffset = 0
                                            }
                                        }
                                    }
                            )
                            .onAppear {
                                configureTerminalBrowserIfNeeded()
                                terminalBrowserVM.handlePanelOpened()
                                terminalBrowserVM.refresh()
                            }
                        }
                        .transition(.move(edge: .trailing))
                        .ignoresSafeArea(.keyboard)
                    }

                    // Right-edge strip — swipe left-to-right to open terminal (when terminal active and panel hidden)
                    if isTerminalActiveInCurrentChat && !showTerminalBrowser {
                        Color.clear
                            .frame(width: 44)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                                    .onChanged { value in
                                        let h = value.translation.width
                                        let v = abs(value.translation.height)
                                        guard abs(h) > v, h < 0 else { return }
                                        isDraggingTerminal = true
                                        terminalDragOffset = 340 + h // start off-screen, slide in
                                    }
                                    .onEnded { value in
                                        guard isDraggingTerminal else { return }
                                        isDraggingTerminal = false
                                        let h = value.translation.width
                                        let vel = value.velocity.width
                                        if h < -60 || vel < -300 {
                                            withAnimation(MicroAnimation.panelOpen) {
                                                showTerminalBrowser = true
                                                terminalDragOffset = 0
                                            }
                                            configureTerminalBrowserIfNeeded()
                                            terminalBrowserVM.handlePanelOpened()
                                            terminalBrowserVM.refresh()
                                            Haptics.play(.light)
                                        } else {
                                            withAnimation(MicroAnimation.panelClose) {
                                                terminalDragOffset = 0
                                            }
                                        }
                                    }
                            )
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .animation(MicroAnimation.panelOpen, value: splitSidebarVisible)

        }
        // When switching TO always-shown, make sure the drawer state is clean
        .onAppear {
            showDrawer = false
            dragOffset = 0
            isDraggingDrawer = false
            terminalDragOffset = 0
            isDraggingTerminal = false
        }
    }

    // MARK: - Main ZStack (auto-hide drawer layout — mirrors MainChatView)

    @ViewBuilder
    private func mainZStack(voiceCallBinding: Binding<Bool>) -> some View {
        ZStack(alignment: .leading) {
            // MARK: Main content — pushed right as drawer opens
            NavigationStack {
                detailContent(voiceCallBinding: voiceCallBinding)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .offset(x: mainContentOffset)
            .scaleEffect(1.0 - (drawerFraction * 0.08), anchor: .center)
            .clipShape(RoundedRectangle(cornerRadius: drawerFraction * 16, style: .continuous))
            .blur(radius: drawerFraction * 8)
            .shadow(color: .black.opacity(0.18 * drawerFraction), radius: 20, x: -4)
            .overlay {
                Color.black
                    .opacity(0.12 * drawerFraction)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            // Tap or swipe-left to close when drawer is open
            .overlay {
                if drawerFraction > 0.01 || isDraggingDrawer {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeDrawerAnimated() }
                        .gesture(
                            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                                .onChanged { value in
                                    let h = value.translation.width
                                    guard h < 0 else { return }
                                    isDraggingDrawer = true
                                    dragOffset = h
                                }
                                .onEnded { value in
                                    guard isDraggingDrawer else { return }
                                    isDraggingDrawer = false
                                    let h = value.translation.width
                                    let v = value.velocity.width
                                    if h < -(drawerWidth * 0.15) || v < -300 {
                                        closeDrawerAnimated()
                                    } else {
                                        openDrawerAnimated()
                                    }
                                }
                        )
                }
            }

            // MARK: Drawer panel
            drawerPanel
                .frame(width: drawerWidth)
                .offset(x: effectiveDrawerX)
                .accessibilityHidden(drawerFraction < 0.01)
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let h = value.translation.width
                            guard h < 0 else { return }
                            isDraggingDrawer = true
                            dragOffset = h
                        }
                        .onEnded { value in
                            guard isDraggingDrawer else { return }
                            isDraggingDrawer = false
                            let h = value.translation.width
                            let v = value.velocity.width
                            if h < -(drawerWidth * 0.15) || v < -300 {
                                closeDrawerAnimated()
                            } else {
                                openDrawerAnimated()
                            }
                        }
                )

            // MARK: Left-edge strip — swipe right to open (when drawer is closed)
            // Note: do NOT hide this based on isDraggingDrawer — removing it mid-gesture
            // cancels the DragGesture before onEnded fires, causing the drawer to open only ~5%.
            if !showDrawer {
                Color.clear
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .local)
                            .onChanged { value in
                                let h = value.translation.width
                                let v = abs(value.translation.height)
                                guard abs(h) > v, h > 0 else { return }
                                if !isDraggingDrawer {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
                                }
                                isDraggingDrawer = true
                                dragOffset = h
                            }
                            .onEnded { value in
                                guard isDraggingDrawer else { return }
                                isDraggingDrawer = false
                                let h = value.translation.width
                                let v = value.velocity.width
                                // Low threshold so even a short flick commits the open
                                if h > drawerWidth * 0.05 || v > 200 {
                                    openDrawerAnimated()
                                } else {
                                    closeDrawerAnimated()
                                }
                            }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Drawer Panel

    private var drawerPanel: some View {
        iPadSidebarContent(
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
            onNewChat: {
                startNewChat()
                if !sidebarAlwaysShown { closeDrawerAnimated() }
            },
            onSelectFolder: { folderId in
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
                if !sidebarAlwaysShown { closeDrawerAnimated() }
            },
            onExport: { conv, format in Task { await exportChat(conv, format: format) } },
            onShowArchivedChats: { showArchivedChats = true },
            onShowSharedChats: { showSharedChats = true },
            onCloseDrawer: sidebarAlwaysShown ? nil : { closeDrawerAnimated() }
        )
    }

    // MARK: - Drawer Animations

    private func openDrawerAnimated() {
        withAnimation(MicroAnimation.panelOpen) {
            showDrawer = true
            dragOffset = 0
        }
        Haptics.play(.light)
    }

    private func closeDrawerAnimated() {
        withAnimation(MicroAnimation.panelClose) {
            showDrawer = false
            dragOffset = 0
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailContent(voiceCallBinding: Binding<Bool>) -> some View {
        if isTerminalActiveInCurrentChat {
            // Three-column layout: chat + terminal browser side by side
            HStack(spacing: 0) {
                chatDetailContent
                    .frame(maxWidth: .infinity)

                if showTerminalBrowser {
                    Divider()

                    TerminalBrowserView(
                        viewModel: terminalBrowserVM,
                        onDismiss: {
                        withAnimation(MicroAnimation.panelClose) {
                            showTerminalBrowser = false
                        }
                        terminalBrowserVM.handlePanelClosed()
                        }
                    )
                    .frame(width: 340)
                    .background(theme.background)
                    .transition(.move(edge: .trailing))
                    .onAppear {
                        configureTerminalBrowserIfNeeded()
                        terminalBrowserVM.handlePanelOpened()
                        terminalBrowserVM.refresh()
                    }
                }
            }
            // ChatDetailView handles its own keyboard via KeyboardTracker.
            // TerminalBrowserView is a fixed side column — no keyboard adjustment needed.
            .ignoresSafeArea(.keyboard)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(showTerminalBrowser ? MicroAnimation.panelClose : MicroAnimation.panelOpen) {
                            if showTerminalBrowser {
                                showTerminalBrowser = false
                                terminalBrowserVM.handlePanelClosed()
                            } else {
                                configureTerminalBrowserIfNeeded()
                                showTerminalBrowser = true
                                terminalBrowserVM.handlePanelOpened()
                                terminalBrowserVM.refresh()
                            }
                        }
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: showTerminalBrowser ? "sidebar.right" : "sidebar.right")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(showTerminalBrowser ? theme.brandPrimary : theme.textSecondary)
                            .symbolVariant(showTerminalBrowser ? .fill : .none)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showTerminalBrowser ? "Hide Files" : "Show Files")
                }
            }
        } else {
            chatDetailContent
        }
    }

    @ViewBuilder
    private var chatDetailContent: some View {
        // In auto-hide mode: hamburger opens the drawer.
        // In always-shown mode: hamburger toggles the sidebar column (hide/show).
        let toggleDrawerAction: () -> Void = sidebarAlwaysShown
            ? {
                withAnimation(splitSidebarVisible ? MicroAnimation.panelClose : MicroAnimation.panelOpen) {
                    splitSidebarVisible.toggle()
                }
                Haptics.play(.light)
            }
            : { openDrawerAnimated() }

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
            .id(conversationId)
        } else if let folderWorkspaceId = activeFolderWorkspaceId {
            let vm = dependencies.activeChatStore.viewModel(for: nil)
            let folder = listViewModel.folderViewModel.folders.first { $0.id == folderWorkspaceId }
                ?? listViewModel.folderViewModel.activeFolderDetail
            ChatDetailView(viewModel: vm, folderWorkspace: folder)
                .onNewChat { startNewChat() }
                .onToggleDrawer(toggleDrawerAction)
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
                .id("new-chat-\(newChatGeneration)")
        }
    }

    /// Hamburger button that opens the sidebar drawer — placed in each detail view's toolbar.
    private var sidebarButton: some View {
        Button {
            openDrawerAnimated()
        } label: {
            Image(systemName: "sidebar.left")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Sidebar")
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

    private func configureTerminalBrowserIfNeeded() {
        guard let apiClient = dependencies.apiClient else { return }
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        guard vm.terminalEnabled, let server = vm.selectedTerminalServer else { return }
        terminalBrowserVM.configure(apiClient: apiClient, serverId: server.id)
    }

    // MARK: - Actions

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
        terminalBrowserVM.reset()
        showTerminalBrowser = true
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
                guard let api = dependencies.apiClient else { return }
                let pdfData = try await api.downloadChatAsPDF(chatId: fullConversation.id)
                let url = tmpDir.appendingPathComponent("\(title).pdf")
                try pdfData.write(to: url)
                exportFileURL = url
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
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                    group.addTask { await channelListVM.refreshChannels() }
                    group.addTask { await dependencies.authViewModel.refreshBackendConfig() }
                }
                if let activeId = activeConversationId {
                    let vm = dependencies.activeChatStore.viewModel(for: activeId)
                    if !vm.isStreaming { await vm.syncWithServer() }
                }
            }
        }

        dependencies.socketService?.onConnect = { [self] in
            Task { @MainActor in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                    group.addTask { await channelListVM.refreshChannels() }
                }
            }
        }
    }
}

// MARK: - iPad Sidebar Content

struct iPadSidebarContent: View {
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
    let onNewChat: () -> Void
    /// Called when the folder name/icon is tapped — opens folder workspace in the detail pane.
    var onSelectFolder: ((String) -> Void)?
    let onExport: (Conversation, iPadMainChatView.ExportFormat) -> Void
    var onShowArchivedChats: (() -> Void)? = nil
    var onShowSharedChats: (() -> Void)? = nil
    /// Called when a conversation/channel is selected — closes the drawer on iPad.
    var onCloseDrawer: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var drawerChatsDropActive = false
    @State private var showMoveSelectedToFolderSheet = false
    @State private var showUpdateSheet = false

    /// Controls the on-device TTS model download sheet shown before opening a voice call.
    @State private var showModelDownloadSheet = false
    /// Pending voice call action stored while the model download sheet is visible.
    @State private var pendingVoiceCallAction: (() -> Void)?

    /// Top-level section collapse states (shared with iPhone via same AppStorage keys).
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
                sidebarSearchBar
            }

            // Conversation list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let folderVM = listViewModel.folderViewModel

                    // Pinned models section (quick-switch shortcuts)
                    pinnedModelsSection

                    // Folders section
                    let foldersEnabled = dependencies.authViewModel.featurePermissions.folders
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
                    if (foldersEnabled && !folderVM.featureDisabled && !folderVM.folders.isEmpty) || (channelsEnabled && !channelListVM.channels.isEmpty) {
                        Rectangle()
                            .fill(theme.textTertiary.opacity(0.12))
                            .frame(height: 1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                    }

                    // Channels section (shown only when enabled on server)
                    if channelsEnabled {
                        channelsSection
                    }

                    // Divider between channels and chats
                    if channelsEnabled && !channelListVM.channels.isEmpty {
                        Rectangle()
                            .fill(theme.textTertiary.opacity(0.12))
                            .frame(height: 1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                    }

                    // Chats section
                    let hasAnyChats = !listViewModel.pinnedConversations.isEmpty
                        || !listViewModel.groupedConversations.isEmpty

                    if hasAnyChats || !folderVM.folders.isEmpty {
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
        .background(theme.background)
        // Sidebar has no text inputs that need keyboard avoidance — ignore
        // keyboard safe area so the sidebar layout doesn't shift when a
        // floating keyboard appears/disappears or changes size on iPad.
        .ignoresSafeArea(.keyboard)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        // Bridge folderVM.showCreateSheet → showCreateFolderSheet (mirrors MainChatView)
        .onChange(of: listViewModel.folderViewModel.showCreateSheet) { _, show in
            if show {
                listViewModel.folderViewModel.showCreateSheet = false
                showCreateFolderSheet = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if listViewModel.isSelectionMode {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            listViewModel.exitSelectionMode()
                        }
                    } label: {
                        Text("Cancel").foregroundStyle(theme.brandPrimary)
                    }
                } else {
                    Menu {
                        if !listViewModel.conversations.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    listViewModel.toggleSelectionMode()
                                }
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
                        }

                        Divider()

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
                        Image(systemName: "ellipsis.circle")
                            .scaledFont(size: 15, weight: .medium, context: .list)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .scaledFont(size: 15, weight: .medium, context: .list)
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Chat")
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Search Bar

    private var sidebarSearchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 13, context: .list)
                .foregroundStyle(theme.textTertiary)

            TextField("Search conversations…", text: $listViewModel.searchText)
                .scaledFont(size: 14, context: .list)
                .foregroundStyle(theme.textPrimary)

            if !listViewModel.searchText.isEmpty {
                Button {
                    listViewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 13, context: .list)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 9)
        .background(theme.surfaceContainer.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - Selection Mode Header

    private var selectionModeHeader: some View {
        HStack(spacing: Spacing.sm) {
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
        .background(theme.surfaceContainer.opacity(0.4))
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
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
                // Section header
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .scaledFont(size: 9, weight: .semibold, context: .list)
                        .foregroundStyle(theme.textTertiary)
                    Text("Models")
                        .scaledFont(size: 12, weight: .medium, context: .list)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)

                // Pinned model rows
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
                        .scaledFont(size: 9, weight: .semibold, context: .list)
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
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xs)
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
                        .scaledFont(size: 9, weight: .semibold, context: .list)
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
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 8, weight: .bold, context: .list)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(channelsExpanded ? 0 : -90))
                        .animation(MicroAnimation.snappy, value: channelsExpanded)

                    Image(systemName: "bubble.left.and.bubble.right")
                        .scaledFont(size: 9, weight: .semibold, context: .list)
                        .foregroundStyle(theme.textTertiary)
                    Text("Channels")
                        .scaledFont(size: 12, weight: .medium, context: .list)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                    Button { showCreateChannel = true } label: {
                        Image(systemName: "plus.bubble")
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
            HStack(spacing: 6) {
                if channel.type == .dm, let participant = channel.dmParticipants.first {
                    ZStack(alignment: .bottomTrailing) {
                        UserAvatar(
                            size: 22,
                            imageURL: participant.resolveAvatarURL(serverBaseURL: dependencies.apiClient?.baseURL ?? ""),
                            name: participant.displayName,
                            authToken: dependencies.apiClient?.network.authToken
                        )
                        Circle()
                            .fill(participant.isOnline ? Color.green : Color.gray.opacity(0.5))
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(theme.background, lineWidth: 1))
                            .offset(x: 2, y: 2)
                    }
                } else {
                    Image(systemName: channel.sidebarIcon)
                        .scaledFont(size: 11, context: .list)
                        .foregroundStyle(activeChannelId == channel.id ? theme.brandPrimary : theme.textTertiary)
                }
                Text(channel.type == .dm
                    ? (channel.dmParticipants.first?.displayName ?? channel.displayName)
                    : channel.displayName)
                    .scaledFont(size: 14, context: .list)
                    .fontWeight(activeChannelId == channel.id || channel.unreadCount > 0 ? .semibold : .regular)
                    .foregroundStyle(activeChannelId == channel.id ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                if activeChannelId == channel.id {
                    Circle()
                        .fill(theme.brandPrimary)
                        .frame(width: 6, height: 6)
                } else if channel.unreadCount > 0 {
                    Text("\(channel.unreadCount)")
                        .scaledFont(size: 11, weight: .bold, context: .list)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.brandPrimary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 7)
            .background(
                activeChannelId == channel.id
                    ? theme.brandPrimary.opacity(0.1)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if channel.type == .dm {
                Button {
                    channelListVM.hideDM(channelId: channel.id)
                    Haptics.play(.light)
                } label: {
                    Label("Hide Conversation", systemImage: "eye.slash")
                }
            } else {
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
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 8, weight: .bold, context: .list)
                        .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                        .rotationEffect(.degrees(chatsExpanded ? 0 : -90))
                        .animation(MicroAnimation.snappy, value: chatsExpanded)

                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .scaledFont(size: 9, weight: .semibold, context: .list)
                        .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                    Text("Chats")
                        .scaledFont(size: 12, weight: .medium, context: .list)
                        .fontWeight(.bold)
                        .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    if drawerChatsDropActive {
                        Text("Drop here")
                            .scaledFont(size: 12, weight: .medium, context: .list)
                            .foregroundStyle(theme.brandPrimary)
                            .transition(.opacity)
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
            withAnimation { drawerChatsDropActive = false; folderVM.dragCompleted() }
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
                    .padding(.vertical, 8)
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
                    activeConversationId = targetId
                    activeChannelId = nil
                    activeFolderWorkspaceId = nil
                    SharedDataService.shared.saveLastActiveConversationId(targetId)
                    onCloseDrawer?()
                    Haptics.play(.light)
                } label: {
                    let isActive = activeConversationId == conversation.id
                    HStack {
                        Text(conversation.title)
                            .scaledFont(size: 14, context: .list)
                            .fontWeight(isActive ? .semibold : .regular)
                            .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        // Always render Circle to avoid layout shifts on insertion/removal
                        Circle()
                            .fill(theme.brandPrimary)
                            .frame(width: 6, height: 6)
                            .opacity(isActive ? 1 : 0)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)
                    .background(
                        isActive
                            ? theme.brandPrimary.opacity(0.1)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            // Subtle top separator
            Rectangle()
                .fill(theme.textTertiary.opacity(0.12))
                .frame(height: 0.5)

            HStack(spacing: Spacing.sm) {
                // Real user avatar + full name — tap → Settings, long-press → Account Picker
                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        UserAvatar(
                            size: 30,
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
                        .scaledFont(size: 13, weight: .medium)
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
                                .scaledFont(size: 15, weight: .medium)
                                .foregroundStyle(.tint)
                            // Extra dot badge when both updates are pending
                            if dependencies.updateChecker.pendingUpdate != nil && dependencies.serverUpdateChecker.pendingUpdate != nil {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 2, y: -2)
                            }
                        }
                        .frame(width: 36, height: 36)
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
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 36, height: 36)
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
                        .scaledFont(size: 17, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
        }
        .background(theme.background)
    }
}

// MARK: - Context Menu (iPad Sidebar)

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
                                Button {
                                    showNotes.wrappedValue = false
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.secondary)
                                        .frame(width: 32, height: 32)
                                        .background(Color(uiColor: .systemGray5).opacity(0.6))
                                        .clipShape(Circle())
                                }
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
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await lvm.refreshIfStale() }
                        group.addTask { await lvm.folderViewModel.refreshFolders() }
                        if let cvm { group.addTask { await cvm.refreshChannels() } }
                        group.addTask { await chatVM.fetchPinnedModels() }
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
            .onReceive(NotificationCenter.default.publisher(for: .adminClonedChat)) { notification in
                if let conversationId = notification.object as? String {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        activeConversationId.wrappedValue = conversationId
                        SharedDataService.shared.saveLastActiveConversationId(conversationId)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUINavigateToChat)) { notification in
                // openui://chat/<id> deep link — select the requested conversation.
                // Works both on warm launch (app running) and after cold-start restore
                // (SharedDataService was already updated before this notification fired).
                if let conversationId = notification.object as? String {
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !newTitle.isEmpty else { return }
                        listViewModel.renamingConversation = conversation
                        listViewModel.renameText = newTitle
                        Task { await listViewModel.commitRename() }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }
}
