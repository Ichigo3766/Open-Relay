import SwiftUI

/// A sheet that shows all saved accounts on the current server,
/// allowing the user to switch accounts or add a new one.
struct AccountPickerSheet: View {
    @Bindable var viewModel: AuthViewModel
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var switchingAccountId: String?
    @State private var accountToRemove: SavedAccount?
    @State private var showRemoveConfirmation = false

    private var accounts: [SavedAccount] {
        viewModel.savedAccountsOnActiveServer
    }

    private var activeAccountId: String? {
        dependencies.serverConfigStore.activeServer?.activeAccountId
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    // Server info header
                    if let server = dependencies.serverConfigStore.activeServer {
                        serverHeader(server)
                    }

                    // Account list
                    VStack(spacing: Spacing.sm) {
                        ForEach(accounts) { account in
                            accountRow(account)
                        }
                    }
                    .padding(.horizontal, Spacing.screenPadding)

                    // Add account button
                    addAccountButton
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.sm)
                }
                .padding(.vertical, Spacing.md)
            }
            .background(theme.background)
            .navigationTitle("Switch Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(Color.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: .systemGray5).opacity(0.6))
                            .clipShape(Circle())
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            "Remove Account",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            if let account = accountToRemove {
                Button("Remove \"\(account.displayName)\"", role: .destructive) {
                    Task {
                        await viewModel.removeAccount(account)
                        if viewModel.savedAccountsOnActiveServer.isEmpty {
                            onDismiss()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                accountToRemove = nil
            }
        } message: {
            if let account = accountToRemove {
                Text("This will remove the saved session for \"\(account.displayName)\". You can sign in again anytime.")
            }
        }
    }

    // MARK: - Server Header

    private func serverHeader(_ server: ServerConfig) -> some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "server.rack")
                .scaledFont(size: 24)
                .foregroundStyle(theme.brandPrimary)

            Text(server.name)
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(theme.textPrimary)

            Text(server.url)
                .scaledFont(size: 13)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s")")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Account Row

    @ViewBuilder
    private func accountRow(_ account: SavedAccount) -> some View {
        let isActive = activeAccountId == account.id
        let isSwitching = switchingAccountId == account.id

        Button {
            guard !isSwitching, !isActive else { return }
            switchingAccountId = account.id
            Task {
                await viewModel.switchToAccount(account)
                switchingAccountId = nil
                onDismiss()
            }
        } label: {
            HStack(spacing: Spacing.md) {
                // Avatar
                accountAvatar(account)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xs) {
                        Text(account.displayName)
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        if account.role == .admin {
                            Text("Admin")
                                .scaledFont(size: 10, weight: .medium)
                                .foregroundStyle(theme.brandPrimary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(theme.brandPrimary.opacity(0.12))
                                )
                        }
                    }

                    Text(account.userEmail)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)

                    if let authType = account.authType {
                        Text(authTypeLabel(authType))
                            .scaledFont(size: 11)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer(minLength: 0)

                // Status
                if isSwitching {
                    ProgressView()
                        .controlSize(.small)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.success)
                }

                // Remove button (only for non-active accounts when there are multiple)
                if !isActive && accounts.count > 1 {
                    Button {
                        accountToRemove = account
                        showRemoveConfirmation = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 18)
                            .foregroundStyle(theme.textTertiary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.md)
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
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
        .accessibilityLabel(isActive ? "Active account: \(account.displayName)" : "Switch to \(account.displayName)")
    }

    // MARK: - Account Avatar

    private func accountAvatar(_ account: SavedAccount) -> some View {
        let server = dependencies.serverConfigStore.activeServer
        let avatarURL: URL? = {
            guard let imageURL = account.profileImageURL, !imageURL.isEmpty,
                  let server else { return nil }
            let full = imageURL.hasPrefix("http") ? imageURL : "\(server.url)\(imageURL)"
            return URL(string: full)
        }()

        // Use the live session token for the active account; for others, pull
        // their individual token from the Keychain.
        let token: String? = {
            if activeAccountId == account.id {
                return dependencies.apiClient?.network.authToken
            }
            guard let serverURL = server?.url else { return nil }
            return KeychainService.shared.getToken(forServer: serverURL, userId: account.userId)
        }()

        return UserAvatar(
            size: 40,
            imageURL: avatarURL,
            name: account.displayName,
            authToken: token
        )
    }

    // MARK: - Add Account

    private var addAccountButton: some View {
        Button {
            onDismiss()
            Task {
                await viewModel.addAnotherAccountOnCurrentServer()
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "person.badge.plus")
                    .scaledFont(size: 16)
                Text("Add Another Account")
                    .scaledFont(size: 15, weight: .medium)
            }
            .foregroundStyle(theme.brandPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                    .fill(theme.brandPrimary.opacity(0.08))
            )
        }
    }

    // MARK: - Helpers

    private func initials(for account: SavedAccount) -> String {
        let name = account.userName.isEmpty ? account.userEmail : account.userName
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func authTypeLabel(_ type: AuthType) -> String {
        switch type {
        case .credentials: return "Email & Password"
        case .ldap: return "LDAP"
        case .sso: return "SSO"
        case .apiKey: return "API Key"
        }
    }
}
