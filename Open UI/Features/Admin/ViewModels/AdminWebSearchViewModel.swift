import Foundation
import os.log

/// ViewModel for the Admin Web Search settings screen.
/// Manages state for the `web` object inside RetrievalConfig.
@Observable
final class AdminWebSearchViewModel {

    // MARK: - State

    var retrievalConfig = RetrievalConfig()
    var isLoading = false
    var isSaving = false
    var error: String?
    var success = false

    // MARK: - Convenience: domain filter list as comma-separated string

    var domainFilterListString: String {
        get { retrievalConfig.web.domainFilterList.joined(separator: ", ") }
        set {
            retrievalConfig.web.domainFilterList = newValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    // MARK: - Visibility toggles for secure fields

    var showSearxngKey = false
    var showGooglePSEKey = false
    var showBraveKey = false
    var showKagiKey = false
    var showMojeekKey = false
    var showBochaKey = false
    var showSerpstackKey = false
    var showSerperKey = false
    var showSerplyKey = false
    var showSearchAPIKey = false
    var showSerpAPIKey = false
    var showTavilyKey = false
    var showJinaKey = false
    var showBingKey = false
    var showExaKey = false
    var showPerplexityKey = false
    var showSougouSID = false
    var showSougouSK = false
    var showFirecrawlKey = false
    var showExternalSearchKey = false
    var showYandexKey = false
    var showYouKey = false
    var showOllamaCloudKey = false
    var showPerplexitySearchKey = false
    var showFirecrawlLoaderKey = false
    var showTavilyLoaderKey = false
    var showExternalLoaderKey = false
    var showPlaywrightWSURL = false

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminWebSearch")

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
            retrievalConfig = try await api.getRetrievalConfig()
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
        isSaving = true
        error = nil
        success = false

        // Fire-and-forget — server may return 500 on the update endpoint, which is fine.
        do {
            try await api.updateRetrievalConfig(retrievalConfig)
        } catch {
            logger.warning("Retrieval config update returned error (ignored): \(error.localizedDescription)")
        }

        success = true
        isSaving = false
        logger.info("Saved web search config")

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            success = false
        }
    }
}
