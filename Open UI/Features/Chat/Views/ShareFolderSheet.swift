import SwiftUI

/// Sheet for managing folder sharing — Public/Private toggle + per-user/group access grants.
///
/// Reuses the existing `AccessControlSection` and `UnifiedAddAccessSheet` components
/// that are already used by Knowledge, Tools, Models, Prompts, and Skills editors.
///
/// Owner-only: this sheet should only be presented for folders owned by the current user.
struct ShareFolderSheet: View {
    // MARK: - Inputs

    let folder: ChatFolder
    let apiClient: APIClient?
    let currentUserId: String
    var onUpdate: ((ChatFolder) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    // MARK: - State

    @State private var localAccessGrants: [AccessGrant] = []
    @State private var isPublic: Bool = false
    @State private var isUpdating: Bool = false
    @State private var allUsers: [ChannelMember] = []
    @State private var resolvedGroups: [String: GroupResponse] = [:]
    /// Sharing mode: nil = Clone only, "continue" = Allow replies.
    @State private var shareMode: String?

    // MARK: - Init

    init(
        folder: ChatFolder,
        apiClient: APIClient? = nil,
        currentUserId: String = "",
        onUpdate: ((ChatFolder) -> Void)? = nil
    ) {
        self.folder = folder
        self.apiClient = apiClient
        self.currentUserId = currentUserId
        self.onUpdate = onUpdate
        _localAccessGrants = State(initialValue: folder.accessGrants)
        _isPublic = State(initialValue: folder.isPublic)
        _shareMode = State(initialValue: folder.data?.shareMode)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header info
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label(folder.name, systemImage: "folder.fill")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Text("Control who can view or edit chats in this folder.")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)

                    Divider()
                        .background(theme.inputBorder.opacity(0.4))

                    // Access control section (reused from Workspace editors)
                    AccessControlSection(
                        localAccessGrants: $localAccessGrants,
                        isPrivate: Binding(
                            get: { !isPublic },
                            set: { isPublic = !$0 }
                        ),
                        allUsers: allUsers,
                        resolvedGroups: resolvedGroups,
                        isUpdating: isUpdating,
                        serverBaseURL: apiClient?.baseURL ?? "",
                        authToken: apiClient?.network.authToken,
                        apiClient: apiClient,
                        onAccessModeChange: { newIsPrivate in
                            isPublic = !newIsPrivate
                            await saveAccess()
                        },
                        onTogglePermission: { principalId, isGroup, currentlyWrite in
                            togglePermission(principalId: principalId, isGroup: isGroup, currentlyWrite: currentlyWrite)
                            await saveAccess()
                        },
                        onRemoveGrant: { principalId, isGroup in
                            removeGrant(principalId: principalId, isGroup: isGroup)
                            await saveAccess()
                        },
                        onAddGrants: { userIds, groupIds in
                            addGrants(userIds: userIds, groupIds: groupIds)
                            await saveAccess()
                        }
                    )

                    // Let people the folder is shared with reply in its chats.
                    if !localAccessGrants.isEmpty || isPublic {
                        Divider().background(theme.inputBorder.opacity(0.4))
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            HStack {
                                Text("Sharing mode")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Picker("Sharing mode", selection: $shareMode) {
                                    Text("Clone only").tag(String?.none)
                                    Text("Allow replies").tag(String?.some("continue"))
                                }
                                .labelsHidden()
                                .tint(theme.brandPrimary)
                                .onChange(of: shareMode) { _, _ in Task { await saveAccess(includeShareMode: true) } }
                            }
                            Text(shareMode == "continue"
                                 ? "People with access can keep writing in this folder's chats."
                                 : "People with access can view this folder's chats and make their own copy.")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("Share Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
            }
            .background(theme.background)
            .task {
                await loadUsers()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.background)
    }

    // MARK: - Access Helpers

    private func togglePermission(principalId: String, isGroup: Bool, currentlyWrite: Bool) {
        if isGroup {
            if let idx = localAccessGrants.firstIndex(where: { $0.groupId == principalId && $0.userId == nil }) {
                let grant = localAccessGrants[idx]
                localAccessGrants[idx] = AccessGrant(
                    id: grant.id, userId: nil, groupId: principalId,
                    read: true, write: !currentlyWrite
                )
            }
        } else {
            if let idx = localAccessGrants.firstIndex(where: { $0.userId == principalId }) {
                let grant = localAccessGrants[idx]
                localAccessGrants[idx] = AccessGrant(
                    id: grant.id, userId: principalId, groupId: nil,
                    read: true, write: !currentlyWrite
                )
            }
        }
    }

    private func removeGrant(principalId: String, isGroup: Bool) {
        if isGroup {
            localAccessGrants.removeAll { $0.groupId == principalId && $0.userId == nil }
        } else {
            localAccessGrants.removeAll { $0.userId == principalId }
        }
    }

    private func addGrants(userIds: [String], groupIds: [String]) {
        for userId in userIds {
            guard !localAccessGrants.contains(where: { $0.userId == userId }) else { continue }
            localAccessGrants.append(
                AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false)
            )
        }
        for groupId in groupIds {
            guard !localAccessGrants.contains(where: { $0.groupId == groupId && $0.userId == nil }) else { continue }
            localAccessGrants.append(
                AccessGrant(id: UUID().uuidString, userId: nil, groupId: groupId, read: true, write: false)
            )
        }

        // Resolve newly added groups
        Task {
            await resolveNewGroups(groupIds: groupIds)
        }
    }

    private func saveAccess(includeShareMode: Bool = false) async {
        guard let api = apiClient else { return }
        isUpdating = true
        // Build payload from current local state
        var tempFolder = folder
        tempFolder.accessGrants = localAccessGrants
        tempFolder.isPublic = isPublic
        let payload = tempFolder.buildGrantsPayload()

        do {
            let raw = try await api.updateFolderAccessGrants(
                id: folder.id, grants: payload,
                shareMode: includeShareMode ? .some(shareMode) : .none
            )
            if let updated = ChatFolder(json: raw) {
                onUpdate?(updated)
            }
        } catch {
            // Non-fatal — local state already reflects the user's intent
        }
        isUpdating = false
    }

    // MARK: - Data Loading

    private func loadUsers() async {
        guard let api = apiClient else { return }
        do {
            // Load all users for the access picker
            var page = 1
            var all: [ChannelMember] = []
            while true {
                let batch = try await api.searchUsers(query: nil, page: page)
                guard !batch.isEmpty else { break }
                all.append(contentsOf: batch)
                if batch.count < 30 { break }
                page += 1
            }
            allUsers = all.filter { $0.id != currentUserId }

            // Resolve any groups already in the grants
            let existingGroupIds = localAccessGrants.compactMap(\.groupId)
            if !existingGroupIds.isEmpty {
                let groups = try await api.getGroups()
                for g in groups where existingGroupIds.contains(g.id) {
                    resolvedGroups[g.id] = g
                }
            }
        } catch {
            // Silently fail — access list will show partial/empty data
        }
    }

    private func resolveNewGroups(groupIds: [String]) async {
        guard let api = apiClient else { return }
        do {
            let groups = try await api.getGroups()
            for g in groups where groupIds.contains(g.id) {
                resolvedGroups[g.id] = g
            }
        } catch {}
    }
}
