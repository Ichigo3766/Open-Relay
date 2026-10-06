import Foundation

// MARK: - Group 2: user-facing features from the API diff

struct UsageInfo: Sendable {
    let userCount: Int
    let modelIds: [String]
}

extension APIClient {

    // MARK: Status

    /// POST /api/v1/users/user/status/update. Empty strings clear the status (web "Clear status").
    func updateMyStatus(emoji: String, message: String, expiresAt: Int? = nil) async throws {
        var body: [String: Any] = ["status_emoji": emoji, "status_message": message]
        body["status_expires_at"] = expiresAt.map { $0 as Any } ?? NSNull()
        _ = try await network.requestRaw(
            path: "/api/v1/users/user/status/update", method: .post,
            body: try JSONSerialization.data(withJSONObject: body))
    }

    /// GET /api/v1/users/user/status → the session user (with `status_*`). 403 when the admin disabled statuses.
    func getMyStatus() async throws -> (emoji: String, message: String, expiresAt: Int?) {
        let json = try await network.requestJSON(path: "/api/v1/users/user/status")
        return (json["status_emoji"] as? String ?? "", json["status_message"] as? String ?? "",
                json["status_expires_at"] as? Int)
    }

    // MARK: Shared chat access

    /// GET /api/v1/chats/shared/{chat_id}/access — grant rows for the shared link.
    func getSharedChatAccess(chatId: String) async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/shared/\(chatId)/access")
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// POST /api/v1/chats/shared/{chat_id}/access/update — replaces the grant list.
    func updateSharedChatAccess(chatId: String, grants: [[String: Any]]) async throws {
        _ = try await network.requestJSON(
            path: "/api/v1/chats/shared/\(chatId)/access/update", method: .post,
            body: ["access_grants": grants])
    }

    // MARK: Archived chats

    /// GET /api/v1/chats/archived/count
    func getArchivedChatCount() async throws -> Int {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/archived/count")
        return (try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? Int) ?? 0
    }

    /// GET /api/v1/chats/all/archived — every archived chat, raw JSON array (for export).
    func exportArchivedChats() async throws -> Data {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/all/archived", timeout: 600)
        return data
    }

    // MARK: Full chat export (web: DataControls "Export Chats")

    /// GET /api/v1/chats/all — NDJSON stream of the user's full chats, returned as a JSON array
    /// (the same file the web downloads, re-importable on any Open WebUI server).
    func exportMyChats() async throws -> Data {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/all", timeout: 900)
        return Self.ndjsonToJSONArray(data)
    }

    /// GET /api/v1/chats/all/db (admin, needs ENABLE_ADMIN_EXPORT) — every user's chats.
    func exportAllUsersChats() async throws -> Data {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/all/db", timeout: 900)
        return data
    }

    nonisolated static func ndjsonToJSONArray(_ data: Data) -> Data {
        // Already a JSON array (older servers) → pass through.
        if let first = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }), first == UInt8(ascii: "[") {
            return data
        }
        var out = Data("[".utf8)
        var firstItem = true
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x0D })
            guard !trimmed.isEmpty, (try? JSONSerialization.jsonObject(with: Data(trimmed))) != nil else { continue }
            if !firstItem { out.append(UInt8(ascii: ",")) }
            out.append(contentsOf: trimmed)
            firstItem = false
        }
        out.append(UInt8(ascii: "]"))
        return out
    }

    // MARK: OAuth tool sessions

    /// DELETE /api/v1/auths/oauth/sessions/{provider} — e.g. `mcp:<server id>`.
    func deleteOAuthSession(provider: String) async throws {
        _ = try await network.requestRaw(path: "/api/v1/auths/oauth/sessions/\(provider)", method: .delete)
    }

    // MARK: Usage

    /// GET /api/usage → active user count and models running now (403 for non-admins
    /// unless the admin enabled the public active-users count).
    func getUsage() async throws -> UsageInfo {
        let json = try await network.requestJSON(path: "/api/usage")
        return UsageInfo(userCount: json["user_count"] as? Int ?? 0, modelIds: json["model_ids"] as? [String] ?? [])
    }

    // MARK: Chat stats

    /// GET /api/v1/chats/stats/export/{chat_id} — anonymised stats for one chat (web "Sync stats").
    func exportChatStats(chatId: String) async throws -> Data {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/stats/export/\(chatId)")
        return data
    }

    /// GET /api/v1/chats/stats/export?stream=true — anonymised stats for every chat, as a JSON array.
    func exportAllChatStats() async throws -> Data {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/stats/export", queryItems: [URLQueryItem(name: "stream", value: "true")], timeout: 900)
        return Self.ndjsonToJSONArray(data)
    }
}
