import Foundation
import os.log

/// Manages note CRUD operations against the OpenWebUI server API.
///
/// Matches the Flutter `NotesList`, `NoteCreator`, `NoteUpdater`, and
/// `NoteDeleter` providers which use the `/api/v1/notes/` endpoints.
///
/// When the server is unavailable or the notes feature is disabled
/// (401/403), falls back to local-only UserDefaults storage.
final class NotesManager: @unchecked Sendable {
    private let apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "NotesManager")
    private let defaults = UserDefaults.standard
    private let storageKey = "com.openui.notes"

    /// Whether the notes feature is enabled on the server.
    /// Set to `false` when the server returns 401/403 for the notes endpoint.
    private(set) var isServerEnabled: Bool = true

    init(apiClient: APIClient? = nil) {
        self.apiClient = apiClient
    }

    // MARK: - Server Operations

    /// Fetches all notes from the server.
    ///
    /// On success, caches the results locally. On 401/403, marks the feature
    /// as disabled and falls back to local storage. Matches the Flutter
    /// `NotesList.build()` which calls `api.getNotes()`.
    func fetchNotes() async -> [Note] {
        guard let apiClient else {
            return fetchLocalNotes()
        }

        do {
            let (rawNotes, featureEnabled) = try await apiClient.getNotes()
            isServerEnabled = featureEnabled

            if !featureEnabled {
                logger.info("Notes feature disabled on server")
                return fetchLocalNotes()
            }

            let notes = rawNotes.compactMap { Note.fromServerJSON($0) }
                .sorted { $0.updatedAt > $1.updatedAt }

            // Cache server notes locally
            saveLocalNotes(notes)

            return notes
        } catch {
            logger.warning("Failed to fetch notes from server: \(error.localizedDescription)")
            return fetchLocalNotes()
        }
    }

    /// Creates a new note on the server.
    ///
    /// Matches the Flutter `NoteCreator.createNote()` which posts to
    /// `/api/v1/notes/create` with `title` and `data.content.md`.
    @discardableResult
    func createNote(title: String = "", content: String = "") async -> Note {
        guard let apiClient, isServerEnabled else {
            return createLocalNote(title: title, content: content)
        }

        do {
            let json = try await apiClient.createNote(
                title: title,
                markdownContent: content
            )

            if let note = Note.fromServerJSON(json) {
                // Add to local cache
                var cached = fetchLocalNotes()
                cached.insert(note, at: 0)
                saveLocalNotes(cached)
                return note
            }
        } catch {
            logger.warning("Failed to create note on server: \(error.localizedDescription)")
        }

        return createLocalNote(title: title, content: content)
    }

    /// Fetches a single note by ID from the server.
    func fetchNote(id: String) async -> Note? {
        guard let apiClient, isServerEnabled else {
            return fetchLocalNote(id: id)
        }

        do {
            let json = try await apiClient.getNoteById(id)
            if let note = Note.fromServerJSON(json) {
                return note
            }
        } catch {
            logger.warning("Failed to fetch note \(id) from server: \(error.localizedDescription)")
        }

        return fetchLocalNote(id: id)
    }

    /// Updates a note on the server.
    ///
    /// Matches the Flutter `NoteUpdater.updateNote()` which posts to
    /// `/api/v1/notes/{id}/update`.
    func updateNote(_ note: Note) async {
        // Always update local cache first
        updateLocalNote(note)

        guard let apiClient, isServerEnabled else { return }

        do {
            _ = try await apiClient.updateNote(
                id: note.id,
                title: note.title,
                markdownContent: note.content
            )
        } catch {
            logger.warning("Failed to update note on server: \(error.localizedDescription)")
        }
    }

    /// Deletes a note on the server.
    ///
    /// Matches the Flutter `NoteDeleter.deleteNote()` which calls
    /// `DELETE /api/v1/notes/{id}/delete`.
    func deleteNote(id: String) async {
        // Always delete from local cache first
        deleteLocalNote(id: id)

        guard let apiClient, isServerEnabled else { return }

        do {
            _ = try await apiClient.deleteNote(id: id)
        } catch {
            logger.warning("Failed to delete note from server: \(error.localizedDescription)")
        }
    }

    // MARK: - Local Storage (Cache / Fallback)

    /// Fetches all notes from local storage.
    func fetchLocalNotes() -> [Note] {
        guard let data = defaults.data(forKey: storageKey),
              let notes = try? JSONDecoder().decode([Note].self, from: data) else {
            return []
        }
        return notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Fetches a single note from local storage by ID.
    func fetchLocalNote(id: String) -> Note? {
        fetchLocalNotes().first { $0.id == id }
    }

    /// Saves the notes array to local storage.
    /// STORAGE FIX: Only cache the most recent 50 notes to prevent
    /// UserDefaults (plist) from growing unboundedly. Full content
    /// is always fetched from the server on demand.
    private func saveLocalNotes(_ notes: [Note]) {
        let limitedNotes = Array(notes.prefix(50))
        guard let data = try? JSONEncoder().encode(limitedNotes) else { return }
        defaults.set(data, forKey: storageKey)

        // Also save to shared container for widget access
        SharedDataService.shared.saveRecentNotes(
            notes.prefix(5).map { SharedDataService.RecentNote(id: $0.id, title: $0.title, preview: $0.contentPreview, updatedAt: $0.updatedAt) }
        )
    }

    /// Creates a note locally (fallback when server unavailable).
    @discardableResult
    private func createLocalNote(title: String, content: String) -> Note {
        let note = Note(title: title, content: content)
        var notes = fetchLocalNotes()
        notes.insert(note, at: 0)
        saveLocalNotes(notes)
        return note
    }

    /// Updates a note in local storage.
    private func updateLocalNote(_ note: Note) {
        var notes = fetchLocalNotes()
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            var updated = note
            updated.updatedAt = .now
            notes[index] = updated
            saveLocalNotes(notes)
        }
    }

    /// Deletes a note from local storage.
    private func deleteLocalNote(id: String) {
        var notes = fetchLocalNotes()
        notes.removeAll { $0.id == id }
        saveLocalNotes(notes)
    }

    // MARK: - Search

    /// Searches notes — uses server-side search when available for comprehensive results,
    /// falls back to local cache filtering when offline.
    func searchNotes(query: String) async -> [Note] {
        // Try server-side search first (covers all notes, not just cached)
        if let apiClient, isServerEnabled {
            do {
                let results = try await apiClient.searchNotes(query: query)
                let notes = results.compactMap { Note.fromServerJSON($0) }
                if !notes.isEmpty { return notes }
            } catch {
                logger.debug("Server notes search failed, falling back to local: \(error.localizedDescription)")
            }
        }

        // Fallback to local cache search
        let lowered = query.lowercased()
        return fetchLocalNotes().filter {
            $0.title.lowercased().contains(lowered) ||
            $0.content.lowercased().contains(lowered) ||
            $0.tags.contains { $0.lowercased().contains(lowered) }
        }
    }

    /// Pins or unpins a note (local-only; OpenWebUI does not have pin for notes).
    func togglePin(id: String) {
        var notes = fetchLocalNotes()
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].isPinned.toggle()
            notes[index].updatedAt = .now
            saveLocalNotes(notes)
        }
    }

    // MARK: - File Operations

    /// Uploads audio data for a note and returns the server file ID.
    func uploadAudio(data: Data, fileName: String) async throws -> String {
        guard let apiClient else {
            throw NotesError.serverUnavailable
        }
        return try await apiClient.uploadFile(data: data, fileName: fileName)
    }

    /// Uploads a file attachment for a note.
    func uploadFile(data: Data, fileName: String) async throws -> String {
        guard let apiClient else {
            throw NotesError.serverUnavailable
        }
        return try await apiClient.uploadFile(data: data, fileName: fileName)
    }
}

// MARK: - Errors

enum NotesError: LocalizedError {
    case serverUnavailable
    case noteNotFound

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            return "Server is not available. Notes are saved locally."
        case .noteNotFound:
            return "Note not found."
        }
    }
}
