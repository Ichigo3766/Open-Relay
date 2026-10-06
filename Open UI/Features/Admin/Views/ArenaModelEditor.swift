import SwiftUI

/// Add/edit one arena model entry. Works on the raw dictionary so `meta.i18n`,
/// `meta.access_grants` and any future keys survive an edit.
struct ArenaModelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencyContainer.self) private var dependencies

    let original: [String: Any]
    /// Names of the other arena models — the web blocks reusing a name when creating.
    var takenNames: Set<String> = []
    let onSave: ([String: Any]) -> Void

    @State private var id: String
    @State private var name: String
    @State private var descriptionText: String
    @State private var filterMode: String
    @State private var selectedIds: Set<String>
    @State private var allModels: [(id: String, name: String)] = []
    @State private var accessGrants: [AccessGrant]
    @State private var isPrivate: Bool
    @State private var allUsers: [ChannelMember] = []
    @State private var resolvedGroups: [String: GroupResponse] = [:]
    @State private var nameError: String?
    @State private var i18n: LocalizedMap = [:]
    private let isNew: Bool

    init(model: [String: Any]?, takenNames: Set<String> = [], onSave: @escaping ([String: Any]) -> Void) {
        let m = model ?? [:]
        let meta = m["meta"] as? [String: Any] ?? [:]
        self.original = m
        self.takenNames = takenNames
        self.onSave = onSave
        // meta.access_grants uses the same {principal_type, principal_id, permission} rows as everywhere else.
        let rows = (meta["access_grants"] as? [[String: Any]] ?? []).compactMap { AccessGrant.fromJSON($0) }
        let merged = AccessGrant.mergedByUser(rows)
        _accessGrants = State(initialValue: merged.filter { $0.userId != "*" })
        _isPrivate = State(initialValue: !merged.contains { $0.userId == "*" })
        self.isNew = model == nil
        _id = State(initialValue: m["id"] as? String ?? "")
        _name = State(initialValue: m["name"] as? String ?? "")
        _descriptionText = State(initialValue: meta["description"] as? String ?? "")
        _filterMode = State(initialValue: meta["filter_mode"] as? String ?? "include")
        _selectedIds = State(initialValue: Set(meta["model_ids"] as? [String] ?? []))
        _i18n = State(initialValue: LocalizedContent.read(meta))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Arena model name", text: $name)
                        .onChange(of: name) { _, v in
                            if isNew { id = v.lowercased().components(separatedBy: .alphanumerics.inverted)
                                .filter { !$0.isEmpty }.joined(separator: "-") }
                        }
                    TextField("Model ID", text: $id).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .disabled(!isNew)
                    TextField("Description", text: $descriptionText, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    ModelTranslationsSection(i18n: $i18n, showsPrompts: false)
                        .listRowInsets(EdgeInsets())
                }
                Section("Access") { accessSection }
                if let nameError {
                    Section { Text(nameError).foregroundStyle(.red).font(.footnote) }
                }
                Section("Models") {
                    Picker("Mode", selection: $filterMode) {
                        Text("Include").tag("include"); Text("Exclude").tag("exclude")
                    }
                    .pickerStyle(.segmented)
                    Text(selectedIds.isEmpty ? "No models selected — every model takes part."
                         : "\(selectedIds.count) selected")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(allModels, id: \.id) { m in
                        Button {
                            if selectedIds.contains(m.id) { selectedIds.remove(m.id) } else { selectedIds.insert(m.id) }
                        } label: {
                            HStack {
                                Text(m.name).foregroundStyle(.primary)
                                Spacer()
                                if selectedIds.contains(m.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Arena Model" : "Edit Arena Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || id.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
                let list = (try? await dependencies.apiClient?.listAllModels()) ?? []
                allModels = list.filter { !$0.isHidden }.map { ($0.id, $0.name) }
                allUsers = (try? await dependencies.apiClient?.searchAllUsers()) ?? []
                if let groups = try? await dependencies.apiClient?.getGroups() {
                    for g in groups { resolvedGroups[g.id] = g }
                }
            }
        }
    }

    private var accessSection: some View {
        AccessControlSection(
            localAccessGrants: $accessGrants, isPrivate: $isPrivate,
            allUsers: allUsers, resolvedGroups: resolvedGroups, isUpdating: false,
            serverBaseURL: dependencies.apiClient?.baseURL ?? "",
            authToken: dependencies.apiClient?.network.authToken,
            apiClient: dependencies.apiClient,
            onAccessModeChange: { _ in },
            onTogglePermission: { id, isGroup, write in
                if let i = accessGrants.firstIndex(where: { isGroup ? $0.groupId == id : $0.userId == id }) {
                    let g = accessGrants[i]
                    accessGrants[i] = AccessGrant(id: g.id, userId: g.userId, groupId: g.groupId, read: true, write: !write)
                }
            },
            onRemoveGrant: { id, isGroup in
                accessGrants.removeAll { isGroup ? $0.groupId == id : $0.userId == id }
            },
            onAddGrants: { users, groups in
                for u in users where !accessGrants.contains(where: { $0.userId == u }) {
                    accessGrants.append(AccessGrant(id: UUID().uuidString, userId: u, groupId: nil, read: true, write: false))
                }
                for g in groups where !accessGrants.contains(where: { $0.groupId == g }) {
                    accessGrants.append(AccessGrant(id: UUID().uuidString, userId: nil, groupId: g, read: true, write: false))
                }
            })
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Web (ArenaModelModal): a new arena model may not reuse an existing model name.
        if isNew, takenNames.contains(trimmed) || allModels.contains(where: { $0.name == trimmed }) {
            nameError = "Model name already exists, please choose a different one"
            return
        }
        var m = original
        var meta = original["meta"] as? [String: Any] ?? [:]
        m["id"] = id.trimmingCharacters(in: .whitespaces)
        m["name"] = name.trimmingCharacters(in: .whitespaces)
        meta["description"] = descriptionText.isEmpty ? NSNull() : descriptionText
        meta["model_ids"] = selectedIds.isEmpty ? NSNull() : Array(selectedIds).sorted()
        meta["filter_mode"] = selectedIds.isEmpty ? NSNull() : filterMode
        if meta["profile_image_url"] == nil { meta["profile_image_url"] = "/favicon.png" }
        var rows: [[String: Any]] = []
        for g in accessGrants {
            let (type, pid) = g.userId != nil ? ("user", g.userId!) : ("group", g.groupId ?? "")
            rows.append(["principal_type": type, "principal_id": pid, "permission": "read"])
            if g.write { rows.append(["principal_type": type, "principal_id": pid, "permission": "write"]) }
        }
        if !isPrivate { rows.append(["principal_type": "user", "principal_id": "*", "permission": "read"]) }
        meta["access_grants"] = rows
        // Web ArenaModelModal: `meta.i18n` (name / description per language), pruned of blanks.
        let pruned = LocalizedContent.prune(i18n)
        if pruned.isEmpty { meta.removeValue(forKey: "i18n") } else { meta["i18n"] = pruned }
        m["meta"] = meta
        onSave(m)
        dismiss()
    }
}
