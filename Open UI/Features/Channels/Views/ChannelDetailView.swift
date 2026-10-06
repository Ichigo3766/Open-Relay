import SwiftUI
import PhotosUI
import QuickLook
import MarkdownView
import os.log

/// Channel chat view with:
/// - Markdown rendering for all message content
/// - Rich mention highlighting (user/model/self badges)
/// - Enhanced reply previews with colored borders
/// - Unified attachment picker with photo browsing
/// - Image grid layout for multi-image messages
/// - Slack/Discord-inspired left-aligned message layout
struct ChannelDetailView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dismiss) private var dismiss
    
    @State private var viewModel: ChannelViewModel
    @State private var scrollPosition = ScrollPosition()
    @State private var isScrolledUp = false
    /// Messages from others that arrived while scrolled up (badge on the scroll FAB).
    @State private var unseenCount = 0
@State private var lastScrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    @State private var keyboard = KeyboardTracker()
    
    // Swipe-to-reply / highlight
    @State private var highlightedMessageId: String?
    @State private var swipeOffsets: [String: CGFloat] = [:]

    // iMessage-style reply focus overlay

    // @mention picker
    @State private var isShowingMentionPicker = false
    @State private var mentionQuery = ""
    
    // Edit focus
    @FocusState private var isEditFocused: Bool
    
    // #channel picker
    @State private var isShowingChannelPicker = false
    @State private var channelQuery = ""
    
    // Attachments — unified picker
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showAttachmentPicker = false
    @State private var showFilePicker = false
    
    // Message actions
    @State private var activeActionMessageId: String?
    
    // Emoji picker (for quick-reaction from context menu)
    @State private var showEmojiKeyboard = false
    @State private var emojiTargetMessageId: String?
    
    // Glass long-press menu
    @State private var menuPresenter = MessageMenuPresenter()
    /// Last known global frame of each row (for lifting the pressed bubble into the menu).
    @State private var rowFrames: [String: CGRect] = [:]

    // Reaction tooltip (MF-003)
    @State private var reactionTooltipText: String?
    @State private var showReactionTooltip = false
    
    // QuickLook for file preview
    @State private var quickLookURL: URL?
    @State private var isLoadingFile = false
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""
    
    // Channel settings
    @State private var showChannelSettings = false

    // Channel info (members / pins / webhooks) + profile card
    @State private var showChannelInfo = false
    @State private var showWebhooks = false
    @State private var profileUserId: String?

    // `/` prompt picker
    @State private var isShowingPromptPicker = false
    @State private var promptQuery = ""

    /// iPad (regular width) shows threads in a trailing side panel like the web's ResizableSidePanel.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var usesThreadPanel: Bool { horizontalSizeClass == .regular }

    // Error alerts (SEC-005 fix)
    @State private var showOperationError = false
    @State private var operationErrorMessage = ""

    /// Optional reference to the parent list VM so we can zero the unread badge
    /// and suppress badge increments while this channel is actively viewed.
    var channelListVM: ChannelListViewModel?

    /// Optional callback invoked when the hamburger/sidebar button is tapped (iPad drawer).
    private var toggleDrawerAction: (() -> Void)?

    init(channelId: String, channelListVM: ChannelListViewModel? = nil) {
        self._viewModel = State(initialValue: ChannelViewModel(channelId: channelId))
        self.channelListVM = channelListVM
    }

    /// Fluent modifier to wire up the sidebar-toggle action (mirrors ChatDetailView pattern).
    func onToggleDrawer(_ action: @escaping () -> Void) -> ChannelDetailView {
        var copy = self
        copy.toggleDrawerAction = action
        return copy
    }
    
    var body: some View {
        HStack(spacing: 0) {
            channelColumn
            if usesThreadPanel, let parent = viewModel.threadParentMessage {
                Divider()
                ThreadDetailSheet(
                    viewModel: viewModel,
                    parentMessage: parent,
                    isPanel: true,
                    onClose: { withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { viewModel.closeThread() } },
                    onShowProfile: { profileUserId = $0 }
                )
                .frame(width: 400)
                .id(parent.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: usesThreadPanel ? viewModel.threadParentMessage?.id : nil)
        .navigationBarHidden(true)
        .sheet(isPresented: Binding(
            get: { profileUserId != nil },
            set: { if !$0 { profileUserId = nil } }
        )) {
            if let userId = profileUserId {
                ChannelProfileSheet(
                    userId: userId,
                    viewModel: viewModel,
                    onMessage: { dmChannelId in
                        profileUserId = nil
                        // Server may have just created the DM — refresh the sidebar list.
                        dependencies.socketService?.emit("join-channels", data: ["auth": ["token": viewModel.serverAuthToken ?? ""]])
                        Task { await channelListVM?.refreshChannels() }
                        guard dmChannelId != viewModel.channelId else { return }
                        NotificationCenter.default.post(name: .navigateToChannel, object: dmChannelId)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.pendingPromptForVariables != nil },
            set: { if !$0 { viewModel.cancelPromptVariables() } }
        )) {
            if let prompt = viewModel.pendingPromptForVariables {
                PromptVariableSheet(
                    promptName: prompt.name,
                    variables: viewModel.pendingPromptVariables,
                    onSave: { values in viewModel.submitPromptVariables(values: values) },
                    onCancel: { viewModel.cancelPromptVariables() }
                )
            }
        }
    }

    /// The channel timeline + glass chrome (the whole screen on iPhone).
    private var channelColumn: some View {
        channelLifecycleLayer
    }

    /// Base layer: timeline + glass chrome + menu host.
    private var channelBaseLayer: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            messageListArea
        }
        .modifier(ChannelDeleteConfirmation(viewModel: viewModel))
        .chatChromeBar(edge: .top) { channelTopBar }
        .chatChromeBar(edge: .bottom) { bottomChrome }
        .statusBarGlassBackdrop(background: theme.background)
        // After the chrome so the scrim covers the header/composer and the
        // card is never drawn behind the input bar.
        .modifier(MessageMenuHost(presenter: menuPresenter))

    }

    /// Mention / channel pickers.
    private var channelPickerLayer: some View {
        channelBaseLayer
        .overlay(alignment: .bottom) {
            if isShowingChannelPicker {
                ChannelLinkPickerView(
                    query: channelQuery,
                    channels: viewModel.availableChannelsForPicker,
                    onSelect: { channel in
                        viewModel.insertChannelMention(channel)
                        dismissChannelPicker()
                        Haptics.play(.light)
                    },
                    onDismiss: { dismissChannelPicker() }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.easeOut(duration: 0.2), value: isShowingChannelPicker)
            }
        }
        .overlay(alignment: .bottom) {
            if isShowingMentionPicker {
                UserModelPickerView(
                    query: mentionQuery,
                    members: viewModel.mentionCandidates(for: mentionQuery),
                    models: viewModel.availableModels,
                    serverBaseURL: viewModel.serverBaseURL,
                    authToken: viewModel.serverAuthToken,
                    onSelectUser: { member in
                        viewModel.insertUserMention(member)
                        dismissMentionPicker()
                        Haptics.play(.light)
                    },
                    onSelectModel: { model in
                        viewModel.setModelMention(model)
                        dismissMentionPicker()
                        Haptics.play(.light)
                    },
                    onDismiss: { dismissMentionPicker() }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.easeOut(duration: 0.2), value: isShowingMentionPicker)
            }
        }
    }

    /// Sheets (thread, members, pins, webhooks, settings, attachments) and overlays.
    private var channelSheetLayer: some View {
        channelPickerLayer
        .sheet(isPresented: Binding(
            get: { !usesThreadPanel && viewModel.threadParentMessage != nil },
            set: { if !$0 { viewModel.closeThread() } }
        )) {
            if let parent = viewModel.threadParentMessage {
                ThreadDetailSheet(
                    viewModel: viewModel,
                    parentMessage: parent,
                    onShowProfile: { userId in
                        viewModel.closeThread()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { profileUserId = userId }
                    }
                )
                .presentationDetents([.large, .fraction(0.92)])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $viewModel.showMembersSheet) {
            ChannelMembersSheet(
                viewModel: viewModel,
                onShowProfile: { userId in
                    viewModel.showMembersSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { profileUserId = userId }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $viewModel.showPinnedSheet) {
            PinnedMessagesSheet(
                viewModel: viewModel,
                onJump: { messageId in
                    viewModel.showPinnedSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        scrollToAndHighlight(messageId: messageId)
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWebhooks) {
            ChannelWebhooksSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Channel settings sheet (SEC-005: error handling)
        .sheet(isPresented: $showChannelSettings, onDismiss: {
            Task {
                await viewModel.loadChannel()
                await viewModel.loadMembers()
            }
        }) {
            if let channel = viewModel.channel {
                if channel.type == .dm {
                    DmSettingsSheet(
                        channel: channel,
                        members: viewModel.dmParticipants,
                        allUsers: viewModel.allServerUsers,
                        currentUserId: viewModel.currentUserId,
                        serverBaseURL: viewModel.serverBaseURL,
                        onAddMembers: { userIds in
                            do {
                                try await dependencies.apiClient?.addChannelMembers(id: channel.id, userIds: userIds)
                            } catch {
                                showError(error.localizedDescription)
                            }
                        },
                        onLeave: {
                            do {
                                try await dependencies.apiClient?.updateMemberActiveStatus(channelId: channel.id, isActive: false)
                            } catch {
                                showError(error.localizedDescription)
                            }
                        }
                    )
                } else {
                    CreateChannelSheet(
                        onUpdate: { channel, name, description, isPrivate in
                            Task {
                                do {
                                    _ = try await dependencies.apiClient?.updateChannel(
                                        id: channel.id,
                                        name: name,
                                        description: description,
                                        isPrivate: isPrivate
                                    )
                                } catch {
                                    showError(error.localizedDescription)
                                }
                            }
                        },
                        onDelete: { channel in
                            Task {
                                do {
                                    try await dependencies.apiClient?.deleteChannel(id: channel.id)
                                } catch {
                                    showError(error.localizedDescription)
                                }
                            }
                        },
                        onUpdateAccessGrants: { channelId, grantsPayload in
                            do {
                                _ = try await dependencies.apiClient?.updateChannel(
                                    id: channelId,
                                    name: channel.name,
                                    description: channel.description,
                                    isPrivate: channel.isPrivate,
                                    accessGrants: grantsPayload
                                )
                            } catch {
                                showError(error.localizedDescription)
                            }
                        },
                        onAddGroupMembers: { channelId, userIds in
                            do {
                                try await dependencies.apiClient?.addChannelMembers(id: channelId, userIds: userIds)
                            } catch {
                                showError(error.localizedDescription)
                            }
                        },
                        onRemoveGroupMembers: { channelId, userIds in
                            do {
                                try await dependencies.apiClient?.removeChannelMembers(id: channelId, userIds: userIds)
                            } catch {
                                showError(error.localizedDescription)
                            }
                        },
                        apiClient: dependencies.apiClient,
                        editingChannel: channel,
                        allUsers: viewModel.allServerUsers,
                        channelMembers: viewModel.members
                    )
                }
            }
        }
        .sheet(isPresented: $showAttachmentPicker) {
            UnifiedAttachmentPicker(
                onPhotoSelected: { items in
                    Task { await processPhotos(items) }
                },
                onFileSelected: { urls in
                    Task { for url in urls { await processFileURL(url) } }
                },
                onDismiss: { showAttachmentPicker = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .overlay(alignment: .bottom) {
            if isShowingPromptPicker {
                PromptPickerView(
                    query: promptQuery,
                    prompts: viewModel.availablePrompts,
                    isLoading: viewModel.isLoadingPrompts,
                    keyboardHeight: keyboard.height,
                    onSelect: { prompt in
                        viewModel.selectPrompt(prompt, isThread: false)
                        dismissPromptPicker()
                    },
                    onDismiss: { dismissPromptPicker() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
.overlay(alignment: .top) {
            if viewModel.showCopiedToast {
                copiedToast
            }
        }
        // MF-003: Reaction tooltip overlay
        .overlay(alignment: .bottom) {
            if showReactionTooltip, let text = reactionTooltipText {
                Text(text)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textInverse)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(theme.textPrimary.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.bottom, 100)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// Lifecycle, alerts, link handling and the inline emoji keyboard.
    private var channelLifecycleLayer: some View {
        channelSheetLayer
        .task {
            keyboard.start()
            // Mark this channel as the active one so the list VM suppresses badge increments
            // and NotificationService suppresses foreground banners for this channel.
            channelListVM?.activeChannelId = viewModel.channelId
            channelListVM?.markChannelRead(id: viewModel.channelId)
            NotificationService.shared.activeChannelId = viewModel.channelId
            if let apiClient = dependencies.apiClient {
                var userId = dependencies.authViewModel.currentUser?.id
                if userId == nil || userId?.isEmpty == true {
                    userId = try? await apiClient.getCurrentUser().id
                }
                viewModel.configure(
                    apiClient: apiClient,
                    socket: dependencies.socketService,
                    currentUserId: userId,
                    isAdmin: dependencies.authViewModel.currentUser?.role == .admin
                )
                if userId == nil {
                    Logger(subsystem: "com.openui", category: "ChannelDetailView")
                        .debug("currentUserId is nil — Edit/Delete will be hidden")
                }
            }
            await viewModel.load()
        }
        .onDisappear {
            keyboard.stop()
            // Clear active channel tracking so future messages increment the badge again
            if channelListVM?.activeChannelId == viewModel.channelId {
                channelListVM?.activeChannelId = nil
            }
            if NotificationService.shared.activeChannelId == viewModel.channelId {
                NotificationService.shared.activeChannelId = nil
            }
            viewModel.cleanup()
        }
        .onChange(of: selectedPhotos) { _, items in
            Task { await processPhotos(items); selectedPhotos = [] }
        }
        .onChange(of: viewModel.editingMessage) { _, newValue in
            if newValue != nil {
                // Small delay so the edit bubble has time to appear before focusing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isEditFocused = true
                }
            } else {
                isEditFocused = false
            }
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { urls in
                Task { for url in urls { await processFileURL(url) } }
            }
        }
        .quickLookPreview($quickLookURL)
        .overlay {
            if isLoadingFile {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Loading file…")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.white)
                    }
                    .padding(Spacing.lg)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .alert("Download Failed", isPresented: $showDownloadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadErrorMessage)
        }
        // SEC-005: Surface operation errors
        .alert("Error", isPresented: $showOperationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationErrorMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .markdownLinkTapped)) { notification in
            guard isEnabled else { return }
            guard let url = notification.userInfo?["url"] as? URL else { return }
            if url.scheme == "openui-channel", let channelId = url.host {
                NotificationCenter.default.post(name: .navigateToChannel, object: channelId)
            } else {
                openURL(url)
            }
        }
        .background {
            InlineEmojiKeyboard(isActive: $showEmojiKeyboard) { emoji in
                if let messageId = emojiTargetMessageId {
                    RecentReactions.record(emoji)
                    Task { await viewModel.toggleReaction(messageId: messageId, emoji: emoji) }
                    Haptics.play(.light)
                }
                showEmojiKeyboard = false
                emojiTargetMessageId = nil
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Error Surfacing (SEC-005)
    
    @MainActor
    private func showError(_ message: String) {
        operationErrorMessage = message
        showOperationError = true
    }
    
    // MARK: - Glass Top Bar
    //
    // Mirrors ChatDetailView.customTopBar: hamburger in a glass circle, a tappable
    // glass title pill (opens channel info), and one grouped glass pill for actions.

    private var channelTopBar: some View {
        HStack(spacing: Spacing.sm) {
            if let drawerAction = toggleDrawerAction {
                Button {
                    drawerAction()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .scaledFont(size: 18, weight: .medium, context: .ui)
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .chatControlGlass(in: Circle(), fallback: .ultraThinMaterial)
                .accessibilityLabel("Menu")
            } else {
                // Pushed inside a NavigationStack (ChannelsListView): the system bar is
                // hidden, so provide a glass back button.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .scaledFont(size: 16, weight: .semibold, context: .ui)
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .chatControlGlass(in: Circle(), fallback: .ultraThinMaterial)
                .accessibilityLabel("Back")
            }

            Button {
                Haptics.play(.light)
                openChannelInfo()
            } label: {
                titlePillContent
                    .padding(.leading, viewModel.isDM ? 5 : 12)
                    .padding(.trailing, 12)
                    .padding(.vertical, 5)
                    .frame(minHeight: 40)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .chatControlGlass(in: Capsule(), fallback: .ultraThinMaterial)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(viewModel.channelDisplayTitle), channel info")

            trailingActionsPill
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var titlePillContent: some View {
        HStack(spacing: 8) {
            if viewModel.isDM {
                dmAvatarStack(size: 30)
            } else if let channel = viewModel.channel {
                Image(systemName: channel.isPrivate ? "lock" : (channel.type == .group ? "person.3" : "number"))
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(viewModel.channelDisplayTitle)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let subtitle = titleSubtitle {
                    Text(subtitle.text)
                        .scaledFont(size: 10.5)
                        .foregroundStyle(subtitle.isActive ? Color.green : theme.textTertiary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Active now" for 1:1 DMs, the DM user's status, or "N members" for channels.
    private var titleSubtitle: (text: String, isActive: Bool)? {
        if viewModel.isDM {
            guard let p = viewModel.dmOtherParticipant else { return nil }
            if let msg = p.statusMessage, !msg.isEmpty {
                return ("\(p.statusEmojiCharacter.map { "\($0) " } ?? "")\(msg)", false)
            }
            return (p.isOnline ? "Active now" : "Away", p.isOnline)
        }
        let count = viewModel.memberCount
        if count > 0 { return ("\(count) member\(count == 1 ? "" : "s")", false) }
        if let desc = viewModel.channel?.description, !desc.isEmpty { return (desc, false) }
        return nil
    }

    @ViewBuilder
    private func dmAvatarStack(size: CGFloat) -> some View {
        let participants = Array(viewModel.dmParticipants.prefix(2))
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: -size * 0.4) {
                ForEach(participants) { p in
                    UserAvatar(
                        size: size,
                        imageURL: p.resolveAvatarURL(serverBaseURL: viewModel.serverBaseURL),
                        name: p.displayName,
                        authToken: viewModel.serverAuthToken
                    )
                    .overlay(Circle().stroke(theme.background, lineWidth: participants.count > 1 ? 1.5 : 0))
                }
            }
            if participants.count == 1, let p = participants.first {
                Circle()
                    .fill(p.isOnline ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(theme.background, lineWidth: 1.5))
                    .offset(x: 1, y: 1)
            }
        }
    }

    private var trailingActionsPill: some View {
        HStack(spacing: 0) {
            pillIconButton(icon: "pin", label: "Pinned messages") {
                Task { await viewModel.loadPinnedMessages() }
                viewModel.showPinnedSheet = true
            }

            Button {
                Haptics.play(.light)
                openMembers()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "person.2")
                        .scaledFont(size: 14, weight: .medium)
                    if viewModel.memberCount > 0 && !viewModel.isDM {
                        Text(compactCount(viewModel.memberCount))
                            .scaledFont(size: 12, weight: .semibold)
                            .contentTransition(.numericText())
                    }
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(minWidth: 40, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Members")

            Menu {
                channelMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More channel actions")
        }
        .chatControlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: .ultraThinMaterial)
    }

    @ViewBuilder
    private var channelMenuItems: some View {
        Button {
            openChannelInfo()
        } label: {
            Label(viewModel.isDM ? "Conversation Info" : "Members", systemImage: viewModel.isDM ? "info.circle" : "person.2")
        }
        if viewModel.canManageChannel {
            Button {
                openSettings()
            } label: {
                Label(viewModel.isDM ? "Conversation Settings" : "Channel Settings", systemImage: "gearshape")
            }
        }
        if viewModel.canManageChannel && !viewModel.isDM {
            Button {
                showWebhooks = true
            } label: {
                Label("Webhooks", systemImage: "link.badge.plus")
            }
        }
        Button {
            UIPasteboard.general.string = "\(viewModel.serverBaseURL)/channels/\(viewModel.channelId)"
            Haptics.notify(.success)
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        if viewModel.isDM {
            Divider()
            Button(role: .destructive) {
                Task {
                    try? await dependencies.apiClient?.updateMemberActiveStatus(channelId: viewModel.channelId, isActive: false)
                    channelListVM?.hideDM(channelId: viewModel.channelId)
                }
            } label: {
                Label("Hide Conversation", systemImage: "eye.slash")
            }
        }
    }

    private func pillIconButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.light)
            action()
        } label: {
            Image(systemName: icon)
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func compactCount(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName))
    }

    private func openMembers() {
        viewModel.searchMembers("", debounce: false)
        Task { await viewModel.loadMembers() }
        viewModel.showMembersSheet = true
    }

    private func openChannelInfo() {
        if viewModel.isDM, let other = viewModel.dmOtherParticipant {
            profileUserId = other.id
        } else {
            openMembers()
        }
    }

    private func openSettings() {
        Task {
            async let channelRefresh: () = viewModel.loadChannel()
            async let usersRefresh: () = viewModel.loadAllServerUsers()
            _ = await (channelRefresh, usersRefresh)
            showChannelSettings = true
        }
    }

    // MARK: - Message List
    
    private var messageListArea: some View {
        ZStack {
            scrollContent
            
            if viewModel.isLoadingMessages && viewModel.messages.isEmpty {
                loadingPlaceholders
            }
            
            if !viewModel.isLoadingMessages && viewModel.messages.isEmpty {
                emptyChannelView
            }
        }
        .overlay(alignment: .bottom) { scrollToBottomFAB }
        .onAppear { scrollPosition.scrollTo(edge: .bottom) }
        // iMessage behaviour: opening the keyboard keeps the latest message visible.
        .onChange(of: keyboard.height > 0) { _, isShown in
            guard isShown, !isScrolledUp else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.25)) { scrollPosition.scrollTo(edge: .bottom) }
            }
        }
        .onChange(of: viewModel.messages.count) { old, new in
            guard new > old else { return }
            // Always scroll when the user sends their own message (last message is theirs).
            // For incoming messages from others, only scroll if not scrolled up.
            let lastIsOwn = viewModel.messages.last?.userId == viewModel.currentUserId
            if lastIsOwn {
                isScrolledUp = false
                withAnimation { scrollPosition.scrollTo(edge: .bottom) }
            } else if !isScrolledUp {
                withAnimation { scrollPosition.scrollTo(edge: .bottom) }
            }
        }
        .onChange(of: viewModel.messages.last?.id) { oldId, newId in
            // Only count appends (new arrivals), not older history prepended at the top.
            guard isScrolledUp, oldId != nil, newId != oldId,
                  let last = viewModel.messages.last,
                  last.userId != viewModel.currentUserId else { return }
            withAnimation(.spring(response: 0.3)) { unseenCount += 1 }
        }
    }
    
    // MARK: - Swipe-to-Reply Logic

    /// Threshold (pts) at which swipe triggers the reply action.
    private let swipeReplyThreshold: CGFloat = 64

    /// Distance (pts) from the bottom at which the scroll-to-bottom button appears.
    private static let fabShowDistance: CGFloat = 250
    /// Distance (pts) from the bottom below which the button hides again.
    private static let fabHideDistance: CGFloat = 200

    /// Current swipe offset for a row (rubber-banded by the gesture).
    private func swipeOffset(for id: String) -> CGFloat {
        swipeOffsets[id] ?? 0
    }

/// Starts a reply to `message`: sets the composer's reply chip and focuses it.
    private func beginReply(to message: ChannelMessage) {
        viewModel.setReplyTo(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
        }
    }

    // MARK: - Glass Long-Press Menu

    /// Builds and presents the glass menu for `message` (reactions + actions).
    private func presentMenu(for message: ChannelMessage, isCurrentUser: Bool,
                             showHeader: Bool, showTimestamp: Bool, position: GroupPosition) {
        guard let frame = rowFrames[message.id] else { return }
        let uid = viewModel.currentUserId ?? ""
        let own = Set(message.reactions.filter { $0.userIds.contains(uid) }.map { $0.name.emojiFromShortcode })
        let canWrite = viewModel.hasWriteAccess

        var quick: [MessageMenuAction] = []
        if canWrite {
            quick.append(.init(id: "reply", title: "Reply", icon: "arrowshape.turn.up.left") {
                beginReply(to: message)
            })
        }
        quick.append(.init(id: "thread", title: message.hasThread || canWrite ? "Thread" : "View",
                           icon: "bubble.left.and.bubble.right") {
            Task { await viewModel.openThread(for: message) }
        })
        quick.append(.init(id: "copy", title: "Copy", icon: "doc.on.doc") {
            viewModel.copyMessage(message)
        })
        quick.append(.init(id: "pin", title: message.isPinned ? "Unpin" : "Pin",
                           icon: message.isPinned ? "pin.slash" : "pin") {
            Task { await viewModel.togglePin(messageId: message.id) }
        })

        var info: [MessageMenuAction] = [
            .init(id: "time", title: message.createdAt.formatted(date: .abbreviated, time: .shortened), icon: "clock") {
                UIPasteboard.general.string = message.createdAt.formatted(date: .complete, time: .standard)
                Haptics.notify(.success)
            }
        ]
        if !isModelOrWebhook(message) && !message.isFromModel {
            info.append(.init(id: "profile", title: "View Profile", icon: "person.crop.circle") {
                profileUserId = message.userId
            })
        }
        var sections: [[MessageMenuAction]] = [info]
        if viewModel.canModify(message) {
            sections.append([
                .init(id: "edit", title: "Edit", icon: "pencil") { viewModel.beginEditing(message: message) },
                .init(id: "delete", title: "Delete", icon: "trash", style: .destructive) {
                    viewModel.pendingDeleteMessage = message
                }
            ])
        }

        let preview = channelMessageRow(message, showSenderHeader: showHeader,
                                        showGroupTimestamp: showTimestamp, position: position)
            .environment(\.theme, theme)
            .frame(width: frame.width)
        menuPresenter.present(MessageMenuContent(
            messageId: message.id,
            preview: AnyView(preview),
            sourceFrame: frame,
            alignTrailing: isCurrentUser,
            header: "\(viewModel.resolvedSenderName(for: message)) · \(message.createdAt.channelTime)",
            ownReactions: own,
            showsReactions: canWrite,
            quickActions: quick,
            sections: sections,
            onReact: { emoji in
                Task { await viewModel.toggleReaction(messageId: message.id, emoji: emoji) }
            },
            onMoreReactions: {
                emojiTargetMessageId = message.id
                showEmojiKeyboard = true
            }
        ))
    }

    private func isModelOrWebhook(_ message: ChannelMessage) -> Bool {
        viewModel.isModelMessage(message) || message.isFromWebhook
    }

    // MARK: - Scroll + Highlight

    /// Scrolls to and briefly highlights the original message referenced by a reply.
    private func scrollToAndHighlight(messageId: String) {
        guard viewModel.messages.contains(where: { $0.id == messageId }) else {
            // Not in the loaded timeline (older history or a thread reply) — open its thread if
            // it's a reply; otherwise surface a hint.
            if let pinned = viewModel.pinnedMessages.first(where: { $0.id == messageId }),
               let parentId = pinned.parentId,
               let parent = viewModel.messages.first(where: { $0.id == parentId }) {
                Task { await viewModel.openThread(for: parent) }
            } else {
                reactionTooltipText = "That message is further back in the history"
                withAnimation { showReactionTooltip = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showReactionTooltip = false }
                }
            }
            return
        }
        // Scroll to the message
        withAnimation(.easeInOut(duration: 0.35)) {
            scrollPosition.scrollTo(id: messageId, anchor: .center)
        }
        // Flash highlight after scroll settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeInOut(duration: 0.2)) {
                highlightedMessageId = messageId
            }
            // Remove highlight after 1.2s
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.4)) {
                    highlightedMessageId = nil
                }
            }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if viewModel.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, Spacing.md)
                }

                if viewModel.reachedChannelStart && !viewModel.messages.isEmpty {
                    channelStartHeader
                }
                
                ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                    if shouldShowDateSeparator(at: index) {
                        dateSeparatorView(for: message.createdAt)
                    }
                    
                    let showHeader = shouldShowSenderHeader(at: index)
                    let showTimestamp = isLastInGroup(at: index)
                    let position = groupPosition(at: index)
                    let isHighlighted = highlightedMessageId == message.id
                    let offset = swipeOffset(for: message.id)
                    let swipeProgress = min(abs(offset) / swipeReplyThreshold, 1.0)
                    let isCurrentUser = message.userId == viewModel.currentUserId && !viewModel.isModelMessage(message)

                    ZStack(alignment: isCurrentUser ? .trailing : .leading) {
                        // Reply icon revealed from the edge the row slides away from
                        // (own messages slide left, others slide right).
                        SwipeReplyIcon(progress: swipeProgress)
                            .opacity(swipeProgress > 0.05 ? 1 : 0)
                            .scaleEffect(0.6 + swipeProgress * 0.4)
                            .padding(isCurrentUser ? .trailing : .leading, Spacing.screenPadding)
                            .allowsHitTesting(false)

                        channelMessageRow(message, showSenderHeader: showHeader, showGroupTimestamp: showTimestamp, position: position)
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(theme.brandPrimary.opacity(isHighlighted ? 0.12 : 0))
                                    .padding(.horizontal, 6)
                            }
                            .offset(x: offset)
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[message.id] = $0 }
                    .opacity(menuPresenter.content?.messageId == message.id && menuPresenter.isVisible ? 0 : 1)
                    .id(message.id)
                    .task {
                        // Reaching the top loads older history; keep the reader's place
                        // by re-anchoring on the message that was first before the load.
                        guard message.id == viewModel.messages.first?.id,
                              !viewModel.reachedChannelStart, !viewModel.isLoadingMore else { return }
                        let anchorId = message.id
                        let countBefore = viewModel.messages.count
                        await viewModel.loadOlderMessages()
                        guard viewModel.messages.count > countBefore else { return }
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { scrollPosition.scrollTo(id: anchorId, anchor: .top) }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(minHeight: max(containerHeight, 0), alignment: .top)
            // Tapping empty space (between/around messages, or below a short
            // conversation) closes the keyboard. Attached as a *background* so
            // bubbles, links and buttons keep first-touch priority.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
            }
            // Prevent keyboard-animation frames from propagating into this subtree
            // (rows track their frames via onGeometryChange), keeping input snappy.
            .transaction { $0.animation = nil }
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition, anchor: .bottom)
        // One atomic snapshot per frame: distance from the visible bottom accounts
        // for the glass composer inset, so "scrolled up" is always accurate.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            let visibleBottom = geo.contentOffset.y + geo.containerSize.height - geo.contentInsets.bottom
            return max(0, geo.contentSize.height - visibleBottom)
        } action: { _, distance in
            // Hysteresis: show once clearly away from the latest messages, hide
            // again as soon as you're back near them (no flicker at the edge).
            let scrolledUp = isScrolledUp ? distance > Self.fabHideDistance
                                          : distance > Self.fabShowDistance
            if scrolledUp != isScrolledUp {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isScrolledUp = scrolledUp }
            }
            if !scrolledUp, unseenCount != 0 { unseenCount = 0 }
        }
        .onScrollGeometryChange(for: CGSize.self) { geo in
            CGSize(width: geo.contentSize.height, height: geo.containerSize.height)
        } action: { _, newSize in
            if abs(newSize.width - contentHeight) > 1 { contentHeight = newSize.width }
            if abs(newSize.height - containerHeight) > 1 { containerHeight = newSize.height }
        }
        .scrollContentBackground(.hidden)
        .background(ScrollViewEdgeEffectDisabler())
        .background(ChannelScrollHorizontalLock())
    }
    
    // MARK: - Message Grouping
    
    private enum GroupPosition {
        case single, first, middle, last
    }
    
    private func shouldShowSenderHeader(at index: Int) -> Bool {
        let messages = viewModel.messages
        guard index < messages.count else { return true }
        guard index > 0 else { return true }
        let current = messages[index]
        let previous = messages[index - 1]
        if !Calendar.current.isDate(current.createdAt, inSameDayAs: previous.createdAt) {
            return true
        }
        return current.effectiveSenderId != previous.effectiveSenderId
    }
    
    private func isLastInGroup(at index: Int) -> Bool {
        let messages = viewModel.messages
        guard index < messages.count else { return true }
        guard index < messages.count - 1 else { return true }
        let current = messages[index]
        let next = messages[index + 1]
        if !Calendar.current.isDate(current.createdAt, inSameDayAs: next.createdAt) {
            return true
        }
        return current.effectiveSenderId != next.effectiveSenderId
    }
    
    private func groupPosition(at index: Int) -> GroupPosition {
        let isFirst = shouldShowSenderHeader(at: index)
        let isLast = isLastInGroup(at: index)
        switch (isFirst, isLast) {
        case (true, true):   return .single
        case (true, false):  return .first
        case (false, false): return .middle
        case (false, true):  return .last
        }
    }
    
    private func shouldShowDateSeparator(at index: Int) -> Bool {
        let messages = viewModel.messages
        guard index < messages.count else { return false }
        guard index > 0 else { return true }
        let current = messages[index].createdAt
        let previous = messages[index - 1].createdAt
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }
    
    // MARK: - Message Row

    private let avatarSize: CGFloat = 28
    
    // MARK: - Date Separator
    
    private func dateSeparatorView(for date: Date) -> some View {
        ChannelDateCapsule(date: date)
    }
    
    @ViewBuilder
    private func channelMessageRow(_ message: ChannelMessage, showSenderHeader: Bool, showGroupTimestamp: Bool, position: GroupPosition = .single) -> some View {
        let isCurrentUser = message.userId == viewModel.currentUserId && !viewModel.isModelMessage(message)
        let isModel = viewModel.isModelMessage(message)
        let resolvedName = viewModel.resolvedSenderName(for: message)
        let showTail = (position == .last || position == .single)
        let bubbleAlignment: HorizontalAlignment = isCurrentUser ? .trailing : .leading
        let frameAlignment: Alignment = isCurrentUser ? .trailing : .leading
        
        VStack(alignment: bubbleAlignment, spacing: 0) {
            // Sender header — only shown for received messages (not current user)
            if showSenderHeader && !isCurrentUser {
                HStack(spacing: 8) {
                    senderAvatar(message, size: avatarSize)
                        .onTapGesture {
                            guard !isModel, !message.isFromWebhook else { return }
                            Haptics.play(.light)
                            profileUserId = message.userId
                        }
                    
                    HStack(spacing: 5) {
                        Text(resolvedName)
                            .scaledFont(size: 13, weight: .bold)
                            .foregroundStyle(isModel ? theme.mentionModelText : theme.textPrimary)

                        if message.isFromWebhook {
                            Text("WEBHOOK")
                                .scaledFont(size: 8, weight: .heavy)
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(theme.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        
                        if isModel {
                            Text("BOT")
                                .scaledFont(size: 8, weight: .heavy)
                                .foregroundStyle(theme.mentionModelText)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(theme.mentionModelBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        
                        Text(message.createdAt.channelTime)
                            .scaledFont(size: 10)
                            .foregroundStyle(theme.textTertiary)
                            .accessibilityLabel(message.createdAt.formatted(date: .complete, time: .shortened))
                    }
                }
                .padding(.bottom, 3)
            }
            
            if let replyId = message.replyToId {
                replyIndicator(for: replyId, message: message)
                    .frame(maxWidth: ChannelLayout.maxBubbleWidth, alignment: frameAlignment)
                    .padding(.bottom, 3)
            }
            
            if viewModel.editingMessage?.id == message.id {
                editBubble(isCurrentUser: isCurrentUser)
            } else if isModel && message.renderedContent.isEmpty && message.files.isEmpty && !message.isModelDone {
                // Model is streaming — show animated typing dots while content arrives
                // This covers the gap between when the empty placeholder message is
                // created by the backend and when the first token arrives via socket.
                HStack(spacing: 8) {
                    TypingDotsView()
                    Text("Generating…")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
                .modifier(ChannelBubbleStyle(isCurrentUser: false, showTail: showTail))
            } else if !message.renderedContent.isEmpty || !message.files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if message.hasStructuredOutput {
                        // Reasoning / tool calls / text streamed by @model responses (web: StructuredOutputRenderer)
                        AssistantMessageContent(
                            content: message.renderedContent,
                            isStreaming: !message.isModelDone,
                            authToken: viewModel.serverAuthToken,
                            serverBaseURL: viewModel.serverBaseURL,
                            apiClient: dependencies.apiClient
                        )
                    } else if !message.content.isEmpty {
                        ChannelMarkdownView(
                            content: message.content,
                            currentUserId: viewModel.currentUserId,
                            isCurrentUser: isCurrentUser,
                            accessibleChannelIds: viewModel.accessibleChannelIds
                        )
                    }

                    if !message.files.isEmpty {
                        messageAttachments(message.files)
                    }

                    if message.isEdited {
                        Text("edited")
                            .scaledFont(size: 10)
                            .foregroundStyle(isCurrentUser ? theme.brandOnPrimary.opacity(0.7) : theme.textTertiary)
                    }
                }
                .modifier(ChannelBubbleStyle(isCurrentUser: isCurrentUser, showTail: showTail))
            }
            
            // Reactions (MF-003: with tooltip on long-press)
            // AnimatedPresence smoothly expands height when reactions arrive via socket
            AnimatedPresence(visible: !message.reactions.isEmpty) {
                if !message.reactions.isEmpty {
                    ChannelReactionsBar(
                        reactions: message.reactions,
                        currentUserId: viewModel.currentUserId,
                        alignment: bubbleAlignment,
                        isEnabled: viewModel.hasWriteAccess,
                        onToggle: { name in
                            Task { await viewModel.toggleReaction(messageId: message.id, emoji: name) }
                            Haptics.play(.light)
                        },
                        onAdd: {
                            emojiTargetMessageId = message.id
                            showEmojiKeyboard = true
                        },
                        onShowReactors: { reaction in showReactors(reaction) }
                    )
                    .frame(maxWidth: ChannelLayout.maxBubbleWidth, alignment: frameAlignment)
                    .padding(.top, 4)
                }
            }

            // Thread reply badge — smoothly appears when a thread reply is created
            AnimatedPresence(visible: message.hasThread) {
                if message.hasThread {
                    ChannelThreadBadge(
                        replyCount: message.replyCount,
                        latestReplyAt: message.latestReplyAt,
                        avatarURLs: threadAvatarURLs(for: message),
                        authToken: viewModel.serverAuthToken
                    ) {
                        Task { await viewModel.openThread(for: message) }
                        Haptics.play(.light)
                    }
                    .padding(.top, 4)
                }
            }
            
            if message.isPinned || (showGroupTimestamp && !showSenderHeader) {
                ChannelMessageMeta(
                    time: showGroupTimestamp && !showSenderHeader ? message.createdAt.channelTime : nil,
                    isPinned: message.isPinned,
                    isEdited: false
                )
                .padding(.top, 3)
            }
            
            if message.isFailed {
                Button {
                    Task { await viewModel.retrySendMessage(id: message.id) }
                } label: {
                    Label("Not sent · Retry", systemImage: "exclamationmark.circle.fill")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.error)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.error.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel("Message not sent. Retry")
            }
        }
        // Gestures live on the content stack (bubble, header, reactions) — not the
        // full-width row — so a swipe on the empty space beside a message still
        // opens the sidebar. No contentShape here: only drawn content is hittable.
        .modifier(ChannelMessageGestures(
            swipeEnabled: viewModel.hasWriteAccess && !message.isOptimistic,
            longPressEnabled: !message.isOptimistic && viewModel.editingMessage?.id != message.id,
            threshold: swipeReplyThreshold,
            direction: isCurrentUser ? .left : .right,
            onSwipeChanged: { swipeOffsets[message.id] = $0 },
            onSwipeEnded: { triggered in
                if triggered { beginReply(to: message) }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    swipeOffsets[message.id] = nil
                }
            },
            onLongPress: {
                presentMenu(for: message, isCurrentUser: isCurrentUser,
                            showHeader: showSenderHeader, showTimestamp: showGroupTimestamp,
                            position: position)
            }
        ))
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, showSenderHeader ? 12 : 2)
        .padding(.bottom, (message.isPinned || repliesToMe(message)) ? 4 : 0)
        .background(rowTint(for: message))
        .opacity(message.isOptimistic ? 0.6 : 1.0)
        // Tapping a message closes the keyboard. Simultaneous so links, mentions,
        // images and text selection inside the bubble keep working.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }

    // MARK: - Sender Avatar
    
    @ViewBuilder
    private func senderAvatar(_ message: ChannelMessage, size: CGFloat = 32) -> some View {
        let isModel = viewModel.isModelMessage(message)
        if isModel, let model = viewModel.resolveModelForMessage(message) {
            ModelAvatar(
                size: size,
                imageURL: model.resolveAvatarURL(baseURL: viewModel.serverBaseURL),
                label: model.shortName,
                authToken: viewModel.serverAuthToken
            )
        } else {
            let resolvedName = viewModel.resolvedSenderName(for: message)
            let avatarURL = ChannelAvatarURL.forSender(
                userId: message.userId, isWebhook: message.isFromWebhook, serverBaseURL: viewModel.serverBaseURL
            )
            UserAvatar(
                size: size,
                imageURL: avatarURL,
                name: resolvedName,
                authToken: viewModel.serverAuthToken
            )
        }
    }
    
    private func avatarURLForUser(id: String) -> URL? {
        guard !id.isEmpty, !viewModel.serverBaseURL.isEmpty else { return nil }
        return URL(string: "\(viewModel.serverBaseURL)/api/v1/users/\(id)/profile/image")
    }
    
    // MARK: - Reply Indicator

    @ViewBuilder
    private func replyIndicator(for replyId: String, message: ChannelMessage) -> some View {
        // Try to find the original message in the loaded list
        if let replyMsg = viewModel.messages.first(where: { $0.id == replyId }) {
            let isModel = viewModel.isModelMessage(replyMsg)
            let avatarURL: URL? = isModel
                ? viewModel.resolveModelForMessage(replyMsg)?.resolveAvatarURL(baseURL: viewModel.serverBaseURL)
                : ChannelAvatarURL.forSender(userId: replyMsg.userId, isWebhook: replyMsg.isFromWebhook, serverBaseURL: viewModel.serverBaseURL)
            ChannelReplyPreview(
                senderName: viewModel.resolvedSenderName(for: replyMsg),
                content: replyMsg.content,
                isModel: isModel,
                avatarURL: avatarURL,
                authToken: viewModel.serverAuthToken,
                hasFiles: !replyMsg.files.isEmpty
            ) {
                scrollToAndHighlight(messageId: replyId)
            }
        } else if let slim = message.replyToMessage {
            // Fallback: use the slim snapshot embedded in the message
            let slimIsModel = slim.modelId != nil
            let avatarURL: URL? = slimIsModel
                ? viewModel.resolveModel(for: slim.modelId)?.resolveAvatarURL(baseURL: viewModel.serverBaseURL)
                : ChannelAvatarURL.forSender(userId: slim.userId, isWebhook: slim.user?.role == "webhook", serverBaseURL: viewModel.serverBaseURL)
            ChannelReplyPreview(
                senderName: slim.modelName ?? slim.user?.displayName ?? "Unknown",
                content: slim.content,
                isModel: slimIsModel,
                avatarURL: avatarURL,
                authToken: viewModel.serverAuthToken,
                hasFiles: false
            ) {
                // Try to scroll even if message may not be visible (best-effort)
                scrollToAndHighlight(messageId: replyId)
            }
        }
    }
    
    // MARK: - File Attachments
    
    @ViewBuilder
    private func messageAttachments(_ files: [ChatMessageFile]) -> some View {
        let imageFiles = files.filter { $0.type == "image" || ($0.contentType ?? "").hasPrefix("image/") }
        let otherFiles = files.filter { $0.type != "image" && !($0.contentType ?? "").hasPrefix("image/") }
        
        if !imageFiles.isEmpty {
            ChannelImageGrid(imageFiles: imageFiles, apiClient: dependencies.apiClient)
        }
        
        ForEach(Array(otherFiles.enumerated()), id: \.offset) { _, file in
            let fileName = file.name ?? file.url ?? "File"
            ChannelFileCard(
                name: fileName,
                contentType: file.contentType,
                onTap: {
                    if let fileId = file.url {
                        Task { await previewFileInApp(fileId: fileId, fileName: fileName) }
                    }
                }
            )
            .frame(maxWidth: 280)
        }
    }
    
    // MARK: - Edit Bubble
    
    private func editBubble(isCurrentUser: Bool) -> some View {
        @Bindable var vm = viewModel
        return VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message…", text: $vm.editingText, axis: .vertical)
                .scaledFont(size: 14)
                .lineLimit(1...10)
                .focused($isEditFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceContainer.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            
            HStack(spacing: 8) {
                Button { viewModel.cancelEditing() } label: {
                    Text("Cancel")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .chatControlGlass(in: Capsule(), fallback: theme.surfaceContainer)
                }
                .buttonStyle(.plain)
                Button { Task { await viewModel.submitEdit() } } label: {
                    Text("Save")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.brandOnPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(theme.brandPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .chatControlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fallback: .ultraThinMaterial)
    }
    
    // MARK: - Reactions / Row Tint Helpers

    /// MF-003: Shows "Alice, Bob and 3 others" when a reaction chip is long-pressed.
    private func showReactors(_ reaction: MessageReaction) {
        let names = reaction.userIds.enumerated().map { idx, id -> String in
            if id == viewModel.currentUserId { return "You" }
            return idx < reaction.userNames.count ? reaction.userNames[idx] : "Someone"
        }
        guard !names.isEmpty else { return }
        let shown = names.prefix(3).joined(separator: ", ")
        let rest = names.count - 3
        reactionTooltipText = (rest > 0 ? "\(shown) and \(rest) other\(rest == 1 ? "" : "s")" : shown)
            + " reacted with \(reaction.name.emojiFromShortcode)"
        Haptics.play(.light)
        withAnimation(.easeOut(duration: 0.15)) { showReactionTooltip = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.15)) { showReactionTooltip = false }
            }
        }
    }

    /// Web parity: a message replying to *you* (or your model) gets an accent tint.
    private func repliesToMe(_ message: ChannelMessage) -> Bool {
        guard let uid = viewModel.currentUserId, message.userId != uid else { return false }
        if let slim = message.replyToMessage { return slim.targetId == uid }
        if let replyId = message.replyToId, let original = viewModel.messages.first(where: { $0.id == replyId }) {
            return original.userId == uid && !viewModel.isModelMessage(original)
        }
        return false
    }

    @ViewBuilder
    private func rowTint(for message: ChannelMessage) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if repliesToMe(message) {
            shape.fill(Color.orange.opacity(theme.isDark ? 0.08 : 0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.orange.opacity(0.8)).frame(width: 3).padding(.vertical, 8)
                }
                .padding(.horizontal, 6)
        } else if message.isPinned {
            shape.fill(Color.orange.opacity(theme.isDark ? 0.05 : 0.04))
                .padding(.horizontal, 6)
        } else {
            Color.clear
        }
    }

    /// Up to three distinct repliers for a thread badge (from loaded thread messages).
    private func threadAvatarURLs(for message: ChannelMessage) -> [URL] {
        guard viewModel.threadParentMessage?.id == message.id else { return [] }
        var seen = Set<String>()
        return viewModel.threadMessages.reversed().compactMap { reply -> URL? in
            guard seen.insert(reply.effectiveSenderId).inserted, seen.count <= 3 else { return nil }
            if viewModel.isModelMessage(reply) {
                return viewModel.resolveModelForMessage(reply)?.resolveAvatarURL(baseURL: viewModel.serverBaseURL)
            }
            return ChannelAvatarURL.forSender(userId: reply.userId, isWebhook: reply.isFromWebhook,
                                              serverBaseURL: viewModel.serverBaseURL)
        }
    }

    // MARK: - Bottom Glass Chrome
    //
    // Floating typing capsule + the glass composer. Reply / @model / "model will
    // respond" context lives inside the composer as chips (no separate bars), and
    // nothing paints an opaque background — messages scroll under the glass.

    private var bottomChrome: some View {
        VStack(spacing: 0) {
            if !viewModel.typingUsers.isEmpty {
                ChannelTypingCapsule(names: viewModel.typingUsers.map(\.name))
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // MF-005: Only show input if user has write access
            if viewModel.hasWriteAccess {
                channelInputField
            } else {
                ChannelReadOnlyBanner()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: viewModel.typingUsers.map(\.id))
    }

    /// Context chips for the composer (reply target, @model, bot-reply hint).
    private var composerChips: [ChannelComposerChip] {
        var chips: [ChannelComposerChip] = []
        if let reply = viewModel.replyToMessage {
            let preview = ChannelMessage.parseMentions(in: reply.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chips.append(ChannelComposerChip(
                id: "reply-\(reply.id)",
                style: .reply,
                icon: "arrowshape.turn.up.left.fill",
                title: "Replying to \(viewModel.resolvedSenderName(for: reply))",
                subtitle: preview.isEmpty ? (reply.files.isEmpty ? nil : "Attachment") : String(preview.prefix(90)),
                onTap: { scrollToAndHighlight(messageId: reply.id) },
                onRemove: { viewModel.clearReply() }
            ))
        }
        if let modelName = viewModel.mentionedModelName {
            chips.append(ChannelComposerChip(
                id: "model-\(modelName)",
                style: .model,
                icon: "cpu",
                title: "\(modelName) will respond",
                subtitle: nil,
                onTap: nil,
                onRemove: { viewModel.clearModelMention() }
            ))
        } else if let replyModel = viewModel.replyTargetModelName {
            // Web parity: replying to a model's message makes that model answer.
            chips.append(ChannelComposerChip(
                id: "reply-model-\(replyModel)",
                style: .model,
                icon: "sparkles",
                title: "\(replyModel) will respond",
                subtitle: nil,
                onTap: nil,
                onRemove: nil
            ))
        }
        return chips
    }

    private var channelInputField: some View {
        @Bindable var vm = viewModel

        return ChannelInputField(
            text: $vm.inputText,
            attachments: $vm.attachments,
            placeholder: viewModel.inputPlaceholder,
            isEnabled: true,
            onSend: { await viewModel.sendMessage() },
            canSend: viewModel.canSend,
            chips: composerChips,
            onAttachmentTapped: { showAttachmentPicker = true },
            onPasteAttachments: { pasted in
                vm.attachments.append(contentsOf: pasted)
                for att in pasted { vm.uploadAttachmentImmediately(attachmentId: att.id) }
            },
            onRemoveAttachment: { att in
                vm.attachments.removeAll { $0.id == att.id }
            },
            onTextChange: {
                // Emit typing indicator to server when user types
                viewModel.emitTyping()
            },
            onAtTrigger: { query in
                mentionQuery = query
                viewModel.searchMentions(query)
                if !isShowingMentionPicker {
                    withAnimation(.easeOut(duration: 0.2)) { isShowingMentionPicker = true }
                }
            },
            onAtDismiss: { dismissMentionPicker() },
            onHashTrigger: { query in
                channelQuery = query
                if !isShowingChannelPicker {
                    withAnimation(.easeOut(duration: 0.2)) { isShowingChannelPicker = true }
                }
            },
            onHashDismiss: { dismissChannelPicker() },
            onSlashTrigger: { query in
                promptQuery = query
                if !isShowingPromptPicker {
                    viewModel.loadPrompts()
                    withAnimation(.easeOut(duration: 0.2)) { isShowingPromptPicker = true }
                }
            },
            onSlashDismiss: { dismissPromptPicker() },
            dictationService: dependencies.dictationService.context == dictationContext ? dependencies.dictationService : nil,
            onDictationStart: dependencies.authViewModel.chatPermissions.stt ? { startDictation() } : nil,
            onDictationStop: { dependencies.dictationService.stopDictation() },
            onDictationCancel: { dependencies.dictationService.cancelDictation() }
        )
    }

    // MARK: - Dictation (shared service with the main chat)

    /// Draft identity for dictation recovery: server + account + channel.
    private var dictationContext: DictationContext? {
        guard let server = dependencies.serverConfigStore.activeServer,
              let user = dependencies.authViewModel.currentUser,
              dependencies.authViewModel.phase == .authenticated else { return nil }
        return DictationContext(server: server.url, account: user.id, conversation: "channel:\(viewModel.channelId)")
    }

    private func startDictation() {
        let service = dependencies.dictationService
        guard let context = dictationContext else { return }
        service.onError = { [weak service] message in
            if service?.showsRecovery != true { showError(message) }
        }
        service.onAutoStopped = nil
        service.bind(to: context, isCurrent: { dictationContext == context },
                     draft: { [weak viewModel] in viewModel?.inputText },
                     deliver: { [weak viewModel] text in viewModel?.inputText = text })
        Task { await service.startDictation() }
    }

    private func dismissPromptPicker() {
        withAnimation(.easeOut(duration: 0.15)) {
            isShowingPromptPicker = false
            promptQuery = ""
        }
    }

    // MARK: - Empty Channel
    
    /// Web parity (Messages.svelte): "This channel was created on …" once the top is reached.
    private var channelStartHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.isDM {
                dmAvatarStack(size: 40)
            } else {
                Image(systemName: viewModel.channel?.isPrivate == true ? "lock" : "number")
                    .scaledFont(size: 20, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .chatControlGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), fallback: theme.surfaceContainer)
            }
            Text(viewModel.channelDisplayTitle)
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            if let created = viewModel.channel?.createdAt {
                Text(viewModel.isDM
                     ? "This is the beginning of your conversation. Started \(created.formatted(date: .long, time: .omitted))."
                     : "This channel was created on \(created.formatted(date: .long, time: .omitted)). This is the very beginning of the \(viewModel.channelDisplayTitle) channel.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var emptyChannelView: some View {
        VStack(spacing: Spacing.md) {
            Group {
                if viewModel.isDM {
                    dmAvatarStack(size: 56)
                } else {
                    Image(systemName: viewModel.channel?.isPrivate == true ? "lock.fill" : "number")
                        .scaledFont(size: 24, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: 64, height: 64)
                        .chatControlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                                          fallback: theme.surfaceContainer)
                }
            }
            VStack(spacing: 4) {
                Text(viewModel.isDM ? "Say hello to \(viewModel.channelDisplayTitle)" : "Welcome to #\(viewModel.channelDisplayTitle)")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Send the first message, or @mention a model to bring it into the conversation.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            if viewModel.hasWriteAccess {
                HStack(spacing: 8) {
                    emptyStateAction("Say hi 👋", icon: "hand.wave") { viewModel.inputText = "Hi everyone! 👋" }
                    emptyStateAction("@ a model", icon: "sparkles") { viewModel.inputText += "@" }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
    }

    private func emptyStateAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.light)
            action()
            NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
        } label: {
            Label(title, systemImage: icon)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .chatControlGlass(in: Capsule(), fallback: theme.surfaceContainer)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Loading (INC-007: Animated shimmer)
    
    /// Skeleton that mirrors the real layout: alternating bubbles with stable widths.
    private var loadingPlaceholders: some View {
        let rows: [(own: Bool, widths: [CGFloat])] = [
            (false, [180, 120]), (true, [150]), (false, [240, 200, 90]),
            (true, [110, 170]), (false, [160])
        ]
        return VStack(spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    if row.own { Spacer(minLength: 60) } else {
                        Circle().fill(theme.surfaceContainer.opacity(0.5)).frame(width: 28, height: 28)
                    }
                    VStack(alignment: row.own ? .trailing : .leading, spacing: 4) {
                        ForEach(Array(row.widths.enumerated()), id: \.offset) { _, w in
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(row.own ? theme.brandPrimary.opacity(0.18) : theme.surfaceContainer.opacity(0.5))
                                .frame(width: w, height: 34)
                        }
                    }
                    if !row.own { Spacer(minLength: 60) }
                }
                .padding(.horizontal, Spacing.screenPadding)
            }
            Spacer()
        }
        .padding(.top, 24)
        .shimmer()
        .accessibilityLabel("Loading messages")
    }
    
    // MARK: - Scroll FAB
    
    @ViewBuilder
    private var scrollToBottomFAB: some View {
        if isScrolledUp && !viewModel.messages.isEmpty {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "chevron.down")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .chatControlGlass(in: Circle(), fallback: .ultraThinMaterial)
                if unseenCount > 0 {
                    Text(unseenCount > 99 ? "99+" : "\(unseenCount)")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(theme.brandOnPrimary)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(theme.brandPrimary, in: Capsule())
                        .offset(x: 4, y: -4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Circle())
            .onTapGesture { scrollToBottom() }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(unseenCount > 0 ? "\(unseenCount) new messages, scroll to bottom" : "Scroll to bottom")
            .accessibilityAction { scrollToBottom() }
            .padding(.bottom, Spacing.sm)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }
    
    private func scrollToBottom() {
        Haptics.play(.light)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
            scrollPosition.scrollTo(edge: .bottom)
            isScrolledUp = false
            unseenCount = 0
        }
    }

    // MARK: - Copied Toast
    
    private var copiedToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc.fill").scaledFont(size: 12)
            Text("Copied").scaledFont(size: 12, weight: .medium)
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .chatControlGlass(in: Capsule(), fallback: .ultraThinMaterial)
        .padding(.top, Spacing.md)
        .transition(.toastTransition)
    }
    
    // MARK: - Pickers
    
    private func dismissChannelPicker() {
        if isShowingChannelPicker {
            withAnimation(.easeOut(duration: 0.15)) {
                isShowingChannelPicker = false
                channelQuery = ""
            }
        }
    }
    
    private func dismissMentionPicker() {
        if isShowingMentionPicker {
            withAnimation(.easeOut(duration: 0.15)) {
                isShowingMentionPicker = false
                mentionQuery = ""
            }
        }
    }
    
    // MARK: - File Processing (DRY-004: Could share with thread, but kept here for view locality)
    
    private func processPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let attachment = FileAttachmentService.makeImageAttachment(data: data) {
                viewModel.attachments.append(attachment)
                viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
            }
        }
    }
    
    private func processFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let attachment = ChatAttachment(type: .file, name: url.lastPathComponent, thumbnail: nil, data: data)
        viewModel.attachments.append(attachment)
        viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
    }
    
    // MARK: - File Preview (QuickLook)
    
    private func previewFileInApp(fileId: String, fileName: String) async {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let cachedFile = cacheDir.appendingPathComponent("\(fileId)_\(fileName)")
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            quickLookURL = cachedFile
            return
        }
        
        guard let apiClient = dependencies.apiClient else { return }
        withAnimation { isLoadingFile = true }
        
        do {
            let (data, _) = try await apiClient.getFileContent(id: fileId)
            try data.write(to: cachedFile)
            withAnimation { isLoadingFile = false }
            quickLookURL = cachedFile
        } catch {
            withAnimation { isLoadingFile = false }
            downloadErrorMessage = "Failed to load file: \(error.localizedDescription)"
            showDownloadError = true
        }
    }
}

// MARK: - Channel Bubble Shape
//
// iMessage-style speech bubble using UIBezierPath with smooth cubic bezier curves.
//
// • showTail = true  → the "last" or "single" bubble in a group gets a smooth pointed tail.
//   - Sent (isCurrentUser): tail at bottom-right, curving outward to the right.
//   - Received           : tail at bottom-left, curving outward to the left.
// • showTail = false → plain rounded rectangle (all four corners smooth).
//
// Adapted from the classic iMessage recreation technique — all corners and the tail
// use addCurve (cubic bezier) for a smooth, natural look with no sharp angular edges.

struct ChannelBubbleShape: InsettableShape {
    let isCurrentUser: Bool
    let showTail: Bool
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> ChannelBubbleShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let b = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let width = b.width
        let height = b.height
        // Offset so coordinates are relative to b.origin
        let minX = b.minX
        let minY = b.minY

        let bezier = UIBezierPath()

        if !isCurrentUser {
            // ── Received bubble: tail at bottom-left ──
            if showTail {
                bezier.move(to: CGPoint(x: minX + 20, y: minY + height))
                bezier.addLine(to: CGPoint(x: minX + width - 15, y: minY + height))
                bezier.addCurve(to: CGPoint(x: minX + width, y: minY + height - 15),
                                controlPoint1: CGPoint(x: minX + width - 8, y: minY + height),
                                controlPoint2: CGPoint(x: minX + width, y: minY + height - 8))
                bezier.addLine(to: CGPoint(x: minX + width, y: minY + 15))
                bezier.addCurve(to: CGPoint(x: minX + width - 15, y: minY),
                                controlPoint1: CGPoint(x: minX + width, y: minY + 8),
                                controlPoint2: CGPoint(x: minX + width - 8, y: minY))
                bezier.addLine(to: CGPoint(x: minX + 20, y: minY))
                bezier.addCurve(to: CGPoint(x: minX + 5, y: minY + 15),
                                controlPoint1: CGPoint(x: minX + 12, y: minY),
                                controlPoint2: CGPoint(x: minX + 5, y: minY + 8))
                bezier.addLine(to: CGPoint(x: minX + 5, y: minY + height - 10))
                bezier.addCurve(to: CGPoint(x: minX, y: minY + height),
                                controlPoint1: CGPoint(x: minX + 5, y: minY + height - 1),
                                controlPoint2: CGPoint(x: minX, y: minY + height))
                bezier.addLine(to: CGPoint(x: minX - 1, y: minY + height))
                bezier.addCurve(to: CGPoint(x: minX + 12, y: minY + height - 4),
                                controlPoint1: CGPoint(x: minX + 4, y: minY + height + 1),
                                controlPoint2: CGPoint(x: minX + 8, y: minY + height - 1))
                bezier.addCurve(to: CGPoint(x: minX + 20, y: minY + height),
                                controlPoint1: CGPoint(x: minX + 15, y: minY + height),
                                controlPoint2: CGPoint(x: minX + 20, y: minY + height))
            } else {
                // Plain rounded rect — no tail
                bezier.move(to: CGPoint(x: minX + 20, y: minY + height))
                bezier.addLine(to: CGPoint(x: minX + width - 15, y: minY + height))
                bezier.addCurve(to: CGPoint(x: minX + width, y: minY + height - 15),
                                controlPoint1: CGPoint(x: minX + width - 8, y: minY + height),
                                controlPoint2: CGPoint(x: minX + width, y: minY + height - 8))
                bezier.addLine(to: CGPoint(x: minX + width, y: minY + 15))
                bezier.addCurve(to: CGPoint(x: minX + width - 15, y: minY),
                                controlPoint1: CGPoint(x: minX + width, y: minY + 8),
                                controlPoint2: CGPoint(x: minX + width - 8, y: minY))
                bezier.addLine(to: CGPoint(x: minX + 20, y: minY))
                bezier.addCurve(to: CGPoint(x: minX + 5, y: minY + 15),
                                controlPoint1: CGPoint(x: minX + 12, y: minY),
                                controlPoint2: CGPoint(x: minX + 5, y: minY + 8))
                bezier.addLine(to: CGPoint(x: minX + 5, y: minY + height - 15))
                bezier.addCurve(to: CGPoint(x: minX + 20, y: minY + height),
                                controlPoint1: CGPoint(x: minX + 5, y: minY + height - 8),
                                controlPoint2: CGPoint(x: minX + 12, y: minY + height))
            }
        } else {
            // ── Sent bubble: tail at bottom-right ──
            if showTail {
                bezier.move(to: CGPoint(x: minX + width - 20, y: minY + height))
                bezier.addLine(to: CGPoint(x: minX + 15, y: minY + height))
                bezier.addCurve(to: CGPoint(x: minX, y: minY + height - 15),
                                controlPoint1: CGPoint(x: minX + 8, y: minY + height),
                                controlPoint2: CGPoint(x: minX, y: minY + height - 8))
                bezier.addLine(to: CGPoint(x: minX, y: minY + 15))
                bezier.addCurve(to: CGPoint(x: minX + 15, y: minY),
                                controlPoint1: CGPoint(x: minX, y: minY + 8),
                                controlPoint2: CGPoint(x: minX + 8, y: minY))
                bezier.addLine(to: CGPoint(x: minX + width - 20, y: minY))
                bezier.addCurve(to: CGPoint(x: minX + width - 5, y: minY + 15),
                                controlPoint1: CGPoint(x: minX + width - 12, y: minY),
                                controlPoint2: CGPoint(x: minX + width - 5, y: minY + 8))
                bezier.addLine(to: CGPoint(x: minX + width - 5, y: minY + height - 12))
                bezier.addCurve(to: CGPoint(x: minX + width, y: minY + height),
                                controlPoint1: CGPoint(x: minX + width - 5, y: minY + height - 1),
                                controlPoint2: CGPoint(x: minX + width, y: minY + height))
                bezier.addLine(to: CGPoint(x: minX + width + 1, y: minY + height))
                bezier.addCurve(to: CGPoint(x: minX + width - 12, y: minY + height - 4),
                                controlPoint1: CGPoint(x: minX + width - 4, y: minY + height + 1),
                                controlPoint2: CGPoint(x: minX + width - 8, y: minY + height - 1))
                bezier.addCurve(to: CGPoint(x: minX + width - 20, y: minY + height),
                                controlPoint1: CGPoint(x: minX + width - 15, y: minY + height),
                                controlPoint2: CGPoint(x: minX + width - 20, y: minY + height))
            } else {
                // Plain rounded rect — no tail
                bezier.move(to: CGPoint(x: minX + width - 20, y: minY + height))
                bezier.addLine(to: CGPoint(x: minX + 15, y: minY + height))
                bezier.addCurve(to: CGPoint(x: minX, y: minY + height - 15),
                                controlPoint1: CGPoint(x: minX + 8, y: minY + height),
                                controlPoint2: CGPoint(x: minX, y: minY + height - 8))
                bezier.addLine(to: CGPoint(x: minX, y: minY + 15))
                bezier.addCurve(to: CGPoint(x: minX + 15, y: minY),
                                controlPoint1: CGPoint(x: minX, y: minY + 8),
                                controlPoint2: CGPoint(x: minX + 8, y: minY))
                bezier.addLine(to: CGPoint(x: minX + width - 20, y: minY))
                bezier.addCurve(to: CGPoint(x: minX + width - 5, y: minY + 15),
                                controlPoint1: CGPoint(x: minX + width - 12, y: minY),
                                controlPoint2: CGPoint(x: minX + width - 5, y: minY + 8))
                bezier.addLine(to: CGPoint(x: minX + width - 5, y: minY + height - 15))
                bezier.addCurve(to: CGPoint(x: minX + width - 20, y: minY + height),
                                controlPoint1: CGPoint(x: minX + width - 5, y: minY + height - 8),
                                controlPoint2: CGPoint(x: minX + width - 12, y: minY + height))
            }
        }

        bezier.close()
        return Path(bezier.cgPath)
    }
}

// MARK: - iOS 26 Liquid Glass Edge Effect Disabler
//
// Walks up the UIView hierarchy from a hidden background view to find the enclosing
// UIScrollView and disables the iOS 26 "Liquid Glass" frosty blur at the scroll edge.

private struct ScrollViewEdgeEffectDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            var current: UIView? = view.superview
            while let sv = current {
                if let scrollView = sv as? UIScrollView {
                    // iOS 26 "Liquid Glass" frosty blur at scroll edges.
                    // edgeEffectEnabled is not yet in the public SDK headers,
                    // so we use KVC to set it at runtime.
                    scrollView.setValue(false, forKey: "edgeEffectEnabled")
                    break
                }
                current = sv.superview
            }
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

