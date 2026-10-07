import SwiftUI

// MARK: - Rows

extension ReadOnlyChatTranscript {

    @ViewBuilder
    func messageRow(_ row: Row) -> some View {
        let message = row.message
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {
            if message.role == .assistant {
                assistantHeader(message)
                statusSteps(message)
            }

            if message.role == .user {
                userAttachments(message)
            }

            ChatMessageBubble(role: message.role, showTimestamp: false, timestamp: message.timestamp) {
                bubbleContent(row)
            }
            .contextMenu {
                Button { copy(message) } label: { Label("Copy", systemImage: "doc.on.doc") }
            }

            if message.role == .assistant {
                assistantExtras(message)
            }

            if let error = message.error {
                ReadOnlyErrorLine(text: error.content ?? "An error occurred")
                    .padding(.horizontal, Spacing.screenPadding)
            }
        }
        .entranceFade()
    }

    @ViewBuilder
    private func bubbleContent(_ row: Row) -> some View {
        if row.message.role == .user {
            if !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserMessageContentView(content: row.text)
                    .lineSpacing(2)
            }
        } else {
            AssistantMessageContent(
                content: row.text,
                isStreaming: false,
                messageEmbeds: row.message.embeds,
                authToken: apiClient?.network.authToken,
                serverBaseURL: serverBaseURL,
                apiClient: apiClient,
                terminalMessageId: row.message.id
            )
        }
    }

    // MARK: Assistant

    private func assistantHeader(_ message: ChatMessage) -> some View {
        let name = message.model ?? conversation.model ?? "Assistant"
        return HStack(spacing: Spacing.sm) {
            ModelAvatar(size: 22, label: name)
            Text(Self.shortModelName(name))
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
        .padding(.bottom, 4)
    }

    /// Web search / tool steps, collapsed, exactly like the main chat.
    @ViewBuilder
    private func statusSteps(_ message: ChatMessage) -> some View {
        if message.statusHistory.contains(where: { $0.hidden != true }) {
            StreamingStatusView(statusHistory: message.statusHistory, isStreaming: false)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.bottom, Spacing.xs)
        }
    }

    @ViewBuilder
    private func assistantExtras(_ message: ChatMessage) -> some View {
        let images = message.files.filter(readOnlyIsImage)
        if !images.isEmpty {
            ReadOnlyImageGrid(files: images, apiClient: apiClient)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.xs)
        }
        if !message.sources.isEmpty {
            ReadOnlySourcesPill(sources: message.sources) { sourcesMessage = message }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.xs)
        }
        actionBar(message)
            .padding(.horizontal, Spacing.screenPadding - 6)
            .padding(.top, 2)
    }

    // MARK: User

    @ViewBuilder
    private func userAttachments(_ message: ChatMessage) -> some View {
        let images = message.files.filter(readOnlyIsImage)
        let others = message.files.filter { !readOnlyIsImage($0) && $0.type != "collection" && $0.type != "folder" }
        if !images.isEmpty || !others.isEmpty {
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                if !images.isEmpty {
                    ReadOnlyImageGrid(files: images, apiClient: apiClient, alignTrailing: true)
                }
                ForEach(Array(others.enumerated()), id: \.offset) { _, file in
                    ReadOnlyFileChip(file: file)
                }
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.bottom, Spacing.xs)
        }
    }
}
