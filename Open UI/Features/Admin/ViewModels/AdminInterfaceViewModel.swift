import Foundation
import os.log

/// ViewModel for the Admin Interface settings screen.
/// Manages task config (generation toggles + prompts) and chat config (context compaction).
@Observable
@MainActor
final class AdminInterfaceViewModel {

    // MARK: - State

    var config = AdminTaskConfig()
    var chatConfig = AdminChatConfig()
    var models: [(id: String, name: String)] = []
    var isLoading = false
    var isSaving = false
    var error: String?
    var success = false

    /// Non-public model warning (shown as a toast).
    var modelWarning: String?

    /// Default interface settings JSON string.
    var defaultInterfaceSettingsJSON: String = "{}"
    /// Error from loading/saving default interface settings.
    var defaultInterfaceError: String?

    // MARK: - Private

    private weak var apiClient: APIClient?
    private weak var activeChatStore: ActiveChatStore?
    private var rawModels: [AIModel] = []
    private let logger = Logger(subsystem: "com.openui", category: "AdminInterface")

    // MARK: - Configure

    func configure(apiClient: APIClient?, activeChatStore: ActiveChatStore? = nil) {
        self.apiClient = apiClient
        self.activeChatStore = activeChatStore
    }

    // MARK: - Load

    func load() async {
        guard let api = apiClient else { return }
        isLoading = true
        error = nil
        do {
            async let configTask = api.getAdminTaskConfig()
            async let chatConfigTask: AdminChatConfig = { @MainActor in
                do { return try await api.getAdminChatConfig() }
                catch { return AdminChatConfig() }
            }()
            async let modelsTask: [AIModel] = {
                do { return try await api.getModels() }
                catch { return [] }
            }()
            config = try await configTask
            chatConfig = await chatConfigTask
            rawModels = await modelsTask
            models = rawModels.map { (id: $0.id, name: $0.name) }
            logger.info("Loaded task config + chat config + \(self.models.count) models")
            // Load default interface settings (fire-and-forget — don't block)
            await loadDefaultInterfaceSettings(api: api)
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to load task configuration."
            logger.error("Failed to load task config: \(error.localizedDescription)")
        }
        isLoading = false
    }

    /// `DEFAULT_INTERFACE_SETTINGS` lives in the admin config
    /// (`GET /api/v1/auths/admin/config`), the same place the web UI's General
    /// settings read it from.
    private func loadDefaultInterfaceSettings(api: APIClient) async {
        do {
            let auth = try await api.getAdminAuthConfig()
            let value = auth.defaultInterfaceSettings
            if !value.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                defaultInterfaceSettingsJSON = str
            } else {
                defaultInterfaceSettingsJSON = "{}"
            }
            loadedDefaultInterfaceJSON = defaultInterfaceSettingsJSON
            defaultInterfaceError = nil
        } catch {
            defaultInterfaceSettingsJSON = "{}"
            loadedDefaultInterfaceJSON = nil
            defaultInterfaceError = APIError.from(error).errorDescription ?? error.localizedDescription
            logger.error("Failed to load default interface settings: \(error.localizedDescription)")
        }
    }

    /// The JSON text as loaded — used to skip the save when nothing changed.
    private var loadedDefaultInterfaceJSON: String?

    // MARK: - Save

    func save() async {
        guard let api = apiClient else { return }
        isSaving = true
        error = nil
        success = false
        do {
            async let taskSave = api.updateTaskConfig(config)
            async let chatSave: AdminChatConfig = { @MainActor in
                do { return try await api.updateAdminChatConfig(self.chatConfig) }
                catch { return self.chatConfig }
            }()
            config = try await taskSave
            chatConfig = await chatSave

            // Propagate tool permissions flag to the active chat store immediately
            // so the HITL Auto/Ask toggle becomes live in open chats without restart.
            activeChatStore?.enableToolPermissions = chatConfig.enableToolPermissions

            // Also save default interface settings if changed
            await saveDefaultInterfaceSettings(api: api)

            success = true
            logger.info("Saved task config + chat config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                success = false
            }
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to save task configuration."
            logger.error("Failed to save task config: \(error.localizedDescription)")
        }
        isSaving = false
    }

    /// Saves through `POST /api/v1/auths/admin/config`. The full admin config is
    /// re-fetched first and re-sent with only `DEFAULT_INTERFACE_SETTINGS` changed,
    /// so no other admin setting is touched.
    private func saveDefaultInterfaceSettings(api: APIClient) async {
        let trimmed = defaultInterfaceSettingsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only save if loading succeeded and the text actually changed.
        guard let loaded = loadedDefaultInterfaceJSON,
              trimmed != loaded.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let value: [String: Any]
        if trimmed.isEmpty {
            value = [:]
        } else {
            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                defaultInterfaceError = "Default interface settings must be a JSON object."
                return
            }
            value = json
        }
        do {
            var auth = try await api.getAdminAuthConfig()
            auth.defaultInterfaceSettings = value
            _ = try await api.updateAdminAuthConfig(auth)
            loadedDefaultInterfaceJSON = trimmed
            defaultInterfaceError = nil
        } catch {
            defaultInterfaceError = APIError.from(error).errorDescription ?? error.localizedDescription
            logger.error("Failed to save default interface settings: \(error.localizedDescription)")
        }
    }

    // MARK: - Public Model Validation

    /// Checks if the given model ID has a wildcard `*` access grant (i.e. is public).
    /// Returns `true` if the model is public or validation can't be performed.
    /// Returns `false` and sets `modelWarning` if the model is not public.
    func isModelPublic(_ modelId: String) -> Bool {
        guard !modelId.isEmpty else {
            modelWarning = nil
            return true
        }
        guard let model = rawModels.first(where: { $0.id == modelId }) else {
            // Model not found in list — might be custom-entered, skip validation
            modelWarning = nil
            return true
        }
        guard let raw = model.rawModelItem,
              let info = raw["info"] as? [String: Any],
              let grants = info["access_grants"] as? [[String: Any]] else {
            // No access_grants data — can't validate, assume OK
            modelWarning = nil
            return true
        }
        let isPublic = grants.contains { ($0["principal_id"] as? String) == "*" }
        if !isPublic {
            modelWarning = "This model is not publicly available. Please select another model."
            return false
        } else {
            modelWarning = nil
            return true
        }
    }

    // MARK: - Helpers

    /// Autocomplete max length as a string for text field binding.
    var autocompleteMaxLengthString: String {
        get { "\(config.autocompleteGenerationInputMaxLength)" }
        set {
            if let val = Int(newValue) {
                config.autocompleteGenerationInputMaxLength = val
            }
        }
    }

    /// Context compaction token threshold as a string for text field binding.
    var contextCompactionTokenThresholdString: String {
        get { "\(chatConfig.contextCompactionTokenThreshold)" }
        set {
            if let val = Int(newValue) {
                chatConfig.contextCompactionTokenThreshold = val
            }
        }
    }

    /// Context compaction token cap as a string for text field binding.
    var contextCompactionTokenCapString: String {
        get { "\(chatConfig.contextCompactionTokenCap)" }
        set {
            if let val = Int(newValue) {
                chatConfig.contextCompactionTokenCap = val
            }
        }
    }

    /// Context compaction retention percentage as a string for text field binding.
    var contextCompactionRetentionPercentageString: String {
        get { "\(chatConfig.contextCompactionRetentionPercentage)" }
        set {
            if let val = Int(newValue) {
                chatConfig.contextCompactionRetentionPercentage = max(10, min(50, val))
            }
        }
    }
}
