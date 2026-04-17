import SwiftUI

// MARK: - Users Sub-Tab

enum UsersSubTab: String, CaseIterable {
    case overview = "Overview"
    case groups   = "Groups"

    var icon: String {
        switch self {
        case .overview: return "person.2"
        case .groups:   return "person.2.badge.gearshape"
        }
    }
}

// MARK: - Admin Console Tab

enum AdminConsoleTab: String, CaseIterable {
    case users       = "Users"
    case analytics   = "Analytics"
    case functions   = "Functions"
    case settings    = "Settings"

    var icon: String {
        switch self {
        case .users:     return "person.2"
        case .analytics: return "chart.bar.xaxis"
        case .functions: return "function"
        case .settings:  return "gear"
        }
    }
}

// MARK: - Settings Sub-Section

enum SettingsSubSection: String, CaseIterable {
    case general      = "General"
    case connections  = "Connections"
    case integrations = "Integrations"
    case documents    = "Documents"
    case webSearch    = "Web Search"
    case codeExecution = "Code Execution"
    case interface_   = "Interface"
    case audio        = "Audio"
    case images       = "Images"

    var icon: String {
        switch self {
        case .general:       return "gear"
        case .connections:   return "link"
        case .integrations:  return "wrench.and.screwdriver"
        case .documents:     return "doc.text"
        case .webSearch:     return "globe"
        case .codeExecution: return "terminal"
        case .interface_:    return "slider.horizontal.3"
        case .audio:         return "waveform"
        case .images:        return "photo"
        }
    }

    var displayName: String {
        switch self {
        case .interface_: return "Interface"
        case .codeExecution: return "Code Execution"
        case .webSearch: return "Web Search"
        default: return rawValue
        }
    }

    /// Used to match search text
    var searchableText: String { displayName.lowercased() }
}

// MARK: - AdminConsoleView

/// The main admin console view with a scrollable tab bar (Users, Functions).
struct AdminConsoleView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router

    @State private var selectedTab: AdminConsoleTab = .users

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            tabBar
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xs)

            Divider()
                .background(theme.inputBorder.opacity(0.3))

            // Tab content
            Group {
                switch selectedTab {
                case .users:
                    AdminUsersTab()
                case .analytics:
                    AdminAnalyticsView()
                case .functions:
                    AdminFunctionsView()
                case .settings:
                    AdminSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.background)
        .navigationTitle("Admin Console")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AdminConsoleTab.allCases, id: \.self) { tab in
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
                                .fixedSize()
                        }
                        .foregroundStyle(selectedTab == tab ? theme.brandPrimary : theme.textTertiary)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 80)
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
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
        }
    }
}

// MARK: - Admin Users Tab

/// The Users section: has an Overview sub-tab (user list) and a Groups sub-tab.
struct AdminUsersTab: View {
    @Environment(\.theme) private var theme
    @State private var selectedSubTab: UsersSubTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            // Sub-tab bar
            usersSubTabBar
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.xs)

            Divider()
                .background(theme.inputBorder.opacity(0.2))

            switch selectedSubTab {
            case .overview:
                AdminUsersListView()
            case .groups:
                AdminGroupsView()
            }
        }
    }

    private var usersSubTabBar: some View {
        HStack(spacing: 6) {
            ForEach(UsersSubTab.allCases, id: \.self) { sub in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedSubTab = sub
                    }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: sub.icon)
                            .scaledFont(size: 12, weight: .medium)
                        Text(sub.rawValue)
                            .scaledFont(size: 13, weight: selectedSubTab == sub ? .semibold : .regular)
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedSubTab == sub ? theme.brandPrimary : theme.textTertiary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .fill(selectedSubTab == sub
                                  ? theme.brandPrimary.opacity(0.12)
                                  : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .strokeBorder(
                                selectedSubTab == sub ? theme.brandPrimary.opacity(0.3) : Color.clear,
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
}

// MARK: - Admin Users List View

/// The original admin users list (formerly AdminUsersTab body).
struct AdminUsersListView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @State private var viewModel = AdminViewModel()

    private var currentUserId: String? {
        dependencies.authViewModel.currentUser?.id
    }

    @State private var showEditSheet = false
    @State private var showChatsSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showAddUserSheet = false
    @State private var roleChangeUser: AdminUser?
    @State private var roleChangeTarget: User.UserRole?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                searchBar
                sortControls

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                if !viewModel.isLoading && !viewModel.users.isEmpty {
                    HStack {
                        Text("Users \(viewModel.userCount)")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xs)
                }

                if viewModel.isLoading && viewModel.users.isEmpty {
                    loadingState
                } else if viewModel.users.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    userList
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.resetAddForm()
                    showAddUserSheet = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
            }
        }
        .refreshable {
            await viewModel.loadUsers()
        }
        .sheet(isPresented: $showEditSheet) {
            EditUserSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        .sheet(isPresented: $showChatsSheet) {
            UserChatsSheet(
                viewModel: viewModel,
                serverBaseURL: dependencies.apiClient?.baseURL ?? "",
                onClone: { clonedConversation in
                    showChatsSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                        NotificationCenter.default.post(
                            name: .adminClonedChat,
                            object: clonedConversation.id
                        )
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
        .sheet(isPresented: $showAddUserSheet) {
            AddUserSheet(viewModel: viewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        .confirmationDialog(
            "Delete User",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let user = viewModel.userToDelete {
                Button("Delete \(user.displayName)", role: .destructive) {
                    Task { await viewModel.deleteUser(user) }
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.userToDelete = nil
            }
        } message: {
            if let user = viewModel.userToDelete {
                Text("Are you sure you want to permanently delete \(user.displayName) (\(user.email))? This action cannot be undone.")
            }
        }
        .confirmationDialog(
            "Change Role",
            isPresented: .init(
                get: { roleChangeUser != nil },
                set: { if !$0 { roleChangeUser = nil; roleChangeTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let user = roleChangeUser, let target = roleChangeTarget {
                Button("Change to \(target.rawValue.capitalized)") {
                    Task { await viewModel.cycleRole(for: user) }
                    roleChangeUser = nil
                    roleChangeTarget = nil
                }
            }
            Button("Cancel", role: .cancel) {
                roleChangeUser = nil
                roleChangeTarget = nil
            }
        } message: {
            if let user = roleChangeUser, let target = roleChangeTarget {
                Text("Change \(user.displayName)'s role from \(user.role.rawValue) to \(target.rawValue)?")
            }
        }
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.loadUsers()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textTertiary)

            TextField("Search users…", text: $viewModel.searchQuery)
                .scaledFont(size: 16)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: viewModel.searchQuery) { _, _ in
                    viewModel.performSearch()
                }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                    viewModel.performSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 16)
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
        .padding(.top, Spacing.sm)
    }

    // MARK: - Sort Controls

    private var sortControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(AdminViewModel.SortField.allCases, id: \.rawValue) { field in
                    Button {
                        Task {
                            if viewModel.sortField == field {
                                await viewModel.toggleSortDirection()
                            } else {
                                await viewModel.changeSortField(field)
                            }
                        }
                        Haptics.play(.light)
                    } label: {
                        HStack(spacing: 4) {
                            Text(field.displayName)
                                .scaledFont(size: 12, weight: .medium)

                            if viewModel.sortField == field {
                                Image(systemName: viewModel.sortDirection.icon)
                                    .scaledFont(size: 10, weight: .bold)
                            }
                        }
                        .foregroundStyle(
                            viewModel.sortField == field ? theme.brandPrimary : theme.textTertiary
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            (viewModel.sortField == field ? theme.brandPrimary : theme.textTertiary)
                                .opacity(0.1)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.top, Spacing.sm)
        }
    }

    // MARK: - User List

    private var userList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.users) { user in
                let isSelf = user.id == currentUserId
                AdminUserRow(
                    user: user,
                    isSelf: isSelf,
                    serverURL: dependencies.apiClient?.baseURL ?? "",
                    onEdit: {
                        viewModel.startEditing(user)
                        showEditSheet = true
                    },
                    onViewChats: {
                        Task { await viewModel.loadUserChats(for: user) }
                        showChatsSheet = true
                    },
                    onDelete: isSelf ? nil : {
                        viewModel.userToDelete = user
                        showDeleteConfirmation = true
                    },
                    onRoleTap: isSelf ? nil : {
                        let nextRole: User.UserRole
                        switch user.role {
                        case .pending: nextRole = .user
                        case .user:    nextRole = .admin
                        case .admin:   nextRole = .user
                        }
                        roleChangeUser = user
                        roleChangeTarget = nextRole
                        Haptics.play(.medium)
                    }
                )

                if user.id != viewModel.users.last?.id {
                    Divider()
                        .padding(.leading, 64)
                        .padding(.horizontal, Spacing.screenPadding)
                }
            }

            if viewModel.hasMorePages {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, Spacing.lg)
                    .onAppear {
                        Task { await viewModel.loadMoreUsers() }
                    }
            }
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Loading users…")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "person.2.slash")
                .scaledFont(size: 40)
                .foregroundStyle(theme.textTertiary)
            Text(viewModel.searchQuery.isEmpty ? "No users were found." : "No results for \"\(viewModel.searchQuery)\"")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 14)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.error)
            Spacer()
            Button("Retry") {
                Task { await viewModel.loadUsers() }
            }
            .scaledFont(size: 12, weight: .medium)
            .fontWeight(.semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .padding(Spacing.md)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
    }
}

// MARK: - Admin User Row

struct AdminUserRow: View {
    let user: AdminUser
    let isSelf: Bool
    let serverURL: String
    var profileImageVersion: Int = 0
    let onEdit: () -> Void
    let onViewChats: () -> Void
    let onDelete: (() -> Void)?
    let onRoleTap: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack(alignment: .bottomTrailing) {
                UserAvatar(
                    size: 40,
                    imageURL: avatarURL,
                    name: user.displayName,
                    dataURIString: dataURIString
                )

                if user.isCurrentlyActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .strokeBorder(theme.background, lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(user.displayName)
                        .scaledFont(size: 16)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if isSelf {
                        Text("You")
                            .scaledFont(size: 8, weight: .heavy)
                            .foregroundStyle(theme.brandPrimary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(theme.brandPrimary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }

                Text(user.email)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)

                Text(user.lastActiveString)
                    .scaledFont(size: 11)
                    .foregroundStyle(
                        user.isCurrentlyActive ? Color.green : theme.textTertiary
                    )
            }

            Spacer()

            if let onRoleTap {
                Button(action: onRoleTap) {
                    RoleBadge(role: user.role)
                }
                .buttonStyle(.plain)
            } else {
                RoleBadge(role: user.role)
            }

            HStack(spacing: 2) {
                adminActionButton(icon: "bubble.left.and.text.bubble.right", action: onViewChats)
                adminActionButton(icon: "pencil", action: onEdit)
                if let onDelete {
                    adminActionButton(icon: "trash", color: theme.error, action: onDelete)
                }
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Returns the data URI string when `profile_image_url` is base64-encoded inline.
    /// Used by `UserAvatar` to render without a network request.
    private var dataURIString: String? {
        guard let urlString = user.profileImageURL,
              urlString.hasPrefix("data:") else { return nil }
        return urlString
    }

    /// Returns a network URL only when `profile_image_url` is NOT a data URI.
    private var avatarURL: URL? {
        guard let urlString = user.profileImageURL, !urlString.isEmpty else { return nil }
        // Data URIs are handled via dataURIString — don't construct a network URL for them
        if urlString.hasPrefix("data:") { return nil }
        if urlString.hasPrefix("http") { return URL(string: urlString) }
        if urlString == "/user.png" { return nil }
        return URL(string: "\(serverURL)/api/v1/users/\(user.id)/profile/image")
    }

    private func adminActionButton(icon: String, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(color ?? theme.textTertiary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Role Badge

struct RoleBadge: View {
    let role: User.UserRole

    var body: some View {
        Text(role.rawValue.uppercased())
            .scaledFont(size: 10, weight: .heavy)
            .foregroundStyle(roleColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(roleColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var roleColor: Color {
        switch role {
        case .admin: return .green
        case .user: return .blue
        case .pending: return .orange
        }
    }
}

// MARK: - Add User Sheet

struct AddUserSheet: View {
    @Bindable var viewModel: AdminViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $viewModel.addName)
                        .textContentType(.name)
                    TextField("Email", text: $viewModel.addEmail)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $viewModel.addPassword)
                        .textContentType(.newPassword)
                } header: {
                    Text("New User")
                }

                Section {
                    Picker("Role", selection: $viewModel.addRole) {
                        Text("User").tag(User.UserRole.user)
                        Text("Admin").tag(User.UserRole.admin)
                        Text("Pending").tag(User.UserRole.pending)
                    }
                }

                if let error = viewModel.addError {
                    Section {
                        Text(error)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.error)
                    }
                }
            }
            .navigationTitle("Add User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await viewModel.addUser()
                            if viewModel.addError == nil {
                                dismiss()
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(viewModel.addName.isEmpty || viewModel.addEmail.isEmpty || viewModel.addPassword.isEmpty || viewModel.isAddingUser)
                }
            }
        }
    }
}
