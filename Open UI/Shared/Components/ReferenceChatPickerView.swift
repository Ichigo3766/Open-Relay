import SwiftUI

// MARK: - Reference Chat Picker View

/// A full-screen sheet that appears when the user taps "Reference Chats" in the `+` menu.
///
/// Shows all of the user's chat conversations fetched via the existing pagination API,
/// grouped by time range (Today, Yesterday, Previous 7 days, etc.).
/// Selected chats are attached as pills in the composer and included in the request's
/// `files` array so the server can use them as context.
struct ReferenceChatPickerView: View {
    @Binding var isPresented: Bool
    let conversationManager: ConversationManager?
    let onSelect: (ReferenceChatItem) -> Void

    @Environment(\.theme) private var theme

    @State private var chats: [ReferenceChatItem] = []
    @State private var isLoading = false
    @State private var loadError: String? = nil
    @State private var searchQuery = ""
    @State private var currentPage = 1
    @State private var hasMorePages = true
    @State private var isLoadingMore = false

    // MARK: - Filtered & Grouped

    private var filteredChats: [ReferenceChatItem] {
        guard !searchQuery.isEmpty else { return chats }
        return chats.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
    }

    private var groupedChats: [(title: String, items: [ReferenceChatItem])] {
        let order = ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "Older"]
        var grouped: [String: [ReferenceChatItem]] = [:]
        for chat in filteredChats {
            let key = chat.timeRange
            grouped[key, default: []].append(chat)
        }
        return order.compactMap { key in
            guard let items = grouped[key], !items.isEmpty else { return nil }
            return (title: key, items: items)
        }
    }

    private var hasResults: Bool {
        !filteredChats.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Search bar
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                    Divider()
                        .foregroundStyle(theme.cardBorder.opacity(0.4))

                    // Content
                    if isLoading && chats.isEmpty {
                        loadingView
                    } else if let err = loadError {
                        errorView(err)
                    } else if !hasResults {
                        emptyView
                    } else {
                        scrollContent
                    }
                }
            }
            .navigationTitle("Reference Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .foregroundStyle(theme.brandPrimary)
                }
            }
        }
        .onAppear {
            Task { await loadChats(page: 1, reset: true) }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textTertiary)

            TextField("Search chats…", text: $searchQuery)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.5 : 0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading chats…")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(size: 32)
                .foregroundStyle(theme.textTertiary)
            Text("Couldn't load chats")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text(message)
                .scaledFont(size: 13)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                loadError = nil
                Task { await loadChats(page: 1, reset: true) }
            }
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(theme.brandPrimary)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "bubble.left.and.bubble.right")
                .scaledFont(size: 36)
                .foregroundStyle(theme.textTertiary)
            Text(searchQuery.isEmpty ? "No conversations found" : "No results for \"\(searchQuery)\"")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        List {
            ForEach(groupedChats, id: \.title) { group in
                Section {
                    ForEach(group.items) { chat in
                        chatRow(chat)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                    }
                } header: {
                    Text(group.title)
                        .scaledFont(size: 11, weight: .semibold)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, 8)
                }
            }

            // Load more trigger
            if hasMorePages && !isLoadingMore {
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        Task { await loadMoreIfNeeded() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Chat Row

    private func chatRow(_ chat: ReferenceChatItem) -> some View {
        Button {
            Haptics.play(.light)
            onSelect(chat)
            isPresented = false
        } label: {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.brandPrimary.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "bubble.left.and.bubble.right")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }

                // Title + relative time
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title.isEmpty ? "Untitled" : chat.title)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    Text(chat.relativeTime)
                        .scaledFont(size: 12, weight: .regular)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "plus.circle")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.brandPrimary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceContainer.opacity(theme.isDark ? 0.35 : 0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.3), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data Loading

    private func loadChats(page: Int, reset: Bool) async {
        guard !isLoading else { return }
        guard let manager = conversationManager else {
            loadError = "Not connected to a server."
            return
        }
        if reset { isLoading = true }
        defer { isLoading = false }

        do {
            let conversations = try await manager.fetchConversationsPage(page: page)
            let newItems = conversations.compactMap { conv -> ReferenceChatItem? in
                // Skip temporary / local chats
                guard !conv.isTemporary else { return nil }
                return ReferenceChatItem(
                    id: conv.id,
                    title: conv.title,
                    updatedAt: conv.updatedAt,
                    createdAt: conv.createdAt
                )
            }
            loadError = nil
            if reset {
                chats = newItems
            } else {
                let existingIds = Set(chats.map(\.id))
                let deduplicated = newItems.filter { !existingIds.contains($0.id) }
                chats.append(contentsOf: deduplicated)
            }
            hasMorePages = !newItems.isEmpty
            currentPage = page
        } catch is CancellationError {
            // Task was cancelled during sheet presentation animation — retry automatically
            if reset && chats.isEmpty {
                isLoading = false
                Task { await loadChats(page: 1, reset: true) }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadMoreIfNeeded() async {
        guard hasMorePages && !isLoadingMore && !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadChats(page: currentPage + 1, reset: false)
    }
}
