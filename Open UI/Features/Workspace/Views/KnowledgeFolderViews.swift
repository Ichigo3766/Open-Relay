import SwiftUI

// MARK: - Knowledge folder navigation UI
//
// Breadcrumbs, search/sort row and folder rows for the knowledge file list.

struct KnowledgeBreadcrumbBar: View {
    @Environment(\.theme) private var theme
    let breadcrumbs: [KnowledgeDirectory]
    let onSelect: (String?) -> Void

    var body: some View {
        if !breadcrumbs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    crumb("All files", id: nil, current: false)
                    ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { i, dir in
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                        crumb(dir.name, id: dir.id, current: i == breadcrumbs.count - 1)
                    }
                }
            }
        }
    }

    private func crumb(_ title: String, id: String?, current: Bool) -> some View {
        Button { if !current { onSelect(id) } } label: {
            Text(title)
                .scaledFont(size: 13, weight: current ? .semibold : .regular)
                .foregroundStyle(current ? theme.textPrimary : theme.brandPrimary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(current)
    }
}

struct KnowledgeFolderRow: View {
    @Environment(\.theme) private var theme
    let directory: KnowledgeDirectory
    let canWrite: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "folder.fill")
                    .scaledFont(size: 20)
                    .foregroundStyle(theme.brandPrimary.opacity(0.85))
                    .frame(width: 36)
                Text(directory.name)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if canWrite {
                Button("Rename", systemImage: "pencil", action: onRename)
                Button("Move", systemImage: "folder", action: onMove)
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
    }
}

/// Search field + sort menu + "New Folder" shown above the file list.
struct KnowledgeFileToolbar: View {
    @Environment(\.theme) private var theme
    @Binding var search: String
    @Binding var sort: KnowledgeFileSort
    let canWrite: Bool
    let isSearching: Bool
    let onNewFolder: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField("Search files", text: $search)
                    .scaledFont(size: 14)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(theme.surfaceContainer.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

            Menu {
                ForEach(KnowledgeFileSort.allCases) { option in
                    Button { sort = option } label: {
                        if sort == option { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").foregroundStyle(theme.textTertiary)
            }
            if canWrite && !isSearching {
                Button(action: onNewFolder) {
                    Image(systemName: "folder.badge.plus").foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Folder")
            }
        }
    }
}
