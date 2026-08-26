import SwiftUI
import PhotosUI
import QuickLook
import MarkdownView
import os.log
import ReactionContextMenu

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
    
    @State private var viewModel: ChannelViewModel
    @State private var scrollPosition = ScrollPosition()
    @State private var isScrolledUp = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    @State private var keyboard = KeyboardTracker()
    
    // Swipe-to-reply / highlight
    @State private var highlightedMessageId: String?
    @State private var swipeOffsets: [String: CGFloat] = [:]
    @State private var swipeTriggered: Set<String> = []

    // iMessage-style reply focus overlay
    @State private var replyFocusMessage: ChannelMessage?
    @State private var replyOverlayInputText: String = ""
    @State private var showReplyOverlay: Bool = false
    
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
    
    // ReactionContextMenu state
    @State private var selectedReaction: String?
    @State private var reactionTargetMessageId: String?
    
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
        ZStack {
            theme.background.ignoresSafeArea()
            messageListArea
        }
        .modifier(ContextMenuHost())
        .environment(\.reactionProvider, ChannelReactionProvider())
        .onChange(of: selectedReaction) { _, newEmoji in
            guard let emoji = newEmoji, let msgId = reactionTargetMessageId else { return }
            selectedReaction = nil
            reactionTargetMessageId = nil
            if emoji == "➕" {
                emojiTargetMessageId = msgId
                showEmojiKeyboard = true
            } else {
                Task { await viewModel.toggleReaction(messageId: msgId, emoji: emoji) }
                Haptics.play(.light)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let replyMsg = viewModel.replyToMessage {
                    replyPreviewBar(replyMsg)
                }
                if viewModel.mentionedModelName != nil {
                    modelMentionBar
                }
                // Typing indicator — show when others are typing
                if !viewModel.typingUsers.isEmpty {
                    typingIndicatorBar
                }
                // MF-005: Only show input if user has write access
                if viewModel.hasWriteAccess {
                    channelInputField
                } else {
                    readOnlyBanner
                }
            }
            .background(theme.background)
        }
        // iMessage-style reply focus overlay
        .overlay {
            if showReplyOverlay, let msg = replyFocusMessage {
                replyFocusOverlay(for: msg)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
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
                    members: viewModel.members,
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
        .sheet(isPresented: Binding(
            get: { viewModel.threadParentMessage != nil },
            set: { if !$0 { viewModel.closeThread() } }
        )) {
            if let parent = viewModel.threadParentMessage {
                ThreadDetailSheet(viewModel: viewModel, parentMessage: parent)
                    .presentationDetents([.large, .fraction(0.92)])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $viewModel.showMembersSheet) {
            ChannelMembersSheet(members: viewModel.members, isLoading: viewModel.isLoadingMembers, serverBaseURL: viewModel.serverBaseURL)
        }
        .sheet(isPresented: $viewModel.showPinnedSheet) {
            PinnedMessagesSheet(messages: viewModel.pinnedMessages)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
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
                    currentUserId: userId
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
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Hamburger — only shown when wired from the drawer parent.
        // Matches ChatDetailView exactly: 46×46 circle, line.3.horizontal icon,
        // surfaceContainer background, .plain style, .contentShape(Circle()).
        if let drawerAction = toggleDrawerAction {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    drawerAction()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .scaledFont(size: 18, weight: .medium, context: .ui)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Menu")
            }
        }
        ToolbarItem(placement: .principal) {
            if viewModel.isDM {
                dmToolbarTitle
            } else if viewModel.isGroup {
                groupToolbarTitle
            } else {
                standardToolbarTitle
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await viewModel.loadPinnedMessages() }
                viewModel.showPinnedSheet = true
            } label: {
                Image(systemName: "pin")
                    .scaledFont(size: 13, weight: .medium)
            }
            
            Button {
                Task { await viewModel.loadMembers() }
                viewModel.showMembersSheet = true
            } label: {
                Image(systemName: "person.2")
                    .scaledFont(size: 13, weight: .medium)
            }
            
            if viewModel.canManageChannel {
                Button {
                    Task {
                        async let channelRefresh: () = viewModel.loadChannel()
                        async let usersRefresh: () = viewModel.loadAllServerUsers()
                        _ = await (channelRefresh, usersRefresh)
                        showChannelSettings = true
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .scaledFont(size: 13, weight: .medium)
                }
            }
        }
    }
    
    // MARK: - Type-Specific Toolbar Titles
    
    private var dmToolbarTitle: some View {
        HStack(spacing: 8) {
            if let participant = viewModel.dmOtherParticipant {
                ZStack(alignment: .bottomTrailing) {
                    UserAvatar(
                        size: 28,
                        imageURL: participant.resolveAvatarURL(serverBaseURL: viewModel.serverBaseURL),
                        name: participant.displayName
                    )
                    Circle()
                        .fill(participant.isOnline ? Color.green : Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(theme.background, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.channelDisplayTitle)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let participant = viewModel.dmOtherParticipant {
                    Text(participant.isOnline ? "Active now" : "Offline")
                        .scaledFont(size: 11)
                        .foregroundStyle(participant.isOnline ? .green : theme.textTertiary)
                }
            }
        }
    }
    
    private var groupToolbarTitle: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "person.3")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                Text(viewModel.channel?.name ?? "Group")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            if !viewModel.members.isEmpty {
                Text("\(viewModel.members.count) members")
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
            } else if let desc = viewModel.channel?.description, !desc.isEmpty {
                Text(desc)
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }
    
    private var standardToolbarTitle: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                if let channel = viewModel.channel {
                    Image(systemName: channel.isPrivate ? "lock" : "number")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
                Text(viewModel.channel?.name ?? "Channel")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            if let desc = viewModel.channel?.description, !desc.isEmpty {
                Text(desc)
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
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
        .overlay(alignment: .bottomTrailing) { scrollToBottomFAB }
        .onAppear { scrollPosition.scrollTo(edge: .bottom) }
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
    }
    
    // MARK: - Swipe-to-Reply Logic

    /// Threshold (pts) at which swipe triggers the reply action.
    private let swipeReplyThreshold: CGFloat = 64

    /// Returns the swipe offset for a given message, clamped to a max so it bounces back.
    private func swipeOffset(for id: String) -> CGFloat {
        min(swipeOffsets[id] ?? 0, swipeReplyThreshold * 1.1)
    }

    /// Handles swipe drag change — moves the bubble and shows the reply icon.
    private func onSwipeChanged(_ value: DragGesture.Value, messageId: String) {
        let translation = value.translation.width
        // Only allow right-swipe (positive x)
        guard translation > 0 else { return }
        let clamped = min(translation, swipeReplyThreshold * 1.5)
        swipeOffsets[messageId] = clamped

        // Trigger haptic once we cross the threshold
        if clamped >= swipeReplyThreshold && !(swipeTriggered.contains(messageId)) {
            swipeTriggered.insert(messageId)
            Haptics.play(.medium)
        } else if clamped < swipeReplyThreshold {
            swipeTriggered.remove(messageId)
        }
    }

    /// Handles swipe drag end — fires the iMessage-style reply overlay if threshold crossed.
    private func onSwipeEnded(_ value: DragGesture.Value, message: ChannelMessage) {
        let translation = value.translation.width
        if translation >= swipeReplyThreshold {
            // Show the iMessage-style focused reply overlay
            replyFocusMessage = message
            replyOverlayInputText = ""
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                showReplyOverlay = true
            }
            Haptics.play(.light)
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            swipeOffsets[message.id] = 0
        }
        swipeTriggered.remove(message.id)
    }

    /// Dismiss the reply overlay with a smooth keyboard-first animation.
    private func dismissReplyOverlay() {
        // Step 1: resign keyboard so it slides away smoothly first
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        // Step 2: wait for keyboard to finish descending (~0.25s), then fade overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.25)) {
                showReplyOverlay = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            replyFocusMessage = nil
            replyOverlayInputText = ""
        }
    }

    // MARK: - Scroll + Highlight

    /// Scrolls to and briefly highlights the original message referenced by a reply.
    private func scrollToAndHighlight(messageId: String) {
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
                
                ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                    if shouldShowDateSeparator(at: index) {
                        dateSeparatorView(for: message.createdAt)
                    }
                    
                    let showHeader = shouldShowSenderHeader(at: index)
                    let showTimestamp = isLastInGroup(at: index)
                    let position = groupPosition(at: index)
                    let isHighlighted = highlightedMessageId == message.id
                    let offset = swipeOffset(for: message.id)
                    let swipeProgress = min(offset / swipeReplyThreshold, 1.0)
                    let isCurrentUser = message.userId == viewModel.currentUserId && !viewModel.isModelMessage(message)

                    // ZStack: message row fills full width; swipe icon is an overlay
                    // pinned to the leading (received) or trailing (sent) edge.
                    // This prevents the icon slot from stealing horizontal space from
                    // the message content, fixing the uneven width issue.
                    ZStack(alignment: isCurrentUser ? .trailing : .leading) {
                        channelMessageRow(message, showSenderHeader: showHeader, showGroupTimestamp: showTimestamp, position: position)
                            .offset(x: offset)
                            .background(
                                isHighlighted
                                    ? theme.brandPrimary.opacity(0.12)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        // Reply icon — fades/scales in as swipe progresses
                        SwipeReplyIcon(progress: swipeProgress)
                            .opacity(swipeProgress > 0.05 ? 1 : 0)
                            .scaleEffect(0.7 + swipeProgress * 0.3)
                            .padding(isCurrentUser ? .trailing : .leading, Spacing.screenPadding)
                            .animation(.easeOut(duration: 0.1), value: swipeProgress)
                            .allowsHitTesting(false)
                    }
                    // Swipe gesture lives on the ZStack OUTSIDE CustomContextMenuWrapper
                    // so it doesn't compete with the long-press context menu gesture.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 10, coordinateSpace: .local)
                            .onChanged { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                // Only activate for clearly-horizontal right-swipes
                                guard dx > 0, abs(dx) > abs(dy) * 1.2 else {
                                    // Wrong direction — reset any partial offset
                                    if swipeOffsets[message.id] != nil {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            swipeOffsets[message.id] = 0
                                        }
                                    }
                                    return
                                }
                                onSwipeChanged(value, messageId: message.id)
                            }
                            .onEnded { value in
                                onSwipeEnded(value, message: message)
                            }
                    )
                    .id(message.id)
                    .task {
                        if message.id == viewModel.messages.first?.id {
                            await viewModel.loadOlderMessages()
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(minHeight: max(containerHeight, 0), alignment: .top)
            // Prevent keyboard-animation frames from propagating into this subtree.
            // Each CustomContextMenuWrapper tracks its frame via
            // onGeometryChange(frame(in: .global)), which fires on every animation
            // tick. Stripping the animation here reduces N-messages × ~15-frame
            // state updates per keyboard event down to one — eliminating input lag.
            // The .padding(.bottom, keyboard.height) on the input bar lives outside
            // this subtree and continues to animate correctly.
            .transaction { $0.animation = nil }
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition, anchor: .bottom)
        .onScrollGeometryChange(for: CGPoint.self) { geo in
            geo.contentOffset
        } action: { _, newOffset in
            let distFromBottom = max(0, contentHeight - newOffset.y - containerHeight)
            if distFromBottom <= 120 {
                if isScrolledUp { isScrolledUp = false }
            } else if newOffset.y < lastScrollOffset - 40 {
                if !isScrolledUp { isScrolledUp = true }
            }
            if abs(newOffset.y - lastScrollOffset) > 2 { lastScrollOffset = newOffset.y }
        }
        .onScrollGeometryChange(for: CGSize.self) { geo in
            CGSize(width: geo.contentSize.height, height: geo.containerSize.height)
        } action: { _, newSize in
            if abs(newSize.width - contentHeight) > 1 { contentHeight = newSize.width }
            if abs(newSize.height - containerHeight) > 1 { containerHeight = newSize.height }
        }
        .scrollContentBackground(.hidden)
        .background(ScrollViewEdgeEffectDisabler())
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
    
    // MARK: - Bubble Colors

    private var receivedBubbleBackground: Color {
        theme.isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.06)
    }

    private var receivedBubbleBorder: Color {
        theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    private var sentBubbleBackground: Color { theme.brandPrimary }
    private var sentBubbleBorder: Color { theme.brandPrimary }

    // MARK: - Message Row

    private let avatarSize: CGFloat = 28
    
    // MARK: - Date Separator
    
    private func dateSeparatorView(for date: Date) -> some View {
        HStack(spacing: 8) {
            VStack { Divider().background(theme.textTertiary.opacity(0.2)) }
            Text(date.channelDateSeparator)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
            VStack { Divider().background(theme.textTertiary.opacity(0.2)) }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 10)
    }
    
    @ViewBuilder
    private func channelMessageRow(_ message: ChannelMessage, showSenderHeader: Bool, showGroupTimestamp: Bool, position: GroupPosition = .single) -> some View {
        let isCurrentUser = message.userId == viewModel.currentUserId && !viewModel.isModelMessage(message)
        let isModel = viewModel.isModelMessage(message)
        let resolvedName = viewModel.resolvedSenderName(for: message)
        let showTail = (position == .last || position == .single)
        let bubbleBg = isCurrentUser ? sentBubbleBackground : receivedBubbleBackground
        let bubbleBd = isCurrentUser ? sentBubbleBorder : receivedBubbleBorder
        let bubbleAlignment: HorizontalAlignment = isCurrentUser ? .trailing : .leading
        let frameAlignment: Alignment = isCurrentUser ? .trailing : .leading
        
        CustomContextMenuWrapper(
            hapticTouchDuration: .default,
            contextMenuAppearingSide: .leading,
            selectedReaction: Binding(
                get: { selectedReaction },
                set: { newVal in
                    if let emoji = newVal {
                        reactionTargetMessageId = message.id
                        selectedReaction = emoji
                    }
                }
            )
        ) {
        VStack(alignment: bubbleAlignment, spacing: 0) {
            // Sender header — only shown for received messages (not current user)
            if showSenderHeader && !isCurrentUser {
                HStack(spacing: 8) {
                    senderAvatar(message, size: avatarSize)
                    
                    HStack(spacing: 5) {
                        Text(resolvedName)
                            .scaledFont(size: 13, weight: .bold)
                            .foregroundStyle(isModel ? theme.mentionModelText : theme.textPrimary)
                        
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
                    }
                }
                .padding(.bottom, 3)
            }
            
            if message.isPinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .scaledFont(size: 9)
                        .rotationEffect(.degrees(45))
                    Text("Pinned")
                        .scaledFont(size: 10, weight: .semibold)
                }
                .foregroundStyle(.yellow.opacity(0.8))
                .padding(.bottom, 2)
            }
            
            if let replyId = message.replyToId {
                replyIndicator(for: replyId, message: message)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.72, alignment: frameAlignment)
                    .padding(.bottom, 2)
            }
            
            if viewModel.editingMessage?.id == message.id {
                editBubble(isCurrentUser: isCurrentUser)
            } else if isModel && message.content.isEmpty && message.files.isEmpty {
                // Model is streaming — show animated typing dots while content arrives
                // This covers the gap between when the empty placeholder message is
                // created by the backend and when the first token arrives via socket.
                HStack(spacing: 8) {
                    TypingDotsView()
                    Text("Generating…")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(receivedBubbleBackground)
                .clipShape(ChannelBubbleShape(isCurrentUser: false, showTail: showTail))
                .overlay(
                    ChannelBubbleShape(isCurrentUser: false, showTail: showTail)
                        .strokeBorder(receivedBubbleBorder, lineWidth: 0.5)
                )
            } else if !message.content.isEmpty || !message.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !message.content.isEmpty {
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
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(bubbleBg)
                .clipShape(ChannelBubbleShape(isCurrentUser: isCurrentUser, showTail: showTail))
                .overlay(
                    ChannelBubbleShape(isCurrentUser: isCurrentUser, showTail: showTail)
                        .strokeBorder(bubbleBd, lineWidth: 0.5)
                )
                .frame(minWidth: 60, maxWidth: UIScreen.main.bounds.width * 0.75, alignment: frameAlignment)
            }
            
            // Reactions (MF-003: with tooltip on long-press)
            // AnimatedPresence smoothly expands height when reactions arrive via socket
            AnimatedPresence(visible: !message.reactions.isEmpty) {
                if !message.reactions.isEmpty {
                    reactionsBar(message)
                        .padding(.top, 3)
                }
            }

            // Thread reply badge — smoothly appears when a thread reply is created
            AnimatedPresence(visible: message.hasThread) {
                if message.hasThread {
                    ThreadReplyBadge(
                        replyCount: message.replyCount,
                        latestReplyAt: message.latestReplyAt
                    ) {
                        Task { await viewModel.openThread(for: message) }
                        Haptics.play(.light)
                    }
                    .padding(.top, 3)
                }
            }
            
            if showGroupTimestamp && !showSenderHeader {
                Text(message.createdAt.channelTime)
                    .scaledFont(size: 10)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, 2)
            }
            
            if message.isFailed {
                Button {
                    Task { await viewModel.retrySendMessage(id: message.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .scaledFont(size: 11)
                        Text("Failed to send. Tap to retry.")
                            .scaledFont(size: 12, weight: .medium)
                    }
                    .foregroundStyle(theme.error)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, showSenderHeader ? 12 : 2)
        } menu: {
            CustomMenuView {
                CustomMenuButton("Reply", systemImage: "arrowshape.turn.up.left") {
                    viewModel.setReplyTo(message)
                }
                
                CustomMenuButton("Reply in Thread", systemImage: "bubble.left.and.bubble.right") {
                    Task { await viewModel.openThread(for: message) }
                    Haptics.play(.light)
                }
                
                CustomMenuButton(action: { Task { await viewModel.togglePin(messageId: message.id) } }) {
                    Label(message.isPinned ? "Unpin" : "Pin", systemImage: message.isPinned ? "pin.slash" : "pin")
                }
                
                CustomMenuButton("Copy", systemImage: "doc.on.doc") {
                    viewModel.copyMessage(message)
                }
                
                if isCurrentUser {
                    CustomMenuDivider()
                    
                    CustomMenuButton("Edit", systemImage: "pencil") {
                        viewModel.beginEditing(message: message)
                    }
                    
                    CustomMenuButton("Delete", systemImage: "trash", role: .destructive) {
                        Task { await viewModel.deleteMessage(id: message.id) }
                    }
                }
            }
        }
        .opacity(message.isOptimistic ? 0.6 : 1.0)
        // Dismiss the keyboard before the context menu appears so it has the full
        // screen height available and doesn't appear off-screen.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        )
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
            let avatarURL = avatarURLForUser(id: message.userId)
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
            let avatarURL = avatarURLForUser(id: replyMsg.userId)
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
            let avatarURL = avatarURLForUser(id: slim.userId)
            ChannelReplyPreview(
                senderName: slim.user?.displayName ?? "Unknown",
                content: slim.content,
                isModel: false,
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
                .background(theme.surfaceContainer.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            
            HStack(spacing: 8) {
                Button { viewModel.cancelEditing() } label: {
                    Text("Cancel")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                Button { Task { await viewModel.submitEdit() } } label: {
                    Text("Save")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                }
                .disabled(viewModel.editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.surfaceContainer.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
    
    // MARK: - Reactions Bar (MF-003: with tooltip on long-press)
    
    private func reactionsBar(_ message: ChannelMessage) -> some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { reaction in
                Button {
                    Task { await viewModel.toggleReaction(messageId: message.id, emoji: reaction.name) }
                    Haptics.play(.light)
                } label: {
                    let isOwn = reaction.userIds.contains(viewModel.currentUserId ?? "")
                    HStack(spacing: 2) {
                        Text(reaction.name.emojiFromShortcode)
                            .font(.system(size: 13))
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .scaledFont(size: 11, weight: .medium)
                                .foregroundStyle(isOwn ? theme.brandPrimary : theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        isOwn ? theme.brandPrimary.opacity(0.12) : theme.surfaceContainer.opacity(0.6)
                    )
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            isOwn ? theme.brandPrimary.opacity(0.3) : Color.clear,
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(.plain)
                // MF-003: Show reactor names on long-press
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            let summary = reaction.reactorSummary
                            if !summary.isEmpty {
                                reactionTooltipText = summary
                                withAnimation(.easeOut(duration: 0.15)) { showReactionTooltip = true }
                                // Auto-hide after 2 seconds
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    await MainActor.run {
                                        withAnimation(.easeOut(duration: 0.15)) { showReactionTooltip = false }
                                    }
                                }
                            }
                        }
                )
            }
            
            Button {
                emojiTargetMessageId = message.id
                showEmojiKeyboard = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "face.smiling")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(theme.surfaceContainer.opacity(0.4))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Read-Only Banner (MF-005)
    
    private var readOnlyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textTertiary)
            Text("This channel is read-only")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 8)
    }
    
    // MARK: - iMessage-Style Reply Focus Overlay
    //
    // Shown when the user swipes to reply. Blurs the background, floats the
    // target message in the center, and presents a focused reply composer at
    // the bottom — mimicking the iMessage / Signal reply UX.

    @ViewBuilder
    private func replyFocusOverlay(for message: ChannelMessage) -> some View {
        // The overlay is structured as a ZStack so the blur fills the entire screen
        // while the content VStack rides *above* the keyboard via normal safe area insets.
        // Key rules:
        //   • Background layer: ignores ALL safe areas (covers status bar + home indicator)
        //   • Content VStack: does NOT ignore the keyboard safe area so it animates up
        //     with the keyboard automatically — no manual height tracking needed.
        ZStack(alignment: .bottom) {
            // ── Full-screen blurred background — sits behind everything ──
            Color.black.opacity(0.35)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()           // covers notch, home indicator, keyboard area
                .contentShape(Rectangle())
                .onTapGesture { dismissReplyOverlay() }

            // ── Foreground content: floats above keyboard ──
            // .overlay{} lives outside SwiftUI's layout tree so automatic keyboard
            // avoidance does NOT apply. We manually offset by keyboard.height +
            // the window's bottom safe area inset so the composer fully clears the
            // keyboard on devices with a home indicator.
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // ── Reply composer — sits directly above the keyboard ──
                VStack(spacing: 0) {
                    // Thin accent bar + context preview
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(theme.replyBorder)
                            .frame(width: 3, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .scaledFont(size: 9, weight: .semibold)
                                    .foregroundStyle(theme.replyBorder)
                                Text(viewModel.resolvedSenderName(for: message))
                                    .scaledFont(size: 12, weight: .bold)
                                    .foregroundStyle(theme.replyBorder)
                                    .lineLimit(1)
                            }
                            let preview = ChannelMessage.parseMentions(in: message.content)
                            if !preview.isEmpty {
                                Text(preview)
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer()
                        // Dismiss / cancel button
                        Button {
                            dismissReplyOverlay()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .scaledFont(size: 22)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(theme.textTertiary, theme.cardBackground.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                    }
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    OverlayReplyInputField(
                        text: $replyOverlayInputText,
                        placeholder: "Reply to \(viewModel.resolvedSenderName(for: message))…",
                        onSend: {
                            let trimmed = replyOverlayInputText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            viewModel.setReplyTo(message)
                            viewModel.inputText = trimmed
                            Task { await viewModel.sendMessage() }
                            dismissReplyOverlay()
                            Haptics.play(.medium)
                        },
                        onDismiss: { dismissReplyOverlay() }
                    )
                    .padding(.bottom, 6)
                }
                .background(theme.background)
            }
            // Push the composer above the keyboard.
            //
            // KeyboardTracker.height = rawKeyboardHeight - safeAreaBottom
            // (it subtracts the safe area so safeAreaInset{bottom} users don't
            //  double-count it).
            //
            // Our overlay uses .ignoresSafeArea() so it extends to the PHYSICAL
            // screen bottom — we must add safeAreaBottom back to get the correct
            // physical offset: rawKeyboardHeight = keyboard.height + safeAreaBottom.
            //
            // When keyboard is hidden (height == 0), we still pad by safeAreaBottom
            // so the composer clears the home indicator.
            .padding(.bottom, keyboard.height + (UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?.safeAreaInsets.bottom ?? 0))
            .animation(keyboard.matchedAnimation, value: keyboard.height)
        }
    }

    // MARK: - Reply Preview Bar
    //
    // Shown above the input field when replying via the context menu (not swipe).
    // Features: sender avatar, name, content preview, smooth slide-in, dismiss button.

    private func replyPreviewBar(_ message: ChannelMessage) -> some View {
        HStack(spacing: 0) {
            // Left accent bar
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.replyBorder)
                .frame(width: 3)
                .padding(.vertical, 8)

            HStack(spacing: 8) {
                // Sender avatar
                let avatarURL = avatarURLForUser(id: message.userId)
                UserAvatar(
                    size: 22,
                    imageURL: avatarURL,
                    name: viewModel.resolvedSenderName(for: message),
                    authToken: viewModel.serverAuthToken
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .scaledFont(size: 9, weight: .semibold)
                            .foregroundStyle(theme.replyBorder)
                        Text("Replying to \(viewModel.resolvedSenderName(for: message))")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(theme.replyBorder)
                            .lineLimit(1)
                    }

                    let preview = ChannelMessage.parseMentions(in: message.content)
                    if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(preview.prefix(80))
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if !message.files.isEmpty {
                        Label("Attachment", systemImage: "paperclip")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                    }
                }

                Spacer()

                Button {
                    viewModel.clearReply()
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(theme.replyBackground)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        ))
    }
    
    // MARK: - Model Mention Bar
    
    private var modelMentionBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(theme.mentionModelText)
            Text(viewModel.mentionedModelName ?? "")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text("will respond to this message")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
            
            Spacer()
            
            Button {
                viewModel.clearModelMention()
                Haptics.play(.light)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 6)
        .background(theme.mentionModelBackground)
    }
    
    // MARK: - Typing Indicator Bar

    /// Shows "Alice is typing…" or "Alice and Bob are typing…" below the input.
    /// Matches the web client's behaviour (Channel.svelte → typingUsers state).
    private var typingIndicatorBar: some View {
        HStack(spacing: 6) {
            // Animated three-dot pulse
            TypingDotsView()
            
            Text(typingLabel)
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
            
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 6)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }
    
    private var typingLabel: String {
        let names = viewModel.typingUsers.prefix(3).map(\.name)
        switch names.count {
        case 1: return "\(names[0]) is typing…"
        case 2: return "\(names[0]) and \(names[1]) are typing…"
        default: return "\(names[0]), \(names[1]) and others are typing…"
        }
    }
    
    // MARK: - Input Field

    private var channelInputField: some View {
        @Bindable var vm = viewModel

        return ChannelInputField(
            text: $vm.inputText,
            attachments: $vm.attachments,
            placeholder: viewModel.inputPlaceholder,
            isEnabled: true,
            onSend: { await viewModel.sendMessage() },
            canSend: viewModel.canSend,
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
            onHashDismiss: { dismissChannelPicker() }
        )
    }
    
    // MARK: - Empty Channel
    
    private var emptyChannelView: some View {
        VStack(spacing: Spacing.md) {
            if viewModel.isDM {
                Image(systemName: "person.crop.circle")
                    .scaledFont(size: 40)
                    .foregroundStyle(Color.green.opacity(0.5))
                Text("Say hello to \(viewModel.channelDisplayTitle)")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                Text("Send a message or @mention a model")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .scaledFont(size: 40)
                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                Text("No messages yet")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                Text("Start the conversation with @model or @user")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }
    
    // MARK: - Loading (INC-007: Animated shimmer)
    
    private var loadingPlaceholders: some View {
        VStack(spacing: 16) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(theme.surfaceContainer.opacity(0.4))
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.surfaceContainer.opacity(0.4))
                            .frame(width: CGFloat.random(in: 80...140), height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.surfaceContainer.opacity(0.3))
                            .frame(width: CGFloat.random(in: 150...280), height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.surfaceContainer.opacity(0.2))
                            .frame(width: CGFloat.random(in: 100...200), height: 14)
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.screenPadding)
            }
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }
    
    // MARK: - Scroll FAB
    
    @ViewBuilder
    private var scrollToBottomFAB: some View {
        if isScrolledUp && !viewModel.messages.isEmpty {
            ZStack {
                Circle().fill(.ultraThinMaterial).frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(theme.textSecondary)
            }
            .contentShape(Circle())
            .highPriorityGesture(TapGesture().onEnded {
                withAnimation { scrollPosition.scrollTo(edge: .bottom) }
                Haptics.play(.light)
            })
            .padding(.trailing, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }
    
    // MARK: - Copied Toast
    
    private var copiedToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc.fill").scaledFont(size: 12)
            Text("Copied").scaledFont(size: 12, weight: .medium)
        }
        .foregroundStyle(theme.textInverse)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.textPrimary.opacity(0.85))
        .clipShape(Capsule())
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
            if let data = try? await item.loadTransferable(type: Data.self) {
                let image = UIImage(data: data)
                let thumbnail = image.map { Image(uiImage: $0) }
                let resized = FileAttachmentService.downsampleForUpload(data: data, image: image)
                let attachment = ChatAttachment(
                    type: .image,
                    name: "Photo_\(Int(Date.now.timeIntervalSince1970)).jpg",
                    thumbnail: thumbnail,
                    data: resized
                )
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

// MARK: - Channel Reaction Provider

struct ChannelReactionProvider: ReactionProvider {
    func reactions() -> [String] {
        ["👍", "❤️", "😂", "😮", "😢", "🔥", "🎉", "➕"]
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

