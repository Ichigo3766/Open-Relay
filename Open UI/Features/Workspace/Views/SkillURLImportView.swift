import SwiftUI

/// The server resolves GitHub repositories/folders and direct ZIP, JSON or Markdown URLs.
/// Keep the complete package so imported supporting files survive the create request.
private struct URLSkillPackage: Identifiable {
    let id = UUID()
    var payload: [String: Any]
    var isSelected = true
    var isImported = false
    var error: String?
    var name: String {
        get { payload["name"] as? String ?? "" }
        set { payload["name"] = newValue }
    }
    var identifier: String {
        get { payload["id"] as? String ?? "" }
        set { payload["id"] = newValue }
    }
    var files: [[String: Any]] { payload["files"] as? [[String: Any]] ?? [] }
    var content: String { files.first { $0["path"] as? String == "SKILL.md" }?["content"] as? String ?? "" }
}

struct SkillURLImportView: View {
    @Environment(\.dismiss) private var dismiss
    let apiClient: APIClient
    let onImport: () async -> Void
    @State private var sourceURL = ""
    @State private var packages: [URLSkillPackage] = []
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var error: String?

    private var selected: [URLSkillPackage] { packages.filter { $0.isSelected && !$0.isImported } }
    private var validURL: Bool {
        guard let url = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    TextField("Skill URL", text: $sourceURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isLoading || isImporting)
                        .onChange(of: sourceURL) { _, _ in packages = []; error = nil }
                    Text("Paste a GitHub repository, folder or SKILL.md URL, or a direct ZIP, JSON or Markdown download URL.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await preview() }
                    } label: {
                        if isLoading { ProgressView("Loading preview…") } else { Text("Preview") }
                    }
                    .disabled(!validURL || isLoading || isImporting)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                ForEach($packages) { $package in
                    Section {
                        if package.isImported {
                            Label("Imported", systemImage: "checkmark.circle")
                        } else {
                            Toggle("Import this skill", isOn: $package.isSelected)
                            TextField("Name", text: $package.name)
                            TextField("Identifier", text: $package.identifier)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        if let description = package.payload["description"] as? String, !description.isEmpty {
                            Text(description).font(.caption)
                        }
                        DisclosureGroup("Instructions") { Text(package.content).textSelection(.enabled) }
                        DisclosureGroup("\(package.files.count) files") {
                            ForEach(Array(package.files.enumerated()), id: \.offset) { _, file in
                                Text(file["path"] as? String ?? "").font(.caption)
                            }
                        }
                        if let error = package.error { Text(error).foregroundStyle(.red) }
                    } header: { Text(package.name) }
                    .disabled(isImporting)
                }
            }
            .navigationTitle("Import from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isImporting) }
                ToolbarItem(placement: .confirmationAction) {
                    if isImporting { ProgressView() } else {
                        Button("Import") { Task { await importSelected() } }
                            .disabled(isLoading || selected.isEmpty || selected.contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty || $0.identifier.trimmingCharacters(in: .whitespaces).isEmpty })
                    }
                }
            }
        }
    }

    private func preview() async {
        isLoading = true
        error = nil
        packages = []
        defer { isLoading = false }
        do {
            let (data, _) = try await apiClient.network.requestRaw(
                path: "/api/v1/skills/load/url", method: .post,
                body: JSONSerialization.data(withJSONObject: ["url": sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)]),
                timeout: 70)
            guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !results.isEmpty else {
                error = "No skills were found at this URL."
                return
            }
            packages = results.map { URLSkillPackage(payload: $0) }
        } catch { self.error = error.localizedDescription }
    }

    private func importSelected() async {
        isImporting = true
        defer { isImporting = false }
        for index in packages.indices where packages[index].isSelected && !packages[index].isImported {
            packages[index].error = nil
            var payload = packages[index].payload
            payload["access_grants"] = []
            do {
                _ = try await apiClient.network.requestJSON(path: "/api/v1/skills/create", method: .post, body: payload)
                packages[index].isImported = true
            } catch { packages[index].error = error.localizedDescription }
        }
        await onImport()
        if selected.isEmpty { dismiss() }
    }
}
