import SwiftUI

/// Destination picker for moving files/folders inside a knowledge base.
/// There is no "all directories" endpoint, so it browses one level at a time
/// through `GET /knowledge/{id}/files?directory_id=`.
struct KnowledgeMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    let knowledgeId: String
    /// Folder being moved (cannot be moved into itself or its own subtree).
    let excludedDirectoryId: String?
    let title: String
    let onPick: (String?) -> Void   // nil = root

    @State private var currentId: String? = nil
    @State private var folders: [KnowledgeDirectory] = []
    @State private var crumbs: [KnowledgeDirectory] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(currentId)
                        dismiss()
                    } label: {
                        Label("Move here", systemImage: "arrow.down.to.line")
                            .foregroundStyle(theme.brandPrimary)
                    }
                }
                if currentId != nil {
                    Button {
                        Task { await go(parentOfCurrent) }
                    } label: {
                        Label("Up", systemImage: "arrow.up.left")
                    }
                }
                Section(crumbs.isEmpty ? "All files" : crumbs.map(\.name).joined(separator: " / ")) {
                    if isLoading {
                        ProgressView()
                    } else if folders.isEmpty {
                        Text("No folders").foregroundStyle(theme.textTertiary)
                    } else {
                        ForEach(folders) { dir in
                            Button { Task { await go(dir.id) } } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(theme.brandPrimary)
                                    Text(dir.name).foregroundStyle(theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .task { await go(nil) }
        }
    }

    private var parentOfCurrent: String? {
        crumbs.count >= 2 ? crumbs[crumbs.count - 2].id : nil
    }

    private func go(_ id: String?) async {
        guard let api = dependencies.apiClient else { return }
        isLoading = true
        currentId = id
        if let page = try? await api.getKnowledgeFolderPage(knowledgeId: knowledgeId, directoryId: id ?? "") {
            folders = page.directories.filter { $0.id != excludedDirectoryId }
            crumbs = page.breadcrumbs
            // A folder can't be moved into its own subtree.
            if let ex = excludedDirectoryId, page.breadcrumbs.contains(where: { $0.id == ex }) { folders = [] }
        }
        isLoading = false
    }
}
