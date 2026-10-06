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
            loadedEmbeddingJSON = Self.fingerprint(embeddingConfig)
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

        // Retrieval config — `web` is intentionally NOT sent from this screen
        // (the server would overwrite every web search setting).
        var failures: [String] = []
        do {
            try await api.updateRetrievalConfig(retrievalConfig, includeWeb: false)
        } catch {
            failures.append(APIError.from(error).errorDescription ?? error.localizedDescription)
            logger.error("Retrieval config update failed: \(error.localizedDescription)")
        }

        // Embedding config — only when changed. The server unloads and reloads the
        // embedding model on every update, matching the web UI which only calls
        // this when the embedding settings were edited.
        if embeddingChanged {
            do {
                embeddingConfig = try await api.updateEmbeddingConfig(embeddingConfig)
                loadedEmbeddingJSON = Self.fingerprint(embeddingConfig)
            } catch {
                failures.append(APIError.from(error).errorDescription ?? error.localizedDescription)
                logger.error("Embedding config update failed: \(error.localizedDescription)")
            }
        }

        isSaving = false
        if failures.isEmpty {
            success = true
            logger.info("Saved documents config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                success = false
            }
        } else {
            error = failures.joined(separator: "\n")
        }
    }

    // MARK: - Embedding change tracking

    private var loadedEmbeddingJSON: Data?

    private var embeddingChanged: Bool {
        Self.fingerprint(embeddingConfig) != loadedEmbeddingJSON
    }

    private static func fingerprint(_ config: EmbeddingConfig) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(config)
    }
}
