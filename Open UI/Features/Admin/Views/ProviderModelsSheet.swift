import SwiftUI

/// Admin → Models → Manage → llama.cpp / LM Studio (web ManageProviderModels).
struct ProviderModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) var dependencies

    let urlIdx: Int
    let url: String
    let provider: String     // "llama.cpp" | "lmstudio"

    @State var models: [ProviderModel] = []
    @State var isLoading = true
    @State var busyModel: String?
    @State var modelRef = ""
    @State var downloadProgress: Double?
    @State var downloadStatus: String?
    @State var deleting: ProviderModel?
    @State var error: String?
    @State var info: String?

    private var label: String { provider == "lmstudio" ? "LM Studio" : "llama.cpp" }
    private var supportsDelete: Bool { provider == "llama.cpp" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(provider == "lmstudio" ? "Model key, e.g. qwen/qwen3-4b" : "Hugging Face ref, e.g. ggml-org/gemma-3-1b-it-GGUF",
                                  text: $modelRef)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button { Task { await download() } } label: { Image(systemName: "arrow.down.circle.fill") }
                            .disabled(modelRef.trimmingCharacters(in: .whitespaces).isEmpty || busyModel != nil)
                    }
                    if let downloadStatus {
                        VStack(alignment: .leading, spacing: 4) {
                            if let p = downloadProgress { ProgressView(value: p, total: 100) }
                            Text(downloadStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Download") } footer: { Text(url).lineLimit(1) }

                Section("Models") {
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if models.isEmpty {
                        Text("No models found").foregroundStyle(theme.textTertiary)
                    }
                    ForEach(models) { m in row(m) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                if let info { Section { Text(info).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            .confirmationDialog("Delete Model", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let m = deleting { deleting = nil; Task { await act(m.id) { api in try await api.deleteProviderModel(urlIdx: urlIdx, model: m.id) } } }
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { Text("This will delete the cached model and cannot be undone.") }
        }
    }

    private func row(_ m: ProviderModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.displayName).lineLimit(1)
                if m.displayName != m.id { Text(m.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Text(m.status).font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill((m.isLoaded ? Color.green : m.isBusy ? Color.yellow : Color.gray).opacity(0.18)))
            if busyModel == m.id {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    if m.isLoaded {
                        Button("Unload", systemImage: "stop.circle") {
                            Task { await act(m.id) { api in try await api.unloadProviderModel(urlIdx: urlIdx, model: m.id, instanceId: m.unloadId) } }
                        }
                    } else {
                        Button("Load", systemImage: "play.circle") {
                            Task { await act(m.id) { api in try await api.loadProviderModel(urlIdx: urlIdx, model: m.id) } }
                        }
                        .disabled(m.isBusy)
                    }
                    if supportsDelete {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = m }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(busyModel != nil)
            }
        }
    }
}
