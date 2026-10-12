import SwiftUI

/// "Access" from a workspace list item's menu: change who can
/// use a model, knowledge base, prompt, skill or tool without opening the editor.
struct WorkspaceItemAccessSheet: View {
    let title: String
    /// Loads the item's current grants (list rows don't carry them).
    let loadGrants: () async throws -> [AccessGrant]
    /// Saves the full grant list + public flag; returns the server's grants.
    let save: ([AccessGrant], Bool) async throws -> [AccessGrant]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var grants: [AccessGrant] = []
    @State private var isPrivate = true
    @State private var users: [ChannelMember] = []
    @State private var groups: [String: GroupResponse] = [:]
    @State private var isUpdating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    AccessControlSection(
                        localAccessGrants: $grants,
                        isPrivate: $isPrivate,
                        allUsers: users,
                        resolvedGroups: groups,
                        isUpdating: isUpdating,
                        serverBaseURL: dependencies.apiClient?.baseURL ?? "",
                        authToken: dependencies.apiClient?.network.authToken,
                        apiClient: dependencies.apiClient,
                        onAccessModeChange: { newPrivate in
                            isPrivate = newPrivate
                            await persist()
                        },
                        onTogglePermission: { principalId, isGroup, currentlyWrite in
                            if let i = grants.firstIndex(where: { isGroup ? ($0.groupId == principalId && $0.userId == nil) : $0.userId == principalId }) {
                                let g = grants[i]
                                grants[i] = AccessGrant(id: g.id, userId: g.userId, groupId: g.groupId, read: true, write: !currentlyWrite)
                            }
                            await persist()
                        },
                        onRemoveGrant: { principalId, isGroup in
                            grants.removeAll { isGroup ? ($0.groupId == principalId && $0.userId == nil) : $0.userId == principalId }
                            await persist()
                        },
                        onAddGrants: { userIds, groupIds in
                            for u in userIds where !grants.contains(where: { $0.userId == u }) {
                                grants.append(AccessGrant(id: UUID().uuidString, userId: u, groupId: nil, read: true, write: false))
                            }
                            for g in groupIds where !grants.contains(where: { $0.groupId == g && $0.userId == nil }) {
                                grants.append(AccessGrant(id: UUID().uuidString, userId: nil, groupId: g, read: true, write: false))
                            }
                            await persist()
                        }
                    )
                    if let error {
                        Text(error).scaledFont(size: 13).foregroundStyle(theme.error)
                            .padding(.horizontal, Spacing.screenPadding)
                    }
                }
                .padding(.vertical, Spacing.md)
            }
            .background(theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do {
            let initial = try await loadGrants()
            isPrivate = !initial.contains { $0.userId == "*" }
            grants = initial.filter { $0.userId != "*" }
        } catch {
            self.error = APIError.from(error).errorDescription
        }
        guard let api = dependencies.apiClient else { return }
        users = (try? await api.searchAllUsers()) ?? []
        if let list = try? await api.getGroups() { for g in list { groups[g.id] = g } }
    }

    private func persist() async {
        isUpdating = true
        error = nil
        do {
            let saved = try await save(grants, !isPrivate)
            grants = saved.filter { $0.userId != "*" }
            Haptics.notify(.success)
        } catch {
            self.error = APIError.from(error).errorDescription
        }
        isUpdating = false
    }
}
