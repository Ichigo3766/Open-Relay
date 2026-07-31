import Foundation
import os.log

/// ViewModel for the Admin Authentication settings screen.
/// Manages state for Auth Config (user access, pending accounts), LDAP, and OAuth/OIDC.
@Observable
final class AdminAuthenticationViewModel {

    // MARK: - Auth Config State

    var authConfig = AdminAuthConfig()
    var isLoadingAuthConfig = false
    var isSavingAuthConfig = false
    var authConfigError: String?
    var authConfigSuccess = false

    // MARK: - LDAP State

    var ldapConfig = AdminLdapConfig()
    var ldapServerConfig = AdminLdapServerConfig()
    var isLoadingLdap = false
    var isSavingLdap = false
    var ldapError: String?
    var ldapSuccess = false
    var showLdapPassword = false

    // MARK: - OAuth State

    var oauthConfig = AdminOAuthConfig()
    var isLoadingOAuth = false
    var isSavingOAuth = false
    var oauthError: String?
    var oauthSuccess = false
    var oauthAvailable = true // false if server doesn't support the endpoint

    // MARK: - Groups State (for Default Group picker)

    var groups: [AdminGroupItem] = []

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminAuthentication")

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load All

    func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadAuthConfig() }
            group.addTask { await self.loadLdap() }
            group.addTask { await self.loadOAuth() }
            group.addTask { await self.loadGroups() }
        }
    }

    // MARK: - Auth Config

    func loadAuthConfig() async {
        guard let api = apiClient else { return }
        isLoadingAuthConfig = true
        authConfigError = nil
        do {
            authConfig = try await api.getAdminAuthConfig()
            logger.info("Loaded admin auth config")
        } catch {
            let apiError = APIError.from(error)
            authConfigError = apiError.errorDescription ?? "Failed to load configuration."
            logger.error("Failed to load auth config: \(error.localizedDescription)")
        }
        isLoadingAuthConfig = false
    }

    func saveAuthConfig() async {
        guard let api = apiClient else { return }
        isSavingAuthConfig = true
        authConfigError = nil
        authConfigSuccess = false
        do {
            authConfig = try await api.updateAdminAuthConfig(authConfig)
            authConfigSuccess = true
            logger.info("Saved admin auth config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                authConfigSuccess = false
            }
        } catch {
            let apiError = APIError.from(error)
            authConfigError = apiError.errorDescription ?? "Failed to save configuration."
            logger.error("Failed to save auth config: \(error.localizedDescription)")
        }
        isSavingAuthConfig = false
    }

    // MARK: - LDAP

    func loadLdap() async {
        guard let api = apiClient else { return }
        isLoadingLdap = true
        ldapError = nil
        do {
            async let configResult = api.getAdminLdapConfig()
            async let serverResult = api.getAdminLdapServerConfig()
            ldapConfig = try await configResult
            ldapServerConfig = try await serverResult
            logger.info("Loaded LDAP config")
        } catch {
            logger.warning("Could not load LDAP config: \(error.localizedDescription)")
        }
        isLoadingLdap = false
    }

    func saveLdapConfig() async {
        guard let api = apiClient else { return }
        isSavingLdap = true
        ldapError = nil
        ldapSuccess = false
        do {
            ldapConfig = try await api.updateAdminLdapConfig(ldapConfig)
            if ldapConfig.enableLdap == true {
                ldapServerConfig = try await api.updateAdminLdapServerConfig(ldapServerConfig)
            }
            ldapSuccess = true
            logger.info("Saved LDAP config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                ldapSuccess = false
            }
        } catch {
            let apiError = APIError.from(error)
            ldapError = apiError.errorDescription ?? "Failed to save LDAP configuration."
            logger.error("Failed to save LDAP config: \(error.localizedDescription)")
        }
        isSavingLdap = false
    }

    // MARK: - OAuth

    func loadOAuth() async {
        guard let api = apiClient else { return }
        isLoadingOAuth = true
        oauthError = nil
        do {
            oauthConfig = try await api.getAdminOAuthConfig()
            oauthAvailable = true
            logger.info("Loaded OAuth config")
        } catch {
            // OAuth endpoint may not be available on older servers
            oauthAvailable = false
            logger.warning("Could not load OAuth config: \(error.localizedDescription)")
        }
        isLoadingOAuth = false
    }

    func saveOAuthConfig() async {
        guard let api = apiClient else { return }
        isSavingOAuth = true
        oauthError = nil
        oauthSuccess = false
        do {
            oauthConfig = try await api.updateAdminOAuthConfig(oauthConfig)
            oauthSuccess = true
            logger.info("Saved OAuth config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                oauthSuccess = false
            }
        } catch {
            let apiError = APIError.from(error)
            oauthError = apiError.errorDescription ?? "Failed to save OAuth configuration."
            logger.error("Failed to save OAuth config: \(error.localizedDescription)")
        }
        isSavingOAuth = false
    }

    // MARK: - Groups

    func loadGroups() async {
        guard let api = apiClient else { return }
        do {
            groups = try await api.getAdminGroups()
        } catch {
            logger.warning("Could not load groups: \(error.localizedDescription)")
        }
    }
}
