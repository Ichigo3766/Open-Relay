import Foundation
import os.log

/// ViewModel for the Admin Sub-agents Settings screen (v0.11.0).
@Observable
final class AdminSubagentsViewModel {

    // MARK: - State

    var config = SubagentsConfig()
    var isLoading = false
    var isSaving = false
    var saveError: String?
    var saveSuccess = false

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminSubagents")

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load

    func load() async {
        guard let api = apiClient else { return }
        isLoading = true
        do {
            config = try await api.getSubagentsConfig()
            logger.info("Loaded subagents config")
        } catch {
            logger.warning("Could not load subagents config: \(error.localizedDescription)")
        }
        isLoading = false
    }

    // MARK: - Save

    func save() async {
        guard let api = apiClient else { return }
        isSaving = true
        saveError = nil
        saveSuccess = false
        do {
            config = try await api.setSubagentsConfig(config)
            saveSuccess = true
            logger.info("Saved subagents config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                saveSuccess = false
            }
        } catch {
            let apiError = APIError.from(error)
            saveError = apiError.errorDescription ?? "Failed to save sub-agents configuration."
            logger.error("Failed to save subagents config: \(error.localizedDescription)")
        }
        isSaving = false
    }
}
