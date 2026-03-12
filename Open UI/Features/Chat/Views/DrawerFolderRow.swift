import SwiftUI

/// A collapsible folder row rendered inside the slide-out drawer of `MainChatView`.
///
/// Shows the folder name with an animated chevron. When expanded, lists
/// the chats inside with a left accent indent. Supports context menu
/// for rename/delete, and drag-and-drop to receive chats.
struct DrawerFolderRow: View {
    var folder: ChatFolder
    @Bindable var folderVM: FolderListViewModel
    var allConversations: [Conversation]
    var activeConversationId: String?
    var onSelectChat: (String) -> Void
    /// Called when a chat is moved (chatId, targetFolderId) so the caller
    /// can update its own conversation list's folderId.
    var onChatMoved: ((String, String?) -> Void)?
    /// Called when a chat should be deleted.
    var onDeleteChat: ((String) -> Void)?
    /// Called when a chat's pin state should be toggled.
    var onTogglePin: ((Conversation) -> Void)?

    @Environment(\.theme) private var theme
    @State private var showDeleteConfirmation = false

    private var isDropTarget: Bool {
        folderVM.dragTargetFolderId == folder.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Folder header ────────────────────────────────────────
            Button {
                Haptics.play(.light)
                Task { await folderVM.toggleExpanded(folder: folder) }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: AnimDuration.fast), value: folder.isExpanded)
                        .frame(width: 12)

                    Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.brandPrimary)

                    Text(folder.name)
                        .font(AppTypography.bodySmallFont)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    // Chat count
                    let count = folder.isExpanded
                        ? folder.chats.count
                        : (folderVM.folders.firstIndex(where: { $0.id == folder.id })
                            .map { _ in 0 } ?? 0)
                    if folder.isExpanded && count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Drop target highlight
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .fill(isDropTarget ? theme.brandPrimary.opacity(0.12) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.sm)
                            .stroke(theme.brandPrimary, lineWidth: isDropTarget ? 1.5 : 0)
                    )
            )
            .animation(.easeInOut(duration: AnimDuration.fast), value: isDropTarget)
            // Accept dropped chats from anywhere (main list or other folders)
            .dropDestination(for: DraggableChat.self) { items, _ in
                guard let item = items.first,
                      item.currentFolderId != folder.id else { return false }
                folderVM.dragCompleted()
                let chatId = item.conversationId
                let sourceFolderId = item.currentFolderId
                let targetFolderId = folder.id

                // Find the full conversation object (with correct title).
                // Search folder chats first, then the main conversations list.
                let folderChats = folderVM.folders.flatMap(\.chats)
                let conv = folderChats.first(where: { $0.id == chatId })
                    ?? allConversations.first(where: { $0.id == chatId })
                    ?? Conversation(id: chatId, title: "", folderId: sourceFolderId)

                Task {
                    // Auto-expand the target folder so the user sees the chat immediately
                    if let idx = folderVM.folders.firstIndex(where: { $0.id == targetFolderId }),
                       !folderVM.folders[idx].isExpanded {
                        await folderVM.toggleExpanded(folder: folderVM.folders[idx])
                    }
                    await folderVM.moveChat(conversation: conv, to: targetFolderId)
                    // Notify caller to update listViewModel.conversations folderId
                    onChatMoved?(chatId, targetFolderId)
                }
                return true
            } isTargeted: { targeted in
                withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                    if targeted {
                        folderVM.dragEntered(folderId: folder.id)
                    } else {
                        folderVM.dragExited(folderId: folder.id)
                    }
                }
            }
            .contextMenu {
                Button {
                    folderVM.beginRename(folder: folder)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Folder", systemImage: "trash")
                }
            }
            .confirmationDialog(
                "Delete \"\(folder.name)\"?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Folder", role: .destructive) {
                    Task { await folderVM.deleteFolder(id: folder.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Chats inside this folder will not be deleted.")
            }

            // ── Expanded chat list ───────────────────────────────────
            if folder.isExpanded {
                let validChats = folder.chats.filter { !$0.title.isEmpty }
                VStack(spacing: 0) {
                    if validChats.isEmpty && folder.chats.isEmpty {
                        // Still loading or genuinely empty
                        Text("No chats")
                            .font(AppTypography.captionFont)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.leading, 36)
                            .padding(.vertical, Spacing.xs)
                    } else {
                        ForEach(validChats) { chat in
                            drawerChatRow(chat)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: AnimDuration.fast), value: folder.isExpanded)
    }

    // MARK: - Chat Row Inside Folder

    private func drawerChatRow(_ chat: Conversation) -> some View {
        Button {
            onSelectChat(chat.id)
        } label: {
            HStack(spacing: Spacing.sm) {
                // Indent + accent bar
                Rectangle()
                    .fill(theme.brandPrimary.opacity(0.3))
                    .frame(width: 2)
                    .cornerRadius(1)
                    .padding(.leading, 22)

                Text(chat.title)
                    .font(AppTypography.bodySmallFont)
                    .fontWeight(activeConversationId == chat.id ? .semibold : .regular)
                    .foregroundStyle(
                        activeConversationId == chat.id
                            ? theme.textPrimary
                            : theme.textSecondary
                    )
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.trailing, Spacing.sm)
            .background(
                activeConversationId == chat.id
                    ? theme.brandPrimary.opacity(0.1)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: CornerRadius.sm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Allow dragging out of folder
        .draggable(DraggableChat(
            conversationId: chat.id,
            currentFolderId: folder.id
        )) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "bubble.left").font(.system(size: 12))
                Text(chat.title)
                    .font(AppTypography.captionFont)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .contextMenu {
            Button {
                onTogglePin?(chat)
            } label: {
                Label(
                    chat.pinned ? "Unpin" : "Pin",
                    systemImage: chat.pinned ? "pin.slash" : "pin"
                )
            }

            Button {
                let chatId = chat.id
                Task {
                    await folderVM.moveChat(conversation: chat, to: nil)
                    onChatMoved?(chatId, nil)
                }
            } label: {
                Label("Remove from Folder", systemImage: "folder.badge.minus")
            }

            let otherFolders = folderVM.folders.filter { $0.id != folder.id }
            if !otherFolders.isEmpty {
                Menu("Move to Folder") {
                    ForEach(otherFolders) { other in
                        Button {
                            Task { await folderVM.moveChat(conversation: chat, to: other.id) }
                        } label: {
                            Label(other.name, systemImage: "folder")
                        }
                    }
                }
            }

            Button(role: .destructive) {
                onDeleteChat?(chat.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel(Text(chat.title))
        .accessibilityHint(Text("Double tap to open. Drag to move between folders."))
    }
}
