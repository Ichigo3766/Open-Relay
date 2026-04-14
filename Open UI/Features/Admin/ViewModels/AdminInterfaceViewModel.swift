import Foundation
import os.log

/// ViewModel for the Admin Interface settings screen (task configuration).
@Observable
final class AdminInterfaceViewModel {

    // MARK: - State

    var config = AdminTaskConfig()
    var models: [(id: String, name: String)] = []
    var isLoading = false
    var isSaving = false
    var error: String?
    var success = false

    /// Non-public model warning (shown as a toast).
    var modelWarning: String?

    // MARK: - Private

    private weak var apiClient: APIClient?
    private var rawModels: [AIModel] = []
    private let logger = Logger(subsystem: "com.openui", category: "AdminInterface")

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load

    func load() async {
        guard let api = apiClient else { return }
        isLoading = true
        error = nil
        do {
            async let configTask = api.getAdminTaskConfig()
            async let modelsTask: [AIModel] = {
                do { return try await api.getModels() }
                catch { return [] }
            }()
            config = try await configTask
            rawModels = await modelsTask
            models = rawModels.map { (id: $0.id, name: $0.name) }
            logger.info("Loaded task config + \(self.models.count) models")
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to load task configuration."
            logger.error("Failed to load task config: \(error.localizedDescription)")
        }
        isLoading = false
    }

    // MARK: - Save

    func save() async {
        guard let api = apiClient else { return }
        isSaving = true
        error = nil
        success = false
        do {
            config = try await api.updateTaskConfig(config)
            success = true
            logger.info("Saved task config")
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
}
