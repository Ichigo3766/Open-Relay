import SwiftUI

/// "Who can open this link" for a shared chat — web ShareChatModal + AccessControl:
///  • Private: only you, admins, and the people/groups you add
///  • Public (`user:*`): any signed-in user
///  • Open (`anyone:*`): anyone with the link, even signed out
/// Public / Open need `sharing.public_chats` / `sharing.open_chats` (or admin).
/// Each change is saved immediately, like the web (`onChange={saveAccessGrants}`).
struct SharedChatAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencyContainer.self) var dependencies
    let chatId: String

    enum Visibility: String, CaseIterable, Identifiable {
        case `private`, `public`, open
        var id: String { rawValue }
        var label: String { self == .private ? "Private" : self == .public ? "Signed-in users" : "Anyone with the link" }
        var detail: String {
            switch self {
            case .private: return "Only select users and groups with permission can access."
            case .public: return "Accessible to all users."
            case .open: return "Anyone with the link can view."
            }
        }
    }

    @State var grants: [AccessGrant] = []        // specific users/groups (read)
    @State var visibility: Visibility = .private
    @State var users: [ChannelMember] = []
    @State var groups: [String: GroupResponse] = [:]
    @State var isLoading = true
    @State var isSaving = false
    @State var error: String?

    private var user: User? { dependencies.authViewModel.currentUser }
    private var isAdmin: Bool { user?.role == .admin }
    private var canPublic: Bool { isAdmin || (user?.permissions?.sharing.publicChats ?? false) }
    private var canOpen: Bool { isAdmin || (user?.permissions?.sharing.openChats ?? false) }
    private var options: [Visibility] {
        Visibility.allCases.filter {
            $0 == .private
                || ($0 == .public && (canPublic || visibility == .public))
                || ($0 == .open && (canOpen || visibility == .open))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView()
                } else {
                    Section {
                        Picker("Access", selection: $visibility) {
                            ForEach(options) { Text($0.label).tag($0) }
                        }
                        Text(visibility.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    .onChange(of: visibility) { _, _ in Task { await save() } }

                    Section("People and groups") {
                        AccessControlSection(
                            localAccessGrants: $grants, isPrivate: .constant(true),
                            allUsers: users, resolvedGroups: groups, isUpdating: isSaving,
                            serverBaseURL: dependencies.apiClient?.baseURL ?? "",
                            authToken: dependencies.apiClient?.network.authToken,
                            apiClient: dependencies.apiClient,
                            onAccessModeChange: { _ in },
                            onTogglePermission: { _, _, _ in },   // shared links are read-only
                            onRemoveGrant: { id, isGroup in
                                grants.removeAll { isGroup ? $0.groupId == id : $0.userId == id }
                                await save()
                            },
                            onAddGrants: { userIds, groupIds in await add(userIds: userIds, groupIds: groupIds) })
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Link Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }
}
