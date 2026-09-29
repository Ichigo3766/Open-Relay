import Foundation
import Observation

struct NoteLinkedChat: Decodable, Identifiable {
    let id: String
    let title: String
}

extension APIClient {
    /// Both native GET routes can write chat state. Do not retry/deduplicate them.
    func noteChat(id: String, create: Bool = false) async throws -> Conversation {
        let (data, _) = try await network.requestRaw(path: "/api/v1/notes/\(id)/chat",
                                                    method: create ? .post : .get, deduplicate: false)
        return try await Task.detached(priority: .userInitiated) {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chatId = json["id"] as? String, !chatId.isEmpty,
                  json["chat"] is [String: Any] else { throw CocoaError(.coderReadCorrupt) }
            return self.parseFullConversation(json)
        }.value
    }

    func noteChats(id: String) async throws -> [NoteLinkedChat] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/notes/\(id)/chats", deduplicate: false)
        return try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode([NoteLinkedChat].self, from: data)
        }.value
    }
}

/// A note's hidden chats belong to the account that opened the editor.
@MainActor @Observable
final class NoteChatSession {
    let noteId: String
    let api: APIClient
    private let token: String?
    private let isCurrent: () -> Bool
    private(set) var chats: [NoteLinkedChat] = []
    private(set) var isBusy = false
    var error: String?
    var revision = 0

    init(noteId: String, api: APIClient, isCurrent: @escaping () -> Bool) {
        self.noteId = noteId
        self.api = api
        self.token = api.network.authToken
        self.isCurrent = isCurrent
    }

    func checkSession() throws {
        try Task.checkCancellation()
        guard isCurrent(), token != nil, token == api.network.authToken else { throw CancellationError() }
    }

    /// Called only by an explicit Chat action, never by merely viewing a note.
    func open(title: String, content: String) async throws -> Conversation {
        try checkSession()
        guard !isBusy else { throw CancellationError() }
        isBusy = true
        defer { isBusy = false }
        // Do not let a chat edit stale server content while the editor has unsaved text.
        let note = try await api.getNoteById(noteId)
        try checkSession()
        let saved = Note.fromServerJSON(note)
        guard saved?.id == noteId, saved?.title == title, saved?.content == content else {
            throw OpenError.unsavedNote
        }
        let chat = try await api.noteChat(id: noteId)
        try checkSession()
        chats = [NoteLinkedChat(id: chat.id, title: chat.title)]
        return chat
    }

    /// New embedded drafts stay local until their first message is sent.
    func create() async throws -> Conversation {
        try checkSession()
        guard !isBusy else { throw CancellationError() }
        isBusy = true
        defer { isBusy = false }
        let chat = try await api.noteChat(id: noteId, create: true)
        try checkSession()
        chats.insert(NoteLinkedChat(id: chat.id, title: chat.title), at: 0)
        return chat
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try checkSession()
            let result = try await api.noteChats(id: noteId)
            try checkSession()
            chats = result
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = "Couldn’t load note chats. Please try again."
        }
    }

    private enum OpenError: LocalizedError {
        case unsavedNote
        var errorDescription: String? { "Save your note before opening its chat. The server does not have the current text yet." }
    }
}
