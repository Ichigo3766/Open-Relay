import SwiftUI

// MARK: - Notes Picker Sheet

/// A bottom sheet that lists user notes and lets the caller pick one.
/// On selection the `onNoteSelected` callback is invoked with the chosen `Note`
/// so the caller can inject the note's content into the message composer.
struct NotesPickerSheet: View {
    @Binding var isPresented: Bool
    var notesManager: NotesManager?
    var onNoteSelected: (Note) -> Void

    @Environment(\.theme) private var theme
    @State private var notes: [Note] = []
    @State private var isLoading = false
    @State private var searchText = ""

    private var filteredNotes: [Note] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return notes }
        let q = searchText.lowercased()
        return notes.filter {
            $0.title.lowercased().contains(q) ||
            $0.content.lowercased().contains(q) ||
            $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredNotes.isEmpty {
                    emptyState
                } else {
                    List(filteredNotes) { note in
                        noteRow(note)
                            .listRowBackground(theme.cardBackground)
                            .listRowSeparatorTint(theme.cardBorder.opacity(0.4))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.background)
            .navigationTitle("Attach Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { isPresented = false }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
            }
            .searchable(text: $searchText, prompt: "Search notes")
        }
        .background(theme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(CornerRadius.modal)
        .task { await loadNotes() }
    }

    // MARK: - Note Row

    private func noteRow(_ note: Note) -> some View {
        Button {
            onNoteSelected(note)
            isPresented = false
        } label: {
            HStack(spacing: Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.brandPrimary.opacity(0.18), theme.brandPrimary.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: "note.text")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if !note.content.isEmpty {
                        Text(note.content)
                            .scaledFont(size: 12, weight: .regular)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }

                    if !note.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(note.tags.prefix(3), id: \.self) { tag in
                                Text(tag)
                                    .scaledFont(size: 10, weight: .medium)
                                    .foregroundStyle(theme.brandPrimary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(theme.brandPrimary.opacity(0.1)))
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()

                Image(systemName: "plus.circle")
                    .scaledFont(size: 18, weight: .medium)
                    .foregroundStyle(theme.brandPrimary.opacity(0.7))
            }
            .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "note.text")
                .scaledFont(size: 40, weight: .light)
                .foregroundStyle(theme.textTertiary)
            Text(searchText.isEmpty ? "No notes yet" : "No matching notes")
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(theme.textSecondary)
            if searchText.isEmpty {
                Text("Create notes to reference them in your chats")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load Notes

    private func loadNotes() async {
        guard let manager = notesManager else { return }
        isLoading = true
        notes = await manager.fetchNotes()
        isLoading = false
    }
}
