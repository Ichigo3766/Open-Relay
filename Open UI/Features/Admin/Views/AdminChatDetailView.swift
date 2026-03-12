import SwiftUI
import MarkdownView

/// Read-only view of a user's chat conversation.
/// Admin can view the full message history, clone it to their own chats,
/// or delete it. Accessed from `UserChatsSheet` by tapping a chat row.
struct AdminChatDetailView: View {
    @Bindable var viewModel: AdminViewModel
    let chatItem: AdminChatItem
    let serverBaseURL: String

    /// Called when a clone succeeds — parent should dismiss the sheet and navigate.
    var onClone: ((Conversation) -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var showCloneConfirmation = false
    @State private var showCopiedToast = false

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
                        .font(.system(size: 14, weight: .medium))
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.error)
                }
            }
            .disabled(viewModel.isDeletingChat || viewModel.isLoadingChatDetail)
        }
    }

    // MARK: - Chat Content

    private func chatContent(_ conversation: Conversation) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Chat info header
                chatInfoHeader(conversation)

                // Messages
                ForEach(conversation.messages) { message in
                    messageRow(message: message, conversation: conversation)
                }
            }
            .padding(.bottom, Spacing.lg)
        }
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.md)
    }

    private func infoPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 10))
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
                .font(AppTypography.labelSmallFont)
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
                .font(.system(size: 16))
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

    @ViewBuilder
    private func userAttachmentFiles(for message: ChatMessage) -> some View {
        let imageFiles = message.files.filter { $0.type == "image" }
        let nonImageFiles = message.files.filter { $0.type != "image" }

        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if !imageFiles.isEmpty {
                HStack(spacing: Spacing.sm) {
                    Spacer()
                    ForEach(Array(imageFiles.prefix(4).enumerated()), id: \.offset) { _, file in
                        if let fileId = file.url, !fileId.isEmpty {
                            // Show a placeholder for images (no auth context in admin view)
                            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                .fill(theme.surfaceContainer)
                                .frame(width: 80, height: 80)
                                .overlay {
                                    Image(systemName: "photo")
                                        .font(.system(size: 20))
                                        .foregroundStyle(theme.textTertiary)
                                }
                        }
                    }
                }
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

    private func fileChip(file: ChatMessageFile) -> some View {
        let name = file.name ?? file.url ?? "File"
        let ext = (name as NSString).pathExtension.lowercased()
        return HStack(spacing: Spacing.xs) {
            Image(systemName: "doc")
                .font(.system(size: 12))
                .foregroundStyle(theme.brandPrimary)
            Text(name)
                .font(AppTypography.captionFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !ext.isEmpty {
                Text(ext.uppercased())
                    .font(.system(size: 9, weight: .bold))
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
            HStack(spacing: Spacing.sm) {
                ForEach(Array(imageFiles.prefix(4).enumerated()), id: \.offset) { _, _ in
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .fill(theme.surfaceContainer)
                        .frame(height: 100)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 24))
                                .foregroundStyle(theme.textTertiary)
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
                    Circle()
                        .fill(theme.brandPrimary.opacity(0.2))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Text(String((source.title ?? source.url ?? "?").prefix(1)).uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(theme.brandPrimary)
                        )
                }
            }
            Text("\(sources.count) Source\(sources.count == 1 ? "" : "s")")
                .font(AppTypography.labelSmallFont)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(theme.surfaceContainer.opacity(0.6))
        .clipShape(Capsule())
    }

    // MARK: - Error View

    private func messageErrorView(_ text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.error)
            Text(text)
                .font(AppTypography.captionFont)
                .foregroundStyle(theme.error)
                .lineLimit(2)
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: - Copied Toast

    private var copiedToastView: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.on.doc.fill").font(.system(size: 12))
            Text("Copied to clipboard").font(AppTypography.labelSmallFont)
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
                .font(AppTypography.bodyMediumFont)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(theme.error)
            Text(message)
                .font(AppTypography.bodyMediumFont)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.loadChatDetail(chatId: chatItem.id) }
            }
            .font(AppTypography.bodyMediumFont)
            .fontWeight(.semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(theme.textTertiary)
            Text("No messages in this chat")
                .font(AppTypography.bodyMediumFont)
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
