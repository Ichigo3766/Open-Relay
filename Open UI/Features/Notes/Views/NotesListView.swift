import SwiftUI

/// Displays a searchable list of notes with time-based grouping,
/// pinned section, and swipe actions for delete/pin.
struct NotesListView: View {
    @State private var viewModel = NotesListViewModel()
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.notes.isEmpty {
                loadingView
            } else if viewModel.notes.isEmpty {
                emptyStateView
            } else {
                notesList
            }
        }
        .navigationTitle("Notes")
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .noteEditor(let noteId):
                NoteEditorView(noteId: noteId)
            default:
                EmptyView()
            }
        }
        .searchable(
            text: $viewModel.searchText,
            prompt: "Search notes"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        if let note = await viewModel.createNote() {
                            router.navigate(to: .noteEditor(noteId: note.id))
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .refreshable {
            await viewModel.refreshNotes()
        }
        .task {
            if let manager = dependencies.notesManager {
                viewModel.configure(with: manager)
            }
            await viewModel.loadNotes()
        }
        .destructiveConfirmation(
            isPresented: .init(
                get: { viewModel.deletingNote != nil },
                set: { if !$0 { viewModel.deletingNote = nil } }
            ),
            title: "Delete Note",
            message: "This action cannot be undone.",
            destructiveTitle: "Delete"
        ) {
            if let note = viewModel.deletingNote {
                Task { await viewModel.deleteNote(note) }
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Loading notes…")
                .font(AppTypography.bodyMediumFont)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ContentUnavailableView {
            SwiftUI.Label("No Notes", systemImage: "note.text")
        } description: {
            Text("Create your first note to get started.")
        } actions: {
            Button {
                Task {
                    if let note = await viewModel.createNote() {
                        router.navigate(to: .noteEditor(noteId: note.id))
                    }
                }
            } label: {
                Text("New Note")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Notes List

    private var notesList: some View {
        List {
            // Pinned section
            if !viewModel.pinnedNotes.isEmpty {
                Section {
                    ForEach(viewModel.pinnedNotes) { note in
                        noteRow(note, isPinned: true)
                    }
                } header: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                        Text("Pinned")
                    }
                    .foregroundStyle(theme.brandPrimary)
                }
            }

            // Time-grouped sections
            ForEach(viewModel.groupedNotes, id: \.0) { section, notes in
                Section(section) {
                    ForEach(notes) { note in
                        noteRow(note, isPinned: false)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.easeInOut(duration: AnimDuration.medium), value: viewModel.notes.count)
    }

    // MARK: - Note Row

    private func noteRow(_ note: Note, isPinned: Bool) -> some View {
        NavigationLink(value: Route.noteEditor(noteId: note.id)) {
            NoteRowView(note: note)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                viewModel.deletingNote = note
            } label: {
                SwiftUI.Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                viewModel.togglePin(note)
            } label: {
                SwiftUI.Label(
                    isPinned ? "Unpin" : "Pin",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            .tint(theme.brandPrimary)
        }
        .contextMenu {
            Button {
                viewModel.togglePin(note)
            } label: {
                SwiftUI.Label(
                    isPinned ? "Unpin" : "Pin",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            Button(role: .destructive) {
                viewModel.deletingNote = note
            } label: {
                SwiftUI.Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Note Row View

private struct NoteRowView: View {
    let note: Note
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(AppTypography.bodyMediumFont)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(note.updatedAt.chatTimestamp)
                    .font(AppTypography.captionFont)
                    .foregroundStyle(theme.textTertiary)
            }

            if !note.contentPreview.isEmpty {
                Text(note.contentPreview)
                    .font(AppTypography.bodySmallFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: Spacing.sm) {
                // Word count
                Text("\(note.wordCount) words")
                    .font(AppTypography.captionFont)
                    .foregroundStyle(theme.textTertiary)

                // Audio indicator
                if !note.audioAttachments.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10))
                        Text("\(note.audioAttachments.count)")
                    }
                    .font(AppTypography.captionFont)
                    .foregroundStyle(theme.brandPrimary)
                }

                // File indicator
                if !note.fileAttachments.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10))
                        Text("\(note.fileAttachments.count)")
                    }
                    .font(AppTypography.captionFont)
                    .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                // Tags
                ForEach(note.tags.prefix(2), id: \.self) { tag in
                    Text(tag)
                        .font(AppTypography.captionFont)
                        .pillStyle(
                            background: theme.brandPrimary.opacity(OpacityLevel.subtle),
                            foreground: theme.brandPrimary
                        )
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}
