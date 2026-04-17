import SwiftUI

// MARK: - Group Edit Sheet Tab

private enum GroupSheetTab: String, CaseIterable {
    case general     = "General"
    case permissions = "Permissions"
    case users       = "Users"

    var icon: String {
        switch self {
        case .general:     return "gearshape"
        case .permissions: return "wrench"
        case .users:       return "person.badge.plus"
        }
    }
}

// MARK: - Group Edit Sheet

/// Sheet for creating or editing a group.
/// • Creating → shows General + Permissions tabs
/// • Editing  → shows General + Permissions + Users tabs
struct GroupEditSheet: View {
    @Bindable var viewModel: AdminGroupsViewModel
    let serverBaseURL: String
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var selectedTab: GroupSheetTab = .general
    @State private var showDeleteConfirm = false

    private var isEditing: Bool { viewModel.editingGroup != nil }

    private var availableTabs: [GroupSheetTab] {
        isEditing ? GroupSheetTab.allCases : [.general, .permissions]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab bar
                tabBar
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xs)

                Divider()
                    .background(theme.inputBorder.opacity(0.3))

                // Tab content
                ScrollView {
                    VStack(spacing: Spacing.sectionGap) {
                        switch selectedTab {
                        case .general:
                            generalTab
                        case .permissions:
                            GroupPermissionsEditor(permissions: $viewModel.editPermissions)
                                .padding(.top, Spacing.sm)
                        case .users:
                            usersTab
                        }
                    }
                    .padding(.bottom, Spacing.xl)
                }
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit User Group" : "Add User Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .foregroundStyle(theme.textPrimary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    saveButton
                }
            }
        }
        .confirmationDialog(
            "Delete Group",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            if let group = viewModel.editingGroup {
                Button("Delete \"\(group.name)\"", role: .destructive) {
                    Task {
                        await viewModel.deleteGroup(group)
                        onDismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This group will be permanently deleted. This action cannot be undone.")
        }
        .task {
            // Load members list when opening an existing group
            if let group = viewModel.editingGroup {
                await viewModel.loadGroupUsers(groupId: group.id)
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(availableTabs, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .scaledFont(size: 12, weight: .medium)
                        Text(tab.rawValue)
                            .scaledFont(size: 13, weight: selectedTab == tab ? .semibold : .regular)
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedTab == tab ? theme.brandPrimary : theme.textTertiary)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .fill(selectedTab == tab
                                  ? theme.brandPrimary.opacity(0.12)
                                  : theme.surfaceContainer.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .strokeBorder(
                                selectedTab == tab ? theme.brandPrimary.opacity(0.3) : Color.clear,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Save Button

    @ViewBuilder
    private var saveButton: some View {
        let isBusy = viewModel.isSaving || viewModel.isCreating
        if isBusy {
            ProgressView()
                .controlSize(.small)
        } else {
            Button("Save") {
                Task {
                    if isEditing {
                        await viewModel.updateGroup()
                    } else {
                        await viewModel.createGroup()
                    }
                    if viewModel.saveSuccess {
                        onDismiss()
                    }
                }
            }
            .fontWeight(.semibold)
            .foregroundStyle(theme.brandPrimary)
            .disabled(viewModel.editName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(spacing: Spacing.sectionGap) {
            // Name & Description
            VStack(alignment: .leading, spacing: 0) {
                Text("NAME")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .tracking(0.8)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, Spacing.sm)

                VStack(spacing: 0) {
                    TextField("Group name", text: $viewModel.editName)
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 12)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Divider().padding(.horizontal, Spacing.md)

                    TextField("Description", text: $viewModel.editDescription, axis: .vertical)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 12)
                        .lineLimit(3, reservesSpace: false)
                }
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
                .padding(.horizontal, Spacing.screenPadding)
            }

            // Sharing Setting
            VStack(alignment: .leading, spacing: 0) {
                Text("SETTING")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .tracking(0.8)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, Spacing.sm)

                VStack(spacing: 0) {
                    HStack {
                        Text("Who can share to this group")
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Menu {
                            ForEach(GroupSharePermission.allCases, id: \.self) { opt in
                                Button {
                                    viewModel.editSharePermission = opt
                                } label: {
                                    HStack {
                                        Text(opt.displayName)
                                        if viewModel.editSharePermission == opt {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(viewModel.editSharePermission.displayName)
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textTertiary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .scaledFont(size: 10, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                }
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
                .padding(.horizontal, Spacing.screenPadding)
            }

            // Error Banner
            if let err = viewModel.saveError {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.error)
                    Text(err)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.error)
                    Spacer()
                }
                .padding(Spacing.md)
                .background(theme.error.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                .padding(.horizontal, Spacing.screenPadding)
            }

            // Actions (edit only)
            if isEditing {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ACTIONS")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .tracking(0.8)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.bottom, Spacing.sm)

                    VStack(spacing: 0) {
                        Button {
                            Haptics.play(.medium)
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Text("Delete")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(theme.error)
                                Spacer()
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .background(theme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )
                    .padding(.horizontal, Spacing.screenPadding)
                }
            }
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: - Users Tab

    @ViewBuilder
    private var usersTab: some View {
        if viewModel.isLoadingUsers {
            VStack(spacing: Spacing.md) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading users…")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else {
            VStack(spacing: Spacing.sectionGap) {
                // Search bar
                usersSearchBar

                if let err = viewModel.usersError {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.error)
                        Text(err)
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.error)
                        Spacer()
                    }
                    .padding(Spacing.md)
                    .background(theme.error.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                    .padding(.horizontal, Spacing.screenPadding)
                }

                // Table header
                usersTableHeader

                // Users list
                usersListContent
            }
        }
    }

    @State private var userSearch = ""

    private var filteredAllUsers: [AdminUser] {
        guard !userSearch.isEmpty else { return viewModel.allUsers }
        return viewModel.allUsers.filter {
            $0.displayName.localizedCaseInsensitiveContains(userSearch)
            || $0.email.localizedCaseInsensitiveContains(userSearch)
        }
    }

    private var usersSearchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)
            TextField("Search", text: $userSearch)
                .scaledFont(size: 15)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !userSearch.isEmpty {
                Button {
                    userSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
    }

    private var usersTableHeader: some View {
        HStack(spacing: 0) {
            Text("MBR")
                .frame(width: 50, alignment: .leading)
            Text("ROLE")
                .frame(width: 70, alignment: .leading)
            Text("NAME")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("LAST ACTIVE")
                .frame(width: 120, alignment: .trailing)
        }
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, Spacing.screenPadding)
    }

    @ViewBuilder
    private var usersListContent: some View {
        let users = filteredAllUsers
        VStack(spacing: 0) {
            ForEach(users) { user in
                GroupUserRow(
                    user: user,
                    isMember: viewModel.isMember(user),
                    serverBaseURL: serverBaseURL,
                    isSaving: viewModel.isSavingUsers,
                    showDivider: user.id != users.last?.id
                ) {
                    guard let group = viewModel.editingGroup else { return }
                    Task { await viewModel.toggleMembership(user: user, groupId: group.id) }
                }
            }
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
    }
}

// MARK: - Group User Row

private struct GroupUserRow: View {
    let user: AdminUser
    let isMember: Bool
    let serverBaseURL: String
    let isSaving: Bool
    let showDivider: Bool
    let onToggle: () -> Void

    @Environment(\.theme) private var theme

    private var dataURIString: String? {
        guard let url = user.profileImageURL, url.hasPrefix("data:") else { return nil }
        return url
    }

    private var avatarURL: URL? {
        guard let url = user.profileImageURL, !url.isEmpty, !url.hasPrefix("data:") else { return nil }
        if url.hasPrefix("http") { return URL(string: url) }
        if url == "/user.png" { return nil }
        return URL(string: "\(serverBaseURL)/api/v1/users/\(user.id)/profile/image")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // MBR checkbox
                Button {
                    guard !isSaving else { return }
                    Haptics.play(.light)
                    onToggle()
                } label: {
                    Image(systemName: isMember ? "checkmark.square.fill" : "square")
                        .scaledFont(size: 18)
                        .foregroundStyle(isMember ? theme.brandPrimary : theme.textTertiary)
                        .frame(width: 50, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)

                // Role badge
                RoleBadge(role: user.role)
                    .frame(width: 70, alignment: .leading)

                // Avatar + Name
                HStack(spacing: 8) {
                    UserAvatar(
                        size: 28,
                        imageURL: avatarURL,
                        name: user.displayName,
                        dataURIString: dataURIString
                    )
                    Text(user.displayName)
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Last active
                Text(user.lastActiveString)
                    .scaledFont(size: 12)
                    .foregroundStyle(user.isCurrentlyActive ? .green : theme.textTertiary)
                    .frame(width: 120, alignment: .trailing)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, 10)

            if showDivider {
                Divider()
                    .padding(.leading, Spacing.screenPadding + 50)
            }
        }
    }
}
