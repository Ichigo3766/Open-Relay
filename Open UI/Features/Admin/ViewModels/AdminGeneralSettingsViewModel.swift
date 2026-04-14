import Foundation
import os.log

/// ViewModel for the Admin General Settings screen.
/// Manages state for Auth Config, Webhook, LDAP, Banners, and Groups.
@Observable
final class AdminGeneralSettingsViewModel {

    // MARK: - Auth Config State

    var authConfig = AdminAuthConfig()
    var isLoadingAuthConfig = false
    var isSavingAuthConfig = false
    var authConfigError: String?
    var authConfigSuccess = false

    // MARK: - Webhook State

    var webhookURL = ""
    var isLoadingWebhook = false
    var isSavingWebhook = false
    var webhookError: String?
    var webhookSuccess = false

    // MARK: - LDAP State

    var ldapConfig = AdminLdapConfig()
    var ldapServerConfig = AdminLdapServerConfig()
    var isLoadingLdap = false
    var isSavingLdap = false
    var ldapError: String?
    var ldapSuccess = false
    var showLdapPassword = false

    // MARK: - Banners State

    var banners: [AdminBannerItem] = []
    var isLoadingBanners = false
    var isSavingBanners = false
    var bannersError: String?
    var bannersSuccess = false

    // Banner editing
    var showBannerEditor = false
    var editingBanner: AdminBannerItem?
    var bannerEditorType = "info"
    var bannerEditorTitle = ""
    var bannerEditorContent = ""
    var bannerEditorDismissible = true

    // MARK: - Groups State

    var groups: [AdminGroupItem] = []
    var isLoadingGroups = false

    // MARK: - Private

    private weak var apiClient: APIClient?
    private var defaultAdminEmail: String = ""
    private var defaultServerURL: String = ""
    private let logger = Logger(subsystem: "com.openui", category: "AdminGeneralSettings")

    // MARK: - Configure

    func configure(apiClient: APIClient?, defaultAdminEmail: String = "", defaultServerURL: String = "") {
        self.apiClient = apiClient
        self.defaultAdminEmail = defaultAdminEmail
        self.defaultServerURL = defaultServerURL
    }

    // MARK: - Load All

    func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadAuthConfig() }
            group.addTask { await self.loadWebhook() }
            group.addTask { await self.loadLdap() }
            group.addTask { await self.loadBanners() }
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
            if authConfig.adminEmail.isEmpty { authConfig.adminEmail = defaultAdminEmail }
            if authConfig.webuiURL.isEmpty { authConfig.webuiURL = defaultServerURL }
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
            // Auto-dismiss success after 3s
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

    // MARK: - Webhook

    func loadWebhook() async {
        guard let api = apiClient else { return }
        isLoadingWebhook = true
        webhookError = nil
        do {
            webhookURL = try await api.getWebhookURL()
            logger.info("Loaded webhook URL")
        } catch {
            // Webhook endpoint may not exist on older servers — silently ignore
            logger.warning("Could not load webhook URL: \(error.localizedDescription)")
        }
        isLoadingWebhook = false
    }

    func saveWebhook() async {
        guard let api = apiClient else { return }
        isSavingWebhook = true
        webhookError = nil
        webhookSuccess = false
        do {
            try await api.updateWebhookURL(webhookURL)
            webhookSuccess = true
            logger.info("Saved webhook URL")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                webhookSuccess = false
            }
        } catch {
            let apiError = APIError.from(error)
            webhookError = apiError.errorDescription ?? "Failed to save webhook URL."
            logger.error("Failed to save webhook: \(error.localizedDescription)")
        }
        isSavingWebhook = false
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
            // LDAP endpoint may not be available — silently ignore
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

    // MARK: - Banners

    func loadBanners() async {
        guard let api = apiClient else { return }
        isLoadingBanners = true
        bannersError = nil
        do {
            banners = try await api.getAdminBanners()
            logger.info("Loaded \(self.banners.count) banners")
        } catch {
            logger.warning("Could not load banners: \(error.localizedDescription)")
        }
        isLoadingBanners = false
    }

    func saveBanners() async {
        guard let api = apiClient else { return }
        isSavingBanners = true
        bannersError = nil
        bannersSuccess = false
        do {
            banners = try await api.updateAdminBanners(banners)
            bannersSuccess = true
            logger.info("Saved banners")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                bannersSuccess = false
            }
        } catch {
            let apiError = APIError.from(error)
            bannersError = apiError.errorDescription ?? "Failed to save banners."
            logger.error("Failed to save banners: \(error.localizedDescription)")
        }
        isSavingBanners = false
    }

    func deleteBanner(id: String) {
        banners.removeAll { $0.id == id }
    }

    // MARK: - Banner Editor

    func startAddingBanner() {
        editingBanner = nil
        bannerEditorType = "info"
        bannerEditorTitle = ""
        bannerEditorContent = ""
        bannerEditorDismissible = true
        showBannerEditor = true
    }

    func startEditingBanner(_ banner: AdminBannerItem) {
        editingBanner = banner
        bannerEditorType = banner.type
        bannerEditorTitle = banner.title ?? ""
        bannerEditorContent = banner.content
        bannerEditorDismissible = banner.dismissible
        showBannerEditor = true
    }

    func commitBannerEdit() {
        if let existing = editingBanner, let index = banners.firstIndex(where: { $0.id == existing.id }) {
            banners[index] = AdminBannerItem(
                id: existing.id,
                type: bannerEditorType,
                title: bannerEditorTitle.isEmpty ? nil : bannerEditorTitle,
                content: bannerEditorContent,
                dismissible: bannerEditorDismissible,
                timestamp: existing.timestamp
            )
        } else {
            let newBanner = AdminBannerItem(
                id: UUID().uuidString,
                type: bannerEditorType,
                title: bannerEditorTitle.isEmpty ? nil : bannerEditorTitle,
                content: bannerEditorContent,
                dismissible: bannerEditorDismissible,
                timestamp: Int(Date().timeIntervalSince1970)
            )
            banners.append(newBanner)
        }
        showBannerEditor = false
        editingBanner = nil
    }

    // MARK: - Groups

    func loadGroups() async {
        guard let api = apiClient else { return }
        isLoadingGroups = true
        do {
            groups = try await api.getAdminGroups()
            logger.info("Loaded \(self.groups.count) groups")
        } catch {
            logger.warning("Could not load groups: \(error.localizedDescription)")
        }
        isLoadingGroups = false
    }
}
