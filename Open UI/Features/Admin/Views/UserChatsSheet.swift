import SwiftUI

/// Sheet for viewing a user's chat history. Admin only.
/// Groups chats by date (Today, Yesterday, Previous 7 days, etc.)
/// Tapping a chat navigates to a read-only detail view with clone/delete actions.
struct UserChatsSheet: View {
    @Bindable var viewModel: AdminViewModel
    let serverBaseURL: String
    /// APIClient for loading authenticated images in the chat detail view.
    let apiClient: APIClient?

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
            .overlay(alignment: .top) {
                if let message = viewModel.cloneError {
                    Text(message)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textInverse)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(theme.error.opacity(0.92), in: Capsule())
                        .padding(.top, Spacing.xl)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(4))
                            withAnimation(MicroAnimation.gentle) { viewModel.cloneError = nil }
                        }
                }
            }
            .animation(MicroAnimation.gentle, value: viewModel.cloneError)
            .navigationTitle(
                viewModel.viewingChatsForUser.map { "\($0.displayName)'s Chats" } ?? "User Chats"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .tint(.secondary)
                }
            }
            // Navigation destination for chat detail
            .navigationDestination(for: AdminChatItem.self) { chat in
                AdminChatDetailView(
                    viewModel: viewModel,
                    chatItem: chat,
                    serverBaseURL: serverBaseURL,
                    apiClient: apiClient,
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
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textTertiary)

            TextField("Search Chats", text: $viewModel.chatSearchQuery)
                .scaledFont(size: 16)
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
                        .scaledFont(size: 16)
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
        List {
            ForEach(groupedChats, id: \.title) { group in
                Section {
                    ForEach(group.chats) { chat in
                        NavigationLink(value: chat) {
                            chatRow(chat)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(theme.background)
                        .listRowSeparatorTint(theme.cardBorder)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                viewModel.chatToDelete = chat
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await copyToMyChats(chat) }
                            } label: {
                                Label("Copy", systemImage: "square.and.arrow.down.on.square")
                            }
                            .tint(theme.brandPrimary)
                        }
                        .contextMenu {
                            Button {
                                Task { await copyToMyChats(chat) }
                            } label: {
                                Label("Copy to My Chats", systemImage: "square.and.arrow.down.on.square")
                            }
                            Button(role: .destructive) {
                                viewModel.chatToDelete = chat
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .task { await viewModel.loadMoreUserChatsIfNeeded(current: chat) }
                    }
                } header: {
                    Text(group.title)
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(nil)
                        .padding(.horizontal, Spacing.screenPadding)
                }
                .listSectionSeparator(.hidden)
            }

            if viewModel.isLoadingMoreChats {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(theme.background)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, Spacing.md)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(MicroAnimation.gentle, value: viewModel.userChats.map(\.id))
        .refreshable { await viewModel.searchUserChats() }
        .overlay(alignment: .top) {
            if viewModel.isRefreshingChats {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, Spacing.xs)
                    .transition(.opacity)
            }
        }
        .animation(MicroAnimation.fade, value: viewModel.isRefreshingChats)
    }

    /// Copies a chat from the list and hands it to the main view, which closes every sheet
    /// and opens it.
    private func copyToMyChats(_ chat: AdminChatItem) async {
        await viewModel.cloneUserChat(chatId: chat.id)
        if let cloned = viewModel.clonedConversation {
            Haptics.notify(.success)
            onClone?(cloned)
        }
    }

    private func chatRow(_ chat: AdminChatItem) -> some View {
        HStack(spacing: Spacing.md) {
            // Chat title
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? "Untitled Chat" : chat.title)
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            // Date
            Text(chat.updatedDate.chatTimestamp)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
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
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }

    private var emptyState: some View {
        let searching = !viewModel.chatSearchQuery.isEmpty
        return VStack(spacing: Spacing.md) {
            Image(systemName: searching ? "magnifyingglass" : "bubble.left.and.text.bubble.right")
                .scaledFont(size: 40)
                .foregroundStyle(theme.textTertiary)
            Text(searching ? "No chats match \"\(viewModel.chatSearchQuery)\"" : "This user has no chats yet")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(size: 40)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
            Button("Retry") {
                if let user = viewModel.viewingChatsForUser {
                    Task { await viewModel.loadUserChats(for: user) }
                }
            }
            .scaledFont(size: 16)
            .fontWeight(.semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 100)
    }
}
