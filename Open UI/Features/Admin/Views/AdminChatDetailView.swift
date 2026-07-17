import SwiftUI
import MarkdownView

/// Read-only view of a user's chat conversation.
/// Admin can view the full message history, clone it to their own chats,
/// or delete it. Accessed from `UserChatsSheet` by tapping a chat row.
struct AdminChatDetailView: View {
    @Bindable var viewModel: AdminViewModel
    let chatItem: AdminChatItem
    let serverBaseURL: String
    /// APIClient for loading authenticated images (user uploads + tool-generated images).
    let apiClient: APIClient?

    /// Called when a clone succeeds — parent should dismiss the sheet and navigate.
    var onClone: ((Conversation) -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var showCloneConfirmation = false
    @State private var showCopiedToast = false

    // MARK: - Scroll State

    @State private var scrollPosition: ScrollPosition = .init()
    /// True when the user has scrolled more than 80pt away from the bottom.
    @State private var isScrolledAway = false

    // MARK: - Sliding Window (pagination)

    /// The ending index (exclusive) of the visible message window.
    /// `nil` = pinned to latest (always shows the newest messages).
    @State private var windowEnd: Int? = nil
    /// Number of messages currently in the rendered window.
    @State private var windowSize: Int = 20
    /// Guard to prevent rapid-fire pagination triggers while expanding the window.
    @State private var isLoadingMore: Bool = false
    /// Cached distance-from-bottom, updated by the first onScrollGeometryChange observer
    /// and consumed by the second (offset-based) observer for re-pin logic.
    @State private var _cachedDistFromBottom: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingChatDetail {
                loadingState
            } else if let error = viewModel.chatDetailError {
                errorState(error)
            } else if let conversation = viewModel.selectedChatDetail {
                chatContent(conversation)
            } else {
                emptyState
            }
        }
        .background(theme.background)
        .navigationTitle(chatItem.title.isEmpty ? "Untitled Chat" : chatItem.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            await viewModel.loadChatDetail(chatId: chatItem.id)
        }
        // Copied toast
        .overlay(alignment: .top) {
            if showCopiedToast { copiedToastView }
        }
        // Delete confirmation
        .confirmationDialog(
            "Delete Chat",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteUserChat(chatItem)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to permanently delete \"\(chatItem.title)\"? This action cannot be undone.")
        }
        // Clone confirmation
        .confirmationDialog(
            "Clone Chat",
            isPresented: $showCloneConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clone to My Chats") {
                Task {
                    await viewModel.cloneUserChat(chatId: chatItem.id)
                    if let cloned = viewModel.clonedConversation {
                        onClone?(cloned)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will create a copy of this chat in your own chat list. You can then continue the conversation.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Clone button
            Button {
                showCloneConfirmation = true
            } label: {
                if viewModel.isCloning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "doc.on.doc")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
            }
            .disabled(viewModel.isCloning || viewModel.isLoadingChatDetail)

            // Delete button
            Button {
                showDeleteConfirmation = true
            } label: {
                if viewModel.isDeletingChat {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "trash")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.error)
                }
            }
            .disabled(viewModel.isDeletingChat || viewModel.isLoadingChatDetail)
        }
    }

    // MARK: - Chat Content

    private func chatContent(_ conversation: Conversation) -> some View {
        // ── Sliding window: compute the visible slice ──
        let allMessages = conversation.messages
        let total = allMessages.count
        let effectiveEnd = windowEnd ?? total
        let effectiveStart = max(0, effectiveEnd - windowSize)
        let clampedEnd = min(effectiveEnd, total)
        let visibleMessages = Array(allMessages[effectiveStart..<clampedEnd])
        let hasMoreAbove = effectiveStart > 0

        return ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // "Loading older messages" indicator at top of window
                    if hasMoreAbove {
                        ProgressView()
                            .padding(.vertical, Spacing.md)
                    }

                    // Chat info header
                    chatInfoHeader(conversation)

                    // Windowed messages
                    ForEach(visibleMessages) { message in
                        messageRow(message: message, conversation: conversation)
                    }
                }
                .padding(.bottom, Spacing.lg)
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                max(0, geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height)
            } action: { _, dist in
                _cachedDistFromBottom = dist
                // FAB visibility
                let shouldBeAway = dist > 80
                if shouldBeAway != isScrolledAway {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isScrolledAway = shouldBeAway
                    }
                }
                // Re-pin to latest when scrolled back near the bottom
                let capturedTotal = total
                if let wEnd = windowEnd, dist < 200, wEnd < capturedTotal {
                    let slideBy = min(5, capturedTotal - wEnd)
                    windowEnd = wEnd + slideBy
                    if windowEnd! >= capturedTotal { windowEnd = nil }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, offsetY in
                // Sliding window: load older messages when approaching the top
                let capturedTotal = total
                let capturedEffectiveStart = effectiveStart
                if offsetY < 600, capturedEffectiveStart > 0, !isLoadingMore {
                    isLoadingMore = true
                    let slideBy = min(10, capturedEffectiveStart)
                    let newStart = capturedEffectiveStart - slideBy
                    windowSize = min(windowSize + slideBy, capturedTotal)
                    windowEnd = min(newStart + windowSize, capturedTotal)
                    if windowEnd! >= capturedTotal { windowEnd = nil }
                    isLoadingMore = false
                }
            }
            .onAppear {
                windowSize = min(20, total)
                scrollPosition.scrollTo(edge: .bottom)
            }

            // Scroll-to-bottom FAB
            if isScrolledAway {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                    windowEnd = nil
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "arrow.down")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(theme.textInverse)
                        .frame(width: 36, height: 36)
                        .background(theme.textPrimary.opacity(0.8), in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.trailing, Spacing.screenPadding)
                .padding(.bottom, Spacing.lg)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isScrolledAway)
            }
        }
    }

    /// Helper to compute distance from bottom from a ScrollGeometry value.
    private func distFromBottom(_ geo: ScrollGeometry) -> CGFloat {
        max(0, geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height)
    }

    // MARK: - Chat Info Header

    private func chatInfoHeader(_ conversation: Conversation) -> some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                infoPill(icon: "bubble.left.and.text.bubble.right",
                         text: "\(conversation.messages.count) messages")

                if let model = conversation.model {
                    infoPill(icon: "cpu", text: modelShortName(model))
                }

                infoPill(icon: "calendar",
                         text: conversation.createdAt.chatTimestamp)
            }

            if let ownerName = viewModel.viewingChatsForUser?.displayName {
                Text("Chat by \(ownerName)")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.md)
    }

    private func infoPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .scaledFont(size: 10, weight: .medium)
            Text(text)
                .scaledFont(size: 11, weight: .medium)
        }
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surfaceContainer.opacity(0.6))
        .clipShape(Capsule())
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(message: ChatMessage, conversation: Conversation) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {
            // Assistant header
            if message.role == .assistant {
                assistantHeader(for: message, conversation: conversation)
            }

            // User attachment images
            if message.role == .user && !message.files.isEmpty {
                userAttachmentFiles(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, Spacing.xs)
            }

            // Message bubble
            ChatMessageBubble(
                role: message.role,
                showTimestamp: false,
                timestamp: message.timestamp
            ) {
                messageContent(for: message)
            }
            .contextMenu {
                Button {
                    copyMessageContent(message.content)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            // Tool-generated images
            if message.role == .assistant && !message.files.isEmpty {
                messageFilesView(files: message.files)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }

            // Sources
            if message.role == .assistant && !message.sources.isEmpty {
                sourcesBar(sources: message.sources)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }

            // Error
            if let error = message.error {
                messageErrorView(error.content ?? "An error occurred")
                    .padding(.horizontal, Spacing.screenPadding)
            }

            // Timestamp for assistant messages
            if message.role == .assistant {
                Text(message.timestamp.chatTimestamp)
                    .scaledFont(size: 10)
                    .foregroundStyle(theme.textTertiary.opacity(0.6))
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Assistant Header

    private func assistantHeader(for message: ChatMessage, conversation: Conversation) -> some View {
        HStack(spacing: Spacing.sm) {
            ModelAvatar(size: 22, label: message.model ?? conversation.model)
            Text(modelShortName(message.model ?? conversation.model ?? "Assistant"))
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
        .padding(.bottom, 4)
    }

    // MARK: - Message Content

    @ViewBuilder
    private func messageContent(for message: ChatMessage) -> some View {
        if message.role == .user {
            Text(message.content)
                .scaledFont(size: 16)
                .lineSpacing(3)
        } else {
            // Process content for display (resolve URLs, citations, hard breaks)
            let processed = preprocessAssistantContent(message.content, sources: message.sources)
            AssistantMessageContent(
                content: processed,
                isStreaming: false
            )
        }
    }

    /// Preprocesses assistant content for display — resolves URLs and citation links.
    /// Note: soft breaks are now handled natively by MarkdownView (renders \n as line breaks).
    private func preprocessAssistantContent(_ content: String, sources: [ChatSourceReference]) -> String {
        let resolved = resolveRelativeURLs(content)
        return preprocessCitations(resolved, sources: sources)
    }

    private func resolveRelativeURLs(_ content: String) -> String {
        let base = serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return content }
        let pattern = #"(\]\()(/api/[^\s\)]+)"#
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
            result += "\(prefix)\(base)\(relativePath)"
            currentIndex = fullRange.location + fullRange.length
        }
        if currentIndex < nsContent.length {
            result += nsContent.substring(from: currentIndex)
        }
        return result
    }

    private func preprocessCitations(_ content: String, sources: [ChatSourceReference]) -> String {
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
                result += " [\(index)](\(url)) "
            } else {
                result += content[fullRange]
            }
            searchStart = fullRange.upperBound
        }
        result += content[searchStart...]
        return result
    }

    // MARK: - User Attachment Files

    /// Returns true when a file should be rendered as an image.
    private func isImageFile(_ file: ChatMessageFile) -> Bool {
        if file.type == "image" { return true }
        if file.type == "file", let ct = file.contentType, ct.hasPrefix("image/") { return true }
        return false
    }

    @ViewBuilder
    private func userAttachmentFiles(for message: ChatMessage) -> some View {
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
                        fileChip(file: file)
                    }
                }
            }
        }
    }

    /// Mosaic grid layout matching the real chat experience.
    @ViewBuilder
    private func userImageMosaicGrid(imageFiles: [ChatMessageFile]) -> some View {
        let shown = Array(imageFiles.prefix(4))
        let overflow = imageFiles.count - 4
        let cornerRadius = CornerRadius.md

        HStack {
            Spacer()
            Group {
                switch shown.count {
                case 1:
                    // Single image: full-width up to 260pt
                    if let fileId = shown[0].url, !fileId.isEmpty {
                        AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                case 2:
                    // Two images side by side
                    HStack(spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, file in
                            if let fileId = file.url, !fileId.isEmpty {
                                AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                                    .scaledToFill()
                                    .frame(width: 120, height: 160)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                            }
                        }
                    }
                case 3:
                    // One on top, two on the bottom
                    VStack(spacing: 2) {
                        if let fileId = shown[0].url, !fileId.isEmpty {
                            AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                                .scaledToFill()
                                .frame(width: 242, height: 160)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        }
                        HStack(spacing: 2) {
                            ForEach(1..<3, id: \.self) { idx in
                                if let fileId = shown[idx].url, !fileId.isEmpty {
                                    AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                                        .scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                                }
                            }
                        }
                    }
                default:
                    // 4 images in a 2×2 grid, with overflow badge on the last
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ForEach(0..<2, id: \.self) { idx in
                                if let fileId = shown[idx].url, !fileId.isEmpty {
                                    AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                                        .scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                                }
                            }
                        }
                        HStack(spacing: 2) {
                            if let fileId = shown[2].url, !fileId.isEmpty {
                                AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                                    .scaledToFill()
                                    .frame(width: 120, height: 120)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                            }
                            ZStack {
                                if let fileId = shown[3].url, !fileId.isEmpty {
                                    AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                                        .scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                                }
                                if overflow > 0 {
                                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                        .fill(.black.opacity(0.5))
                                        .frame(width: 120, height: 120)
                                    Text("+\(overflow)")
                                        .scaledFont(size: 20, weight: .bold)
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func fileChip(file: ChatMessageFile) -> some View {
        let name = file.name ?? file.url ?? "File"
        let ext = (name as NSString).pathExtension.lowercased()
        return HStack(spacing: Spacing.xs) {
            Image(systemName: "doc")
                .scaledFont(size: 12)
                .foregroundStyle(theme.brandPrimary)
            Text(name)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !ext.isEmpty {
                Text(ext.uppercased())
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(theme.surfaceContainer.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    }

    // MARK: - Tool-Generated Images

    @ViewBuilder
    private func messageFilesView(files: [ChatMessageFile]) -> some View {
        let imageFiles = files.filter { $0.type == "image" || ($0.contentType ?? "").hasPrefix("image/") }
        if !imageFiles.isEmpty {
            let columns = imageFiles.count == 1
                ? [GridItem(.flexible())]
                : [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: Spacing.sm) {
                ForEach(Array(imageFiles.enumerated()), id: \.offset) { _, file in
                    if let fileUrl = file.url, !fileUrl.isEmpty {
                        // Extract file ID from path (e.g. /api/v1/files/<id>/content)
                        let fileId: String = {
                            if !fileUrl.contains("/") { return fileUrl }
                            let parts = fileUrl.split(separator: "/")
                            if let idx = parts.firstIndex(of: "files"), idx + 1 < parts.count {
                                return String(parts[idx + 1])
                            }
                            return fileUrl
                        }()
                        AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(imageFiles.count == 1 ? nil : 1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .fill(theme.surfaceContainer)
                            .frame(height: 100)
                            .overlay {
                                Image(systemName: "photo")
                                    .scaledFont(size: 24)
                                    .foregroundStyle(theme.textTertiary)
                            }
                    }
                }
            }
        }
    }

    // MARK: - Sources Bar

    private func sourcesBar(sources: [ChatSourceReference]) -> some View {
        HStack(spacing: Spacing.xs) {
            HStack(spacing: -4) {
                ForEach(Array(sources.prefix(3).enumerated()), id: \.offset) { _, source in
                    sourceIconBadge(source: source)
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

    // MARK: - Error View

    private func messageErrorView(_ text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(theme.error)
            Text(text)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.error)
                .lineLimit(2)
        }
        .padding(.top, Spacing.xs)
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

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Loading conversation…")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(size: 40)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.loadChatDetail(chatId: chatItem.id) }
            }
            .scaledFont(size: 16)
            .fontWeight(.semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .scaledFont(size: 40)
                .foregroundStyle(theme.textTertiary)
            Text("No messages in this chat")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    // MARK: - Helpers

    private func copyMessageContent(_ content: String) {
        UIPasteboard.general.string = content
        Haptics.notify(.success)
        withAnimation(MicroAnimation.gentle) { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(MicroAnimation.gentle) { showCopiedToast = false }
        }
    }

    private func modelShortName(_ fullName: String) -> String {
        // Extract the short model name (after last / or : )
        let name = fullName
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        if let lastColon = name.lastIndex(of: ":") {
            return String(name[..<lastColon])
        }
        return name
    }
}
