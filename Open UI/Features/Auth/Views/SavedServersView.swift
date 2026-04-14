import SwiftUI

/// Full-page server switcher — shows all saved server profiles with their
/// saved accounts, connection status, and switch/edit/delete actions.
///
/// Presented as:
/// - The root phase after sign-out when multiple servers are saved.
/// - A sheet/navigation destination from Settings → "Switch Server".
/// - The bottom section of `ServerConnectionView` when servers exist.
struct SavedServersView: View {
    @Bindable var viewModel: AuthViewModel
    /// When `true`, the view includes an "Add New Server" button and full controls.
    /// When `false` (embedded in ServerConnectionView), it's a compact list.
    var showAddServerButton: Bool = true
    /// Optional dismiss action for sheet presentation.
    var onDismiss: (() -> Void)? = nil

    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @State private var serverToDelete: ServerConfig?
    @State private var showDeleteConfirmation = false
    @State private var isSwitching = false
    @State private var switchingServerId: String?
    @State private var switchingAccountId: String?
    /// Sheet state for "Add New Server" — presented modally so the user can cancel.
    @State private var showAddServerSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — only shown when used as a standalone screen
            if showAddServerButton {
                headerView
                    .padding(.bottom, Spacing.lg)
            }

            if viewModel.savedServers.isEmpty {
                emptyStateView
            } else {
                serverListView
            }

            if showAddServerButton {
                addServerButton
                    .padding(.top, Spacing.lg)
            }
        }
        // "Add New Server" — presented as a sheet so the user can cancel
        .sheet(isPresented: $showAddServerSheet) {
            AddServerSheet(viewModel: viewModel, onDismiss: {
                showAddServerSheet = false
            })
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "server.rack")
                .scaledFont(size: 36)
                .foregroundStyle(theme.brandPrimary)
                .padding(.bottom, Spacing.xs)

            Text("Your Servers")
                .scaledFont(size: 28, weight: .bold, design: .rounded)
                .foregroundStyle(theme.textPrimary)

            Text("Select a server to continue")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xl)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "network.slash")
                .scaledFont(size: 44)
                .foregroundStyle(theme.textTertiary)
            Text("No Saved Servers")
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text("Connect to an OpenWebUI server to get started.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    // MARK: - Server List

    private var serverListView: some View {
        VStack(spacing: Spacing.md) {
            ForEach(viewModel.savedServers) { server in
                let isActive = dependencies.serverConfigStore.activeServer?.id == server.id
                ServerRowView(
                    server: server,
                    isActive: isActive,
                    isSwitchingServer: switchingServerId == server.id && isSwitching,
                    switchingAccountId: $switchingAccountId,
                    onSwitchServer: {
                        Task { await handleSwitch(to: server) }
                    },
                    onSwitchToAccount: { account in
                        Task { await handleSwitchToAccount(account, on: server) }
                    },
                    onAddAccount: {
                        Task { await handleAddAccount(on: server) }
                    },
                    onDelete: {
                        serverToDelete = server
                        showDeleteConfirmation = true
                    }
                )
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .confirmationDialog(
            "Remove Server",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let server = serverToDelete {
                Button("Remove \"\(server.name)\"", role: .destructive) {
                    Task { await viewModel.removeServer(id: server.id) }
                }
            }
            Button("Cancel", role: .cancel) {
                serverToDelete = nil
            }
        } message: {
            if let server = serverToDelete {
                Text("This will remove \"\(server.name)\" and sign you out of that server. Your server-side data is not affected.")
            }
        }
    }

    // MARK: - Add Server Button

    private var addServerButton: some View {
        Button {
            // Present as a sheet — user can cancel without losing current session
            showAddServerSheet = true
        } label: {
            Label("Add New Server", systemImage: "plus.circle.fill")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.brandPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                        .fill(theme.brandPrimary.opacity(0.08))
                )
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.xl)
    }

    // MARK: - Switch Handler

    private func handleSwitch(to server: ServerConfig) async {
        guard !isSwitching else { return }
        isSwitching = true
        switchingServerId = server.id
        onDismiss?()
        await viewModel.switchToServer(server)
        isSwitching = false
        switchingServerId = nil
    }

    // MARK: - Switch To Specific Account on a Server

    private func handleSwitchToAccount(_ account: SavedAccount, on server: ServerConfig) async {
        guard switchingAccountId == nil else { return }
        switchingAccountId = account.id

        let isActiveServer = dependencies.serverConfigStore.activeServer?.id == server.id

        if isActiveServer {
            // Already on this server — just switch account
            await viewModel.switchToAccount(account)
        } else {
            // Switch server first, then switch to the specific account
            onDismiss?()
            await viewModel.switchToServer(server)
            // Now switch to the specific account if it's not the one that was auto-selected
            if dependencies.serverConfigStore.activeServer?.activeAccountId != account.id {
                await viewModel.switchToAccount(account)
            }
        }

        switchingAccountId = nil
    }

    // MARK: - Add Account on a Server

    private func handleAddAccount(on server: ServerConfig) async {
        let isActiveServer = dependencies.serverConfigStore.activeServer?.id == server.id

        if !isActiveServer {
            // Switch to the server first
            onDismiss?()
            await viewModel.switchToServer(server)
        }
        // Now add another account
        await viewModel.addAnotherAccountOnCurrentServer()
    }
}

// MARK: - Server Row

private struct ServerRowView: View {
    let server: ServerConfig
    let isActive: Bool
    let isSwitchingServer: Bool
    @Binding var switchingAccountId: String?
    let onSwitchServer: () -> Void
    let onSwitchToAccount: (SavedAccount) -> Void
    let onAddAccount: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    private var hasToken: Bool {
        KeychainService.shared.hasToken(forServer: server.url)
    }

    private var statusColor: Color {
        if isActive { return theme.success }
        if hasToken { return theme.warning }
        return theme.textTertiary
    }

    private var statusLabel: String {
        if isActive { return "Connected" }
        if hasToken { return "Saved" }
        return "Not signed in"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Server header row
            serverHeaderRow

            // Saved accounts section
            if !server.savedAccounts.isEmpty {
                Divider()
                    .padding(.horizontal, Spacing.md)

                accountsList
            }

            // Add account / Connect button
            Divider()
                .padding(.horizontal, Spacing.md)

            bottomAction
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .fill(isActive ? theme.brandPrimary.opacity(0.06) : theme.surfaceContainer)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                        .strokeBorder(
                            isActive ? theme.brandPrimary.opacity(0.3) : theme.cardBorder,
                            lineWidth: isActive ? 1.5 : 0.5
                        )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
    }

    // MARK: - Server Header

    private var serverHeaderRow: some View {
        HStack(spacing: Spacing.md) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityLabel(statusLabel)

            // Server info
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(server.name)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                Text(server.url)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            // Status pill
            Text(statusLabel)
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(isActive ? theme.success : theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isActive ? theme.success.opacity(0.12) : theme.surfaceContainer)
                )

            // Delete button
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .padding(Spacing.sm)
            }
            .accessibilityLabel("Remove \(server.name)")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Accounts List

    private var accountsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(server.savedAccounts.enumerated()), id: \.element.id) { index, account in
                let isActiveAccount = isActive && server.activeAccountId == account.id
                let isSwitching = switchingAccountId == account.id

                accountRow(account, isActiveAccount: isActiveAccount, isSwitching: isSwitching)

                if index < server.savedAccounts.count - 1 {
                    Divider()
                        .padding(.leading, Spacing.md + 32 + Spacing.sm)
                }
            }
        }
    }

    private func accountRow(_ account: SavedAccount, isActiveAccount: Bool, isSwitching: Bool) -> some View {
        Button {
            guard !isSwitching, !isActiveAccount else { return }
            onSwitchToAccount(account)
        } label: {
            HStack(spacing: Spacing.sm) {
                // Avatar
                accountAvatarView(account)

                // Name & email
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Spacing.xs) {
                        Text(account.displayName)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        if account.role == .admin {
                            Text("Admin")
                                .scaledFont(size: 9, weight: .semibold)
                                .foregroundStyle(theme.brandPrimary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(theme.brandPrimary.opacity(0.12))
                                )
                        }
                    }

                    Text(account.userEmail)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // Status
                if isSwitching {
                    ProgressView()
                        .controlSize(.small)
                } else if isActiveAccount {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.success)
                } else {
                    Text("Switch")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(theme.brandPrimary.opacity(0.1))
                        )
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSwitching || isActiveAccount)
    }

    private func accountAvatarView(_ account: SavedAccount) -> some View {
        let avatarURL: URL? = {
            guard let imageURL = account.profileImageURL, !imageURL.isEmpty else { return nil }
            let full = imageURL.hasPrefix("http") ? imageURL : "\(server.url)\(imageURL)"
            return URL(string: full)
        }()

        // Use per-account token from Keychain
        let token = KeychainService.shared.getToken(forServer: server.url, userId: account.userId)

        return UserAvatar(
            size: 32,
            imageURL: avatarURL,
            name: account.displayName,
            authToken: token
        )
    }

    // MARK: - Bottom Action

    private var bottomAction: some View {
        Group {
            if server.savedAccounts.isEmpty {
                // No accounts — show "Connect" button
                Button(action: onSwitchServer) {
                    HStack(spacing: Spacing.xs) {
                        if isSwitchingServer {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.right.circle")
                                .scaledFont(size: 13)
                        }
                        Text("Connect")
                            .scaledFont(size: 13, weight: .medium)
                    }
                    .foregroundStyle(theme.brandPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.sm)
                }
                .disabled(isSwitchingServer)
            } else {
                // Has accounts — show "Add Another Account"
                Button(action: onAddAccount) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "person.badge.plus")
                            .scaledFont(size: 12)
                        Text("Add Another Account")
                            .scaledFont(size: 12, weight: .medium)
                    }
                    .foregroundStyle(theme.brandPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.sm)
                }
            }
        }
    }
}

// MARK: - Compact Saved Servers (embedded in ServerConnectionView)

/// A compact list of saved servers shown beneath the URL field in
/// `ServerConnectionView`. Tapping a row immediately switches to that server.
struct CompactSavedServersSection: View {
    @Bindable var viewModel: AuthViewModel

    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @State private var switchingServerId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Saved Servers")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, Spacing.xs)

            VStack(spacing: Spacing.sm) {
                ForEach(viewModel.savedServers) { server in
                    compactServerRow(server)
                }
            }
        }
    }

    @ViewBuilder
    private func compactServerRow(_ server: ServerConfig) -> some View {
        let isActive = dependencies.serverConfigStore.activeServer?.id == server.id
        let isSwitching = switchingServerId == server.id
        let accounts = server.savedAccounts

        Button {
            guard !isSwitching else { return }
            switchingServerId = server.id
            Task {
                await viewModel.switchToServer(server)
                switchingServerId = nil
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(isActive ? theme.success : (KeychainService.shared.hasToken(forServer: server.url) ? theme.warning : theme.textTertiary))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if !accounts.isEmpty {
                        // Show account names
                        Text(accounts.map(\.displayName).joined(separator: ", "))
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    } else if let userName = server.lastUserName, !userName.isEmpty {
                        Text(userName)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text(server.url)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                // Show stacked avatars for saved accounts
                if !accounts.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(accounts.prefix(3)) { account in
                            compactAccountAvatar(account, serverURL: server.url)
                        }
                        if accounts.count > 3 {
                            Text("+\(accounts.count - 3)")
                                .scaledFont(size: 10, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(theme.surfaceContainer))
                        }
                    }
                }

                if isSwitching {
                    ProgressView()
                        .controlSize(.small)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.success)
                } else {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .fill(theme.surfaceContainer)
            )
        }
        // Only disable when actively switching — always allow tapping, even the
        // "active" server (user may be signed out and want to go to login screen).
        .disabled(isSwitching)
    }

    private func compactAccountAvatar(_ account: SavedAccount, serverURL: String) -> some View {
        let avatarURL: URL? = {
            guard let imageURL = account.profileImageURL, !imageURL.isEmpty else { return nil }
            let full = imageURL.hasPrefix("http") ? imageURL : "\(serverURL)\(imageURL)"
            return URL(string: full)
        }()
        let token = KeychainService.shared.getToken(forServer: serverURL, userId: account.userId)

        return UserAvatar(
            size: 22,
            imageURL: avatarURL,
            name: account.displayName,
            authToken: token
        )
        .overlay(
            Circle()
                .stroke(theme.surfaceContainer, lineWidth: 1.5)
        )
    }
}
