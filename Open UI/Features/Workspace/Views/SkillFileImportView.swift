import SwiftUI
import UniformTypeIdentifiers

/// One skill found in an import file (server `/skills/import/preview`).
struct SkillImportItem: Identifiable {
    let id = UUID()
    let index: Int
    var name: String
    var identifier: String
    let description: String
    let files: [String]
    let idTaken: Bool
    let canReplace: Bool
    let expectedVersionId: String?
    /// "create" | "copy" | "replace" | "skip"
    var action: String
    var status: String?

    init(preview p: [String: Any]) {
        let taken = p["id_taken"] as? Bool ?? false
        index = p["index"] as? Int ?? 0
        name = p["name"] as? String ?? ""
        identifier = p["id"] as? String ?? ""
        description = p["description"] as? String ?? ""
        files = (p["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        idTaken = taken
        canReplace = p["can_replace"] as? Bool ?? false
        expectedVersionId = p["expected_version_id"] as? String
        action = taken ? "copy" : "create"
    }

    var decision: [String: Any] {
        var d: [String: Any] = ["action": action]
        if action == "copy" || action == "create" {
            d["id"] = identifier.trimmingCharacters(in: .whitespaces)
            d["name"] = name.trimmingCharacters(in: .whitespaces)
        }
        if action == "replace", let expectedVersionId { d["expected_version_id"] = expectedVersionId }
        return d
    }
}

/// Imports skills from a ZIP folder, a JSON file or a single SKILL.md:
/// the server parses the file, shows a preview, and imports every supporting file.
struct SkillFileImportView: View {
    let apiClient: APIClient
    let onImport: () async -> Void

    @Environment(\.dismiss) var dismiss

    @State var showPicker = true
    @State var fileData: Data?
    @State var fileName = ""
    @State var items: [SkillImportItem] = []
    @State var isLoading = false
    @State var isImporting = false
    @State var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView("Reading file…")
                } else if items.isEmpty {
                    Section {
                        Button("Choose File", systemImage: "doc") { showPicker = true }
                        Text("Pick a ZIP folder, a JSON export or a SKILL.md file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                ForEach($items) { $item in
                    itemSection($item).disabled(isImporting)
                }
            }
            .navigationTitle("Import Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isImporting) }
                ToolbarItem(placement: .confirmationAction) {
                    if isImporting { ProgressView() } else {
                        Button("Import") { Task { await runImport() } }
                            .disabled(items.isEmpty || items.allSatisfy { $0.action == "skip" })
                    }
                }
            }
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.zip, .json, .plainText, UTType(filenameExtension: "md") ?? .plainText]
            ) { result in
                guard case .success(let url) = result else { return }
                Task { await load(url) }
            }
        }
    }

    private func itemSection(_ item: Binding<SkillImportItem>) -> some View {
        Section {
            Picker("Action", selection: item.action) {
                if item.wrappedValue.idTaken {
                    Text("Import as copy").tag("copy")
                    if item.wrappedValue.canReplace { Text("Replace existing").tag("replace") }
                } else {
                    Text("Import").tag("create")
                }
                Text("Skip").tag("skip")
            }
            if item.wrappedValue.action == "copy" || item.wrappedValue.action == "create" {
                TextField("Name", text: item.name)
                TextField("Identifier", text: item.identifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if !item.wrappedValue.description.isEmpty { Text(item.wrappedValue.description).font(.caption) }
            DisclosureGroup("\(item.wrappedValue.files.count) files") {
                ForEach(item.wrappedValue.files, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
            if let status = item.wrappedValue.status {
                Text(status).font(.caption).foregroundStyle(status == "saved" ? .green : .red)
            }
        } header: {
            Text(item.wrappedValue.name)
        } footer: {
            if item.wrappedValue.idTaken { Text("A skill with this identifier already exists.") }
        }
    }
}
