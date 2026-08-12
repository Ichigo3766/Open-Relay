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
    var activeFolderWorkspaceId: String?
    var onSelectChat: (String) -> Void
    /// Called when the folder name/icon is tapped to open as workspace.
    var onSelectFolder: ((String) -> Void)?
    /// Called when a chat is moved (chatId, targetFolderId) so the caller
    /// can update its own conversation list's folderId.
    var onChatMoved: ((String, String?) -> Void)?
    /// Called when a chat should be deleted.
    var onDeleteChat: ((String) -> Void)?
    /// Called when a chat's pin state should be toggled.
    var onTogglePin: ((Conversation) -> Void)?
    /// Called when a conversation should be permanently deleted (used in bulk delete).
    var onDeleteConversation: ((String) async -> Void)?
    /// Called when the user wants to share a chat from inside the folder.
    var onShareChat: ((Conversation) -> Void)?
    /// Called when the user wants to export/download a chat (conversation + format).
    var onExportChat: ((Conversation, ExportFormat) -> Void)?
    /// Called when the user wants to rename a chat from inside the folder.
    var onRenameChat: ((Conversation) -> Void)?
    /// Called when the user wants to clone a chat from inside the folder.
    var onCloneChat: ((Conversation) -> Void)?
    /// Called when the user wants to archive a chat from inside the folder.
    var onArchiveChat: ((Conversation) -> Void)?
    /// Called when the user taps "Share" on the folder itself (from the folder header context menu).
    var onShareFolder: ((ChatFolder) -> Void)?

    /// Export format for chat download menu.
    enum ExportFormat { case json, txt, pdf }
    /// Indentation depth for subfolders (0 = root level)
    var depth: Int = 0

    @Environment(\.theme) private var theme
    @State private var showDeleteConfirmation = false
    @State private var chatToDelete: Conversation?

    private var isDropTarget: Bool {
        folderVM.dragTargetFolderId == folder.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Folder header ────────────────────────────────────────
            // Header is split: chevron = expand/collapse, folder icon + name = open workspace
            let isActiveWorkspace = activeFolderWorkspaceId == folder.id
            HStack(spacing: 0) {
                // Depth indentation for subfolders
                if depth > 0 {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: CGFloat(depth) * 16)
                }

                // Chevron button — expand/collapse only
                Button {
                    Haptics.play(.light)
                    Task { await folderVM.toggleExpanded(folder: folder) }
                } label: {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 9, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: AnimDuration.fast), value: folder.isExpanded)
                        .frame(width: 12)
                        .padding(.vertical, 7)
                        .padding(.leading, Spacing.sm)
                        .padding(.trailing, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Folder name + icon button — opens workspace
                Button {
                    Haptics.play(.light)
                    onSelectFolder?(folder.id)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        // Show custom emoji icon when set, otherwise default folder SF Symbol
                        if let icon = folder.meta?.icon, !icon.isEmpty {
                            Text(icon)
                                .scaledFont(size: 14)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                                .scaledFont(size: 12)
                                .foregroundStyle(isActiveWorkspace ? theme.brandPrimary : theme.brandPrimary)
                        }

                        Text(folder.name)
                            .scaledFont(size: 14, weight: isActiveWorkspace ? .semibold : .medium, context: .list)
                            .foregroundStyle(isActiveWorkspace ? theme.brandPrimary : theme.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        // Chat count badge
                        if folder.isExpanded && !folder.chats.isEmpty {
                            let count = folder.chats.filter { !$0.title.isEmpty }.count
                            if count > 0 {
                                Text("\(count)")
                                    .scaledFont(size: 10, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.trailing, Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    isActiveWorkspace
                        ? theme.brandPrimary.opacity(0.1)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: CornerRadius.sm)
                )
            }
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
                    onShareFolder?(folder)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button {
                    Task { await folderVM.beginEdit(folder: folder) }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button {
                    folderVM.createSubfolderParentId = folder.id
                    folderVM.showCreateSheet = true
                } label: {
                    Label("Create Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    folderVM.beginRename(folder: folder)
                } label: {
                    Label("Rename", systemImage: "character.cursor.ibeam")
                }

                Divider()

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete folder?", systemImage: "trash")
                }
            }
            .confirmationDialog(
                "Delete \"\(folder.name)\"?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Folder Only", role: .destructive) {
                    Task { await folderVM.deleteFolder(id: folder.id, deleteContents: false) }
                }
                Button("Delete Folder and Chats", role: .destructive) {
                    Task { await folderVM.deleteFolder(id: folder.id, deleteContents: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose whether to keep the chats or delete them along with the folder.")
            }

            // ── Expanded chat list + subfolders ─────────────────────
            if folder.isExpanded {
                // Look up the live folder from the flat array so chats/subfolders
                // reflect the latest server data (avoids stale value-type snapshots).
                let liveFolder = folderVM.folders.first(where: { $0.id == folder.id }) ?? folder
                let validChats = liveFolder.chats.filter { !$0.title.isEmpty }
                // Live child folders from the flat array — reactive to isExpanded changes
                let liveChildren = folderVM.folders
                    .filter { $0.parentId == folder.id }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                // LazyVStack renders only visible rows — critical for large folders (100+ chats).
                // Subfolders are kept outside the lazy section since they have variable height.
                VStack(spacing: 0) {
                    ForEach(liveChildren) { child in
                        DrawerFolderRow(
                            folder: child,
                            folderVM: folderVM,
                            allConversations: allConversations,
                            activeConversationId: activeConversationId,
                            activeFolderWorkspaceId: activeFolderWorkspaceId,
                            onSelectChat: onSelectChat,
                            onSelectFolder: onSelectFolder,
                            onChatMoved: onChatMoved,
                            onDeleteChat: onDeleteChat,
                            onTogglePin: onTogglePin,
                            onDeleteConversation: onDeleteConversation,
                            onShareChat: onShareChat,
                            onExportChat: onExportChat,
                            onRenameChat: onRenameChat,
                            onCloneChat: onCloneChat,
                            onArchiveChat: onArchiveChat,
                            onShareFolder: onShareFolder,
                            depth: depth + 1
                        )
                    }

                    // Chats inside this folder — LazyVStack for O(visible) rendering
                    if validChats.isEmpty && liveFolder.chats.isEmpty && liveChildren.isEmpty {
                        // Still loading or genuinely empty
                        Text("No chats")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.leading, CGFloat(depth + 2) * 12 + 12)
                            .padding(.vertical, Spacing.xs)
                    } else {
                        // Selection mode header — shown when this folder is in selection mode
                        let isThisFolderSelecting = folderVM.isFolderChatSelectionMode
                            && folderVM.selectionFolderId == folder.id
                        if isThisFolderSelecting {
                            folderSelectionHeader(folder: liveFolder, validChats: validChats)
                        }

                        LazyVStack(spacing: 0) {
                            ForEach(validChats) { chat in
                                drawerChatRow(chat)
                                    // Fixed height so LazyVStack can pre-calculate total size
                                    // without measuring every off-screen row.
                                    // Row = 12pt top padding + ~14pt font cap height + 12pt bottom = ~38pt
                                    .frame(height: 38)
                            }
                        }

                        // Selection mode action bar
                        if isThisFolderSelecting {
                            folderSelectionActionBar(folder: liveFolder)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: AnimDuration.fast), value: folder.isExpanded)
    }

    // MARK: - Folder Chat Selection Header

    @ViewBuilder
    private func folderSelectionHeader(folder: ChatFolder, validChats: [Conversation]) -> some View {
        HStack(spacing: Spacing.sm) {
            Button {
                folderVM.exitFolderChatSelectionMode()
            } label: {
                Text("Cancel")
                    .scaledFont(size: 13, context: .list)
                    .foregroundStyle(theme.brandPrimary)
            }

            Spacer()

            Text("\(folderVM.selectedFolderChatCount) selected")
                .scaledFont(size: 12, weight: .semibold, context: .list)
                .foregroundStyle(theme.textPrimary)

            Spacer()

            Button {
                if folderVM.selectedFolderChatCount == validChats.count {
                    folderVM.selectedFolderChatIds.removeAll()
                } else {
                    folderVM.selectAllChats(in: folder.id)
                }
            } label: {
                Text(folderVM.selectedFolderChatCount == validChats.count ? "Deselect All" : "Select All")
                    .scaledFont(size: 11, weight: .medium, context: .list)
                    .foregroundStyle(theme.brandPrimary)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(theme.surfaceContainer.opacity(0.6), in: RoundedRectangle(cornerRadius: CornerRadius.sm))
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.xs)
    }

    // MARK: - Folder Chat Selection Action Bar

    @ViewBuilder
    private func folderSelectionActionBar(folder: ChatFolder) -> some View {
        VStack(spacing: Spacing.xs) {
            if folderVM.isBulkFolderChatOperating {
                ProgressView()
                    .padding(.vertical, Spacing.xs)
            } else {
                HStack(spacing: Spacing.xs) {
                    // Remove from folder button
                    Button {
                        Task { await folderVM.removeSelectedChatsFromFolder() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.minus")
                                .scaledFont(size: 11)
                            Text("Remove")
                                .scaledFont(size: 12, weight: .medium, context: .list)
                        }
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 6)
                        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: CornerRadius.sm))
                    }
                    .disabled(folderVM.selectedFolderChatCount == 0)

                    // Move to folder button
                    Menu {
                        ForEach(folderVM.folders.filter { $0.id != folder.id }) { otherFolder in
                            Button {
                                Task {
                                    let ids = folderVM.selectedFolderChatIds
                                    let chatsToMove = folder.chats.filter { ids.contains($0.id) }
                                    for chat in chatsToMove {
                                        await folderVM.moveChat(conversation: chat, to: otherFolder.id)
                                    }
                                    folderVM.exitFolderChatSelectionMode()
                                }
                            } label: {
                                Label(otherFolder.name, systemImage: "folder")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .scaledFont(size: 11)
                            Text("Move to…")
                                .scaledFont(size: 12, weight: .medium, context: .list)
                        }
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 6)
                        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: CornerRadius.sm))
                    }
                    .disabled(folderVM.selectedFolderChatCount == 0 || folderVM.folders.filter { $0.id != folder.id }.isEmpty)

                    Spacer()

                    // Delete button
                    Button(role: .destructive) {
                        folderVM.showDeleteSelectedFolderChatsConfirmation = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .scaledFont(size: 11)
                            Text("Delete")
                                .scaledFont(size: 12, weight: .medium, context: .list)
                        }
                        .foregroundStyle(folderVM.selectedFolderChatCount > 0 ? Color.red : Color.red.opacity(0.4))
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: CornerRadius.sm))
                    }
                    .disabled(folderVM.selectedFolderChatCount == 0)
                }
                .padding(.horizontal, Spacing.sm)
            }
        }
        .padding(.vertical, Spacing.xs)
        .confirmationDialog(
            "Delete \(folderVM.selectedFolderChatCount) Chat(s)?",
            isPresented: Binding(
                get: { folderVM.showDeleteSelectedFolderChatsConfirmation },
                set: { folderVM.showDeleteSelectedFolderChatsConfirmation = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await folderVM.deleteSelectedFolderChats(
                        folderId: folder.id,
                        deleteConversation: { chatId in
                            await onDeleteConversation?(chatId)
                        }
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected conversations. This action cannot be undone.")
        }
    }

    // MARK: - Chat Row Inside Folder

    private func drawerChatRow(_ chat: Conversation) -> some View {
        let isSelecting = folderVM.isFolderChatSelectionMode && folderVM.selectionFolderId == folder.id
        let isSelected = folderVM.isFolderChatSelected(chat.id)

        return Group {
            if isSelecting {
                // Selection mode — tap toggles checkbox, no navigation
                Button {
                    Haptics.play(.light)
                    folderVM.toggleFolderChatSelection(chat.id)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        // Checkbox
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .scaledFont(size: 16)
                            .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                            .padding(.leading, 22 + CGFloat(depth) * 16)

                        Text(chat.title)
                            .scaledFont(size: 14)
                            .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.trailing, Spacing.sm)
                    .background(
                        isSelected ? theme.brandPrimary.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: CornerRadius.sm)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(chat.title))
                .accessibilityHint(Text(isSelected ? "Selected. Double tap to deselect." : "Double tap to select."))

            } else {
                // Normal mode — tap opens chat, long press enters selection mode
                Button {
                    onSelectChat(chat.id)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        // Indent + accent bar — indent increases with subfolder depth
                        Rectangle()
                            .fill(theme.brandPrimary.opacity(0.3))
                            .frame(width: 2)
                            .cornerRadius(1)
                            .padding(.leading, 22 + CGFloat(depth) * 16)

                        Text(chat.title)
                            .scaledFont(size: 14)
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
                        Image(systemName: "bubble.left").scaledFont(size: 12)
                        Text(chat.title)
                            .scaledFont(size: 12, weight: .medium)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .contextMenu {
                    // Share
                    Button {
                        onShareChat?(chat)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    // Download submenu
                    Menu {
                        Button {
                            onExportChat?(chat, .json)
                        } label: {
                            Label("Export chat (.json)", systemImage: "doc")
                        }
                        Button {
                            onExportChat?(chat, .txt)
                        } label: {
                            Label("Plain text (.txt)", systemImage: "doc.plaintext")
                        }
                        Button {
                            onExportChat?(chat, .pdf)
                        } label: {
                            Label("PDF document (.pdf)", systemImage: "doc.richtext")
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }

                    // Rename — hidden for chats in read-only shared folders
                    if !folder.readonly {
                        Button {
                            onRenameChat?(chat)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }

                    // Pin / Unpin
                    Button {
                        onTogglePin?(chat)
                    } label: {
                        Label(
                            chat.pinned ? "Unpin" : "Pin",
                            systemImage: chat.pinned ? "pin.slash" : "pin"
                        )
                    }

                    // Clone
                    Button {
                        onCloneChat?(chat)
                    } label: {
                        Label("Clone", systemImage: "doc.on.doc")
                    }

                    // Move to folder (remove from this folder or move to another)
                    Menu("Move to Folder") {
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
                        ForEach(otherFolders) { other in
                            Button {
                                Task { await folderVM.moveChat(conversation: chat, to: other.id) }
                            } label: {
                                Label(other.name, systemImage: "folder")
                            }
                        }
                    }

                    // Archive
                    Button {
                        onArchiveChat?(chat)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }

                    // Select (multi-select mode)
                    Button {
                        folderVM.enterFolderChatSelectionMode(folderId: folder.id)
                        folderVM.toggleFolderChatSelection(chat.id)
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }

                    Divider()

                    // Delete
                    Button(role: .destructive) {
                        chatToDelete = chat
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .confirmationDialog(
                    "Delete \"\(chatToDelete?.title ?? chat.title)\"?",
                    isPresented: .init(
                        get: { chatToDelete?.id == chat.id },
                        set: { if !$0 { chatToDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let toDelete = chatToDelete {
                            chatToDelete = nil
                            onDeleteChat?(toDelete.id)
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        chatToDelete = nil
                    }
                } message: {
                    Text("This action cannot be undone.")
                }
                .accessibilityLabel(Text(chat.title))
                .accessibilityHint(Text("Double tap to open. Drag to move between folders."))
                // Long press enters selection mode for this folder
                .onLongPressGesture {
                    Haptics.play(.medium)
                    folderVM.enterFolderChatSelectionMode(folderId: folder.id)
                    folderVM.toggleFolderChatSelection(chat.id)
                }
            }
        }
    }
}
