import SwiftUI

struct NoteSharingView: View {
    @State var model: NoteSharingModel
    @State private var names: [String: String] = [:]
    @State private var showPicker = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if model.note == nil {
                    if model.isBusy { ProgressView("Loading access…") }
                    else { Button("Retry") { Task { await model.load() } } }
                } else {
                    Section {
                        Picker("Everyone on this server", selection: Binding(
                            get: { model.publicPermission },
                            set: { value in Task { await model.setAccess(type: "user", id: "*", permission: value == "private" ? nil : value) } }
                        )) {
                            Text("No access").tag("private")
                            Text("Can read").tag("read")
                            Text("Can edit").tag("write")
                        }
                        .disabled(!model.canChange(type: "user", id: "*") || model.isBusy)
                    } footer: {
                        Text("Sharing grants access to signed-in users. It does not create an anonymous public link.")
                    }
                    Section("People and Groups") {
                        ForEach(model.entries) { grant in
                            HStack {
                                Label(names[grant.id] ?? grant.principalId,
                                      systemImage: grant.principalType == "group" ? "person.3" : "person")
                                Spacer()
                                Menu {
                                    Button("Can read") { change(grant, permission: "read") }
                                    Button("Can edit") { change(grant, permission: "write") }
                                    Button("Remove access", role: .destructive) { change(grant, permission: nil) }
                                } label: {
                                    Text(grant.permission == "write" ? "Can edit" : grant.permission == "read" ? "Can read" : grant.permission)
                                }
                                .accessibilityLabel("Access for \(names[grant.id] ?? grant.principalId)")
                                .disabled(!model.canChange(type: grant.principalType, id: grant.principalId) || model.isBusy)
                            }
                        }
                        if model.canManage && model.allowsSharing && (model.allowsUsers || model.allowsGroups) {
                            Button("Add Access", systemImage: "person.badge.plus") { showPicker = true }
                                .disabled(model.isBusy)
                        }
                        if model.entries.isEmpty { Text("No individual access grants.").foregroundStyle(.secondary) }
                    }
                    if !model.canManage {
                        Text("Only the owner or an administrator can manage this note’s access.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red) } header: { Text("Couldn’t update access") }
                }
            }
            .navigationTitle("Note Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).tint(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isBusy { ProgressView().accessibilityLabel("Updating access") }
                }
            }
            .task {
                await model.load()
                for grant in model.entries where grant.principalType == "user" {
                    guard !Task.isCancelled else { return }
                    if let user = try? await model.api.network.requestJSON(path: "/api/v1/users/\(grant.principalId)/info"),
                       let name = user["name"] as? String {
                        names[grant.id] = name
                    }
                }
                if model.entries.contains(where: { $0.principalType == "group" }),
                   let groups = try? await model.api.getGroups() {
                    for group in groups { names["group:\(group.id)"] = group.name }
                }
            }
            .sheet(isPresented: $showPicker) {
                NoteAccessPicker(model: model) { grant, name in
                    names[grant.id] = name
                    await model.setAccess(type: grant.principalType, id: grant.principalId, permission: "read")
                }
            }
        }
    }

    private func change(_ grant: NoteAccessGrant, permission: String?) {
        Task { await model.setAccess(type: grant.principalType, id: grant.principalId, permission: permission) }
    }
}

private struct NoteAccessPicker: View {
    let model: NoteSharingModel
    let onAdd: (NoteAccessGrant, String) async -> Void
    @State private var type = "user"
    @State private var query = ""
    @State private var users: [ChannelMember] = []
    @State private var groups: [GroupResponse] = []
    @State private var groupsLoaded = false
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchID = UUID()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Picker("Type", selection: $type) {
                    if model.allowsUsers { Text("Users").tag("user") }
                    if model.allowsGroups { Text("Groups").tag("group") }
                }.pickerStyle(.segmented)
                if type == "user" {
                    ForEach(users) { user in row(id: user.id, name: user.displayName) }
                    if hasMore { Button(error == nil ? "Load More" : "Retry") { Task { await loadUsers(reset: false) } }.disabled(isLoading) }
                } else {
                    ForEach(groups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { group in
                        row(id: group.id, name: group.name)
                    }
                    if error != nil { Button("Retry") { Task { await loadGroups() } } }
                }
                if isLoading { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Add Access")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).tint(.secondary)
                }
            }
            .task { if !model.allowsUsers { type = "group" } }
            .task(id: type + ":" + query) {
                if type == "user" { await loadUsers(reset: true) }
                else if !groupsLoaded { await loadGroups() }
            }
        }
    }

    private func row(id: String, name: String) -> some View {
        Button(name) {
            let grant = NoteAccessGrant(principalType: type, principalId: id, permission: "read")
            dismiss()
            Task { await onAdd(grant, name) }
        }
        .disabled(id == model.user.id || model.grants.contains { $0.principalType == type && $0.principalId == id })
    }

    private func loadUsers(reset: Bool) async {
        guard model.allowsUsers else { return }
        let search = query
        let requestedPage = reset ? 1 : page
        let id = UUID()
        searchID = id
        if reset { users = []; page = 1; hasMore = true }
        isLoading = true
        error = nil
        defer { if searchID == id { isLoading = false } }
        do {
            if reset { try await Task.sleep(for: .milliseconds(200)) }
            let result = try await model.api.searchUsers(query: search, page: requestedPage)
            try Task.checkCancellation()
            guard searchID == id, query == search, type == "user" else { return }
            users.append(contentsOf: result.filter { item in !users.contains { $0.id == item.id } })
            hasMore = !result.isEmpty
            page = requestedPage + 1
        } catch { if !Task.isCancelled, searchID == id { self.error = error.localizedDescription } }
    }

    private func loadGroups() async {
        guard model.allowsGroups else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await model.api.getGroups()
            try Task.checkCancellation()
            groups = result
            groupsLoaded = true
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
