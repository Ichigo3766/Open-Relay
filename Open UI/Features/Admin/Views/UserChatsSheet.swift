import SwiftUI

/// Sheet for viewing a user's chat history. Admin only.
/// Groups chats by date (Today, Yesterday, Previous 7 days, etc.)
/// Tapping a chat navigates to a read-only detail view with clone/delete actions.
struct UserChatsSheet: View {
    @Bindable var viewModel: AdminViewModel
    let serverBaseURL: String

    /// Called when a chat is cloned — parent should dismiss and navigate to it.
    var onClone: ((Conversation) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var chatSearchTask: Task<Void, Never>?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                chatSearchBar

                // Content
                if viewModel.isLoadingChats {
                    loadingState
                } else if let error = viewModel.chatError {
                    errorState(error)
                } else if viewModel.userChats.isEmpty {
                    emptyState
                } else {
                    chatList
                }
            }
            .background(theme.background)
            .navigationTitle(
                viewModel.viewingChatsForUser.map { "\($0.displayName)'s Chats" } ?? "User Chats"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(theme.surfaceContainer)
                            .clipShape(Circle())
                    }
                }
            }
            // Navigation destination for chat detail
            .navigationDestination(for: AdminChatItem.self) { chat in
                AdminChatDetailView(
                    viewModel: viewModel,
                    chatItem: chat,
                    serverBaseURL: serverBaseURL,
                    onClone: { clonedConversation in
                        onClone?(clonedConversation)
                    }
                )
            }
            // Delete confirmation dialog
            .confirmationDialog(
                "Delete Chat",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                if let chat = viewModel.chatToDelete {
                    Button("Delete \"\(chat.title)\"", role: .destructive) {
                        Task {
                            await viewModel.deleteUserChat(chat)
                            viewModel.chatToDelete = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.chatToDelete = nil
                }
            } message: {
                if let chat = viewModel.chatToDelete {
                    Text("Are you sure you want to permanently delete \"\(chat.title)\"? This action cannot be undone.")
                }
            }
        }
    }

    // MARK: - Search Bar

    private var chatSearchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.textTertiary)

            TextField("Search Chats", text: $viewModel.chatSearchQuery)
                .font(AppTypography.bodyMediumFont)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: viewModel.chatSearchQuery) { _, _ in
                    chatSearchTask?.cancel()
                    chatSearchTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        await viewModel.searchUserChats()
                    }
                }

            if !viewModel.chatSearchQuery.isEmpty {
                Button {
                    viewModel.chatSearchQuery = ""
                    Task { await viewModel.searchUserChats() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Chat List (grouped by date)

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedChats, id: \.title) { group in
                    // Section header
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.md)
                        .padding(.bottom, Spacing.xs)

                    // Chat items
                    ForEach(group.chats) { chat in
                        NavigationLink(value: chat) {
                            chatRow(chat)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                viewModel.chatToDelete = chat
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }

                        if chat.id != group.chats.last?.id {
                            Divider()
                                .padding(.leading, Spacing.screenPadding + 28)
                        }
                    }
                }
            }
            .padding(.bottom, Spacing.lg)
        }
    }

    private func chatRow(_ chat: AdminChatItem) -> some View {
        HStack(spacing: Spacing.md) {
            // Chat title
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? "Untitled Chat" : chat.title)
                    .font(AppTypography.bodyMediumFont)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            // Date
            Text(chat.updatedDate.chatTimestamp)
                .font(AppTypography.captionFont)
                .foregroundStyle(theme.textTertiary)

            // Chevron indicator
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textTertiary.opacity(0.5))
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Date Grouping

    private struct ChatGroup: Identifiable {
        let title: String
        let chats: [AdminChatItem]
        var id: String { title }
    }

    private var groupedChats: [ChatGroup] {
        let calendar = Calendar.current
        let now = Date()

        var today: [AdminChatItem] = []
        var yesterday: [AdminChatItem] = []
        var previousWeek: [AdminChatItem] = []
        var previousMonth: [AdminChatItem] = []
        var older: [AdminChatItem] = []

        for chat in viewModel.userChats {
            let date = chat.updatedDate
            if calendar.isDateInToday(date) {
                today.append(chat)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(chat)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      date >= weekAgo {
                previousWeek.append(chat)
            } else if let monthAgo = calendar.date(byAdding: .day, value: -30, to: now),
                      date >= monthAgo {
                previousMonth.append(chat)
            } else {
                older.append(chat)
            }
        }

        var groups: [ChatGroup] = []
        if !today.isEmpty { groups.append(ChatGroup(title: "Today", chats: today)) }
        if !yesterday.isEmpty { groups.append(ChatGroup(title: "Yesterday", chats: yesterday)) }
        if !previousWeek.isEmpty { groups.append(ChatGroup(title: "Previous 7 days", chats: previousWeek)) }
        if !previousMonth.isEmpty { groups.append(ChatGroup(title: "Previous 30 days", chats: previousMonth)) }
        if !older.isEmpty { groups.append(ChatGroup(title: "Older", chats: older)) }

        return groups
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Loading chats…")
                .font(AppTypography.bodyMediumFont)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(theme.textTertiary)
            Text("No chats found")
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
            Button("Retry") {
                if let user = viewModel.viewingChatsForUser {
                    Task { await viewModel.loadUserChats(for: user) }
                }
            }
            .font(AppTypography.bodyMediumFont)
            .fontWeight(.semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }
}
