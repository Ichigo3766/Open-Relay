import Foundation
import os.log

/// ViewModel for the Admin Code Execution settings screen.
@Observable
final class AdminCodeExecutionViewModel {

    // MARK: - State

    var config = CodeExecutionConfig()
    var isLoading = false
    var isSaving = false
    var error: String?
    var success = false

    // Visibility toggles for secure fields
    var showExecAuthToken = false
    var showExecAuthPassword = false
    var showInterpreterAuthToken = false
    var showInterpreterAuthPassword = false

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminCodeExecution")

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
            config = try await api.getCodeExecutionConfig()
            logger.info("Loaded code execution config")
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to load code execution configuration."
            logger.error("Failed to load code execution config: \(error.localizedDescription)")
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
            config = try await api.updateCodeExecutionConfig(config)
            success = true
            logger.info("Saved code execution config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                success = false
            }
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to save code execution configuration."
            logger.error("Failed to save code execution config: \(error.localizedDescription)")
        }
        isSaving = false
    }
}
