import Foundation
import CryptoKit
import Observation

/// Unsynced edits are durable data, separate from the replaceable Notes cache.
@MainActor final class NoteDraftStore {
    struct Identity: Equatable {
        let server: String
        let account: String
    }
    struct Entry: Codable {
        var revision = UUID()
        var original: Note
        var edited: Note
    }

    let identity: Identity
    private let directory: URL
    private static var activeSaves: Set<URL> = []

    func beginSave(_ id: String) -> Bool { Self.activeSaves.insert(url(id)).inserted }
    func endSave(_ id: String) { Self.activeSaves.remove(url(id)) }

    enum Failure: LocalizedError {
        case saveInProgress
        var errorDescription: String? { "A save is still in progress. Try again when it finishes." }
    }

    init(identity: Identity, root: URL = URL.applicationSupportDirectory.appendingPathComponent("NoteDrafts")) {
        self.identity = identity
        // Length-prefix each field; neither paths nor credentials become filenames.
        directory = root.appendingPathComponent(Self.hash("\(identity.server.utf8.count):\(identity.server)\(identity.account)"))
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func url(_ id: String) -> URL { directory.appendingPathComponent(Self.hash(id)).appendingPathExtension("json") }

    func load(_ id: String) throws -> Entry? {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
    }

    func pendingNotes() throws -> [Note] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)).edited }
    }

    func stage(original: Note, edited: Note) throws {
        let pending = try load(edited.id)
        if pending?.edited.title == edited.title && pending?.edited.content == edited.content { return }
        let base = pending?.original ?? original
        try write(Entry(original: base, edited: edited))
    }

    /// A late save cannot delete a newer edit made while the request was running.
    func acknowledge(_ sent: Entry, saved: Note) throws {
        guard var latest = try load(sent.edited.id) else { return }
        if latest.revision == sent.revision {
            try remove(sent.edited.id)
        } else {
            if latest.edited.title == sent.edited.title { latest.edited.title = saved.title }
            if latest.edited.content == sent.edited.content { latest.edited.content = saved.content }
            latest.original = saved
            try write(latest)
        }
    }

    func discard(_ id: String) throws {
        guard !Self.activeSaves.contains(url(id)) else { throw Failure.saveInProgress }
        try remove(id)
    }

    private func remove(_ id: String) throws {
        let file = url(id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func write(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try JSONEncoder().encode(entry).write(to: url(entry.edited.id),
                                             options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// One editor's save coordinator. Recovered/failed edits require an explicit retry.
@MainActor @Observable final class NoteDraftSession {
    let store: NoteDraftStore
    let noteID: String
    private let api: APIClient
    private let token: String?
    private let isCurrent: () -> Bool
    private(set) var requiresRetry: Bool
    private(set) var isSaving = false
    private(set) var error: Failure?

    enum Failure: String, LocalizedError {
        case server = "Couldn’t save to the server. Your changes are saved on this device."
        case conflict = "The server note has changed. Copy your saved text before reloading the server version."
        case storage = "Couldn’t save your changes on this device. Keep this editor open and copy your text."
        var errorDescription: String? { rawValue }
    }

    init(noteID: String, api: APIClient, store: NoteDraftStore, isCurrent: @escaping () -> Bool) throws {
        self.noteID = noteID
        self.api = api
        self.store = store
        self.token = api.network.authToken
        self.isCurrent = isCurrent
        self.requiresRetry = try store.load(noteID) != nil
    }

    func stage(original: Note, title: String, content: String) -> Bool {
        var edited = original
        edited.title = title
        edited.content = content
        edited.updatedAt = .now
        do {
            try store.stage(original: original, edited: edited)
            if error == .storage { error = nil }
            return true
        } catch {
            self.error = .storage
            return false
        }
    }

    func save() async -> Note? {
        guard !isSaving, store.beginSave(noteID) else { return nil }
        isSaving = true
        defer { isSaving = false; store.endSave(noteID) }
        do {
            try checkSession()
            guard let entry = try store.load(noteID) else { return nil }
            let titleChanged = entry.edited.title != entry.original.title
            let bodyChanged = entry.edited.content != entry.original.content
            if requiresRetry {
                let remote = try await request()
                if (!titleChanged || remote.title == entry.edited.title)
                    && (!bodyChanged || remote.content == entry.edited.content) {
                    try store.acknowledge(entry, saved: remote)
                    requiresRetry = false
                    error = nil
                    return remote
                }
                guard (!titleChanged || remote.title == entry.original.title)
                        && (!bodyChanged || remote.content == entry.original.content) else {
                    error = .conflict
                    return nil
                }
            }
            var body: [String: Any] = [:]
            if titleChanged { body["title"] = entry.edited.title }
            if bodyChanged {
                body["data"] = ["content": ["md": entry.edited.content, "html": "", "json": NSNull()]]
            }
            let saved = body.isEmpty ? entry.original : try await request(body: body)
            guard (!titleChanged || saved.title == entry.edited.title)
                    && (!bodyChanged || saved.content == entry.edited.content) else { throw Failure.server }
            try store.acknowledge(entry, saved: saved)
            requiresRetry = false
            error = nil
            return saved
        } catch {
            requiresRetry = true
            self.error = .server
            return nil
        }
    }

    private func checkSession() throws {
        try Task.checkCancellation()
        guard isCurrent(), token != nil, token == api.network.authToken else { throw CancellationError() }
    }

    private func request(body: [String: Any]? = nil) async throws -> Note {
        try checkSession()
        // Build on this actor before suspension: an account switch must not substitute
        // credentials. Use the existing authenticated session, with no automatic retry.
        let request = try api.network.buildRequest(path: "/api/v1/notes/\(noteID)" + (body == nil ? "" : "/update"),
                                                  method: body == nil ? .get : .post,
                                                  body: try body.map { try JSONSerialization.data(withJSONObject: $0) })
        let (data, response) = try await api.network.session.data(for: request)
        try checkSession()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let note = Note.fromServerJSON(json), note.id == noteID else { throw Failure.server }
        return note
    }
}
