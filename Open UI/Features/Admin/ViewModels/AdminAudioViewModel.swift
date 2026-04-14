import Foundation
import os.log

/// ViewModel for the Admin Audio settings screen.
@Observable
final class AdminAudioViewModel {

    // MARK: - State

    var config = AdminAudioConfig()
    var ttsModels: [(id: String, name: String)] = []
    var voices: [(id: String, name: String)] = []
    var isLoading = false
    var isSaving = false
    var error: String?
    var success = false

    // Visibility toggles for secure fields
    // TTS
    var showTTSOpenAIKey = false
    var showTTSApiKey = false
    // STT
    var showSTTOpenAIKey = false
    var showSTTDeepgramKey = false
    var showSTTAzureKey = false
    var showSTTMistralKey = false

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminAudio")

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
            async let configTask = api.getAdminAudioConfig()
            async let modelsTask: [[String: Any]] = {
                do { return try await api.getAudioModels() }
                catch { return [] }
            }()
            async let voicesTask: [[String: Any]] = {
                do { return try await api.getVoices() }
                catch { return [] }
            }()
            config = try await configTask
            let rawModels = await modelsTask
            ttsModels = rawModels.compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                let name = m["name"] as? String ?? id
                return (id: id, name: name)
            }
            let rawVoices = await voicesTask
            voices = rawVoices.compactMap { v in
                guard let id = v["id"] as? String else { return nil }
                let name = v["name"] as? String ?? id
                return (id: id, name: name)
            }
            logger.info("Loaded audio config + \(self.ttsModels.count) models + \(self.voices.count) voices")
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to load audio configuration."
            logger.error("Failed to load audio config: \(error.localizedDescription)")
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
            config = try await api.updateAudioConfig(config)
            success = true
            logger.info("Saved audio config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                success = false
            }
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to save audio configuration."
            logger.error("Failed to save audio config: \(error.localizedDescription)")
        }
        isSaving = false
    }

    // MARK: - Helpers

    /// Supported MIME types as a comma-separated string for editing
    var supportedMIMETypesString: String {
        get { config.stt.supportedContentTypes.joined(separator: ", ") }
        set {
            config.stt.supportedContentTypes = newValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}
