import Foundation
import os.log

/// Manages the notes list state including search, grouping, and CRUD operations.
///
/// Updated to use server-backed ``NotesManager`` with async operations,
/// matching the Flutter `NotesList`, `NoteCreator`, `NoteDeleter` providers.
@MainActor @Observable
final class NotesListViewModel {

    // MARK: - State

    var notes: [Note] = []
    var searchText: String = ""
    var isLoading: Bool = false
    var errorMessage: String?

    /// Whether the notes feature is enabled on the server.
    var isFeatureEnabled: Bool = true

    /// The note being deleted (for confirmation dialog).
    var deletingNote: Note?

    // MARK: - Private

    private var manager: NotesManager?
    private var drafts: NoteDraftStore?
    private let logger = Logger(subsystem: "com.openui", category: "NotesListVM")

    /// Cached search results (updated asynchronously by `performSearch`).
    private var searchResults: [Note]?

    /// Task for debounced search.
    private var searchTask: Task<Void, Never>?

    // MARK: - Computed

    /// Notes filtered by search text.
    var filteredNotes: [Note] {
        if searchText.isEmpty { return notes }
        return searchResults ?? notes.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Pinned notes.
    var pinnedNotes: [Note] {
        filteredNotes.filter(\.isPinned)
    }

    /// Notes grouped by time range.
    var groupedNotes: [(String, [Note])] {
        let unpinned = filteredNotes.filter { !$0.isPinned }
        var groups: [(String, [Note])] = []
        var today: [Note] = []
        var yesterday: [Note] = []
        var thisWeek: [Note] = []
        var thisMonth: [Note] = []
        var older: [Note] = []

        let calendar = Calendar.current
        let now = Date.now

        for note in unpinned {
            if calendar.isDateInToday(note.updatedAt) {
                today.append(note)
            } else if calendar.isDateInYesterday(note.updatedAt) {
                yesterday.append(note)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      note.updatedAt > weekAgo {
                thisWeek.append(note)
            } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
                      note.updatedAt > monthAgo {
                thisMonth.append(note)
            } else {
                older.append(note)
            }
        }

        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { groups.append(("This Month", thisMonth)) }
        if !older.isEmpty { groups.append(("Older", older)) }

        return groups
    }

    // MARK: - Configuration

    func configure(with manager: NotesManager, drafts: NoteDraftStore? = nil) {
        if self.drafts?.identity != drafts?.identity {
            searchTask?.cancel()
            searchResults = nil
            notes = []
        }
        self.manager = manager
        self.drafts = drafts
    }

    private func withDrafts(_ notes: [Note], matching query: String? = nil) -> [Note] {
        do {
            var byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for draft in try drafts?.pendingNotes() ?? [] {
                if let query, !draft.title.localizedCaseInsensitiveContains(query),
                   !draft.content.localizedCaseInsensitiveContains(query) { continue }
                var merged = byID[draft.id] ?? draft
                merged.title = draft.title
                merged.content = draft.content
                merged.updatedAt = max(merged.updatedAt, draft.updatedAt)
                byID[draft.id] = merged
            }
            return byID.values.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            errorMessage = "Couldn’t read saved note drafts. They have not been deleted."
            return notes
        }
    }

    // MARK: - Operations

    /// Loads notes from the server (or local cache if unavailable).
    ///
    /// Matches the Flutter `NotesList.build()` which calls `api.getNotes()`
    /// and updates the `notesFeatureEnabledProvider`.
    func loadNotes() async {
        isLoading = true
        errorMessage = nil
        guard let manager else {
            isLoading = false
            return
        }
        let identity = drafts?.identity
        let result = await manager.fetchNotes()
        guard !Task.isCancelled, identity == drafts?.identity else { return }
        notes = withDrafts(result)
        isFeatureEnabled = manager.isServerEnabled
        isLoading = false
    }

    /// Refreshes the notes list from the server.
    func refreshNotes() async {
        guard let manager else { return }
        let identity = drafts?.identity
        let result = await manager.fetchNotes()
        guard !Task.isCancelled, identity == drafts?.identity else { return }
        notes = withDrafts(result)
        isFeatureEnabled = manager.isServerEnabled
    }

    /// Creates a new note on the server and returns it.
    ///
    /// Matches the Flutter `NoteCreator.createNote()` which posts to
    /// `/api/v1/notes/create`.
    @discardableResult
    func createNote() async -> Note? {
        guard let manager else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let title = dateFormatter.string(from: .now)
        let note = await manager.createNote(title: title)
        await refreshNotes()
        return note
    }

    /// Deletes a note from the server.
    ///
    /// Matches the Flutter `NoteDeleter.deleteNote()`.
    func deleteNote(_ note: Note) async {
        guard let manager else { return }
        do {
            guard try drafts?.load(note.id) == nil else {
                errorMessage = "This note has unsynced changes. Open it and retry saving or discard the local changes before deleting."
                return
            }
        } catch {
            errorMessage = "Couldn’t check saved note drafts. The note has not been deleted."
            return
        }
        await manager.deleteNote(id: note.id)
        await refreshNotes()
    }

    /// Triggers a debounced server-side search. Call from onChange of searchText.
    func triggerSearch() {
        searchTask?.cancel()
        guard searchText.count >= 2 else {
            searchResults = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let manager else { return }
            let query = searchText
            let identity = drafts?.identity
            let results = await manager.searchNotes(query: query)
            guard !Task.isCancelled, identity == drafts?.identity else { return }
            searchResults = withDrafts(results, matching: query)
        }
    }

    /// Clears search results when search text is cleared.
    func clearSearch() {
        searchResults = nil
        searchTask?.cancel()
    }

    /// Toggles a note's pinned state (local-only).
    func togglePin(_ note: Note) {
        manager?.togglePin(id: note.id)
        notes = withDrafts(manager?.fetchLocalNotes() ?? [])
    }
}
