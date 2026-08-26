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

    private func loadDefaultInterfaceSettings(api: APIClient) async {
        do {
            // DEFAULT_INTERFACE_SETTINGS is stored under ui.default_interface_settings in the
            // server config. Load it via GET /api/v1/configs/ui which returns the full ui config.
            let json = try await api.network.requestJSON(path: "/api/v1/configs/ui")
            // The value is nested under the "default_interface_settings" key
            if let nested = json["default_interface_settings"],
               let data = try? JSONSerialization.data(withJSONObject: nested, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                defaultInterfaceSettingsJSON = str
            } else {
                defaultInterfaceSettingsJSON = "{}"
            }
            defaultInterfaceError = nil
        } catch {
            // Endpoint may not exist on older servers — silently ignore
            defaultInterfaceSettingsJSON = "{}"
            logger.debug("Default interface settings endpoint unavailable: \(error.localizedDescription)")
        }
    }

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

    private func saveDefaultInterfaceSettings(api: APIClient) async {
        let trimmed = defaultInterfaceSettingsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            defaultInterfaceError = "Invalid JSON"
            return
        }
        do {
            _ = try await api.network.requestJSON(path: "/api/v1/configs/interface", method: .post, body: json)
            defaultInterfaceError = nil
        } catch {
            defaultInterfaceError = error.localizedDescription
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
