import SwiftUI

// MARK: - Access Control Section (Shared)

/// A fully self-contained access control UI section used by all workspace editors
/// (Prompts, Knowledge, Models, Tools, Skills) and Channels.
///
/// Displays:
/// - Public/Private visibility picker
/// - Access list showing users AND groups with read/write permission pills
/// - "Add Access" button that opens `UnifiedAddAccessSheet`
///
/// The parent editor provides callbacks for persistence (each editor calls its own manager API).
struct AccessControlSection: View {
    @Environment(\.theme) private var theme

    // MARK: - Bindings from parent

    @Binding var localAccessGrants: [AccessGrant]
    @Binding var isPrivate: Bool
    let allUsers: [ChannelMember]
    let resolvedGroups: [String: GroupResponse]
    let isUpdating: Bool
    let serverBaseURL: String
    var authToken: String?
    var apiClient: APIClient?

    // MARK: - Callbacks

    /// Called when the user toggles Public/Private. The parent should call its API.
    let onAccessModeChange: (Bool) async -> Void
    /// Called when the user taps the permission pill. Params: (principalId, isGroup, currentlyWrite).
    let onTogglePermission: (String, Bool, Bool) async -> Void
    /// Called when the user taps the remove button. Params: (principalId, isGroup).
    let onRemoveGrant: (String, Bool) async -> Void
    /// Called when the user adds new grants via the picker. Params: (userIds, groupIds).
    let onAddGrants: ([String], [String]) async -> Void

    // MARK: - Local State

    @State private var showAddAccessSheet = false

    // MARK: - Computed

    /// Users who currently have access, resolved from allUsers for display names.
    private var accessedUsers: [ChannelMember] {
        let ids = Set(localAccessGrants.compactMap(\.userId).filter { $0 != "*" })
        return allUsers.filter { ids.contains($0.id) }
    }

    /// Group grants (groupId is non-nil AND userId is nil — a true group principal).
    /// Only includes groups that actually exist on the server (present in resolvedGroups).
    private var groupGrants: [AccessGrant] {
        localAccessGrants.filter { $0.groupId != nil && $0.userId == nil && resolvedGroups[$0.groupId ?? ""] != nil }
    }

    /// Existing user IDs for the add-access sheet (to hide already-added users).
    private var existingUserIds: Set<String> {
        Set(localAccessGrants.compactMap(\.userId))
    }

    /// Existing group IDs for the add-access sheet (to hide already-added groups).
    private var existingGroupIds: Set<String> {
        Set(localAccessGrants.compactMap(\.groupId))
    }

    var body: some View {
        VStack(spacing: 0) {
            visibilityRow
            Divider().background(theme.inputBorder.opacity(0.4))
            accessListSection
        }
        .sheet(isPresented: $showAddAccessSheet) {
            UnifiedAddAccessSheet(
                existingUserIds: existingUserIds,
                existingGroupIds: existingGroupIds,
                allUsers: allUsers,
                isLoading: isUpdating,
                serverBaseURL: serverBaseURL,
                authToken: authToken,
                apiClient: apiClient,
                onAdd: { userIds, groupIds in
                    showAddAccessSheet = false
                    Task { await onAddGrants(userIds, groupIds) }
                },
                onCancel: { showAddAccessSheet = false }
            )
            .interactiveDismissDisabled()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Visibility Row

    private var visibilityRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: isPrivate ? "lock.fill" : "globe")
                .scaledFont(size: 16)
                .foregroundStyle(isPrivate ? theme.textSecondary : theme.brandPrimary)
                .frame(width: 20)

            Text("Access")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)

            Spacer()

            if isUpdating {
                ProgressView().controlSize(.mini).tint(theme.brandPrimary)
                    .padding(.trailing, 4)
            }

            Picker("", selection: $isPrivate) {
                Text("Private").tag(true)
                Text("Public").tag(false)
            }
            .pickerStyle(.menu)
            .tint(theme.brandPrimary)
            .scaledFont(size: 15)
            .onChange(of: isPrivate) { _, newVal in
                Task { await onAccessModeChange(newVal) }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 12)
    }

    // MARK: - Access List

    private var accessListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Access List")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if localAccessGrants.isEmpty {
                Text("No access grants. Private to you.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 10)
            } else {
                // User grants
                ForEach(accessedUsers) { user in
                    accessGrantRow(
                        displayName: user.displayName,
                        subtitle: user.role?.capitalized,
                        icon: nil,
                        avatarURL: user.resolveAvatarURL(serverBaseURL: serverBaseURL),
                        avatarName: user.displayName,
                        principalId: user.id,
                        isGroup: false,
                        grant: localAccessGrants.first(where: { $0.userId == user.id })
                    )
                    Divider()
                        .background(theme.inputBorder.opacity(0.3))
                        .padding(.leading, Spacing.md + 42)
                }

                // Group grants
                ForEach(groupGrants, id: \.id) { grant in
                    let gid = grant.groupId ?? ""
                    let group = resolvedGroups[gid]
                    accessGrantRow(
                        displayName: group?.name ?? "Group",
                        subtitle: group.map { "\($0.member_count ?? 0) members" },
                        icon: "person.3.fill",
                        avatarURL: nil,
                        avatarName: group?.name ?? "G",
                        principalId: gid,
                        isGroup: true,
                        grant: grant
                    )
                    Divider()
                        .background(theme.inputBorder.opacity(0.3))
                        .padding(.leading, Spacing.md + 42)
                }
            }

            // Add Access button
            Button {
                Haptics.play(.light)
                showAddAccessSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.brandPrimary)
                    Text("Add Access")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.brandPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Grant Row (User or Group)

    @ViewBuilder
    private func accessGrantRow(
        displayName: String,
        subtitle: String?,
        icon: String?,
        avatarURL: URL?,
        avatarName: String,
        principalId: String,
        isGroup: Bool,
        grant: AccessGrant?
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            // Avatar: user image or group icon
            if isGroup {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon ?? "person.3.fill")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(.orange)
                }
            } else {
                UserAvatar(
                    size: 30,
                    imageURL: avatarURL,
                    name: avatarName,
                    authToken: authToken
                )
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Spacer()

            // READ / WRITE permission toggle pill
            if let grant {
                Button {
                    Task { await onTogglePermission(principalId, isGroup, grant.write) }
                } label: {
                    Text(grant.write ? "Write" : "Read")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(grant.write ? theme.brandOnPrimary : theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(grant.write ? theme.brandPrimary : theme.surfaceContainerHighest)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(grant.write ? Color.clear : theme.inputBorder.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isUpdating)
            }

            // Remove button
            Button {
                Task { await onRemoveGrant(principalId, isGroup) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 18)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 8)
    }
}

// MARK: - Unified Add Access Sheet

/// A shared sheet for adding users AND groups to an access list.
/// Replaces both `WorkspaceAddAccessSheet` and `AddAccessSheet` (channels).
///
/// Features:
/// - Segmented "Users" / "Groups" tab
/// - Search for each tab
/// - Groups fetched from `GET /api/v1/groups/` via apiClient
/// - Returns selected user IDs and group IDs via `onAdd` callback
struct UnifiedAddAccessSheet: View {
    @Environment(\.theme) private var theme

    let existingUserIds: Set<String>
    let existingGroupIds: Set<String>
    let allUsers: [ChannelMember]
    let isLoading: Bool
    var serverBaseURL: String = ""
    var authToken: String?
    var apiClient: APIClient?
    let onAdd: ([String], [String]) -> Void
    let onCancel: () -> Void

    // MARK: - State

    private enum Tab: String, CaseIterable { case users = "Users", groups = "Groups" }

    @State private var selectedTab: Tab = .users
    @State private var searchText = ""
    @State private var selectedUserIds: Set<String> = []
    @State private var selectedGroupIds: Set<String> = []

    @State private var allGroups: [GroupResponse] = []
    @State private var isLoadingGroups = false

    // MARK: - Computed

    private var availableUsers: [ChannelMember] {
        let filtered = allUsers.filter { !existingUserIds.contains($0.id) }
        if searchText.isEmpty { return filtered }
        let q = searchText.lowercased()
        return filtered.filter {
            ($0.name ?? "").lowercased().contains(q) || $0.email.lowercased().contains(q)
        }
    }

    private var availableGroups: [GroupResponse] {
        let filtered = allGroups.filter { !existingGroupIds.contains($0.id) }
        if searchText.isEmpty { return filtered }
        let q = searchText.lowercased()
        return filtered.filter {
            $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q)
        }
    }

    private var totalSelected: Int { selectedUserIds.count + selectedGroupIds.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 4)

                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textTertiary)
                    TextField("Search \(selectedTab.rawValue.lowercased())…", text: $searchText)
                        .scaledFont(size: 15)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, 4)

                // Content
                switch selectedTab {
                case .users:
                    usersTabContent
                case .groups:
                    groupsTabContent
                }

                // Add button
                addButton
            }
            .background(theme.background)
            .navigationTitle("Add Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .semibold)
                    }
                    .disabled(isLoading)
                }
            }
            .onChange(of: selectedTab) { _, _ in
                searchText = ""
            }
            .task {
                guard apiClient != nil, allGroups.isEmpty else { return }
                await fetchGroups()
            }
        }
    }

    // MARK: - Users Tab

    @ViewBuilder
    private var usersTabContent: some View {
        if availableUsers.isEmpty {
            ContentUnavailableView {
                Label("No Users", systemImage: "person.slash")
            } description: {
                Text(searchText.isEmpty
                    ? "All available users already have access."
                    : "No users match your search.")
            }
        } else {
            List(availableUsers) { user in
                Button {
                    toggleSelection(user.id, in: &selectedUserIds)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        UserAvatar(
                            size: 32,
                            imageURL: user.resolveAvatarURL(serverBaseURL: serverBaseURL),
                            name: user.displayName,
                            authToken: authToken
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user.displayName)
                                .scaledFont(size: 15, weight: .medium)
                                .foregroundStyle(theme.textPrimary)
                            Text(user.role?.capitalized ?? "User")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        }
                        Spacer()
                        Image(systemName: selectedUserIds.contains(user.id)
                              ? "checkmark.square.fill" : "square")
                            .scaledFont(size: 20)
                            .foregroundStyle(selectedUserIds.contains(user.id)
                                             ? theme.brandPrimary : theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Groups Tab

    @ViewBuilder
    private var groupsTabContent: some View {
        if isLoadingGroups {
            VStack {
                Spacer()
                ProgressView("Loading groups…")
                    .controlSize(.regular)
                Spacer()
            }
        } else if availableGroups.isEmpty {
            ContentUnavailableView {
                Label("No Groups", systemImage: "person.3.slash")
            } description: {
                Text(searchText.isEmpty
                    ? "All available groups already have access."
                    : "No groups match your search.")
            }
        } else {
            List(availableGroups) { group in
                Button {
                    toggleSelection(group.id, in: &selectedGroupIds)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.12))
                                .frame(width: 32, height: 32)
                            Image(systemName: "person.3.fill")
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                                .scaledFont(size: 15, weight: .medium)
                                .foregroundStyle(theme.textPrimary)
                            if let desc = group.description, !desc.isEmpty {
                                Text(desc)
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(1)
                            } else if let count = group.member_count {
                                Text("\(count) members")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        Spacer()
                        if let count = group.member_count {
                            Text("\(count)")
                                .scaledFont(size: 11, weight: .bold)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.surfaceContainerHighest)
                                .clipShape(Capsule())
                        }
                        Image(systemName: selectedGroupIds.contains(group.id)
                              ? "checkmark.square.fill" : "square")
                            .scaledFont(size: 20)
                            .foregroundStyle(selectedGroupIds.contains(group.id)
                                             ? theme.brandPrimary : theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Add Button

    private var addButton: some View {
        Button {
            onAdd(Array(selectedUserIds), Array(selectedGroupIds))
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(isLoading ? "Adding…" : "Add\(totalSelected > 0 ? " (\(totalSelected))" : "")")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(totalSelected == 0 || isLoading
                        ? theme.textTertiary.opacity(0.3)
                        : theme.brandPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(totalSelected == 0 || isLoading)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func toggleSelection(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func fetchGroups() async {
        guard let api = apiClient else { return }
        isLoadingGroups = true
        do {
            allGroups = try await api.getGroups()
        } catch {
            // Silently fail — groups tab will show empty
        }
        isLoadingGroups = false
    }
}

// MARK: - Backward-Compatible Wrapper

/// Wrapper used by workspace editors (Model, Tool, Skill) that still have their own
/// access control UI but want the unified Users+Groups picker sheet.
///
/// Passes both userIds AND groupIds to the callback so editors can create
/// proper AccessGrant objects for both users and groups.
struct WorkspaceAddAccessSheet: View {
    let existingUserIds: Set<String>
    var existingGroupIds: Set<String> = []
    let allUsers: [ChannelMember]
    let isLoading: Bool
    var serverBaseURL: String = ""
    var authToken: String?
    var apiClient: APIClient?
    let onAdd: ([String], [String]) -> Void
    let onCancel: () -> Void

    var body: some View {
        UnifiedAddAccessSheet(
            existingUserIds: existingUserIds,
            existingGroupIds: existingGroupIds,
            allUsers: allUsers,
            isLoading: isLoading,
            serverBaseURL: serverBaseURL,
            authToken: authToken,
            apiClient: apiClient,
            onAdd: { userIds, groupIds in
                onAdd(userIds, groupIds)
            },
            onCancel: onCancel
        )
    }
}
