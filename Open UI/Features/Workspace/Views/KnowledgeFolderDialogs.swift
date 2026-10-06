import SwiftUI

/// Alerts and sheets for Knowledge folder operations (new / rename / delete folder,
/// rename file, move). Kept as a modifier so `KnowledgeEditorView`'s chain stays short.
struct KnowledgeFolderDialogs: ViewModifier {
    let knowledgeId: String?

    @Binding var showNewFolder: Bool
    @Binding var newFolderName: String
    @Binding var renamingDirectory: KnowledgeDirectory?
    @Binding var renameDirectoryName: String
    @Binding var deletingDirectory: KnowledgeDirectory?
    @Binding var renamingFile: KnowledgeFileEntry?
    @Binding var renameFileName: String
    @Binding var showMoveSheet: Bool
    @Binding var movingFileIds: [String]
    @Binding var movingDirectory: KnowledgeDirectory?

    let onCreateFolder: (String) -> Void
    let onRenameFolder: (KnowledgeDirectory, String) -> Void
    let onDeleteFolder: (KnowledgeDirectory, Bool) -> Void   // moveFiles
    let onRenameFile: (KnowledgeFileEntry, String) -> Void
    let onMove: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    let n = newFolderName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { onCreateFolder(n) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename Folder", isPresented: .init(
                get: { renamingDirectory != nil },
                set: { if !$0 { renamingDirectory = nil } }
            )) {
                TextField("Folder name", text: $renameDirectoryName)
                Button("Rename") {
                    let n = renameDirectoryName.trimmingCharacters(in: .whitespaces)
                    if let d = renamingDirectory, !n.isEmpty, n != d.name { onRenameFolder(d, n) }
                    renamingDirectory = nil
                }
                Button("Cancel", role: .cancel) { renamingDirectory = nil }
            }
            .alert("Rename File", isPresented: .init(
                get: { renamingFile != nil },
                set: { if !$0 { renamingFile = nil } }
            )) {
                TextField("File name", text: $renameFileName)
                Button("Rename") {
                    let n = renameFileName.trimmingCharacters(in: .whitespaces)
                    if let f = renamingFile, !n.isEmpty { onRenameFile(f, n) }
                    renamingFile = nil
                }
                Button("Cancel", role: .cancel) { renamingFile = nil }
            }
            .confirmationDialog(
                "Delete \"\(deletingDirectory?.name ?? "")\"?",
                isPresented: .init(
                    get: { deletingDirectory != nil },
                    set: { if !$0 { deletingDirectory = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete folder, keep files") {
                    if let d = deletingDirectory { onDeleteFolder(d, true) }
                    deletingDirectory = nil
                }
                Button("Delete folder and its files", role: .destructive) {
                    if let d = deletingDirectory { onDeleteFolder(d, false) }
                    deletingDirectory = nil
                }
                Button("Cancel", role: .cancel) { deletingDirectory = nil }
            } message: {
                Text("Files can be moved up to the parent folder or removed with the folder.")
            }
            .sheet(isPresented: $showMoveSheet, onDismiss: {
                // Cancelling must not leave a stale target behind for the next Move.
                movingDirectory = nil
                movingFileIds = []
            }) {
                if let knowledgeId {
                    KnowledgeMoveSheet(
                        knowledgeId: knowledgeId,
                        excludedDirectoryId: movingDirectory?.id,
                        title: movingDirectory != nil ? "Move Folder" : "Move Files",
                        onPick: onMove)
                    .presentationDetents([.medium, .large])
                }
            }
    }
}
