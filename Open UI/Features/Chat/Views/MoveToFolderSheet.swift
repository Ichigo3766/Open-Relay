import SwiftUI

/// A sheet that presents all available folders so the user can move
/// one or more selected chats into a chosen folder.
struct MoveToFolderSheet: View {
    let folders: [ChatFolder]
    let selectedCount: Int
    /// Called with the chosen folder ID when the user picks a folder.
    let onMove: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if folders.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Folders"),
                        systemImage: "folder",
                        description: Text("Create a folder first to move chats into it.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(folders) { folder in
                                Button {
                                    onMove(folder.id)
                                    dismiss()
                                } label: {
                                    HStack(spacing: Spacing.sm) {
                                        Image(systemName: "folder.fill")
                                            .scaledFont(size: 18)
                                            .foregroundStyle(theme.brandPrimary)
                                            .frame(width: 32, height: 32)

                                        Text(folder.name)
                                            .scaledFont(size: 16, weight: .medium)
                                            .foregroundStyle(theme.textPrimary)

                                        Spacer()

                                        Text("\(folder.chats.count)")
                                            .scaledFont(size: 13)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Choose a folder")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textSecondary)
                                .textCase(nil)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(
                selectedCount == 1
                    ? String(localized: "Move 1 Chat")
                    : String(localized: "Move \(selectedCount) Chats")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel"), systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
