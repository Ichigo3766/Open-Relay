import Foundation

// MARK: - Chat read / unread API (web Sidebar + ChatItem + RecursiveFolder parity)
//
// Server rules (routers/chats.py, models/chats.py):
//  • unread  ⇔  updated_at > coalesce(last_read_at, 0)
//  • opening a chat → socket `events:chat {type: last_read_at}` → server sets last_read_at = now
//    and broadcasts `events {type: chat:list, data: {last_read_at, folder_unread_counts?}}`
//  • POST /chats/{id}/unread → last_read_at = 0
//  • POST /chats/read, POST /folders/{id}/read → mark all / a folder subtree read

extension Conversation {
    /// Parses `last_read_at` (Int / Double / null) from a server row.
    nonisolated func withLastReadAt(_ raw: Any?) -> Conversation {
        var c = self
        if let i = raw as? Int { c.lastReadAt = TimeInterval(i) }
        else if let d = raw as? Double { c.lastReadAt = d }
        else { c.lastReadAt = nil }
        return c
    }
}

/// Response shared by the read/unread endpoints and the `chat:list` broadcast.
nonisolated struct ReadStateResponse: Sendable {
    var lastReadAt: TimeInterval?
    var folderUnreadCounts: [String: Int]?

    init(json: [String: Any]) {
        if let i = json["last_read_at"] as? Int { lastReadAt = TimeInterval(i) }
        else if let d = json["last_read_at"] as? Double { lastReadAt = d }
        folderUnreadCounts = (json["folder_unread_counts"] as? [String: Any])?.compactMapValues {
            ($0 as? Int) ?? ($0 as? Double).map { Int($0) }
        }
    }
}

extension APIClient {
    /// POST /api/v1/chats/{id}/unread
    func markChatUnread(id: String) async throws -> ReadStateResponse {
        ReadStateResponse(json: try await network.requestJSON(path: "/api/v1/chats/\(id)/unread", method: .post, body: [:]))
    }

    /// POST /api/v1/chats/read — every chat of the user.
    func markAllChatsRead() async throws -> ReadStateResponse {
        ReadStateResponse(json: try await network.requestJSON(path: "/api/v1/chats/read", method: .post, body: [:]))
    }

    /// POST /api/v1/folders/{id}/read — the folder and (for owners) its subfolders.
    func markFolderChatsRead(folderId: String) async throws -> ReadStateResponse {
        ReadStateResponse(json: try await network.requestJSON(path: "/api/v1/folders/\(folderId)/read", method: .post, body: [:]))
    }
}
