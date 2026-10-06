import SwiftUI

extension APIClient {
    /// GET /api/v1/groups/id/{id}/preview — what the group can access (admin).
    /// Returns sections: models / knowledge / tools, each `{ items: [{id,name}], total }`.
    func getGroupPreview(id: String) async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/groups/id/\(id)/preview")
    }

    /// GET /api/v1/groups/id/{id}/export — group with member user ids (raw JSON).
    func exportGroup(id: String) async throws -> Data {
        let (data, _) = try await network.requestRaw(path: "/api/v1/groups/id/\(id)/export")
        return data
    }
}

/// Audit view: which models, knowledge bases and tools a group can read.
struct GroupPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    let groupId: String
    let groupName: String

    @State private var sections: [(title: String, items: [String], total: Int)] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(sections, id: \.title) { s in
                    Section("\(s.title) — \(s.items.count) of \(s.total)") {
                        if s.items.isEmpty {
                            Text("No access").foregroundStyle(theme.textTertiary)
                        }
                        ForEach(s.items, id: \.self) { Text($0) }
                    }
                }
            }
            .navigationTitle(groupName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = dependencies.apiClient else { return }
        do {
            let json = try await api.getGroupPreview(id: groupId)
            func section(_ key: String, _ title: String) -> (String, [String], Int) {
                let block = json[key] as? [String: Any] ?? [:]
                let names = (block["items"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                return (title, names, block["total"] as? Int ?? names.count)
            }
            sections = [section("models", "Models"), section("knowledge", "Knowledge"), section("tools", "Tools")]
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }
}
