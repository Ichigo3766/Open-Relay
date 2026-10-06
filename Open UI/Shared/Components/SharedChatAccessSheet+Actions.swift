import SwiftUI

extension SharedChatAccessSheet {
    func add(userIds: [String], groupIds: [String]) async {
        for u in userIds where !grants.contains(where: { $0.userId == u }) {
            grants.append(AccessGrant(id: UUID().uuidString, userId: u, groupId: nil, read: true, write: false))
        }
        for g in groupIds where !grants.contains(where: { $0.groupId == g }) {
            grants.append(AccessGrant(id: UUID().uuidString, userId: nil, groupId: g, read: true, write: false))
        }
        await save()
    }

    func load() async {
        guard let api = dependencies.apiClient else { return }
        do {
            let rows = try await api.getSharedChatAccess(chatId: chatId)
            func wildcard(_ type: String) -> Bool {
                rows.contains { $0["principal_id"] as? String == "*" && $0["principal_type"] as? String == type }
            }
            if wildcard("anyone") { visibility = .open } else if wildcard("user") { visibility = .public }
            let specific = rows.filter { $0["principal_id"] as? String != "*" }
            grants = AccessGrant.mergedByUser(specific.compactMap { AccessGrant.fromJSON($0) })
        } catch { self.error = error.localizedDescription }
        users = (try? await api.searchAllUsers()) ?? []
        if let list = try? await api.getGroups() { for g in list { groups[g.id] = g } }
        isLoading = false
    }

    func save() async {
        guard let api = dependencies.apiClient, !isLoading else { return }
        isSaving = true
        var rows: [[String: Any]] = grants.map { g in
            if let uid = g.userId { return ["principal_type": "user", "principal_id": uid, "permission": "read"] }
            return ["principal_type": "group", "principal_id": g.groupId ?? "", "permission": "read"]
        }
        switch visibility {
        case .private: break
        case .public: rows.append(["principal_type": "user", "principal_id": "*", "permission": "read"])
        case .open: rows.append(["principal_type": "anyone", "principal_id": "*", "permission": "read"])
        }
        do {
            try await api.updateSharedChatAccess(chatId: chatId, grants: rows)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
