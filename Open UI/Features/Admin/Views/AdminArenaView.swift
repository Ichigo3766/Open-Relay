import SwiftUI

/// Arena models (`/evaluations/config`): enable toggle and the list of arena entries.
/// The server replaces the whole `EVALUATION_ARENA_MODELS` list on save, so unknown keys
/// on each entry are preserved by editing the raw dictionaries in place.
struct AdminArenaView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var enabled = false
    @State private var models: [[String: Any]] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?
    @State private var editingIndex: Int?
    @State private var showAdd = false

    var body: some View {
        List {
            Section {
                Toggle("Arena Models", isOn: $enabled).tint(theme.brandPrimary)
                Text("Blind side-by-side comparison of models; users rate the winner.")
                    .scaledFont(size: 12).foregroundStyle(theme.textTertiary)
            }
            Section("Models") {
                if models.isEmpty {
                    Text("No arena models — the server uses a default “Arena Model”.")
                        .scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                }
                ForEach(models.indices, id: \.self) { i in
                    Button { editingIndex = i } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(models[i]["name"] as? String ?? "Untitled").foregroundStyle(theme.textPrimary)
                            let ids = (models[i]["meta"] as? [String: Any])?["model_ids"] as? [String] ?? []
                            Text(ids.isEmpty ? "All models" : "\(ids.count) model\(ids.count == 1 ? "" : "s")")
                                .scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                .onDelete { models.remove(atOffsets: $0) }
                Button { showAdd = true } label: { Label("Add Arena Model", systemImage: "plus") }
            }
            if let error { Text(error).foregroundStyle(.red).scaledFont(size: 13) }
            Section {
                Button { Task { await save() } } label: {
                    if isSaving { ProgressView() } else { Text("Save").frame(maxWidth: .infinity) }
                }
                .disabled(isSaving || isLoading)
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAdd) {
            ArenaModelEditor(model: nil, takenNames: arenaNames(excluding: nil)) { models.append($0) }
        }
        .sheet(item: Binding(get: { editingIndex.map { IndexBox(i: $0) } }, set: { editingIndex = $0?.i })) { box in
            ArenaModelEditor(model: models[box.i], takenNames: arenaNames(excluding: box.i)) { models[box.i] = $0 }
        }
    }

    private struct IndexBox: Identifiable { let i: Int; var id: Int { i } }

    private func arenaNames(excluding index: Int?) -> Set<String> {
        Set(models.enumerated().compactMap { $0.offset == index ? nil : $0.element["name"] as? String })
    }

    private func load() async {
        guard let api = dependencies.apiClient else { return }
        do {
            let c = try await api.getEvaluationConfig()
            enabled = c["ENABLE_EVALUATION_ARENA_MODELS"] as? Bool ?? false
            models = c["EVALUATION_ARENA_MODELS"] as? [[String: Any]] ?? []
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }

    private func save() async {
        guard let api = dependencies.apiClient else { return }
        isSaving = true
        do {
            try await api.updateEvaluationConfig(enabled: enabled, arenaModels: models)
            error = nil
            Haptics.notify(.success)
        } catch { self.error = error.localizedDescription }
        isSaving = false
    }
}
