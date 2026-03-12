import Foundation
import os.log

/// Observable view model that drives the Folders section of the chat list.
///
/// Handles all folder CRUD operations with optimistic local updates,
/// lazy-loading of folder contents, and debounced expand/collapse sync.
@MainActor @Observable
final class FolderListViewModel {

    // MARK: - Published State

    /// All top-level (root) folders sorted by name.
    var folders: [ChatFolder] = []

    /// Whether the initial folder load is in progress.
    var isLoading: Bool = false

    /// Folder currently being renamed (drives the rename alert).
    var renamingFolder: ChatFolder?

    /// Text for the rename alert text field.
    var renameText: String = ""

    /// Folder pending deletion (drives the delete confirmation).
    var deletingFolder: ChatFolder?

    /// Whether the "create folder" sheet is shown.
    var showCreateSheet: Bool = false

    /// Non-nil when folders feature is confirmed disabled on this server.
    var featureDisabled: Bool = false

    /// ID of a folder currently highlighted as a drag drop target.
    var dragTargetFolderId: String?

    /// ID of a folder that auto-expanded during a drag hover.
    private var autoExpandedFolderId: String?
    private var autoExpandTask: Task<Void, Never>?

    // MARK: - Private

    private var manager: FolderManager?
    private let logger = Logger(subsystem: "com.openui", category: "FolderListVM")

    // MARK: - Setup

    func configure(with manager: FolderManager) {
        self.manager = manager
    }

    // MARK: - Load

    /// Loads folders from the server. Call on appear and after refresh.
    /// Automatically fetches chats for any folder that starts expanded.
    func loadFolders() async {
        guard let manager, !isLoading else { return }
        isLoading = true
        do {
            let (fetched, enabled) = try await manager.fetchFolders()
            featureDisabled = !enabled
            if enabled {
                // Preserve local expand states so UI doesn't flicker
                let existingExpandState = Dictionary(
                    uniqueKeysWithValues: folders.map { ($0.id, $0.isExpanded) }
                )
                folders = fetched.map { folder in
                    var f = folder
                    if let existing = existingExpandState[folder.id] {
                        f.isExpanded = existing
                    }
                    return f
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                // Auto-load chats for folders that are expanded on initial load
                await withTaskGroup(of: Void.self) { group in
                    for folder in folders where folder.isExpanded {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            await self.loadChatsIfNeeded(for: folder)
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to load folders: \(error.localizedDescription)")
        }
        isLoading = false
    }

    /// Loads (or reloads) the chats inside a folder.
    func loadChatsIfNeeded(for folder: ChatFolder) async {
        guard let manager else { return }
        guard folder.isExpanded else { return }

        do {
            let chats = try await manager.fetchChatsInFolder(folderId: folder.id)
            if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[idx].chats = chats
            }
        } catch {
            logger.error("Failed to load chats for folder \(folder.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Expand / Collapse

    /// Toggles the expanded state of a folder and syncs to server (debounced).
    func toggleExpanded(folder: ChatFolder) async {
        guard let idx = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        let newExpanded = !folders[idx].isExpanded
        folders[idx].isExpanded = newExpanded
        manager?.syncExpanded(folderId: folder.id, expanded: newExpanded)

        // Lazily load contents when expanding
        if newExpanded {
            await loadChatsIfNeeded(for: folders[idx])
        }
    }

    // MARK: - Create

    /// Creates a new folder with the given name (optimistic insert).
    func createFolder(name: String) async {
        guard let manager else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Optimistic placeholder with a local ID
        let localId = "local-\(UUID().uuidString)"
        let placeholder = ChatFolder(id: localId, name: trimmed)
        folders.append(placeholder)

        do {
            let created = try await manager.createFolder(name: trimmed)
            // Replace placeholder with real server model
            if let idx = folders.firstIndex(where: { $0.id == localId }) {
                folders[idx] = created
            }
        } catch {
            logger.error("Failed to create folder: \(error.localizedDescription)")
            // Revert optimistic insert
            folders.removeAll { $0.id == localId }
        }
    }

    // MARK: - Rename

    /// Begins the rename flow for a folder.
    func beginRename(folder: ChatFolder) {
        renamingFolder = folder
        renameText = folder.name
    }

    /// Commits the rename to the server.
    func commitRename() async {
        guard let manager,
              let folder = renamingFolder,
              !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            renamingFolder = nil
            return
        }

        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldName = folder.name
        renamingFolder = nil

        // Optimistic update
        if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[idx].name = newName
        }

        do {
            let updated = try await manager.renameFolder(id: folder.id, name: newName)
            if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[idx].name = updated.name
            }
        } catch {
            logger.error("Failed to rename folder: \(error.localizedDescription)")
            // Revert
            if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[idx].name = oldName
            }
        }
    }

    // MARK: - Delete

    /// Deletes a folder and moves its chats out (server handles orphaning).
    func deleteFolder(id: String) async {
        guard let manager else { return }

        let removed = folders.first { $0.id == id }
        folders.removeAll { $0.id == id }

        do {
            try await manager.deleteFolder(id: id)
        } catch {
            logger.error("Failed to delete folder: \(error.localizedDescription)")
            // Revert
            if let removed {
                folders.append(removed)
            }
        }
    }

    // MARK: - Move Chat to Folder

    /// Moves a conversation into a folder (or out to root when folderId is nil).
    ///
    /// Updates both the source folder's chat list and the destination folder's
    /// chat list so the UI stays consistent without a full reload.
    func moveChat(conversation: Conversation, to folderId: String?) async {
        guard let manager else { return }

        let conversationId = conversation.id
        let sourceFolderId = conversation.folderId

        // --- Optimistic UI update ---
        // Remove from source folder's chat list
        if let srcId = sourceFolderId,
           let srcIdx = folders.firstIndex(where: { $0.id == srcId }) {
            folders[srcIdx].chats.removeAll { $0.id == conversationId }
        }

        // Add to destination folder's chat list (if folder is loaded/expanded)
        if let dstId = folderId,
           let dstIdx = folders.firstIndex(where: { $0.id == dstId }) {
            var updatedConv = conversation
            updatedConv.folderId = dstId
            if !folders[dstIdx].chats.contains(where: { $0.id == conversationId }) {
                folders[dstIdx].chats.insert(updatedConv, at: 0)
            }
        }

        // --- Server sync ---
        do {
            try await manager.moveChat(conversationId: conversationId, to: folderId)

            // Reload the destination folder's chat list from the server
            // so the UI shows the chat instantly without a sidebar close/reopen.
            if let dstId = folderId,
               let dstIdx = folders.firstIndex(where: { $0.id == dstId }) {
                let freshChats = try await manager.fetchChatsInFolder(folderId: dstId)
                folders[dstIdx].chats = freshChats
            }

            // Also refresh the source folder if it was a folder-to-folder move
            if let srcId = sourceFolderId, srcId != folderId,
               let srcIdx = folders.firstIndex(where: { $0.id == srcId }) {
                let freshChats = try? await manager.fetchChatsInFolder(folderId: srcId)
                if let freshChats {
                    folders[srcIdx].chats = freshChats
                }
            }
        } catch {
            logger.error("Failed to move chat \(conversationId) to folder \(folderId ?? "nil"): \(error.localizedDescription)")

            // Revert: put chat back in source folder, remove from destination
            if let srcId = sourceFolderId,
               let srcIdx = folders.firstIndex(where: { $0.id == srcId }),
               !folders[srcIdx].chats.contains(where: { $0.id == conversationId }) {
                folders[srcIdx].chats.insert(conversation, at: 0)
            }
            if let dstId = folderId,
               let dstIdx = folders.firstIndex(where: { $0.id == dstId }) {
                folders[dstIdx].chats.removeAll { $0.id == conversationId }
            }
        }
    }

    // MARK: - Drag & Drop Helpers

    /// Called when a chat drag enters a folder.
    /// Starts an auto-expand timer (standard 0.8 s iOS behaviour).
    func dragEntered(folderId: String) {
        dragTargetFolderId = folderId
        autoExpandTask?.cancel()
        autoExpandTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            if let idx = self.folders.firstIndex(where: { $0.id == folderId }),
               !self.folders[idx].isExpanded {
                await self.toggleExpanded(folder: self.folders[idx])
                self.autoExpandedFolderId = folderId
            }
        }
    }

    /// Called when a chat drag leaves a folder.
    func dragExited(folderId: String) {
        if dragTargetFolderId == folderId {
            dragTargetFolderId = nil
        }
        autoExpandTask?.cancel()
        autoExpandTask = nil
    }

    /// Called when a drop is completed on a folder.
    func dragCompleted() {
        dragTargetFolderId = nil
        autoExpandTask?.cancel()
        autoExpandTask = nil
        autoExpandedFolderId = nil
    }

    // MARK: - Refresh

    /// Silently refreshes folder metadata and chats for expanded folders.
    /// Unlike `loadFolders()` this does NOT set `isLoading`, so the UI
    /// won't flash a loading state. Safe to call on drawer open, foreground
    /// resume, and socket reconnect.
    func refreshFolders() async {
        guard let manager else { return }
        do {
            let (fetched, enabled) = try await manager.fetchFolders()
            featureDisabled = !enabled
            guard enabled else { return }

            // Preserve local expand states
            let existingExpandState = Dictionary(
                uniqueKeysWithValues: folders.map { ($0.id, $0.isExpanded) }
            )
            folders = fetched.map { folder in
                var f = folder
                if let existing = existingExpandState[folder.id] {
                    f.isExpanded = existing
                }
                return f
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Reload chats for all expanded folders
            await withTaskGroup(of: Void.self) { group in
                for folder in folders where folder.isExpanded {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.loadChatsIfNeeded(for: folder)
                    }
                }
            }
        } catch {
            logger.error("Failed to refresh folders: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Returns the folder that contains the given conversation (if any).
    func folder(for conversationId: String) -> ChatFolder? {
        folders.first { folder in
            folder.chats.contains { $0.id == conversationId }
        }
    }

    /// Inserts an updated `Conversation` object (e.g. after title change)
    /// into the correct folder chat list.
    func updateConversation(_ conversation: Conversation) {
        for idx in folders.indices {
            if let chatIdx = folders[idx].chats.firstIndex(where: { $0.id == conversation.id }) {
                folders[idx].chats[chatIdx] = conversation
                return
            }
        }
    }
}
