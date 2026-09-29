import Foundation
import Observation

/// Keep the native dictionaries intact, including fields this client cannot edit.
struct NoteFileReference {
    let raw: [String: Any]
    init(_ raw: [String: Any]) {
        self.raw = raw
    }
    var fileId: String? { raw["id"] as? String ?? (raw["file"] as? [String: Any])?["id"] as? String }
    var isImage: Bool { raw["type"] as? String == "image" }
    private var metadata: [String: Any] { (raw["file"] as? [String: Any])?["meta"] as? [String: Any] ?? [:] }
    var name: String { raw["name"] as? String ?? metadata["name"] as? String ?? (isImage ? "Image" : "Attachment") }
    var size: Int64? { (raw["size"] as? NSNumber ?? metadata["size"] as? NSNumber)?.int64Value }
    var contentType: String { raw["content_type"] as? String ?? metadata["content_type"] as? String ?? "" }
    var icon: String {
        if isImage || contentType.hasPrefix("image/") { return "photo" }
        if contentType.hasPrefix("audio/") { return "waveform" }
        if contentType.hasPrefix("video/") { return "film" }
        return "doc"
    }
    func matches(_ other: NoteFileReference) -> Bool {
        if let fileId, let otherId = other.fileId {
            return fileId == otherId && raw["type"] as? String == other.raw["type"] as? String
        }
        return NSDictionary(dictionary: raw).isEqual(to: other.raw)
    }
}

extension APIClient {
    /// Files-only patch: never reconstruct the note's rich content, versions or grants.
    func saveNoteFiles(id: String, files: [NoteFileReference]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["data": ["files": files.map(\.raw)]])
        let (data, _) = try await network.requestRaw(path: "/api/v1/notes/\(id)/update", method: .post,
                                                   body: body, contentType: "application/json")
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["id"] as? String == id else { throw CocoaError(.coderReadCorrupt) }
        return result
    }
}

@MainActor @Observable final class NoteFilesModel {
    let api: APIClient
    let noteId: String
    private let token: String?
    private let isCurrent: () -> Bool
    private(set) var files: [NoteFileReference] = []
    private(set) var canEdit = false
    private(set) var isBusy = false
    private(set) var loaded = false
    private(set) var pending: NoteFileReference?
    var error: String?

    init(noteId: String, api: APIClient, isCurrent: @escaping () -> Bool) {
        self.noteId = noteId
        self.api = api
        self.token = api.network.authToken
        self.isCurrent = isCurrent
    }
    var sessionIsCurrent: Bool { isCurrent() && token == api.network.authToken }

    private func checkSession() throws {
        try Task.checkCancellation()
        guard sessionIsCurrent else { throw CancellationError() }
    }

    private func readFiles(_ note: [String: Any]) throws -> [NoteFileReference] {
        guard note["id"] as? String == noteId else { throw CocoaError(.coderReadCorrupt) }
        guard let noteData = note["data"], !(noteData is NSNull) else { return [] }
        guard let data = noteData as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        guard let value = data["files"], !(value is NSNull) else { return [] }
        guard let array = value as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
        return array.map(NoteFileReference.init)
    }

    @discardableResult
    func load() async -> [String: Any]? {
        guard !isBusy, sessionIsCurrent else { return nil }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            let note = try await api.getNoteById(noteId)
            try checkSession()
            guard note["id"] as? String == noteId else { throw CocoaError(.coderReadCorrupt) }
            canEdit = false
            do {
                files = try readFiles(note)
                canEdit = note["write_access"] as? Bool == true
                loaded = true
            } catch { report(error) }
            return note
        } catch { report(error); return nil }
    }

    func attach(data: Data, name: String) async {
        guard !isBusy, canEdit, pending == nil, sessionIsCurrent else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let (id, file) = try await api.uploadFile(data: data, fileName: name)
            try checkSession()
            var reference: [String: Any] = ["id": id, "type": "file", "name": name,
                "size": data.count, "url": id, "status": "uploaded", "file": file]
            if let collection = (file["meta"] as? [String: Any])?["collection_name"] ?? file["collection_name"] {
                reference["collection_name"] = collection
            }
            pending = NoteFileReference(reference)
            try await save(adding: pending)
        } catch { report(error) }
    }

    func retryAttachment() async {
        guard !isBusy, pending != nil, sessionIsCurrent else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do { try await save(adding: pending) } catch { report(error) }
    }

    func remove(_ file: NoteFileReference) async {
        guard !isBusy, canEdit, sessionIsCurrent else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do { try await save(removing: file) } catch { report(error) }
    }

    private func save(adding: NoteFileReference? = nil, removing: NoteFileReference? = nil) async throws {
        try checkSession()
        // Refresh before replacing the native list so unrelated recent additions survive.
        let latest = try await api.getNoteById(noteId)
        try checkSession()
        canEdit = latest["write_access"] as? Bool == true
        guard canEdit else { throw CocoaError(.fileWriteNoPermission) }
        var updated = try readFiles(latest)
        if let removing { updated.removeAll { $0.matches(removing) } }
        if let adding, !updated.contains(where: { $0.matches(adding) }) { updated.append(adding) }
        let saved = try await api.saveNoteFiles(id: noteId, files: updated)
        try checkSession()
        let confirmed = try readFiles(saved)
        if let adding, !confirmed.contains(where: { $0.matches(adding) }) { throw CocoaError(.fileWriteUnknown) }
        if let removing, confirmed.contains(where: { $0.matches(removing) }) { throw CocoaError(.fileWriteUnknown) }
        files = confirmed
        if adding != nil { pending = nil }
    }

    private func report(_ error: Error) {
        if !(error is CancellationError), !Task.isCancelled, sessionIsCurrent { self.error = error.localizedDescription }
    }
}
