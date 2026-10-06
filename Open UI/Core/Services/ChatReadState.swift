import Foundation
import Observation

/// App-wide chat read state. The iPhone drawer, the iPad sidebar and folder rows all read
/// from here, so a change from any source shows up everywhere immediately.
///
/// Stores *overrides* on top of what the server lists returned:
///  • `readAt[chatId]` — a local read time (opened here / socket broadcast / mark-unread = 0)
///  • `folderCounts` — the latest `folder_unread_counts` from any response or broadcast
@MainActor @Observable
final class ChatReadState {
    static let shared = ChatReadState()

    private(set) var readAt: [String: TimeInterval] = [:]
    private(set) var folderCounts: [String: Int] = [:]
    /// The chat currently on screen — never shown as unread (web: `id !== $chatId`).
    var openChatId: String?

    @ObservationIgnored private var subscription: SocketSubscription?
    @ObservationIgnored private weak var socket: SocketIOService?

    // MARK: Rules

    /// `generatingId` = the chat streaming on this device (web: `!active`).
    func isUnread(_ c: Conversation, generatingId: String? = nil) -> Bool {
        Self.isUnread(updatedAt: c.updatedAt.timeIntervalSince1970,
                      serverReadAt: c.lastReadAt, localReadAt: readAt[c.id],
                      isOpen: c.id == openChatId, isGenerating: c.id == generatingId,
                      isTemporary: c.isTemporary)
    }

    nonisolated static func isUnread(updatedAt: TimeInterval, serverReadAt: TimeInterval?, localReadAt: TimeInterval?,
                                     isOpen: Bool, isGenerating: Bool, isTemporary: Bool) -> Bool {
        if isOpen || isGenerating || isTemporary { return false }
        // A local override replaces the server value — it can be *lower* (mark-unread → 0).
        guard let effective = localReadAt ?? serverReadAt, effective > 0 else { return true }
        // Server timestamps are whole seconds; tolerate drift on a chat read the same second.
        return updatedAt > effective + 0.5
    }

    /// Badge count; shared-with-me folders never show one (web RecursiveFolder).
    func folderUnreadCount(_ folder: ChatFolder) -> Int {
        folder.readonly ? 0 : max(0, folderCounts[folder.id] ?? folder.unreadCount)
    }

    // MARK: Mutations

    func apply(_ r: ReadStateResponse, chatId: String? = nil) {
        if let chatId, let t = r.lastReadAt { readAt[chatId] = t }
        if let counts = r.folderUnreadCounts { folderCounts.merge(counts) { _, new in new } }
    }

    /// Opening a chat: hide the dot now, and tell the server (which tells the web).
    func markOpened(_ chatId: String) {
        guard !chatId.isEmpty, !chatId.hasPrefix("local:") else { return }
        readAt[chatId] = Date().timeIntervalSince1970
        socket?.emit("events:chat", data: ["chat_id": chatId, "data": ["type": "last_read_at"]])
    }

    func markUnread(_ chatId: String, api: APIClient) async throws {
        let r = try await api.markChatUnread(id: chatId)
        readAt[chatId] = r.lastReadAt ?? 0
        apply(r)
    }

    func markAllRead(_ visible: [Conversation], api: APIClient) async throws {
        let r = try await api.markAllChatsRead()
        markLocallyRead(visible)
        // Chats we haven't listed yet: lift every existing override too.
        let now = Date().timeIntervalSince1970
        readAt = readAt.mapValues { max($0, now) }
        apply(r)
    }

    func markFolderRead(_ folderId: String, chats: [Conversation], api: APIClient) async throws {
        let r = try await api.markFolderChatsRead(folderId: folderId)
        markLocallyRead(chats)
        apply(r)
    }

    private func markLocallyRead(_ chats: [Conversation]) {
        let now = Date().timeIntervalSince1970
        for c in chats { readAt[c.id] = max(now, c.updatedAt.timeIntervalSince1970) }
    }

    /// Fresh `GET /folders/` rows carry authoritative `unread_count`s — drop older overrides.
    func adoptServerFolderCounts(_ folders: [ChatFolder]) {
        for f in folders { folderCounts.removeValue(forKey: f.id) }
    }

    /// Fresh server rows: drop overrides the server has caught up with (so they never go stale).
    func reconcile(with conversations: [Conversation]) {
        for c in conversations {
            guard let local = readAt[c.id], let server = c.lastReadAt else { continue }
            if local > 0 ? server >= local : server == 0 { readAt.removeValue(forKey: c.id) }
        }
    }

    /// The open chat changed (iPhone drawer / iPad sidebar). Marks the outgoing chat read
    /// (it may have received a reply while open) and the incoming one read.
    func handleOpenChatChange(from oldId: String?, to newId: String?) {
        if let oldId, oldId != newId { markOpened(oldId) }
        openChatId = newId
        if let newId { markOpened(newId) }
    }

    // MARK: Live updates (another device / the web read a chat)

    func attach(to socket: SocketIOService?) {
        subscription?.dispose()
        subscription = nil
        self.socket = socket
        readAt = [:]; folderCounts = [:]; openChatId = nil
        guard let socket else { return }
        subscription = socket.addChatEventHandler { [weak self] event, _ in
            // Cheap filter off the main thread — this handler sees every streaming token.
            guard let data = event["data"] as? [String: Any], let type = data["type"] as? String else { return }
            let chatId = event["chat_id"] as? String
            // Web Chat.svelte: when the open chat's reply finishes, mark it read so the
            // reply doesn't leave it "unread" on other devices.
            if type == "chat:active", (data["data"] as? [String: Any])?["active"] as? Bool == false, let chatId {
                Task { @MainActor [weak self] in
                    if self?.openChatId == chatId { self?.markOpened(chatId) }
                }
                return
            }
            guard type == "chat:list", let inner = data["data"] as? [String: Any],
                  inner["last_read_at"] != nil || inner["folder_unread_counts"] != nil else { return }
            let r = ReadStateResponse(json: inner)
            Task { @MainActor [weak self] in self?.apply(r, chatId: chatId) }
        }
    }
}
