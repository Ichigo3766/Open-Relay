import Foundation
import CryptoKit

/// Identity contains no credentials. A new-chat draft is distinct from every saved chat.
struct DictationContext: Codable, Equatable {
    let server: String
    let account: String
    var conversation: String?
}

/// One pending recording per draft, not a recording history. Audio is never a cache.
@MainActor final class DictationRecoveryStore {
    static let shared = DictationRecoveryStore()

    struct Recording: Codable, Equatable {
        let id: UUID
        let engine: String
        var duration: TimeInterval = 0
        var completed = false
        var committed = false
    }

    struct Entry: Codable {
        var draft: String
        var recording: Recording?
    }

    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("DictationRecovery")) {
        self.directory = directory
    }

    func audioURL(_ recording: Recording) -> URL {
        directory.appendingPathComponent(recording.id.uuidString).appendingPathExtension("m4a")
    }

    private func metadataURL(_ context: DictationContext) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let hash = SHA256.hash(data: try encoder.encode(context)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("json")
    }

    func load(_ context: DictationContext) throws -> Entry? {
        let url = try metadataURL(context)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
    }

    func save(_ entry: Entry, for context: DictationContext) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(entry).write(to: metadataURL(context), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func begin(_ context: DictationContext, draft: String, engine: String) throws -> Recording {
        guard try load(context)?.recording == nil else { throw RecoveryError.pendingRecording }
        let recording = Recording(id: UUID(), engine: engine)
        try save(Entry(draft: draft, recording: recording), for: context)
        return recording
    }

    func update(_ recording: Recording, for context: DictationContext) throws {
        guard var entry = try load(context), entry.recording?.id == recording.id else {
            throw RecoveryError.missingRecording
        }
        entry.recording = recording
        try save(entry, for: context)
    }

    /// Only drafts that have used dictation are persisted; ordinary composers are unchanged.
    func saveDraft(_ text: String, for context: DictationContext) throws {
        guard var entry = try load(context), entry.draft != text else { return }
        entry.draft = text
        try save(entry, for: context)
    }

    /// The draft and delivery receipt are one atomic write, before audio can be removed.
    func commit(_ text: String, recordingID: UUID, draft: String, context: DictationContext) throws -> String {
        guard var entry = try load(context), var recording = entry.recording,
              recording.id == recordingID else { throw RecoveryError.missingRecording }
        if recording.committed { return entry.draft }
        entry.draft = draft.isEmpty ? text : draft + " " + text
        recording.committed = true
        entry.recording = recording
        try save(entry, for: context)
        return entry.draft
    }

    func discard(_ context: DictationContext) throws {
        guard var entry = try load(context), let recording = entry.recording else { return }
        let url = audioURL(recording)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        entry.recording = nil
        try save(entry, for: context)
    }

    /// Atomic rename when the server assigns an ID to the same new-chat draft.
    func move(from: DictationContext, to: DictationContext) throws {
        let source = try metadataURL(from)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.moveItem(at: source, to: metadataURL(to))
    }

    enum RecoveryError: LocalizedError {
        case pendingRecording, missingRecording, emptyTranscript, unavailable
        var errorDescription: String? {
            switch self {
            case .pendingRecording: "Finish or discard the saved recording first."
            case .missingRecording: "The saved recording could not be opened."
            case .emptyTranscript: "No transcript was returned. Try again or save the audio."
            case .unavailable: "Transcription is unavailable. Try again later."
            }
        }
    }
}
