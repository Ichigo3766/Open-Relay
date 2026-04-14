import Foundation
import os.log

/// ViewModel for the Admin Images settings screen.
@Observable
final class AdminImagesViewModel {

    // MARK: - State

    var config = ImageConfig()
    var models: [ImageModelItem] = []
    var isLoading = false
    var isSaving = false
    var error: String?
    var success = false

    // URL verification
    var isVerifying = false
    var verifyResult: Bool?

    // Visibility toggles for secure fields
    var showOpenAIKey = false
    var showComfyUIKey = false
    var showAutoAuth = false
    var showGeminiKey = false
    var showEditOpenAIKey = false
    var showEditComfyUIKey = false
    var showEditGeminiKey = false

    // Workflow editor sheet state
    var showWorkflowEditor = false
    var editingWorkflowIsEdit = false  // false = create workflow, true = edit workflow
    var workflowEditorText = ""

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminImages")

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
            async let configTask = api.getImageConfig()
            async let modelsTask: [ImageModelItem] = {
                do { return try await api.getImageModels() }
                catch { return [] }
            }()
            config = try await configTask
            models = await modelsTask
            logger.info("Loaded image config + \(self.models.count) models")
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to load image configuration."
            logger.error("Failed to load image config: \(error.localizedDescription)")
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
            config = try await api.updateImageConfig(config)
            success = true
            logger.info("Saved image config")
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                success = false
            }
        } catch {
            let apiError = APIError.from(error)
            self.error = apiError.errorDescription ?? "Failed to save image configuration."
            logger.error("Failed to save image config: \(error.localizedDescription)")
        }
        isSaving = false
    }

    // MARK: - Verify URL

    func verifyURL() async {
        guard let api = apiClient else { return }
        isVerifying = true
        verifyResult = nil
        do {
            // Save first so the server uses the current URL
            config = try await api.updateImageConfig(config)
            let result = try await api.verifyImageConfigURL()
            verifyResult = result
            logger.info("URL verify result: \(result)")
        } catch {
            verifyResult = false
            logger.error("URL verify failed: \(error.localizedDescription)")
        }
        isVerifying = false
        // Clear result after 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            verifyResult = nil
        }
    }

    // MARK: - Workflow Editor Helpers

    func openWorkflowEditor(forEdit: Bool) {
        editingWorkflowIsEdit = forEdit
        let raw = forEdit ? config.imagesEditComfyUIWorkflow : config.comfyUIWorkflow
        workflowEditorText = prettyPrintJSON(raw)
        showWorkflowEditor = true
    }

    func saveWorkflowFromEditor() {
        // Compact the JSON for storage (remove pretty-printing)
        let compacted = compactJSON(workflowEditorText) ?? workflowEditorText
        if editingWorkflowIsEdit {
            config.imagesEditComfyUIWorkflow = compacted
        } else {
            config.comfyUIWorkflow = compacted
        }
        showWorkflowEditor = false
    }

    func importWorkflowJSON(_ data: Data, forEdit: Bool) {
        if let str = String(data: data, encoding: .utf8) {
            let compacted = compactJSON(str) ?? str
            if forEdit {
                config.imagesEditComfyUIWorkflow = compacted
            } else {
                config.comfyUIWorkflow = compacted
            }
        }
    }

    // MARK: - JSON Helpers

    func prettyPrintJSON(_ string: String) -> String {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8)
        else { return string }
        return result
    }

    private func compactJSON(_ string: String) -> String? {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let result = String(data: compact, encoding: .utf8)
        else { return nil }
        return result
    }
}
