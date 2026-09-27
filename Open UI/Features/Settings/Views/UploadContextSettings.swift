import SwiftUI

struct UploadContextSettings: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var mode: String?
    @State private var isSaving = false
    @State private var failed = false

    var body: some View {
        Section {
            if let mode {
                Picker("Default Upload Mode", selection: Binding(
                    get: { mode },
                    set: { value in Task { await save(value) } }
                )) {
                    Text("Focused Retrieval").tag("focused")
                    Text("Entire Document").tag("full")
                }
                .disabled(isSaving)
                if failed { Text("Couldn’t save the setting. Please try again.").foregroundStyle(.secondary) }
            } else if failed {
                Button("Couldn’t load upload mode. Retry") { Task { await load() } }
            } else {
                ProgressView("Loading upload mode…")
            }
        } header: {
            Text("Attachments")
        } footer: {
            Text("Synced with Open WebUI. Applies to newly attached files and knowledge; each attachment can override it. The model’s File Context and Builtin Tools settings determine how sources are used.")
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = dependencies.apiClient else { failed = true; return }
        do {
            let defaults = try await client.fetchUserDefaultParams()
            mode = defaults.defaultUploadContext == "full" ? "full" : "focused"
            dependencies.activeChatStore.cachedUserDefaultParams = defaults
            failed = false
        } catch { failed = true }
    }

    private func save(_ value: String) async {
        guard !isSaving, let client = dependencies.apiClient else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.mergeUserUISettings(["defaultUploadContext": value])
            dependencies.activeChatStore.cachedUserDefaultParams?.defaultUploadContext = value
            mode = value
            failed = false
        } catch { failed = true }
    }
}
