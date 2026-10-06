import SwiftUI

// MARK: - Workspace Model list filter bar
//
// Mirrors the web Models page controls: view (All / Created by you / Shared with you),
// tag, sort, and (admin) bulk actions. Filtering and sorting are done by the server
// (`GET /api/v1/models/list?view_option=&tag=&order_by=&direction=`).

enum ModelBulkAction: String, Identifiable {
    case enableAll = "Enable All", disableAll = "Disable All", showAll = "Show All", hideAll = "Hide All"
    var id: String { rawValue }
}

struct ModelFilterBar: View {
    @Environment(\.theme) private var theme
    let manager: ModelManager
    let isAdmin: Bool
    @Binding var bulkAction: ModelBulkAction?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                viewMenu
                if !manager.tags.isEmpty { tagMenu }
                sortMenu
                if isAdmin { bulkMenu }
            }
            .padding(.horizontal, Spacing.md)
        }
        .padding(.bottom, Spacing.xs)
    }

    private var viewMenu: some View {
        Menu {
            ForEach([("", "All"), ("created", "Created by you"), ("shared", "Shared with you")], id: \.0) { opt in
                Button {
                    manager.viewOption = opt.0
                    Task { await manager.fetchAll() }
                } label: {
                    if manager.viewOption == opt.0 { Label(opt.1, systemImage: "checkmark") } else { Text(opt.1) }
                }
            }
        } label: {
            chip(icon: "person.2", text: viewLabel, active: !manager.viewOption.isEmpty)
        }
    }

    private var viewLabel: String {
        manager.viewOption == "created" ? "Created by you"
            : manager.viewOption == "shared" ? "Shared with you" : "All"
    }

    private var tagMenu: some View {
        Menu {
            Button {
                manager.selectedTag = ""
                Task { await manager.fetchAll() }
            } label: {
                if manager.selectedTag.isEmpty { Label("All", systemImage: "checkmark") } else { Text("All") }
            }
            ForEach(manager.tags, id: \.self) { tag in
                Button {
                    manager.selectedTag = tag
                    Task { await manager.fetchAll() }
                } label: {
                    if manager.selectedTag == tag { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                }
            }
        } label: {
            chip(icon: "tag", text: manager.selectedTag.isEmpty ? "Tag" : manager.selectedTag,
                 active: !manager.selectedTag.isEmpty)
        }
    }

    private var sortMenu: some View {
        Menu {
            sortButton("Default", key: "", dir: "")
            sortButton("Name (A–Z)", key: "name", dir: "asc")
            sortButton("Name (Z–A)", key: "name", dir: "desc")
            sortButton("Recently updated", key: "updated_at", dir: "desc")
            sortButton("Recently created", key: "created_at", dir: "desc")
        } label: {
            chip(icon: "arrow.up.arrow.down", text: "Sort", active: !manager.sortKey.isEmpty)
        }
    }

    private var bulkMenu: some View {
        Menu {
            Button("Enable All", systemImage: "checkmark.circle") { bulkAction = .enableAll }
            Button("Disable All", systemImage: "pause.circle") { bulkAction = .disableAll }
            Button("Show All", systemImage: "eye") { bulkAction = .showAll }
            Button("Hide All", systemImage: "eye.slash") { bulkAction = .hideAll }
        } label: {
            chip(icon: "ellipsis.circle", text: "Bulk", active: false)
        }
    }

    private func sortButton(_ title: String, key: String, dir: String) -> some View {
        Button {
            manager.sortKey = key
            manager.sortDirection = dir
            Task { await manager.fetchAll() }
        } label: {
            if manager.sortKey == key && manager.sortDirection == dir {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func chip(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).scaledFont(size: 12, weight: .medium)
            Text(text).scaledFont(size: 13, weight: active ? .semibold : .regular).lineLimit(1)
        }
        .foregroundStyle(active ? theme.brandPrimary : theme.textTertiary)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .fill(active ? theme.brandPrimary.opacity(0.12) : theme.surfaceContainer.opacity(0.5))
        )
    }
}
