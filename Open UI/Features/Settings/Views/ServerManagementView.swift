import SwiftUI

/// Server configuration management view for viewing and editing server settings.
struct ServerManagementView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var editingURL: String = ""
    @State private var editingName: String = ""
    @State private var editingSelfSigned: Bool = false
    @State private var editingHeaderEntries: [CustomHeaderEntry] = []
    @State private var isEditing: Bool = false
    @State private var showDeleteConfirmation = false
    @State private var serverHealthy: Bool?
    @State private var isCheckingHealth: Bool = false
    @State private var refreshedConfig: BackendConfig?
    @State private var accountToRemove: SavedAccount?
    @State private var showRemoveAccountConfirmation = false
    @State private var switchingAccountId: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sectionGap) {
                // Connection status
                connectionStatusSection

                // Server details
                SettingsSection(header: "Server Details") {
                    detailRow(icon: "globe", label: "URL", value: activeServer?.url ?? "—")
                    detailRow(icon: "tag", label: "Name", value: displayedConfig?.name ?? activeServer?.name ?? "—")
                    if let version = displayedConfig?.version ?? viewModel.serverVersion {
                        detailRow(icon: "number", label: "Version", value: version)
                    }
                    detailRow(
                        icon: "lock.shield",
                        label: "Self-Signed Certs",
                        value: activeServer?.allowSelfSignedCertificates == true ? "Allowed" : "Not Allowed",
                        showDivider: false
                    )
                }

                // Accounts on this server
                accountsSection

                // Actions
                SettingsSection(header: "Actions") {
                    SettingsCell(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Check Connection",
                        subtitle: isCheckingHealth ? "Checking..." : nil,
                        accessory: isCheckingHealth ? .none : .chevron
                    ) {
                        Task { await checkHealth() }
                    }

                    SettingsCell(
                        icon: "pencil",
                        title: "Edit Server",
                        showDivider: false,
                        accessory: .chevron
                    ) {
                        startEditing()
                    }
                }

                // Danger zone
                SettingsSection(header: "Danger Zone") {
                    DestructiveSettingsCell(
                        icon: "trash",
                        title: "Remove Server"
                    ) {
                        showDeleteConfirmation = true
                    }
                }
            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await checkHealth()
        }
        .sheet(isPresented: $isEditing) {
            editServerSheet
        }
        .confirmationDialog(
            "Remove Server",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove & Sign Out", role: .destructive) {
                Task { await viewModel.signOutAndDisconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will sign you out and remove the server configuration.")
        }
        .confirmationDialog(
            "Remove Account",
            isPresented: $showRemoveAccountConfirmation,
            titleVisibility: .visible
        ) {
            if let account = accountToRemove {
                Button("Remove \"\(account.displayName)\"", role: .destructive) {
                    Task {
                        await viewModel.removeAccount(account)
                    }
                    accountToRemove = nil
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

    // MARK: - Active Server

    @Environment(AppDependencyContainer.self) private var dependencies

    private var activeServer: ServerConfig? {
        dependencies.serverConfigStore.activeServer
    }

    /// The most up-to-date backend config: prefer what we refreshed during health check,
    /// fall back to what the view model already has.
    private var displayedConfig: BackendConfig? {
        refreshedConfig ?? viewModel.backendConfig
    }

    // MARK: - Connection Status

    private var connectionStatusSection: some View {
        SettingsSection {
            HStack(spacing: Spacing.md) {
                serverLogoView
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.divider, lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(statusTitle)
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textPrimary)

                    Text(statusSubtitle)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                // Status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            .padding(Spacing.md)
        }
    }

    @ViewBuilder
    private var serverLogoView: some View {
        if let urlString = activeServer?.url,
           let faviconURL = URL(string: "\(urlString)/favicon.ico") {
            CachedAsyncImage(url: faviconURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .background(Color.white)
            } placeholder: {
                fallbackServerIcon
            }
        } else {
            fallbackServerIcon
        }
    }

    private var fallbackServerIcon: some View {
        Image(systemName: "server.rack")
            .scaledFont(size: 20, weight: .medium)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surfaceContainer)
    }

    private var statusColor: Color {
        switch serverHealthy {
        case .some(true): return theme.success
        case .some(false): return theme.error
        case .none: return theme.textTertiary
        }
    }

    private var statusTitle: String {
        if isCheckingHealth { return "Checking…" }
        switch serverHealthy {
        case .some(true): return "Connected"
        case .some(false): return "Connection Issue"
        case .none: return "Unknown"
        }
    }

    private var statusSubtitle: String {
        activeServer?.url ?? "No server configured"
    }

    // MARK: - Health Check

    private func checkHealth() async {
        guard let config = activeServer else { return }
        isCheckingHealth = true
        let client = APIClient(serverConfig: config)
        // Re-use the existing auth token so the request is authenticated
        if let token = dependencies.apiClient?.network.authToken {
            client.updateAuthToken(token)
        }
        async let healthTask = client.checkHealth()
        async let configTask: BackendConfig? = try? await client.getBackendConfig()
        let (healthy, freshConfig) = await (healthTask, configTask)
        serverHealthy = healthy
        if let fresh = freshConfig {
            refreshedConfig = fresh
            // Keep the view model in sync too
            viewModel.backendConfig = fresh
        }
        isCheckingHealth = false
    }

    // MARK: - Accounts Section

    private var accountsSection: some View {
        let accounts = viewModel.savedAccountsOnActiveServer
        let activeId = activeServer?.activeAccountId

        return SettingsSection(header: "Accounts") {
            if accounts.isEmpty {
                // No saved accounts yet — show a hint
                HStack(spacing: Spacing.md) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textTertiary)
                    Text("No saved accounts")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.chatBubblePadding)
            } else {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    let isActive = activeId == account.id
                    let isSwitching = switchingAccountId == account.id
                    let isLast = index == accounts.count - 1

                    accountRowInSettings(
                        account,
                        isActive: isActive,
                        isSwitching: isSwitching,
                        showDivider: !isLast
                    )
                }
            }

            // Add another account button
            Button {
                Task {
                    await viewModel.addAnotherAccountOnCurrentServer()
                }
            } label: {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "person.badge.plus")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: IconSize.lg)

                    Text("Add Another Account")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)

                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.chatBubblePadding)
            }
            .buttonStyle(.plain)
        }
    }

    private func accountRowInSettings(
        _ account: SavedAccount,
        isActive: Bool,
        isSwitching: Bool,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                guard !isSwitching, !isActive else { return }
                switchingAccountId = account.id
                Task {
                    await viewModel.switchToAccount(account)
                    switchingAccountId = nil
                }
            } label: {
                HStack(spacing: Spacing.md) {
                    // Avatar
                    accountAvatarView(account)

                    // Name & email
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Spacing.xs) {
                            Text(account.displayName)
                                .scaledFont(size: 14, weight: .medium)
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
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    // Status indicator
                    if isSwitching {
                        ProgressView()
                            .controlSize(.small)
                    } else if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 18)
                            .foregroundStyle(theme.success)
                    } else {
                        Text("Switch")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(theme.brandPrimary.opacity(0.1))
                            )
                    }

                    // Remove button for non-active accounts
                    if !isActive {
                        Button {
                            accountToRemove = account
                            showRemoveAccountConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .scaledFont(size: 13)
                                .foregroundStyle(theme.error.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }
            .buttonStyle(.plain)
            .disabled(isSwitching)

            if showDivider {
                Divider()
                    .padding(.leading, Spacing.md + 36 + Spacing.md)
            }
        }
    }

    private func accountAvatarView(_ account: SavedAccount) -> some View {
        let avatarURL: URL? = {
            guard let imageURL = account.profileImageURL, !imageURL.isEmpty,
                  let server = activeServer else { return nil }
            let full = imageURL.hasPrefix("http") ? imageURL : "\(server.url)\(imageURL)"
            return URL(string: full)
        }()

        // Use the live session token for the active account; for others, pull
        // their individual token from the Keychain.
        let token: String? = {
            let activeId = activeServer?.activeAccountId
            if activeId == account.id {
                return dependencies.apiClient?.network.authToken
            }
            guard let serverURL = activeServer?.url else { return nil }
            return KeychainService.shared.getToken(forServer: serverURL, userId: account.userId)
        }()

        return UserAvatar(
            size: 36,
            imageURL: avatarURL,
            name: account.displayName,
            authToken: token
        )
    }

    // MARK: - Detail Row

    private func detailRow(
        icon: String,
        label: String,
        value: String,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: IconSize.lg)

                Text(label)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                Text(value)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider()
                    .padding(.leading, Spacing.md + IconSize.lg + Spacing.md)
            }
        }
    }

    // MARK: - Edit Sheet

    private func startEditing() {
        editingURL = activeServer?.url ?? ""
        editingName = activeServer?.name ?? ""
        editingSelfSigned = activeServer?.allowSelfSignedCertificates ?? false
        // Convert persisted [String:String] dict back to editable entries.
        // Skip system-managed headers (User-Agent set by CF/proxy flows).
        let systemKeys: Set<String> = ["User-Agent"]
        editingHeaderEntries = (activeServer?.customHeaders ?? [:])
            .filter { !systemKeys.contains($0.key) }
            .map { CustomHeaderEntry(id: UUID().uuidString, key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
        isEditing = true
    }

    private var editServerSheet: some View {
        NavigationStack {
            Form {
                Section("Server URL") {
                    TextField("https://your-server.com", text: $editingURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section("Display Name") {
                    TextField("My Server", text: $editingName)
                }

                Section("Security") {
                    Toggle("Allow Self-Signed Certificates", isOn: $editingSelfSigned)
                }

                Section {
                    CustomHeadersEditor(entries: $editingHeaderEntries)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("Custom Headers")
                } footer: {
                    Text("HTTP headers sent with every request to this server. Useful for reverse proxies or services that require extra authentication headers.")
                        .font(.caption)
                }
            }
            .navigationTitle("Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isEditing = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEdits()
                        isEditing = false
                    }
                    .disabled(editingURL.isEmpty)
                }
            }
        }
    }

    private func saveEdits() {
        guard var config = activeServer else { return }
        config.url = editingURL
        config.name = editingName
        config.allowSelfSignedCertificates = editingSelfSigned

        // Merge user-edited headers back in. Preserve system-managed headers
        // (CF User-Agent etc.) that were stripped out of the editing UI.
        let systemKeys: Set<String> = ["User-Agent"]
        var updatedHeaders: [String: String] = config.customHeaders.filter { systemKeys.contains($0.key) }
        for entry in editingHeaderEntries {
            let trimmedKey = entry.key.trimmingCharacters(in: .whitespaces)
            guard !trimmedKey.isEmpty else { continue }
            updatedHeaders[trimmedKey] = entry.value
        }
        config.customHeaders = updatedHeaders

        dependencies.serverConfigStore.updateServer(config)
        dependencies.refreshServices()
    }
}
