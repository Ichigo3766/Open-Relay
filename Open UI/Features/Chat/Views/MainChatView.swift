import SwiftUI

/// The primary authenticated view that shows the chat screen as the
/// landing page, with a slide-out drawer for conversation history,
/// settings, and notes — matching the Flutter app's layout.
///
/// ## Performance
/// - The drawer is **always in the view tree** (offset-based, not `if/else`),
///   so toggling it never destroys/recreates its view hierarchy.
/// - The main content is **never** `.disabled()` — the dimming overlay
///   intercepts taps instead, avoiding a full re-render of the chat stack.
/// - Haptic feedback uses the pre-prepared `Haptics` service.
struct MainChatView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// Controls the drawer visibility.
    @State private var showDrawer = false

    /// Controls the settings sheet presentation.
    @State private var showSettings = false

    /// Controls the notes sheet presentation.
    @State private var showNotes = false

    /// The conversation currently being viewed. `nil` = new chat.
    @State private var activeConversationId: String?

    /// Monotonically increasing counter to force new-chat view recreation.
    @State private var newChatGeneration: Int = 0

    /// Conversation list view model (shared with drawer).
    @State private var listViewModel = ChatListViewModel()

    /// Controls the "delete all" confirmation dialog.
    @State private var showDeleteAllConfirmation = false

    /// Controls the "delete selected" confirmation dialog.
    @State private var showDeleteSelectedConfirmation = false

    /// Whether the "create folder" sheet is visible.
    @State private var showCreateFolderSheet = false

    /// Tracks whether socket reconnect handler has been registered.
    @State private var hasRegisteredSocketHandlers = false

    /// Whether the drawer "Chats" header is being targeted by a drag.
    @State private var drawerChatsDropActive: Bool = false

    /// Cached container width from GeometryReader (avoids deprecated UIScreen.main).
    @State private var containerWidth: CGFloat = 360

    /// Live drag offset for interactive drawer sliding.
    @State private var dragOffset: CGFloat = 0

    /// Whether a drawer drag is in progress (prevents animation fighting).
    @State private var isDraggingDrawer = false

    // MARK: Terminal file browser (right-side panel)
    @State private var showFileBrowser = false
    @State private var fileBrowserDragOffset: CGFloat = 0
    @State private var isDraggingFileBrowser = false
    @State private var terminalBrowserVM = TerminalBrowserViewModel()

    /// Rename conversation state.
    @State private var renamingConversation: Conversation?
    @State private var renameText = ""

    /// Export file URL for share sheet.
    @State private var exportFileURL: URL?
    @State private var showExportShareSheet = false

    /// Whether title is being AI-generated.
    @State private var isGeneratingTitle = false

    /// Whether a chat export is in progress (shows loading overlay).
    @State private var isExporting = false
    @State private var exportError: String?

    /// Drawer width as a fraction of container width, capped.
    private var drawerWidth: CGFloat {
        min(containerWidth * 0.82, 360)
    }

    var body: some View {
        @Bindable var bindableRouter = router
        mainContent(voiceCallBinding: $bindableRouter.isVoiceCallPresented)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                if abs(containerWidth - newWidth) > 1 {
                    containerWidth = newWidth
                }
            }
    }

    /// Computes the effective drawer X offset (0 = fully open, -drawerWidth = fully closed).
    /// Combines the base `showDrawer` state with the live `dragOffset` during a gesture.
    private var effectiveDrawerX: CGFloat {
        let base: CGFloat = showDrawer ? 0 : -drawerWidth
        let combined = base + dragOffset
        return min(0, max(-drawerWidth, combined))
    }

    /// Drawer open fraction (0 = fully closed, 1 = fully open) — drives dimming opacity.
    private var drawerFraction: CGFloat {
        let fraction = (effectiveDrawerX + drawerWidth) / drawerWidth
        return min(1, max(0, fraction))
    }

    // MARK: File Browser Computed Properties (right-side panel, mirrors drawer)

    /// File browser panel width.
    private var fileBrowserWidth: CGFloat {
        min(containerWidth * 0.85, 380)
    }

    /// Effective X offset for the file browser (containerWidth = off-screen right,
    /// containerWidth - fileBrowserWidth = fully visible).
    private var effectiveFileBrowserX: CGFloat {
        let base: CGFloat = showFileBrowser ? (containerWidth - fileBrowserWidth) : containerWidth
        let combined = base + fileBrowserDragOffset
        return max(containerWidth - fileBrowserWidth, min(containerWidth, combined))
    }

    /// File browser open fraction (0 = closed, 1 = fully open).
    private var fileBrowserFraction: CGFloat {
        let fraction = (containerWidth - effectiveFileBrowserX) / fileBrowserWidth
        return min(1, max(0, fraction))
    }

    /// Whether the current active chat has terminal enabled with a server selected.
    private var isTerminalActiveInCurrentChat: Bool {
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        return vm.terminalEnabled && vm.selectedTerminalServer != nil
    }

    // MARK: - Main Content Pipeline
    // Split into distinct sub-methods so the Swift type checker can resolve
    // each modifier group independently (fixes "unable to type-check" error).

    private func mainContent(voiceCallBinding: Binding<Bool>) -> some View {
        applyOverlays(
            content: applyLifecycleHandlers(
                content: applyDialogsAndAlerts(
                    content: applySheets(
                        content: mainZStack(voiceCallBinding: voiceCallBinding),
                        voiceCallBinding: voiceCallBinding
                    )
                )
            )
        )
    }

    // MARK: - Main ZStack (Core Layout)

    @ViewBuilder
    private func mainZStack(voiceCallBinding: Binding<Bool>) -> some View {
        ZStack(alignment: .leading) {
            // MARK: Main chat content
            NavigationStack {
                chatContent
                    // Interactive edge-swipe to open drawer from left edge.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .local)
                            .onChanged { value in
                                let horizontal = value.translation.width
                                let vertical = abs(value.translation.height)
                                guard horizontal > vertical,
                                      value.startLocation.x < 44,
                                      !showDrawer else { return }
                                if !isDraggingDrawer {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                                isDraggingDrawer = true
                                dragOffset = horizontal
                            }
                            .onEnded { value in
                                guard isDraggingDrawer else { return }
                                let horizontal = value.translation.width
                                let velocity = value.velocity.width
                                isDraggingDrawer = false
                                if horizontal > drawerWidth * 0.4 || velocity > 500 {
                                    openDrawerAnimated()
                                } else {
                                    closeDrawerAnimated()
                                }
                            }
                    )
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                toggleDrawer()
                            } label: {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Menu")
                        }

                        ToolbarItem(placement: .principal) {
                            modelSelector
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                startNewChat()
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("New Chat")
                        }
                    }
            }
            .allowsHitTesting(drawerFraction < 0.01)

            // MARK: Dimming overlay
            Color.black
                .opacity(0.4 * drawerFraction)
                .ignoresSafeArea()
                .allowsHitTesting(drawerFraction > 0.01)
                .onTapGesture {
                    closeDrawerAnimated()
                }
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = value.translation.width
                            guard horizontal < 0 else { return }
                            isDraggingDrawer = true
                            dragOffset = horizontal
                        }
                        .onEnded { value in
                            guard isDraggingDrawer else { return }
                            let horizontal = value.translation.width
                            let velocity = value.velocity.width
                            isDraggingDrawer = false
                            if horizontal < -(drawerWidth * 0.3) || velocity < -500 {
                                closeDrawerAnimated()
                            } else {
                                openDrawerAnimated()
                            }
                        }
                )

            // MARK: Drawer
            drawerContent
                .frame(width: drawerWidth)
                .offset(x: effectiveDrawerX)
                .accessibilityHidden(drawerFraction < 0.01)
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = value.translation.width
                            guard horizontal < 0 else { return }
                            isDraggingDrawer = true
                            dragOffset = horizontal
                        }
                        .onEnded { value in
                            guard isDraggingDrawer else { return }
                            let horizontal = value.translation.width
                            let velocity = value.velocity.width
                            isDraggingDrawer = false
                            if horizontal < -(drawerWidth * 0.3) || velocity < -500 {
                                closeDrawerAnimated()
                            } else {
                                openDrawerAnimated()
                            }
                        }
                )

            // MARK: File browser dimming overlay (right side — only when terminal is active)
            if isTerminalActiveInCurrentChat {
            Color.black
                .opacity(0.4 * fileBrowserFraction)
                .ignoresSafeArea()
                .allowsHitTesting(fileBrowserFraction > 0.01)
                .onTapGesture {
                    closeFileBrowserAnimated()
                }
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = value.translation.width
                            guard horizontal > 0 else { return }
                            isDraggingFileBrowser = true
                            fileBrowserDragOffset = horizontal
                        }
                        .onEnded { value in
                            guard isDraggingFileBrowser else { return }
                            let horizontal = value.translation.width
                            let velocity = value.velocity.width
                            isDraggingFileBrowser = false
                            if horizontal > fileBrowserWidth * 0.3 || velocity > 500 {
                                closeFileBrowserAnimated()
                            } else {
                                openFileBrowserAnimated()
                            }
                        }
                )

            // MARK: File browser panel (right side)
            TerminalBrowserView(
                viewModel: terminalBrowserVM,
                onDismiss: { closeFileBrowserAnimated() }
            )
            .frame(width: fileBrowserWidth)
            .background(theme.background)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .shadow(color: .black.opacity(0.2), radius: 16, x: -4)
            .offset(x: effectiveFileBrowserX)
            .accessibilityHidden(fileBrowserFraction < 0.01)
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        let horizontal = value.translation.width
                        guard horizontal > 0 else { return }
                        isDraggingFileBrowser = true
                        fileBrowserDragOffset = horizontal
                    }
                    .onEnded { value in
                        guard isDraggingFileBrowser else { return }
                        let horizontal = value.translation.width
                        let velocity = value.velocity.width
                        isDraggingFileBrowser = false
                        if horizontal > fileBrowserWidth * 0.3 || velocity > 500 {
                            closeFileBrowserAnimated()
                        } else {
                            openFileBrowserAnimated()
                        }
                    }
            )
            } // end if isTerminalActiveInCurrentChat
        }
        // Right-edge swipe to open file browser (mirrors left-edge drawer gesture)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onChanged { value in
                    let horizontal = value.translation.width
                    let vertical = abs(value.translation.height)
                    guard isTerminalActiveInCurrentChat,
                          abs(horizontal) > vertical,
                          horizontal < 0,
                          value.startLocation.x > containerWidth - 40,
                          !showFileBrowser, !showDrawer else { return }
                    if !isDraggingFileBrowser {
                        // Configure terminal browser VM on first drag touch
                        configureTerminalBrowserIfNeeded()
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    isDraggingFileBrowser = true
                    fileBrowserDragOffset = horizontal
                }
                .onEnded { value in
                    guard isDraggingFileBrowser else { return }
                    let horizontal = abs(value.translation.width)
                    let velocity = abs(value.velocity.width)
                    isDraggingFileBrowser = false
                    if horizontal > fileBrowserWidth * 0.3 || velocity > 500 {
                        openFileBrowserAnimated()
                    } else {
                        closeFileBrowserAnimated()
                    }
                }
        )
    }

    // MARK: - Sheets (Settings, Notes, Voice Call, Folders, Rename, Export)

    private func applySheets<Content: View>(content: Content, voiceCallBinding: Binding<Bool>) -> some View {
        content
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    viewModel: dependencies.authViewModel,
                    appearanceManager: dependencies.appearanceManager
                )
                .preferredColorScheme(dependencies.appearanceManager.resolvedColorScheme ?? systemColorScheme)
                .themed(with: dependencies.appearanceManager)
            }
            .sheet(isPresented: $showNotes) {
                NavigationStack {
                    NotesListView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showNotes = false }
                            }
                        }
                }
            }
            .sheet(isPresented: voiceCallBinding) {
                if let voiceCallVM = router.voiceCallViewModel {
                    VoiceCallView(viewModel: voiceCallVM)
                        .environment(dependencies)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.hidden)
                        .presentationCornerRadius(24)
                        .presentationBackground(.ultraThinMaterial)
                        .interactiveDismissDisabled(false)
                }
            }
            .onChange(of: router.isVoiceCallPresented) { _, isPresented in
                if !isPresented {
                    router.voiceCallViewModel = nil
                }
            }
            .sheet(isPresented: $showCreateFolderSheet) {
                CreateFolderSheet(onCreate: { name in
                    Task { await listViewModel.folderViewModel.createFolder(name: name) }
                })
            }
            .alert(
                "Rename Folder",
                isPresented: .init(
                    get: { listViewModel.folderViewModel.renamingFolder != nil },
                    set: { if !$0 { listViewModel.folderViewModel.renamingFolder = nil } }
                )
            ) {
                TextField(
                    "Folder Name",
                    text: Bindable(listViewModel.folderViewModel).renameText
                )
                Button("Cancel", role: .cancel) {
                    listViewModel.folderViewModel.renamingFolder = nil
                }
                Button("Rename") {
                    Task { await listViewModel.folderViewModel.commitRename() }
                }
            }
            .sheet(item: $renamingConversation) { conv in
                renameConversationSheet(conv)
            }
            .sheet(isPresented: $showExportShareSheet, onDismiss: {
                if let url = exportFileURL {
                    try? FileManager.default.removeItem(at: url)
                    exportFileURL = nil
                }
            }) {
                if let url = exportFileURL {
                    ShareSheet(items: [url])
                }
            }
    }

    // MARK: - Rename Conversation Sheet (extracted for readability)

    @ViewBuilder
    private func renameConversationSheet(_ conv: Conversation) -> some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                TextField("Chat title", text: $renameText)
                    .font(AppTypography.bodyMediumFont)
                    .padding(Spacing.md)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

                Button {
                    Task { await generateTitleForRename(conv) }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if isGeneratingTitle {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGeneratingTitle ? "Generating…" : "Generate")
                    }
                    .font(AppTypography.labelMediumFont)
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
                    Button("Cancel") { renamingConversation = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !newTitle.isEmpty else { return }
                        listViewModel.renamingConversation = conv
                        listViewModel.renameText = newTitle
                        Task { await listViewModel.commitRename() }
                        renamingConversation = nil
                    }
                    .fontWeight(.semibold)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Confirmation Dialogs & Alerts

    private func applyDialogsAndAlerts<Content: View>(content: Content) -> some View {
        content
            // Archive all confirmation
            .confirmationDialog(
                "Archive All Chats",
                isPresented: $listViewModel.showArchiveAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Archive All", role: .destructive) {
                    Task {
                        await listViewModel.archiveAllConversations()
                        activeConversationId = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will archive all your conversations. You can unarchive them later from the web interface.")
            }
            // Delete all confirmation
            .confirmationDialog(
                "Delete All Chats",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    Task {
                        await listViewModel.deleteAllConversations()
                        activeConversationId = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all your conversations. This action cannot be undone.")
            }
            // Delete selected confirmation
            .confirmationDialog(
                "Delete Selected Chats",
                isPresented: $showDeleteSelectedConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete \(listViewModel.selectedCount) Chat\(listViewModel.selectedCount == 1 ? "" : "s")", role: .destructive) {
                    if let activeId = activeConversationId,
                       listViewModel.selectedConversationIds.contains(activeId) {
                        activeConversationId = nil
                    }
                    Task { await listViewModel.deleteSelectedConversations() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete \(listViewModel.selectedCount) selected conversation\(listViewModel.selectedCount == 1 ? "" : "s"). This action cannot be undone.")
            }
            // Export error alert
            .alert("Export Failed", isPresented: .init(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportError ?? "") }
    }

    // MARK: - Lifecycle Handlers (.task, .onChange, .onReceive)

    private func applyLifecycleHandlers<Content: View>(content: Content) -> some View {
        content
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
                registerSocketReconnectHandler()
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active && oldPhase != .active {
                    Task { await refreshAllDataOnForeground() }
                }
            }
            .onChange(of: activeConversationId) { _, _ in
                // Reset terminal file browser when switching conversations
                // so it doesn't show stale state from the previous chat
                if showFileBrowser { closeFileBrowserAnimated() }
                terminalBrowserVM.reset()
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationTitleUpdated)) { notification in
                guard let userInfo = notification.userInfo,
                      let conversationId = userInfo["conversationId"] as? String,
                      let title = userInfo["title"] as? String
                else { return }
                listViewModel.updateTitle(for: conversationId, title: title)
                let folderVM = listViewModel.folderViewModel
                for idx in folderVM.folders.indices {
                    if let chatIdx = folderVM.folders[idx].chats.firstIndex(where: { $0.id == conversationId }) {
                        folderVM.folders[idx].chats[chatIdx].title = title
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .adminClonedChat)) { notification in
                if let conversationId = notification.object as? String {
                    showSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        activeConversationId = conversationId
                        SharedDataService.shared.saveLastActiveConversationId(conversationId)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationListNeedsRefresh)) { _ in
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await listViewModel.refreshConversations() }
                        group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                    }
                }
            }
    }

    // MARK: - Progress Overlays

    private func applyOverlays<Content: View>(content: Content) -> some View {
        content
            .overlay {
                if isExporting {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        VStack(spacing: Spacing.md) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Preparing export…")
                                .font(AppTypography.bodyMediumFont)
                                .foregroundStyle(.white)
                        }
                        .padding(Spacing.xl)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if listViewModel.isDeletingBulk {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        VStack(spacing: Spacing.md) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Deleting…")
                                .font(AppTypography.bodyMediumFont)
                                .foregroundStyle(.white)
                        }
                        .padding(Spacing.xl)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .transition(.opacity)
                }
            }
    }

    // MARK: - Drawer Toggle

    private func toggleDrawer() {
        if showDrawer {
            closeDrawerAnimated()
        } else {
            openDrawerAnimated()
        }
    }

    private func closeDrawer() {
        closeDrawerAnimated()
    }

    /// Animates the drawer to fully open, resets drag offset, triggers haptic + refresh.
    private func openDrawerAnimated() {
        // Dismiss keyboard immediately so it doesn't overlap the drawer
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showDrawer = true
            dragOffset = 0
        }
        Haptics.play(.light)
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await listViewModel.refreshIfStale() }
                group.addTask { await listViewModel.folderViewModel.refreshFolders() }
            }
        }
    }

    /// Animates the drawer to fully closed and resets drag offset.
    private func closeDrawerAnimated() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showDrawer = false
            dragOffset = 0
        }
    }

    // MARK: - File Browser Open/Close (right panel, mirrors drawer)

    /// Configures the terminal browser VM with the active chat's terminal server.
    private func configureTerminalBrowserIfNeeded() {
        guard let apiClient = dependencies.apiClient else { return }
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        guard vm.terminalEnabled, let server = vm.selectedTerminalServer else { return }
        terminalBrowserVM.configure(apiClient: apiClient, serverId: server.id)
    }

    /// Animates the file browser to fully open.
    private func openFileBrowserAnimated() {
        configureTerminalBrowserIfNeeded()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showFileBrowser = true
            fileBrowserDragOffset = 0
        }
        // Explicitly load directory after opening to ensure files appear
        // (the .task modifier may have fired before configure() was called)
        terminalBrowserVM.refresh()
        Haptics.play(.light)
    }

    /// Animates the file browser to fully closed.
    private func closeFileBrowserAnimated() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showFileBrowser = false
            fileBrowserDragOffset = 0
        }
    }

    // MARK: - New Chat

    private func startNewChat() {
        dependencies.activeChatStore.remove(nil)
        activeConversationId = nil
        newChatGeneration += 1
        // Reset terminal file browser state so it starts fresh in the new chat
        closeFileBrowserAnimated()
        terminalBrowserVM.reset()
        Haptics.play(.light)
    }

    // MARK: - Chat Content

    @ViewBuilder
    private var chatContent: some View {
        if let conversationId = activeConversationId {
            ChatDetailView(
                conversationId: conversationId,
                viewModel: dependencies.activeChatStore.viewModel(for: conversationId)
            )
            .id(conversationId)
            .transition(.opacity)
        } else {
            ChatDetailView(
                viewModel: dependencies.activeChatStore.viewModel(for: nil)
            )
            .id("new-chat-\(newChatGeneration)")
            .transition(.opacity)
        }
    }

    // MARK: - Model Selector

    private var modelSelector: some View {
        ModelSelectorLabel(
            conversationId: activeConversationId,
            activeChatStore: dependencies.activeChatStore,
            theme: theme
        )
    }

    // MARK: - Drawer Content

    private var drawerContent: some View {
        VStack(spacing: 0) {
            // Top bar: search or selection controls
            if listViewModel.isSelectionMode {
                selectionModeHeader
            } else {
                searchBar
            }

            // Conversation list grouped by time
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {

                    // ── FOLDERS SECTION (always visible so user can create new folders) ─
                    let folderVM = listViewModel.folderViewModel
                    if !folderVM.featureDisabled {
                        drawerFoldersSection(folderVM: folderVM)
                    }

                    // ── DIVIDER between Folders & Chats ──────────────
                    if !folderVM.folders.isEmpty {
                        Rectangle()
                            .fill(theme.textTertiary.opacity(0.15))
                            .frame(height: 1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                    }

                    // ── CHATS SECTION (entire section is a drop zone) ─
                    let hasAnyChats = !listViewModel.pinnedConversations.isEmpty
                        || !listViewModel.groupedConversations.isEmpty

                    if hasAnyChats || !folderVM.folders.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            // Header
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                                Text("Chats")
                                    .font(AppTypography.captionFont)
                                    .fontWeight(.bold)
                                    .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                                    .textCase(.uppercase)
                                    .tracking(0.5)
                                if drawerChatsDropActive {
                                    Text("Drop here")
                                        .font(AppTypography.captionFont)
                                        .foregroundStyle(theme.brandPrimary)
                                        .transition(.opacity)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.top, Spacing.sm)
                            .padding(.bottom, Spacing.xs)

                            // Pinned
                            if !listViewModel.pinnedConversations.isEmpty {
                                CollapsibleDrawerSection(title: "Pinned") {
                                    ForEach(listViewModel.pinnedConversations) { conversation in
                                        drawerConversationRow(conversation)
                                    }
                                }
                            }

                            // Time-grouped
                            ForEach(listViewModel.groupedConversations, id: \.0) { group in
                                CollapsibleDrawerSection(title: group.0, count: group.1.count) {
                                    ForEach(group.1) { conversation in
                                        drawerConversationRow(conversation)
                                    }
                                }
                            }
                        }
                        .background(
                            drawerChatsDropActive
                                ? theme.brandPrimary.opacity(0.06)
                                : Color.clear
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .stroke(theme.brandPrimary, lineWidth: drawerChatsDropActive ? 1.5 : 0)
                                .padding(.horizontal, 2)
                        )
                        .animation(.easeInOut(duration: AnimDuration.fast), value: drawerChatsDropActive)
                        .dropDestination(for: DraggableChat.self) { items, _ in
                            guard let item = items.first,
                                  item.currentFolderId != nil else { return false }
                            let chatId = item.conversationId
                            let folderChats = folderVM.folders.flatMap(\.chats)
                            let conversation = folderChats.first(where: { $0.id == chatId })
                                ?? listViewModel.conversations.first(where: { $0.id == chatId })
                            guard let conversation else { return false }

                            withAnimation {
                                drawerChatsDropActive = false
                                folderVM.dragCompleted()
                            }
                            // Update folderId locally — add to conversations list if missing
                            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == chatId }) {
                                listViewModel.conversations[idx].folderId = nil
                            } else {
                                var conv = conversation
                                conv.folderId = nil
                                listViewModel.conversations.insert(conv, at: 0)
                            }
                            Task { await folderVM.moveChat(conversation: conversation, to: nil) }
                            return true
                        } isTargeted: { isTargeted in
                            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                                drawerChatsDropActive = isTargeted
                            }
                        }
                    }
                }
                .padding(.bottom, Spacing.md)
            }

            Spacer(minLength: 0)

            if listViewModel.isSelectionMode {
                selectionModeBottomBar
            } else {
                drawerBottomBar
            }
        }
        .background(theme.background)
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
                    .font(AppTypography.bodyMediumFont)
                    .foregroundStyle(theme.brandPrimary)
            }

            Spacer()

            Text("\(listViewModel.selectedCount) selected")
                .font(AppTypography.labelMediumFont)
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
                    .font(AppTypography.captionFont)
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

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(theme.textTertiary)

            TextField("Search conversations...", text: $listViewModel.searchText)
                .font(AppTypography.bodyMediumFont)
                .foregroundStyle(theme.textPrimary)

            if !listViewModel.searchText.isEmpty {
                Button {
                    listViewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textTertiary)
                }
            }

            if !listViewModel.conversations.isEmpty {
                Menu {
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
                        Label("Archive All Chats", systemImage: "archivebox")
                    }

                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Chats", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }

            Button {
                closeDrawer()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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

    // MARK: - Drawer Section

    @ViewBuilder
    private func drawerSection<Content: View>(
        title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)

                Text(title)
                    .font(AppTypography.labelMediumFont)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.textSecondary)

                if let count {
                    Text("\(count)")
                        .font(AppTypography.captionFont)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.surfaceContainer)
                        .clipShape(Capsule())
                }

                Spacer()

                if systemImage == "folder" {
                    Button {} label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            content()
        }
    }

    // MARK: - Drawer Folders Section

    @ViewBuilder
    private func drawerFoldersSection(folderVM: FolderListViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header with "New Folder" button
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)

                Text("Folders")
                    .font(AppTypography.captionFont)
                    .fontWeight(.bold)
                    .foregroundStyle(theme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()

                Button {
                    showCreateFolderSheet = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            // Folder rows
            ForEach(folderVM.folders) { folder in
                DrawerFolderRow(
                    folder: folder,
                    folderVM: folderVM,
                    allConversations: listViewModel.conversations,
                    activeConversationId: activeConversationId,
                    onSelectChat: { chatId in
                        activeConversationId = chatId
                        SharedDataService.shared.saveLastActiveConversationId(chatId)
                        closeDrawer()
                    },
                    onChatMoved: { chatId, targetFolderId in
                        // Update the folderId in the main conversations list
                        // so unfolderedConversations immediately excludes/includes it
                        if let idx = listViewModel.conversations.firstIndex(where: { $0.id == chatId }) {
                            listViewModel.conversations[idx].folderId = targetFolderId
                        } else if targetFolderId == nil {
                            // Chat was only in folder's chats array — add to main list
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
                            // Also remove from the folder's local chat list
                            if let fIdx = folderVM.folders.firstIndex(where: { $0.id == folder.id }) {
                                folderVM.folders[fIdx].chats.removeAll { $0.id == chatId }
                            }
                            if activeConversationId == chatId {
                                activeConversationId = nil
                            }
                        }
                    },
                    onTogglePin: { conversation in
                        Task { await listViewModel.togglePin(conversation: conversation) }
                    }
                )
                .padding(.horizontal, Spacing.sm)
            }
        }
        .animation(.easeInOut(duration: AnimDuration.medium), value: folderVM.folders.map(\.id))
    }

    // MARK: - Drawer Conversation Row

    private func drawerConversationRow(_ conversation: Conversation) -> some View {
        Group {
            if listViewModel.isSelectionMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        listViewModel.toggleSelection(for: conversation.id)
                    }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: listViewModel.isSelected(conversation.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                        )
                        .font(.system(size: 18))
                        .foregroundStyle(
                            listViewModel.isSelected(conversation.id)
                                ? theme.brandPrimary
                                : theme.textTertiary
                        )

                        Text(conversation.title)
                            .font(AppTypography.bodySmallFont)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 7)
                    .background(
                        listViewModel.isSelected(conversation.id)
                            ? theme.brandPrimary.opacity(0.1)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    activeConversationId = conversation.id
                    SharedDataService.shared.saveLastActiveConversationId(conversation.id)
                    closeDrawer()
                } label: {
                    HStack {
                        Text(conversation.title)
                            .font(AppTypography.bodySmallFont)
                            .fontWeight(activeConversationId == conversation.id ? .semibold : .regular)
                            .foregroundStyle(
                                activeConversationId == conversation.id
                                    ? theme.textPrimary
                                    : theme.textSecondary
                            )
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 7)
                    .background(
                        activeConversationId == conversation.id
                            ? theme.brandPrimary.opacity(0.08)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                // Make draggable into a folder
                .draggable(DraggableChat(
                    conversationId: conversation.id,
                    currentFolderId: conversation.folderId
                )) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "bubble.left").font(.system(size: 12))
                        Text(conversation.title)
                            .font(AppTypography.captionFont)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .contextMenu {
                    // Share
                    Button {
                        Task { _ = await listViewModel.shareConversation(conversation) }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    // Download submenu (matching WebUI)
                    Menu {
                        Button {
                            Task { await exportChat(conversation, format: .json) }
                        } label: {
                            Label("Export chat (.json)", systemImage: "doc")
                        }
                        Button {
                            Task { await exportChat(conversation, format: .txt) }
                        } label: {
                            Label("Plain text (.txt)", systemImage: "doc.plaintext")
                        }
                        Button {
                            Task { await exportChat(conversation, format: .pdf) }
                        } label: {
                            Label("PDF document (.pdf)", systemImage: "doc.richtext")
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }

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
                        Label(
                            conversation.pinned ? "Unpin" : "Pin",
                            systemImage: conversation.pinned ? "pin.slash" : "pin"
                        )
                    }

                    // Clone
                    Button {
                        Task {
                            guard let manager = dependencies.conversationManager else { return }
                            let cloned = try? await manager.cloneConversation(id: conversation.id)
                            if let cloned {
                                await listViewModel.refreshConversations()
                                activeConversationId = cloned.id
                                closeDrawer()
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
                                    let folderId = folder.id
                                    Task {
                                        await listViewModel.folderViewModel.moveChat(conversation: conv, to: folderId)
                                        if let idx = listViewModel.conversations.firstIndex(where: { $0.id == conv.id }) {
                                            listViewModel.conversations[idx].folderId = folderId
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

                    // Delete
                    Button(role: .destructive) {
                        let deletedId = conversation.id
                        Task {
                            await listViewModel.deleteConversation(id: deletedId)
                            if activeConversationId == deletedId {
                                activeConversationId = nil
                            }
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Selection Mode Bottom Bar

    private var selectionModeBottomBar: some View {
        Button(role: .destructive) {
            showDeleteSelectedConfirmation = true
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "trash")
                Text("Delete Selected (\(listViewModel.selectedCount))")
            }
            .font(AppTypography.labelMediumFont)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(
                listViewModel.selectedCount > 0
                    ? Color.red
                    : Color.red.opacity(0.3)
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
        .disabled(listViewModel.selectedCount == 0)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
        .background(theme.surfaceContainer.opacity(0.3))
    }

    // MARK: - Drawer Bottom Bar

    private var drawerBottomBar: some View {
        HStack(spacing: Spacing.md) {
            // User avatar + name
            Button {
                closeDrawer()
                showSettings = true
            } label: {
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(theme.brandPrimary.opacity(0.2))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text(String((dependencies.authViewModel.currentUser?.displayName ?? "U").prefix(1)).uppercased())
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(theme.brandPrimary)
                        )

                    Text(dependencies.authViewModel.currentUser?.displayName ?? "User")
                        .font(AppTypography.labelMediumFont)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Notes
            Button {
                closeDrawer()
                showNotes = true
            } label: {
                Image(systemName: "note.text")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            // Settings
            Button {
                closeDrawer()
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer.opacity(0.3))
    }

    // MARK: - Title Generation

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
        } catch {
            // Silently fail — keep current text
        }
        isGeneratingTitle = false
    }

    // MARK: - Chat Export

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
                // Use the server's raw message format for PDF generation.
                // The API fetches the full chat JSON and passes native messages
                // to the PDF renderer, avoiding any format mismatches.
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

    // MARK: - Foreground Refresh

    private func refreshAllDataOnForeground() async {
        // Use connect() without force so an already-in-progress connection
        // is NOT cancelled. connect(force:true) calls disconnectInternal()
        // which cancels the current URLSessionWebSocketTask, causing
        // "Receive error: cancelled" → handleDisconnect → autoReconnect →
        // connect(force:true) → infinite reconnect loop.
        if let socket = dependencies.socketService, !socket.isConnected, !socket.isConnecting {
            socket.connect()
        }

        // Refresh both conversations and folders in parallel
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await listViewModel.refreshIfStale() }
            group.addTask { await listViewModel.folderViewModel.refreshFolders() }
        }

        // Do NOT call loadConversation() here — it sets isLoadingConversation=true
        // which tears down the entire message list and replaces it with skeleton
        // placeholders, destroying scroll position and causing the avatar flash.
        //
        // ChatViewModel.startForegroundSyncListener() (registered during load())
        // already handles foreground sync via syncWithServer(), which uses
        // adoptServerMessages() for in-place surgical updates — no view recreation,
        // no scroll jump, no flash.
        //
        // Similarly do NOT reload models/tools — they're loaded once on init and
        // refreshed lazily before each send via refreshSelectedModelMetadata().

        dependencies.updateWidgetData(conversations: listViewModel.conversations)
    }

    // MARK: - Socket Reconnect Handler

    private func registerSocketReconnectHandler() {
        guard !hasRegisteredSocketHandlers else { return }
        hasRegisteredSocketHandlers = true

        dependencies.socketService?.onReconnect = { [self] in
            Task { @MainActor in
                // Refresh both conversations and folders in parallel
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                }
                // Use syncWithServer() instead of loadConversation() —
                // syncWithServer() does in-place updates via adoptServerMessages()
                // and does NOT set isLoadingConversation=true, so the message list
                // stays stable (no flash, no scroll jump).
                if let activeId = activeConversationId {
                    let vm = dependencies.activeChatStore.viewModel(for: activeId)
                    if !vm.isStreaming {
                        await vm.syncWithServer()
                    }
                }
            }
        }

        dependencies.socketService?.onConnect = { [self] in
            Task { @MainActor in
                // Refresh both conversations and folders in parallel
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                }
            }
        }
    }
}

// MARK: - Model Selector Label (Extracted to avoid re-computing viewModel in MainChatView body)

/// A lightweight view that reads the active chat's model info
/// only when it actually needs to render. This avoids the parent
/// `MainChatView` body from accessing `ActiveChatStore.viewModel(for:)`
/// on every evaluation.
private struct ModelSelectorLabel: View {
    let conversationId: String?
    let activeChatStore: ActiveChatStore
    let theme: AppTheme

    private var vm: ChatViewModel {
        activeChatStore.viewModel(for: conversationId)
    }

    var body: some View {
        Group {
            if vm.availableModels.isEmpty {
                Text("New Chat")
                    .font(AppTypography.labelMediumFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            } else {
                Menu {
                    ForEach(vm.availableModels) { model in
                        Button {
                            vm.selectModel(model.id)
                        } label: {
                            HStack {
                                Text(model.name)
                                if model.id == vm.selectedModelId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if let model = vm.selectedModel {
                            ModelAvatar(
                                size: 22,
                                imageURL: vm.resolvedImageURL(for: model),
                                label: model.shortName,
                                authToken: vm.serverAuthToken
                            )
                            .fixedSize()
                        }
                        Text(vm.selectedModel?.shortName ?? "Select Model")
                            .font(AppTypography.labelMediumFont)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 160)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
