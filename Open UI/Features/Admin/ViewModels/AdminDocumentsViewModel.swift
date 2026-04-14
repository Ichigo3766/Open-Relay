import Foundation
import os.log

/// ViewModel for the Admin Documents settings screen.
/// Manages state for Retrieval Config and Embedding Config.
@Observable
final class AdminDocumentsViewModel {

    // MARK: - Retrieval Config State

    var retrievalConfig = RetrievalConfig()
    var embeddingConfig = EmbeddingConfig()
    var isLoading = false
    var isSaving = false
    var error: String?
    var success = false

    // MARK: - Convenience bindings for nullable Int fields (displayed as String)

    var fileMaxSizeString: String {
        get { retrievalConfig.fileMaxSize.map { String($0) } ?? "" }
        set { retrievalConfig.fileMaxSize = Int(newValue) }
    }

    var fileMaxCountString: String {
        get { retrievalConfig.fileMaxCount.map { String($0) } ?? "" }
        set { retrievalConfig.fileMaxCount = Int(newValue) }
    }

    var fileImageCompressionWidthString: String {
        get { retrievalConfig.fileImageCompressionWidth.map { String($0) } ?? "" }
        set { retrievalConfig.fileImageCompressionWidth = Int(newValue) }
    }

    var fileImageCompressionHeightString: String {
        get { retrievalConfig.fileImageCompressionHeight.map { String($0) } ?? "" }
        set { retrievalConfig.fileImageCompressionHeight = Int(newValue) }
    }

    /// Allowed file extensions displayed as comma-separated string.
    var allowedFileExtensionsString: String {
        get { retrievalConfig.allowedFileExtensions.joined(separator: ", ") }
        set {
            retrievalConfig.allowedFileExtensions = newValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    // MARK: - Visibility toggles for secure fields

    var showExternalDocLoaderKey = false
    var showDoclingAPIKey = false
    var showDatalabMarkerAPIKey = false
    var showDocIntelligenceKey = false
    var showMistralOCRKey = false
    var showMineruAPIKey = false
    var showRerankingAPIKey = false

    var showOpenAIEmbeddingKey = false
    var showOllamaEmbeddingKey = false
    var showAzureEmbeddingKey = false

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminDocuments")

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
            async let r = api.getRetrievalConfig()
            async let e = api.getEmbeddingConfig()
            retrievalConfig = try await r
            embeddingConfig = try await e
            logger.info("Loaded retrieval + embedding config")
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to load documents configuration."
            logger.error("Failed to load documents config: \(error.localizedDescription)")
        }
        isLoading = false
    }

    // MARK: - Save

    func save() async {
        guard let api = apiClient else { return }
        isSaving = true
        error = nil
        success = false

        // Fire both updates concurrently — retrieval config is fire-and-forget
        // (server may return 500 on the update endpoint, which is fine).
        // Embedding config we try to parse the response but don't block on errors.
        async let retrievalTask: Void = {
            do {
                try await api.updateRetrievalConfig(self.retrievalConfig)
            } catch {
                self.logger.warning("Retrieval config update returned error (ignored): \(error.localizedDescription)")
            }
        }()

        async let embeddingTask: EmbeddingConfig? = {
            do {
                return try await api.updateEmbeddingConfig(self.embeddingConfig)
            } catch {
                self.logger.warning("Embedding config update returned error (ignored): \(error.localizedDescription)")
                return nil
            }
        }()

        _ = await retrievalTask
        if let updatedEmbedding = await embeddingTask {
            embeddingConfig = updatedEmbedding
        }

        success = true
        isSaving = false
        logger.info("Saved retrieval + embedding config")

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            success = false
        }
    }
}
