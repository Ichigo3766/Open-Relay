import Foundation
import Observation

struct NoteAccessGrant: Codable, Hashable, Identifiable, Sendable {
    let principalType: String
    let principalId: String
    let permission: String
    var id: String { "\(principalType):\(principalId)" }
    enum CodingKeys: String, CodingKey {
        case principalType = "principal_type", principalId = "principal_id", permission
    }
}

struct NoteAccessSnapshot: Decodable, Sendable {
    let id: String
    let userId: String
    let writeAccess: Bool?
    let accessGrants: [NoteAccessGrant]
    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", writeAccess = "write_access", accessGrants = "access_grants"
    }
}

extension APIClient {
    func getNoteAccess(id: String) async throws -> NoteAccessSnapshot {
        let (data, _) = try await network.requestRaw(path: "/api/v1/notes/\(id)")
        return try JSONDecoder().decode(NoteAccessSnapshot.self, from: data)
    }

    func updateNoteAccess(id: String, grants: [NoteAccessGrant]) async throws -> NoteAccessSnapshot {
        let body = try JSONEncoder().encode(["access_grants": grants])
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/notes/\(id)/access/update", method: .post,
            body: body, contentType: "application/json")
        let result = try JSONDecoder().decode(NoteAccessSnapshot.self, from: data)
        guard result.id == id else { throw APIError.responseDecoding(underlying: CocoaError(.coderReadCorrupt), data: nil) }
        return result
    }
}

@MainActor @Observable final class NoteSharingModel {
    let api: APIClient
    let user: User
    let noteId: String
    private let token: String?
    private let isCurrent: () -> Bool
    private(set) var note: NoteAccessSnapshot?
    private(set) var isBusy = false
    var error: String?

    init(noteId: String, api: APIClient, user: User, isCurrent: @escaping () -> Bool) {
        self.noteId = noteId
        self.api = api
        self.user = user
        self.token = api.network.authToken
        self.isCurrent = isCurrent
    }

    var canManage: Bool {
        guard let note, sessionIsCurrent else { return false }
        return note.writeAccess != false && (user.role == .admin || note.userId == user.id)
    }
    private var sessionIsCurrent: Bool { isCurrent() && api.network.authToken == token }
    var allowsUsers: Bool { user.role == .admin || (user.permissions?.accessGrants.allowUsers ?? true) }
    var allowsGroups: Bool { user.role == .admin || (user.permissions?.accessGrants.allowGroups ?? true) }
    var allowsSharing: Bool { user.role == .admin || user.permissions?.sharing.notes == true }
    var allowsPublic: Bool { user.role == .admin || user.permissions?.sharing.publicNotes == true }
    var grants: [NoteAccessGrant] { note?.accessGrants ?? [] }
    var entries: [NoteAccessGrant] {
        // Native write access may arrive as separate read and write grants.
        var result: [NoteAccessGrant] = []
        for grant in grants where !(grant.principalType == "user" && grant.principalId == "*") {
            if let index = result.firstIndex(where: { $0.id == grant.id }) {
                if grant.permission == "write" { result[index] = grant }
            } else { result.append(grant) }
        }
        return result
    }
    var publicPermission: String {
        let permissions = grants.filter { $0.principalType == "user" && $0.principalId == "*" }.map(\.permission)
        return permissions.contains("write") ? "write" : permissions.contains("read") ? "read" : "private"
    }

    func canChange(type: String, id: String) -> Bool {
        guard canManage else { return false }
        if type == "user", id == "*" { return allowsPublic }
        return allowsSharing && ((type == "user" && allowsUsers) || (type == "group" && allowsGroups))
    }

    func load() async {
        guard !isBusy, sessionIsCurrent else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            let result = try await api.getNoteAccess(id: noteId)
            try Task.checkCancellation()
            guard sessionIsCurrent else { return }
            guard result.id == noteId else { throw CocoaError(.coderReadCorrupt) }
            note = result
        } catch is CancellationError {} catch { if sessionIsCurrent { self.error = error.localizedDescription } }
    }

    func setAccess(type: String, id: String, permission: String?) async {
        guard !isBusy, !id.isEmpty, canChange(type: type, id: id),
              permission == nil || permission == "read" || permission == "write" else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        var updated = grants.filter { !($0.principalType == type && $0.principalId == id) }
        if let permission {
            if permission == "write" {
                updated.append(NoteAccessGrant(principalType: type, principalId: id, permission: "read"))
            }
            updated.append(NoteAccessGrant(principalType: type, principalId: id, permission: permission))
        }
        do {
            let saved = try await api.updateNoteAccess(id: noteId, grants: updated)
            try Task.checkCancellation()
            guard sessionIsCurrent else { return }
            // Use the server's filtered grants, not the optimistic request.
            note = NoteAccessSnapshot(id: saved.id, userId: saved.userId,
                                      writeAccess: note?.writeAccess, accessGrants: saved.accessGrants)
        } catch is CancellationError {} catch { if sessionIsCurrent { self.error = error.localizedDescription } }
    }
}
