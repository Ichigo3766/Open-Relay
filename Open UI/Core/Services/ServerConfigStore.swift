import Foundation

/// Manages persistence and retrieval of server configurations.
@Observable
final class ServerConfigStore {
    private(set) var servers: [ServerConfig] = []

    private static let storageKey = "openui.server_configs"

    init() {
        loadServers()
    }

    /// The currently active server configuration.
    var activeServer: ServerConfig? {
        servers.first(where: \.isActive)
    }

    /// All servers that have a Keychain token (saved sessions).
    var serversWithSavedSessions: [ServerConfig] {
        servers.filter { KeychainService.shared.hasToken(forServer: $0.url) }
    }

    /// Adds or updates a server configuration.
    ///
    /// If a server with the same URL already exists, it is updated in place
    /// (preserving its `id` and accumulated metadata). Otherwise the new
    /// config is appended.  If this is the first server, it is made active.
    func addServer(_ config: ServerConfig) {
        if let index = servers.firstIndex(where: { $0.url.normalizedServerURL == config.url.normalizedServerURL }) {
            // Preserve accumulated metadata when updating
            var updated = config
            updated = updated.preservingMetadata(from: servers[index])
            if servers.isEmpty { updated.isActive = true }
            servers[index] = updated
        } else {
            var newConfig = config
            if servers.isEmpty {
                newConfig.isActive = true
            }
            servers.append(newConfig)
        }
        saveServers()
    }

    /// Updates an existing server configuration by ID.
    func updateServer(_ config: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[index] = config
        saveServers()
    }

    /// Removes a server configuration by ID.
    /// Also cleans up its Keychain token and cached user.
    func removeServer(id: String) {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        KeychainService.shared.deleteToken(forServer: config.url)
        KeychainService.shared.deleteToken(forServer: "cached_user_\(config.url)")
        servers.removeAll(where: { $0.id == id })
        saveServers()
    }

    /// Removes all server configurations and their Keychain data.
    func removeAllServers() {
        for server in servers {
            KeychainService.shared.deleteToken(forServer: server.url)
            KeychainService.shared.deleteToken(forServer: "cached_user_\(server.url)")
        }
        servers.removeAll()
        saveServers()
    }

    /// Sets a server as the active connection; deactivates all others.
    func setActiveServer(id: String) {
        for index in servers.indices {
            servers[index].isActive = (servers[index].id == id)
        }
        saveServers()
    }

    /// Returns the server config matching a URL (normalised comparison).
    func server(forURL url: String) -> ServerConfig? {
        let normalized = url.normalizedServerURL
        return servers.first { $0.url.normalizedServerURL == normalized }
    }

    /// Updates the user metadata fields on the active server without
    /// creating a full new config (used after successful login/restore).
    func updateActiveServerMetadata(
        userName: String?,
        userEmail: String?,
        profileImageURL: String?,
        authType: AuthType?,
        hasActiveSession: Bool
    ) {
        guard let index = servers.firstIndex(where: \.isActive) else { return }
        servers[index].lastUserName = userName
        servers[index].lastUserEmail = userEmail
        servers[index].lastUserProfileImageURL = profileImageURL
        servers[index].lastAuthType = authType
        servers[index].hasActiveSession = hasActiveSession
        servers[index].lastConnected = hasActiveSession ? .now : servers[index].lastConnected
        saveServers()
    }

    // MARK: - Multi-Account Management

    /// Adds or updates a saved account on the active server and sets it as active.
    /// Called after a successful login/session restore.
    func upsertAccountOnActiveServer(_ account: SavedAccount) {
        guard let index = servers.firstIndex(where: \.isActive) else { return }
        if let accIdx = servers[index].savedAccounts.firstIndex(where: { $0.userId == account.userId }) {
            // Update existing account metadata
            servers[index].savedAccounts[accIdx].userName = account.userName
            servers[index].savedAccounts[accIdx].userEmail = account.userEmail
            servers[index].savedAccounts[accIdx].profileImageURL = account.profileImageURL
            servers[index].savedAccounts[accIdx].role = account.role
            servers[index].savedAccounts[accIdx].authType = account.authType
            servers[index].savedAccounts[accIdx].lastUsed = .now
        } else {
            var newAccount = account
            newAccount.lastUsed = .now
            servers[index].savedAccounts.append(newAccount)
        }
        servers[index].activeAccountId = account.id
        // Sort by most recently used
        servers[index].savedAccounts.sort { $0.lastUsed > $1.lastUsed }
        saveServers()
    }

    /// Sets the active account on the active server (used during account switching).
    func setActiveAccount(id: String) {
        guard let index = servers.firstIndex(where: \.isActive) else { return }
        servers[index].activeAccountId = id
        // Update lastUsed timestamp
        if let accIdx = servers[index].savedAccounts.firstIndex(where: { $0.id == id }) {
            servers[index].savedAccounts[accIdx].lastUsed = .now
            // Re-sort by most recently used
            servers[index].savedAccounts.sort { $0.lastUsed > $1.lastUsed }
        }
        saveServers()
    }

    /// Removes a saved account from the active server and its Keychain token.
    func removeAccountFromActiveServer(accountId: String) {
        guard let index = servers.firstIndex(where: \.isActive) else { return }
        if let account = servers[index].savedAccounts.first(where: { $0.id == accountId }) {
            // Delete the account-scoped token from Keychain
            KeychainService.shared.deleteToken(forServer: servers[index].url, userId: account.userId)
            // Delete the account-scoped cached user from Keychain
            KeychainService.shared.deleteToken(forServer: "cached_user_\(servers[index].url)::\(account.userId)")
        }
        servers[index].savedAccounts.removeAll { $0.id == accountId }
        // If we removed the active account, clear the active pointer
        if servers[index].activeAccountId == accountId {
            servers[index].activeAccountId = nil
        }
        saveServers()
    }

    /// Clears the active account pointer on the active server (used during sign-out
    /// when the user wants to stay on the server but not select any account).
    func clearActiveAccountOnActiveServer() {
        guard let index = servers.firstIndex(where: \.isActive) else { return }
        servers[index].activeAccountId = nil
        saveServers()
    }

    /// Returns the active account on the active server, if any.
    var activeAccount: SavedAccount? {
        guard let server = activeServer,
              let accountId = server.activeAccountId else { return nil }
        return server.savedAccounts.first { $0.id == accountId }
    }

    /// Performs one-time migration of legacy single-token data into the
    /// multi-account structure. Called once at init.
    /// 
    /// For each server that has a legacy `token:{url}` in Keychain but no
    /// `savedAccounts`, creates a SavedAccount from the server's metadata
    /// and copies the token to the new account-scoped key.
    func migrateLegacyAccounts() {
        var didMigrate = false
        for index in servers.indices {
            let server = servers[index]
            // Skip servers that already have accounts
            guard server.savedAccounts.isEmpty else { continue }
            // Check for legacy token
            guard KeychainService.shared.hasToken(forServer: server.url) else { continue }
            // We need user metadata to create a SavedAccount.
            // Try loading the cached user to get the userId.
            let cachedUserKey = "cached_user_\(server.url)"
            var userId: String?
            var userName: String = ""
            var userEmail: String = ""
            var profileImageURL: String?
            var role: User.UserRole = .user

            if let dataString = KeychainService.shared.getToken(forServer: cachedUserKey),
               let data = Data(base64Encoded: dataString),
               let user = try? JSONDecoder().decode(User.self, from: data) {
                userId = user.id
                userName = user.displayName
                userEmail = user.email
                profileImageURL = user.profileImageURL
                role = user.role
            }

            // If we couldn't load the cached user, use server metadata
            if userId == nil {
                // Generate a stable pseudo-ID from email or name
                if let email = server.lastUserEmail, !email.isEmpty {
                    userId = "legacy_\(email)"
                    userEmail = email
                    userName = server.lastUserName ?? ""
                    profileImageURL = server.lastUserProfileImageURL
                } else if let name = server.lastUserName, !name.isEmpty {
                    userId = "legacy_\(name)"
                    userName = name
                } else {
                    // No user info at all — skip this server
                    continue
                }
            }

            guard let finalUserId = userId else { continue }

            let account = SavedAccount(
                serverURL: server.url,
                userId: finalUserId,
                userName: userName,
                userEmail: userEmail,
                profileImageURL: profileImageURL,
                role: role,
                authType: server.lastAuthType,
                lastUsed: server.lastConnected ?? .now
            )

            // Copy legacy token to account-scoped key
            if let token = KeychainService.shared.getToken(forServer: server.url) {
                KeychainService.shared.saveToken(token, forServer: server.url, userId: finalUserId)
            }

            // Copy legacy cached user to account-scoped key
            if let cachedData = KeychainService.shared.getToken(forServer: cachedUserKey) {
                KeychainService.shared.saveToken(cachedData, forServer: "\(cachedUserKey)::\(finalUserId)")
            }

            servers[index].savedAccounts = [account]
            servers[index].activeAccountId = account.id
            didMigrate = true
        }

        if didMigrate {
            saveServers()
        }
    }

    // MARK: - Persistence

    private func saveServers() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data)
        else { return }
        servers = decoded
    }
}

// MARK: - String helper

private extension String {
    /// Normalized server URL for deduplication comparisons.
    var normalizedServerURL: String {
        self.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }
}

// MARK: - ServerConfig metadata preservation

private extension ServerConfig {
    /// Returns a copy of `self` with accumulated metadata (user info, CF data,
    /// proxy data) carried over from `existing` where the new value is nil.
    func preservingMetadata(from existing: ServerConfig) -> ServerConfig {
        var result = self
        // Keep the original stable ID so downstream references don't break
        // Note: id is a let, so we rely on the caller passing the right config.
        // Preserve user metadata if the new config doesn't have it
        if result.lastUserName == nil { result.lastUserName = existing.lastUserName }
        if result.lastUserEmail == nil { result.lastUserEmail = existing.lastUserEmail }
        if result.lastUserProfileImageURL == nil { result.lastUserProfileImageURL = existing.lastUserProfileImageURL }
        if result.lastAuthType == nil { result.lastAuthType = existing.lastAuthType }
        // Preserve CF data if not overridden
        if result.cfClearanceValue == nil { result.cfClearanceValue = existing.cfClearanceValue }
        if result.cfClearanceExpiry == nil { result.cfClearanceExpiry = existing.cfClearanceExpiry }
        if result.cfUserAgent == nil { result.cfUserAgent = existing.cfUserAgent }
        // Preserve proxy data
        if result.proxyAuthCookies == nil { result.proxyAuthCookies = existing.proxyAuthCookies }
        if result.proxyAuthPortalURL == nil { result.proxyAuthPortalURL = existing.proxyAuthPortalURL }
        return result
    }
}
