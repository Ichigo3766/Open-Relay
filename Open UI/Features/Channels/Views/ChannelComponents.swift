import SwiftUI
import PhotosUI
import QuickLook

// MARK: - Overlay Reply Input Field
//
// A focused, minimal text field used inside the iMessage-style reply overlay.
// Auto-focuses when shown, sends on Return (if text is non-empty), and
// respects the keyboard safe area so it sits just above the keyboard.

struct OverlayReplyInputField: View {
    @Binding var text: String
    var placeholder: String = "Reply…"
    var onSend: () -> Void
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .scaledFont(size: 15)
                .lineLimit(1...6)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSend()
                }
                .foregroundStyle(theme.textPrimary)

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    onSend()
                } label: {
                    Circle()
                        .fill(theme.brandPrimary)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "arrow.up")
                                .scaledFont(size: 14, weight: .bold)
                                .foregroundStyle(theme.brandOnPrimary)
                        )
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(ComposerGlassModifier(
            cornerRadius: 24,
            borderColor: Color(uiColor: .separator),
            shadowColor: Color.black.opacity(theme.isDark ? 0.2 : 0.08),
            isDark: theme.isDark
        ))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
        .onAppear {
            // Auto-focus with a tiny delay so the overlay animation completes first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isFocused = true
            }
        }
    }
}

// MARK: - Typing Dots View
//
// Animated three-dot indicator shown when someone is typing in a channel.
// Matches the Slack/Discord "X is typing…" pattern.

struct TypingDotsView: View {
    @State private var phase: Int = 0
    @Environment(\.theme) private var theme
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(theme.textTertiary)
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase == index ? 1.3 : 0.8)
                    .opacity(phase == index ? 1.0 : 0.4)
            }
        }
        .onAppear { startAnimation() }
    }
    
    private func startAnimation() {
        // Cycle through dots with a 300ms interval
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            withAnimation(.easeInOut(duration: 0.25)) {
                phase = (phase + 1) % 3
            }
        }
    }
}

// MARK: - User & Model Picker (Combined @mention)

/// Combined picker that shows channel members (users) first, then AI models.
/// Used when typing `@` in a channel — users get text mentions, models get AI responses.
struct UserModelPickerView: View {
    let query: String
    let members: [ChannelMember]
    let models: [AIModel]
    let serverBaseURL: String
    let authToken: String?
    let onSelectUser: (ChannelMember) -> Void
    let onSelectModel: (AIModel) -> Void
    let onDismiss: () -> Void
    
    @Environment(\.theme) private var theme
    
    /// Caller passes candidates already filtered + ordered (members first, then
    /// other server users). Capped only for rendering cost; the list scrolls.
    private var filteredMembers: [ChannelMember] {
        Array(members.prefix(200))
    }
    
    private var filteredModels: [AIModel] {
        if query.isEmpty { return Array(models.prefix(8)) }
        let q = query.lowercased()
        return models.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }.prefix(8).map { $0 }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(theme.textTertiary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Users section
                    if !filteredMembers.isEmpty {
                        sectionHeader("Users", icon: "person.fill")
                        ForEach(filteredMembers) { member in
                            Button { onSelectUser(member) } label: {
                                userRow(member)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // Models section
                    if !filteredModels.isEmpty {
                        sectionHeader("Models", icon: "cpu")
                        ForEach(filteredModels) { model in
                            Button { onSelectModel(model) } label: {
                                modelRow(model)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    if filteredMembers.isEmpty && filteredModels.isEmpty {
                        HStack {
                            Spacer()
                            Text("No matches for \"@\(query)\"")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.vertical, Spacing.lg)
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.bottom, Spacing.md)
            }
            .frame(maxHeight: 320)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .chatControlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: .ultraThinMaterial)
        .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
        .padding(.horizontal, Spacing.sm)
        .padding(.bottom, 80)
    }
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .scaledFont(size: 10, weight: .semibold)
            Text(title)
                .scaledFont(size: 11, weight: .bold)
        }
        .foregroundStyle(theme.textTertiary)
        .textCase(.uppercase)
        .padding(.top, Spacing.md)
        .padding(.bottom, 4)
    }
    
    private func userRow(_ member: ChannelMember) -> some View {
        HStack(spacing: Spacing.sm) {
            // Avatar
            UserAvatar(
                size: 30,
                imageURL: member.resolveAvatarURL(serverBaseURL: serverBaseURL),
                name: member.displayName
            )
            
            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if !member.email.isEmpty {
                    Text(member.email)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Online indicator
            if member.isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    
    private func memberInitials(_ name: String) -> some View {
        Circle()
            .fill(theme.brandPrimary.opacity(0.12))
            .frame(width: 30, height: 30)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(theme.brandPrimary)
            )
    }
    
    private func modelRow(_ model: AIModel) -> some View {
        HStack(spacing: Spacing.sm) {
            ModelAvatar(
                size: 30,
                imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                label: model.shortName,
                authToken: authToken
            )
            
            VStack(alignment: .leading, spacing: 1) {
                Text(model.shortName)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let desc = model.description, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            Image(systemName: "cpu")
                .scaledFont(size: 11)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Channel Link Picker (#channel mentions)

/// Popup picker shown when user types `#` in a channel input.
/// Displays a filterable list of accessible channels for creating `<#id|name>` links.
struct ChannelLinkPickerView: View {
    let query: String
    let channels: [Channel]
    let onSelect: (Channel) -> Void
    let onDismiss: () -> Void
    
    @Environment(\.theme) private var theme
    
    private var filtered: [Channel] {
        if query.isEmpty { return Array(channels.prefix(10)) }
        let q = query.lowercased()
        return channels.filter {
            $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q)
        }.prefix(10).map { $0 }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(theme.textTertiary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Channels", icon: "number")
                    
                    if filtered.isEmpty {
                        HStack {
                            Spacer()
                            Text("No channels match \"#\(query)\"")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.vertical, Spacing.lg)
                            Spacer()
                        }
                    } else {
                        ForEach(filtered) { channel in
                            Button { onSelect(channel) } label: {
                                channelRow(channel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.bottom, Spacing.md)
            }
            .frame(maxHeight: 280)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .chatControlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: .ultraThinMaterial)
        .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
        .padding(.horizontal, Spacing.sm)
        .padding(.bottom, 80)
    }
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .scaledFont(size: 10, weight: .semibold)
            Text(title)
                .scaledFont(size: 11, weight: .bold)
        }
        .foregroundStyle(theme.textTertiary)
        .textCase(.uppercase)
        .padding(.top, Spacing.md)
        .padding(.bottom, 4)
    }
    
    private func channelRow(_ channel: Channel) -> some View {
        HStack(spacing: Spacing.sm) {
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Thread Detail Sheet

/// Shows a thread's parent message and replies with full channel-equivalent features:
/// markdown rendering, @mention picker, file attachments, same input field.
struct ThreadDetailSheet: View {
    @Bindable var viewModel: ChannelViewModel
    let parentMessage: ChannelMessage
    /// When true the thread is rendered as an iPad side panel (no sheet chrome);
    /// closing calls `onClose` instead of dismissing a sheet.
    var isPanel: Bool = false
    var onClose: (() -> Void)? = nil
    var onShowProfile: ((String) -> Void)? = nil
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    
    // Smart local snapshot — syncs when messages arrive, ignores dismiss clearance
    @State private var displayMessages: [ChannelMessage] = []
    
    // Edit focus
    @FocusState private var isThreadEditFocused: Bool
    
    // @mention picker state (same as main channel)
    @State private var isShowingMentionPicker = false
    @State private var mentionQuery = ""

    // Swipe-to-reply offsets inside the thread
    @State private var threadSwipeOffsets: [String: CGFloat] = [:]

    // `/` prompt picker
    @State private var isShowingPromptPicker = false
    @State private var promptQuery = ""
    @State private var keyboard = KeyboardTracker()

    // Thread attachment picker
    @State private var showThreadAttachmentPicker = false
    
    // Inline emoji keyboard (for quick-reaction from context menu)
    @State private var threadShowEmojiKeyboard = false
    @State private var threadEmojiTargetMessageId: String?
    
    // Glass long-press menu
    @State private var threadMenu = MessageMenuPresenter()
    @State private var threadRowFrames: [String: CGRect] = [:]
    
    // QuickLook for file preview
    @State private var quickLookURL: URL?
    @State private var isLoadingFile = false
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""
    
    var body: some View {
        threadContent
    }

    private func closeThread() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// Glass header (title, channel, close) — matches the channel's glass nav bar.
    private var threadHeader: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thread")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text(threadSubtitle)
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .chatControlGlass(in: Capsule(), fallback: .ultraThinMaterial)

            Spacer()

            Button {
                closeThread()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .chatControlGlass(in: Circle(), fallback: .ultraThinMaterial)
            .accessibilityLabel("Close thread")
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.top, isPanel ? 8 : 12)
        .padding(.bottom, 6)
    }

    private var threadSubtitle: String {
        let count = max(parentMessage.replyCount, displayMessages.count)
        let replies = count == 1 ? "1 reply" : "\(count) replies"
        return "\(viewModel.channelDisplayTitle) · \(replies)"
    }

    private var threadContent: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            threadScroll
        }
        .modifier(ChannelDeleteConfirmation(viewModel: viewModel))
        .chatChromeBar(edge: .top) { threadHeader }
        .chatChromeBar(edge: .bottom) { threadBottomChrome }
        .modifier(MessageMenuHost(presenter: threadMenu))
        .task { keyboard.start() }
        .onDisappear { keyboard.stop() }
        .overlay(alignment: .bottom) { threadPromptPicker }
        .overlay(alignment: .bottom) { threadMentionPicker }
        .onAppear { displayMessages = viewModel.threadMessages }
        .onChange(of: viewModel.threadMessages) { oldValue, newValue in
            // Sync when messages arrive; ignore the clear-to-[] during dismiss.
            if !newValue.isEmpty || oldValue.isEmpty { displayMessages = newValue }
        }
        .onChange(of: viewModel.editingMessage) { _, newValue in
            if newValue != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isThreadEditFocused = true }
            } else {
                isThreadEditFocused = false
            }
        }
        .quickLookPreview($quickLookURL)
        .overlay { threadFileLoadingOverlay }
        .alert("Download Failed", isPresented: $showDownloadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadErrorMessage)
        }
        .background {
            InlineEmojiKeyboard(isActive: $threadShowEmojiKeyboard) { emoji in
                if let messageId = threadEmojiTargetMessageId {
                    RecentReactions.record(emoji)
                    Task { await viewModel.toggleReaction(messageId: messageId, emoji: emoji) }
                    Haptics.play(.light)
                }
                threadShowEmojiKeyboard = false
                threadEmojiTargetMessageId = nil
            }
            .allowsHitTesting(false)
        }
    }

    private var threadBottomChrome: some View {
        VStack(spacing: 0) {
            if !viewModel.threadTypingUsers.isEmpty {
                ChannelTypingCapsule(names: viewModel.threadTypingUsers.map(\.name))
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if viewModel.hasWriteAccess {
                threadInput
            } else {
                ChannelReadOnlyBanner(text: "You do not have permission to send messages in this thread.")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: viewModel.threadTypingUsers.map(\.id))
    }

    @ViewBuilder
    private var threadPromptPicker: some View {
        if isShowingPromptPicker {
            PromptPickerView(
                query: promptQuery,
                prompts: viewModel.availablePrompts,
                isLoading: viewModel.isLoadingPrompts,
                keyboardHeight: keyboard.height,
                onSelect: { prompt in
                    viewModel.selectPrompt(prompt, isThread: true)
                    dismissPromptPicker()
                },
                onDismiss: { dismissPromptPicker() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var threadMentionPicker: some View {
        if isShowingMentionPicker {
            UserModelPickerView(
                query: mentionQuery,
                members: viewModel.mentionCandidates(for: mentionQuery),
                models: viewModel.availableModels,
                serverBaseURL: viewModel.serverBaseURL,
                authToken: viewModel.serverAuthToken,
                onSelectUser: { member in
                    viewModel.insertThreadUserMention(member)
                    dismissMentionPicker()
                    Haptics.play(.light)
                },
                onSelectModel: { model in
                    viewModel.setThreadModelMention(model)
                    dismissMentionPicker()
                    Haptics.play(.light)
                },
                onDismiss: { dismissMentionPicker() }
            )
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
        }
    }

    @ViewBuilder
    private var threadFileLoadingOverlay: some View {
        if isLoadingFile {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Loading file…")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(.white)
                }
                .padding(Spacing.lg)
                .chatControlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), fallback: .ultraThinMaterial)
            }
            .transition(.opacity)
        }
    }

    private func dismissPromptPicker() {
        withAnimation(.easeOut(duration: 0.15)) {
            isShowingPromptPicker = false
            promptQuery = ""
        }
    }

    private var threadScroll: some View {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            // Parent message
                            threadMessageRow(parentMessage, isParent: true, showHeader: true)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { threadRowFrames[parentMessage.id] = $0 }
                                .opacity(threadMenu.content?.messageId == parentMessage.id && threadMenu.isVisible ? 0 : 1)
                                .padding(.bottom, 4)
                            
                            // Divider
                            HStack(spacing: 8) {
                                VStack { Divider() }
                                Text("\(parentMessage.replyCount) repl\(parentMessage.replyCount == 1 ? "y" : "ies")")
                                    .scaledFont(size: 11, weight: .semibold)
                                    .foregroundStyle(theme.textTertiary)
                                VStack { Divider() }
                            }
                            .padding(.horizontal, Spacing.screenPadding)
                            .padding(.vertical, 8)
                            
                            if viewModel.isLoadingThread {
                                ProgressView()
                                    .padding(.vertical, Spacing.xl)
                            } else if displayMessages.isEmpty {
                                VStack(spacing: 8) {
                                    Text("No replies yet")
                                        .scaledFont(size: 15, weight: .medium)
                                        .foregroundStyle(theme.textSecondary)
                                    Text("Be the first to reply")
                                        .scaledFont(size: 13)
                                        .foregroundStyle(theme.textTertiary)
                                }
                                .padding(.vertical, Spacing.xl)
                            } else {
                                if viewModel.isLoadingOlderThread {
                                    ProgressView().controlSize(.small).padding(.vertical, 8)
                                }
                                // BUG-009 fix: Safe index bounds checking for message grouping
                                ForEach(Array(displayMessages.enumerated()), id: \.element.id) { index, msg in
                                    let showHeader = index == 0 || msg.effectiveSenderId != displayMessages[index - 1].effectiveSenderId
                                    let showTimestamp: Bool = {
                                        guard index < displayMessages.count - 1 else { return true }
                                        return msg.effectiveSenderId != displayMessages[index + 1].effectiveSenderId
                                    }()
                                    threadReplyRow(msg, index: index, showHeader: showHeader, showTimestamp: showTimestamp)
                                }
                            }
                            
                            // Scroll anchor at the bottom
                            Color.clear
                                .frame(height: 1)
                                .id("threadBottom")
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                        // Tap empty space to close the keyboard (background keeps links/buttons first).
                        .background {
                            Color.clear.contentShape(Rectangle()).onTapGesture { dismissKeyboard() }
                        }
                        // Prevent keyboard-animation frames propagating into row geometry trackers.
                        .transaction { $0.animation = nil }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .background(ChannelScrollHorizontalLock())
                    .onAppear {
                        proxy.scrollTo("threadBottom", anchor: .bottom)
                    }
                    .onChange(of: displayMessages.last?.id) { old, new in
                        // Only follow appended replies, not older pages prepended at the top.
                        guard new != old, new != nil else { return }
                        withAnimation(MicroAnimation.snappy) {
                            proxy.scrollTo("threadBottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: keyboard.height > 0) { _, shown in
                        guard shown else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("threadBottom", anchor: .bottom) }
                        }
                    }
                }
            }
    }
    
    private func dismissMentionPicker() {
        withAnimation(.easeOut(duration: 0.15)) {
            isShowingMentionPicker = false
            mentionQuery = ""
        }
    }
    
    // MARK: - File Preview (QuickLook)
    
    /// Downloads a file from the server and presents it in an in-app QuickLook preview.
    /// Uses a local cache so files don't need to be re-downloaded.
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
        withAnimation(MicroAnimation.snappy) { isLoadingFile = true }
        
        do {
            let (data, _) = try await apiClient.getFileContent(id: fileId)
            try data.write(to: cachedFile)
            withAnimation(MicroAnimation.snappy) { isLoadingFile = false }
            quickLookURL = cachedFile
        } catch {
            withAnimation(MicroAnimation.snappy) { isLoadingFile = false }
            downloadErrorMessage = "Failed to load file: \(error.localizedDescription)"
            showDownloadError = true
        }
    }
    
    // MARK: - Thread Edit Bubble
    
    private var threadEditBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message…", text: $viewModel.editingText, axis: .vertical)
                .scaledFont(size: 13)
                .lineLimit(1...10)
                .focused($isThreadEditFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.surfaceContainer.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.surfaceContainer.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    
    // MARK: - Bubble Colors

    private var receivedBubbleBg: Color {
        theme.isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.06)
    }
    private var receivedBubbleBorder: Color {
        theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }
    private var sentBubbleBg: Color { theme.brandPrimary }
    private var sentBubbleBorderColor: Color { theme.brandPrimary }

    // MARK: - Message Row
    
    // MARK: - Thread Rows

    /// Reply row with swipe-to-reply and the glass long-press menu.
    @ViewBuilder
    private func threadReplyRow(_ msg: ChannelMessage, index: Int, showHeader: Bool, showTimestamp: Bool) -> some View {
        let offset = threadSwipeOffsets[msg.id] ?? 0
        let progress = min(abs(offset) / 64, 1)
        let isOwn = msg.userId == viewModel.currentUserId && !viewModel.isModelMessage(msg)
        ZStack(alignment: isOwn ? .trailing : .leading) {
            SwipeReplyIcon(progress: progress)
                .opacity(progress > 0.05 ? 1 : 0)
                .scaleEffect(0.6 + progress * 0.4)
                .padding(isOwn ? .trailing : .leading, Spacing.screenPadding)
                .allowsHitTesting(false)
            threadMessageRow(msg, isParent: false, showHeader: showHeader, showGroupTimestamp: showTimestamp)
                .offset(x: offset)
        }
        .onAppear {
            if index == 0 { Task { await viewModel.loadOlderThreadMessages() } }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { threadRowFrames[msg.id] = $0 }
        .opacity(threadMenu.content?.messageId == msg.id && threadMenu.isVisible ? 0 : 1)
    }

    private func threadMessageRow(_ message: ChannelMessage, isParent: Bool, showHeader: Bool, showGroupTimestamp: Bool = false) -> some View {
        let isCurrentUser = message.userId == viewModel.currentUserId && !viewModel.isModelMessage(message)
        let bubbleAlignment: HorizontalAlignment = isCurrentUser ? .trailing : .leading
        let frameAlignment: Alignment = isCurrentUser ? .trailing : .leading

        return VStack(alignment: bubbleAlignment, spacing: 0) {
            if showHeader && !isCurrentUser {
                threadSenderHeader(message, isParent: isParent)
                    .padding(.bottom, 4)
            }

            if !isParent, let replyId = message.replyToId {
                threadReplyQuote(replyId: replyId, message: message)
                    .frame(maxWidth: ChannelLayout.maxBubbleWidth, alignment: frameAlignment)
                    .padding(.bottom, 3)
            }

            if viewModel.editingMessage?.id == message.id {
                threadEditBubble
            } else {
                threadBubble(message, isCurrentUser: isCurrentUser, showTail: showHeader)
            }

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
                        threadEmojiTargetMessageId = message.id
                        threadShowEmojiKeyboard = true
                    }
                )
                .frame(maxWidth: ChannelLayout.maxBubbleWidth, alignment: frameAlignment)
                .padding(.top, 4)
            }

            if message.isPinned || (showGroupTimestamp && !showHeader) {
                ChannelMessageMeta(
                    time: showGroupTimestamp && !showHeader ? message.createdAt.channelTime : nil,
                    isPinned: message.isPinned,
                    isEdited: false
                )
                .padding(.top, 3)
            }
        }
        // Bubble-scoped gestures (not the full row) — see ChannelMessageGestures.
        .modifier(ChannelMessageGestures(
            swipeEnabled: !isParent && viewModel.hasWriteAccess && !message.isOptimistic,
            longPressEnabled: !message.isOptimistic && viewModel.editingMessage?.id != message.id,
            direction: isCurrentUser ? .left : .right,
            onSwipeChanged: { threadSwipeOffsets[message.id] = $0 },
            onSwipeEnded: { triggered in
                if triggered {
                    viewModel.setThreadReplyTo(message)
                    NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { threadSwipeOffsets[message.id] = nil }
            },
            onLongPress: {
                presentThreadMenu(for: message, isParent: isParent, isOwn: isCurrentUser,
                                  showHeader: showHeader, showTimestamp: showGroupTimestamp)
            }
        ))
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, showHeader ? 12 : 2)
        .padding(.vertical, isParent ? 8 : 0)
        .background {
            if isParent {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.brandPrimary.opacity(theme.isDark ? 0.08 : 0.05))
                    .padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
    }

    private func threadSenderHeader(_ message: ChannelMessage, isParent: Bool) -> some View {
        let isModel = viewModel.isModelMessage(message)
        return HStack(spacing: 8) {
            threadAvatar(message, size: 26)
                .onTapGesture {
                    guard !isModel, !message.isFromWebhook else { return }
                    onShowProfile?(message.userId)
                }
            Text(viewModel.resolvedSenderName(for: message))
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(isModel ? theme.mentionModelText : theme.textPrimary)
                .lineLimit(1)
            if isModel { ChannelBadge(text: "BOT", tint: theme.mentionModelText) }
            if message.isFromWebhook { ChannelBadge(text: "WEBHOOK", tint: theme.textSecondary) }
            if isParent { ChannelBadge(text: "OP", tint: theme.brandPrimary) }
            Text(message.createdAt.channelTime)
                .scaledFont(size: 11)
                .foregroundStyle(theme.textTertiary)
        }
    }

    @ViewBuilder
    private func threadBubble(_ message: ChannelMessage, isCurrentUser: Bool, showTail: Bool) -> some View {
        let isModel = viewModel.isModelMessage(message)
        if isModel && message.renderedContent.isEmpty && message.files.isEmpty && !message.isModelDone {
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
                    threadFileAttachments(message.files)
                }
                if message.isEdited {
                    Text("edited")
                        .scaledFont(size: 10)
                        .foregroundStyle(isCurrentUser ? theme.brandOnPrimary.opacity(0.7) : theme.textTertiary)
                }
            }
            .modifier(ChannelBubbleStyle(isCurrentUser: isCurrentUser, showTail: showTail))
        }
    }

    /// Glass long-press menu for a thread message (Reply in thread, Copy, Pin, Edit, Delete).
    private func presentThreadMenu(for message: ChannelMessage, isParent: Bool, isOwn: Bool,
                                   showHeader: Bool, showTimestamp: Bool) {
        guard let frame = threadRowFrames[message.id] else { return }
        let uid = viewModel.currentUserId ?? ""
        let own = Set(message.reactions.filter { $0.userIds.contains(uid) }.map { $0.name.emojiFromShortcode })
        let canWrite = viewModel.hasWriteAccess

        var quick: [MessageMenuAction] = []
        if !isParent && canWrite {
            quick.append(.init(id: "reply", title: "Reply", icon: "arrowshape.turn.up.left") {
                viewModel.setThreadReplyTo(message)
                NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
            })
        }
        quick.append(.init(id: "copy", title: "Copy", icon: "doc.on.doc") { viewModel.copyMessage(message) })
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
        if !viewModel.isModelMessage(message) && !message.isFromWebhook, let onShowProfile {
            info.append(.init(id: "profile", title: "View Profile", icon: "person.crop.circle") {
                onShowProfile(message.userId)
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

        let preview = threadMessageRow(message, isParent: isParent, showHeader: showHeader,
                                       showGroupTimestamp: showTimestamp)
            .environment(\.theme, theme)
            .frame(width: frame.width)
        threadMenu.present(MessageMenuContent(
            messageId: message.id,
            preview: AnyView(preview),
            sourceFrame: frame,
            alignTrailing: isOwn,
            header: "\(viewModel.resolvedSenderName(for: message)) · \(message.createdAt.channelTime)",
            ownReactions: own,
            showsReactions: canWrite,
            quickActions: quick,
            sections: sections,
            onReact: { emoji in
                Task { await viewModel.toggleReaction(messageId: message.id, emoji: emoji) }
            },
            onMoreReactions: {
                threadEmojiTargetMessageId = message.id
                threadShowEmojiKeyboard = true
            }
        ))
    }

    /// Reply-target chip (+ "model will respond" hint) inside the thread composer.
    private var threadComposerChips: [ChannelComposerChip] {
        guard let reply = viewModel.threadReplyToMessage else { return [] }
        let preview = ChannelMessage.parseMentions(in: reply.content).trimmingCharacters(in: .whitespacesAndNewlines)
        var chips = [ChannelComposerChip(
            id: "thread-reply-\(reply.id)",
            style: .reply,
            icon: "arrowshape.turn.up.left.fill",
            title: "Replying to \(viewModel.resolvedSenderName(for: reply))",
            subtitle: preview.isEmpty ? (reply.files.isEmpty ? nil : "Attachment") : String(preview.prefix(90)),
            onTap: nil,
            onRemove: { viewModel.clearThreadReply() }
        )]
        if let model = viewModel.threadReplyTargetModelName {
            chips.append(ChannelComposerChip(
                id: "thread-reply-model-\(model)", style: .model, icon: "sparkles",
                title: "\(model) will respond", subtitle: nil, onTap: nil, onRemove: nil
            ))
        }
        return chips
    }

    /// Compact quote of the message a thread reply points to.
    @ViewBuilder
    private func threadReplyQuote(replyId: String, message: ChannelMessage) -> some View {
        let original = displayMessages.first(where: { $0.id == replyId })
            ?? (parentMessage.id == replyId ? parentMessage : nil)
        if let original {
            let isModel = viewModel.isModelMessage(original)
            ChannelReplyPreview(
                senderName: viewModel.resolvedSenderName(for: original),
                content: original.content,
                isModel: isModel,
                avatarURL: isModel
                    ? viewModel.resolveModelForMessage(original)?.resolveAvatarURL(baseURL: viewModel.serverBaseURL)
                    : ChannelAvatarURL.forSender(userId: original.userId, isWebhook: original.isFromWebhook,
                                                 serverBaseURL: viewModel.serverBaseURL),
                authToken: viewModel.serverAuthToken,
                hasFiles: !original.files.isEmpty
            )
        } else if let slim = message.replyToMessage {
            ChannelReplyPreview(
                senderName: slim.modelName ?? slim.user?.displayName ?? "Unknown",
                content: slim.content,
                isModel: slim.modelId != nil,
                avatarURL: ChannelAvatarURL.forSender(userId: slim.userId, isWebhook: slim.user?.role == "webhook",
                                                      serverBaseURL: viewModel.serverBaseURL),
                authToken: viewModel.serverAuthToken,
                hasFiles: false
            )
        }
    }

    @ViewBuilder
    private func threadAvatar(_ message: ChannelMessage, size: CGFloat) -> some View {
        let isModel = viewModel.isModelMessage(message)
        let name = viewModel.resolvedSenderName(for: message)
        if isModel, let model = viewModel.resolveModelForMessage(message) {
            ModelAvatar(size: size, imageURL: model.resolveAvatarURL(baseURL: viewModel.serverBaseURL), label: model.shortName, authToken: viewModel.serverAuthToken)
        } else {
            // Build URL directly from userId — don't depend on member lookup
            let avatarURL = ChannelAvatarURL.forSender(
                userId: message.userId, isWebhook: message.isFromWebhook, serverBaseURL: viewModel.serverBaseURL
            )
            UserAvatar(
                size: size,
                imageURL: avatarURL,
                name: name,
                authToken: viewModel.serverAuthToken
            )
        }
    }
    
    @ViewBuilder
    private func threadFileAttachments(_ files: [ChatMessageFile]) -> some View {
        let imageFiles = files.filter { $0.type == "image" || ($0.contentType ?? "").hasPrefix("image/") }
        let otherFiles = files.filter { $0.type != "image" && !($0.contentType ?? "").hasPrefix("image/") }
        
        // Image thumbnails — use AuthenticatedImageView (same as channel + AI chat)
        if !imageFiles.isEmpty {
            ChannelImageGrid(imageFiles: imageFiles, apiClient: dependencies.apiClient)
        }
        
        // File cards — tappable with QuickLook preview (same as channel + AI chat)
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
            .frame(maxWidth: 240)
        }
    }
    
    // MARK: - Thread Input

    // Uses the shared ChannelInputField so sendOnEnter preference is respected
    // and attachment UI stays in sync with the main channel input.
    private var threadInput: some View {
        ChannelInputField(
            text: $viewModel.threadInputText,
            attachments: $viewModel.threadAttachments,
            placeholder: "Reply in thread…",
            isEnabled: true,
            onSend: { await viewModel.sendThreadMessage() },
            canSend: viewModel.canSendThread,
            chips: threadComposerChips,
            onAttachmentTapped: { showThreadAttachmentPicker = true },
            onPasteAttachments: { pasted in
                // BUG-011 fix: Paste into thread-specific attachments
                withAnimation(MicroAnimation.snappy) { viewModel.threadAttachments.append(contentsOf: pasted) }
                for att in pasted { viewModel.uploadAttachmentImmediately(attachmentId: att.id, isThread: true) }
            },
            onRemoveAttachment: { att in
                withAnimation(MicroAnimation.snappy) { viewModel.threadAttachments.removeAll { $0.id == att.id } }
            },
            onTextChange: { viewModel.emitThreadTyping() },
            onAtTrigger: { query in
                mentionQuery = query
                viewModel.searchMentions(query)
                if !isShowingMentionPicker {
                    withAnimation(.easeOut(duration: 0.2)) { isShowingMentionPicker = true }
                }
            },
            onAtDismiss: { dismissMentionPicker() },
            onSlashTrigger: { query in
                promptQuery = query
                if !isShowingPromptPicker {
                    viewModel.loadPrompts()
                    withAnimation(.easeOut(duration: 0.2)) { isShowingPromptPicker = true }
                }
            },
            onSlashDismiss: { dismissPromptPicker() }
        )
        .sheet(isPresented: $showThreadAttachmentPicker) {
            UnifiedAttachmentPicker(
                onPhotoSelected: { items in
                    Task { await processThreadPhotos(items) }
                },
                onFileSelected: { urls in
                    Task { for url in urls { await processThreadFileURL(url) } }
                },
                onDismiss: { showThreadAttachmentPicker = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
    }
    
    // MARK: - Thread Attachment Processing
    
    // BUG-011 fix: Thread attachment processing uses threadAttachments
    private func processThreadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let attachment = FileAttachmentService.makeImageAttachment(data: data) {
                viewModel.threadAttachments.append(attachment)
                viewModel.uploadAttachmentImmediately(attachmentId: attachment.id, isThread: true)
            }
        }
    }
    
    private func processThreadFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let attachment = ChatAttachment(type: .file, name: url.lastPathComponent, thumbnail: nil, data: data)
        viewModel.threadAttachments.append(attachment)
        viewModel.uploadAttachmentImmediately(attachmentId: attachment.id, isThread: true)
    }
}

// MARK: - DM Settings Sheet

/// Dedicated settings sheet for Direct Message channels.
/// Shows participants, allows adding people, and leaving the conversation.
/// No name field, no visibility toggle, no delete — per the docs.
struct DmSettingsSheet: View {
    let channel: Channel
    let members: [ChannelMember]
    let allUsers: [ChannelMember]
    let currentUserId: String?
    var serverBaseURL: String = ""
    let onAddMembers: ([String]) async -> Void
    let onLeave: () async -> Void
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var showAddPeoplePicker = false
    @State private var isAddingMembers = false
    @State private var isLeaving = false
    @State private var showLeaveConfirmation = false
    
    /// User IDs already in the DM.
    private var existingMemberIds: Set<String> {
        Set(members.map(\.id)).union(currentUserId.map { [$0] } ?? [])
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Participants
                Section("Participants (\(members.count + 1))") {
                    // Other participants
                    ForEach(members) { member in
                        HStack(spacing: Spacing.md) {
                            ZStack(alignment: .bottomTrailing) {
                                UserAvatar(
                                    size: 36,
                                    imageURL: member.resolveAvatarURL(serverBaseURL: serverBaseURL),
                                    name: member.displayName
                                )
                                Circle()
                                    .fill(member.isOnline ? Color.green : Color.gray.opacity(0.4))
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().stroke(theme.background, lineWidth: 1.5))
                                    .offset(x: 2, y: 2)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName)
                                    .scaledFont(size: 15, weight: .medium)
                                    .foregroundStyle(theme.textPrimary)
                                Text(member.isOnline ? "Active now" : "Offline")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(member.isOnline ? Color.green : theme.textTertiary)
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    
                    // "You" row
                    HStack(spacing: Spacing.md) {
                        ZStack(alignment: .bottomTrailing) {
                            UserAvatar(
                                size: 36,
                                imageURL: {
                                    guard let userId = currentUserId, !userId.isEmpty, !serverBaseURL.isEmpty else { return nil }
                                    return URL(string: "\(serverBaseURL)/api/v1/users/\(userId)/profile/image")
                                }(),
                                name: "You"
                            )
                            Circle()
                                .fill(Color.green)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(theme.background, lineWidth: 1.5))
                                .offset(x: 2, y: 2)
                        }
                        Text("You")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                
                // Add People
                Section {
                    Button {
                        showAddPeoplePicker = true
                    } label: {
                        Label {
                            Text("Add People")
                                .scaledFont(size: 15, weight: .medium)
                        } icon: {
                            Image(systemName: "person.badge.plus")
                                .foregroundStyle(theme.brandPrimary)
                        }
                    }
                }
                
                // Leave Conversation
                Section {
                    Button(role: .destructive) {
                        showLeaveConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if isLeaving {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Leave Conversation", systemImage: "arrow.right.square")
                                    .scaledFont(size: 15, weight: .semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isLeaving)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .tint(.secondary)
                }
            }
            .confirmationDialog("Leave Conversation", isPresented: $showLeaveConfirmation, titleVisibility: .visible) {
                Button("Leave", role: .destructive) {
                    isLeaving = true
                    Task {
                        await onLeave()
                        isLeaving = false
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll stop receiving messages from this conversation. It will be hidden from your sidebar.")
            }
            .sheet(isPresented: $showAddPeoplePicker) {
                AddAccessSheet(
                    channelId: channel.id,
                    existingMemberIds: existingMemberIds,
                    allUsers: allUsers,
                    isLoading: isAddingMembers,
                    serverBaseURL: serverBaseURL,
                    onAdd: { _, selectedIds in
                        isAddingMembers = true
                        Task {
                            await onAddMembers(selectedIds)
                            isAddingMembers = false
                            showAddPeoplePicker = false
                        }
                    },
                    onCancel: { showAddPeoplePicker = false }
                )
                .interactiveDismissDisabled()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}
