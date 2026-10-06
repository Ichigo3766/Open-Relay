import Foundation
import os.log

/// ViewModel for the Admin Web Search settings screen.
/// Manages the `web` object inside RetrievalConfig (raw server JSON, see `WebSearchConfig`).
@Observable
final class AdminWebSearchViewModel {

    // MARK: - State

    var retrievalConfig = RetrievalConfig()
    var isLoading = false
    var isSaving = false
    var error: String?
    var success = false

    /// Linkup params are edited as text and validated on save.
    var linkupParamsText = ""

    /// Secure fields currently revealed (keyed by server key).
    var revealedKeys: Set<String> = []

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminWebSearch")

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Field bindings (exact server keys)

    func string(_ key: String) -> String { retrievalConfig.web.string(key) }
    func setString(_ key: String, _ value: String) { retrievalConfig.web.setString(key, value) }
    func bool(_ key: String, default def: Bool = false) -> Bool { retrievalConfig.web.bool(key, default: def) }
    func setBool(_ key: String, _ value: Bool) { retrievalConfig.web.setBool(key, value) }
    func intText(_ key: String) -> String { retrievalConfig.web.intText(key) }
    func setInt(_ key: String, _ text: String) { retrievalConfig.web.setInt(key, text) }
    func setNumericString(_ key: String, _ text: String) { retrievalConfig.web.setNumericString(key, text) }
    func listText(_ key: String) -> String { retrievalConfig.web.stringList(key).joined(separator: ", ") }
    func setList(_ key: String, _ text: String) { retrievalConfig.web.setStringList(key, commaSeparated: text) }

    // MARK: - Load

    func load() async {
        guard let api = apiClient else { return }
        isLoading = true
        error = nil
        do {
            retrievalConfig = try await api.getRetrievalConfig()
            linkupParamsText = retrievalConfig.web.linkupSearchParamsJSON
            logger.info("Loaded web search config")
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to load web search configuration."
            logger.error("Failed to load web search config: \(error.localizedDescription)")
        }
        isLoading = false
    }

    // MARK: - Save

    func save() async {
        guard let api = apiClient else { return }
        // Never send an empty `web` object — the server would reset every web
        // search setting. Only save after a successful load.
        guard retrievalConfig.web.isLoaded else {
            error = "Settings haven't loaded yet. Pull to refresh and try again."
            return
        }
        guard retrievalConfig.web.setLinkupSearchParams(linkupParamsText) else {
            error = "Linkup parameters must be a valid JSON object."
            return
        }
        isSaving = true
        error = nil
        success = false

        do {
            try await api.updateRetrievalConfig(retrievalConfig, includeWeb: true)
            success = true
            logger.info("Saved web search config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                success = false
            }
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to save web search configuration."
            logger.error("Failed to save web search config: \(error.localizedDescription)")
        }
        isSaving = false
    }
}
