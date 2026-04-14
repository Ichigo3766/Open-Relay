import Foundation
import SwiftUI
import os.log

/// ViewModel for the Admin Connections tab.
/// Loads OpenAI config, Ollama config, and the misc connections config,
/// then allows toggling/editing each connection and persisting immediately.
@Observable
final class AdminConnectionsViewModel {

    // MARK: - Loading / Error

    var isLoading = false
    var errorMessage: String?

    // MARK: - OpenAI State

    var openAIConfig = OpenAIConfig()
    var isSavingOpenAI = false
    var openAIError: String?

    // MARK: - Ollama State

    var ollamaConfig = OllamaConfig()
    var isSavingOllama = false
    var ollamaError: String?

    // MARK: - Connections Config (Direct Connections + Cache)

    var connectionsConfig = ConnectionsConfig()
    var isSavingConnections = false
    var connectionsError: String?

    // MARK: - Edit Sheet State (OpenAI)

    /// Index of the OpenAI connection being edited (nil = not editing)
    var editingOpenAIIndex: Int?

    // Basic
    var editOpenAIURL = ""
    var editOpenAIKey = ""
    var editOpenAIEnable = true

    // Auth
    var editOpenAIAuthType = "bearer"
    var editOpenAIShowKey = false

    // Headers (raw JSON string)
    var editOpenAIHeadersJSON = ""

    // Config fields
    var editOpenAIConnectionType = "external"
    var editOpenAIPrefixId = ""

    // Model IDs
    var editOpenAIModelIds: [String] = []
    var editOpenAINewModelId = ""

    // Tags
    var editOpenAITags: [String] = []
    var editOpenAINewTag = ""

    // Provider / API type
    var editOpenAIProviderType = ""      // "" = standard OpenAI, "azure" = Azure OpenAI
    var editOpenAIAPIVersion = ""        // only used when providerType == "azure"
    var editOpenAIAPIType = "chat_completions"  // "chat_completions" or "responses"

    // Saving / deleting state
    var isSavingEditedOpenAI = false
    var showDeleteOpenAIConfirmation = false

    // MARK: - Add Sheet State (OpenAI)

    var isShowingAddOpenAI = false

    // Basic
    var addOpenAIURL = ""
    var addOpenAIKey = ""
    var addOpenAIEnable = true

    // Auth
    var addOpenAIAuthType = "bearer"
    var addOpenAIShowKey = false

    // Headers
    var addOpenAIHeadersJSON = ""

    // Config fields
    var addOpenAIConnectionType = "external"
    var addOpenAIPrefixId = ""

    // Model IDs
    var addOpenAIModelIds: [String] = []
    var addOpenAINewModelId = ""

    // Tags
    var addOpenAITags: [String] = []
    var addOpenAINewTag = ""

    // Provider / API type
    var addOpenAIProviderType = ""
    var addOpenAIAPIVersion = ""
    var addOpenAIAPIType = "chat_completions"

    // Saving state
    var isSavingAddOpenAI = false

    // MARK: - Edit Sheet State (Ollama)

    /// Index of the Ollama connection being edited (nil = not editing)
    var editingOllamaIndex: Int?

    // Basic
    var editOllamaURL = ""
    var editOllamaEnable = true

    // Auth
    var editOllamaAuthType = "none"
    var editOllamaShowKey = false
    var editOllamaKey = ""

    // Headers
    var editOllamaHeadersJSON = ""

    // Config fields
    var editOllamaConnectionType = "external"
    var editOlamaPrefixId = ""

    // Model IDs
    var editOllamaModelIds: [String] = []
    var editOllamaNewModelId = ""

    // Tags
    var editOlamaTags: [String] = []
    var editOlamaNewTag = ""

    // Saving / deleting state
    var isSavingEditedOllama = false
    var showDeleteOllamaConfirmation = false

    // MARK: - Add Sheet State (Ollama)

    var isShowingAddOllama = false

    // Basic
    var addOllamaURL = ""
    var addOllamaEnable = true

    // Auth
    var addOllamaAuthType = "none"
    var addOllamaShowKey = false
    var addOllamaKey = ""

    // Headers
    var addOllamaHeadersJSON = ""

    // Config fields
    var addOllamaConnectionType = "external"
    var addOlamaPrefixId = ""

    // Model IDs
    var addOllamaModelIds: [String] = []
    var addOllamaNewModelId = ""

    // Tags
    var addOlamaTags: [String] = []
    var addOlamaNewTag = ""

    // Saving state
    var isSavingAddOllama = false

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminConnections")

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load All

    func loadAll() async {
        guard let api = apiClient else { return }
        isLoading = true
        errorMessage = nil

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadOpenAIConfig(api: api) }
            group.addTask { await self.loadOllamaConfig(api: api) }
            group.addTask { await self.loadConnectionsConfig(api: api) }
        }

        isLoading = false
    }

    // MARK: - OpenAI

    private func loadOpenAIConfig(api: APIClient) async {
        do {
            openAIConfig = try await api.getOpenAIConfig()
        } catch {
            logger.error("Failed to load OpenAI config: \(error)")
            openAIError = error.localizedDescription
        }
    }

    func toggleEnableOpenAIAPI() async {
        guard let api = apiClient else { return }
        openAIConfig.enableOpenAIAPI.toggle()
        await saveOpenAIConfig(api: api)
    }

    func toggleOpenAIConnectionEnabled(at index: Int) async {
        guard let api = apiClient else { return }
        let key = "\(index)"
        if openAIConfig.openAIAPIConfigs[key] == nil {
            openAIConfig.openAIAPIConfigs[key] = OpenAIConnectionConfig()
        }
        openAIConfig.openAIAPIConfigs[key]?.enable.toggle()
        await saveOpenAIConfig(api: api)
    }

    func beginAddOpenAIConnection() {
        addOpenAIURL = ""
        addOpenAIKey = ""
        addOpenAIEnable = true
        addOpenAIAuthType = "bearer"
        addOpenAIShowKey = false
        addOpenAIHeadersJSON = ""
        addOpenAIConnectionType = "external"
        addOpenAIPrefixId = ""
        addOpenAIModelIds = []
        addOpenAINewModelId = ""
        addOpenAITags = []
        addOpenAINewTag = ""
        addOpenAIProviderType = ""
        addOpenAIAPIVersion = ""
        addOpenAIAPIType = "chat_completions"
        isShowingAddOpenAI = true
    }

    func addOpenAIConnection() async {
        guard let api = apiClient else { return }
        isSavingAddOpenAI = true

        let newIndex = openAIConfig.openAIAPIBaseURLs.count
        openAIConfig.openAIAPIBaseURLs.append(addOpenAIURL)
        openAIConfig.openAIAPIKeys.append(addOpenAIKey)

        var cfg = OpenAIConnectionConfig()
        cfg.enable = addOpenAIEnable
        cfg.authType = addOpenAIAuthType
        cfg.connectionType = addOpenAIConnectionType
        cfg.prefixId = addOpenAIPrefixId
        cfg.modelIds = addOpenAIModelIds
        cfg.tags = addOpenAITags.map { OpenAITag(name: $0) }
        cfg.headers = parseHeadersJSON(addOpenAIHeadersJSON)
        cfg.providerType = addOpenAIProviderType
        cfg.apiVersion = addOpenAIAPIVersion
        cfg.apiType = addOpenAIAPIType

        openAIConfig.openAIAPIConfigs["\(newIndex)"] = cfg

        await saveOpenAIConfig(api: api)
        isSavingAddOpenAI = false
        isShowingAddOpenAI = false
    }

    // Add/remove helpers for the Add sheet
    func addNewOpenAIModelId() {
        let trimmed = addOpenAINewModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !addOpenAIModelIds.contains(trimmed) else { return }
        addOpenAIModelIds.append(trimmed)
        addOpenAINewModelId = ""
    }

    func removeNewOpenAIModelId(at offsets: IndexSet) {
        addOpenAIModelIds.remove(atOffsets: offsets)
    }

    func addNewOpenAITag() {
        let trimmed = addOpenAINewTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !addOpenAITags.contains(trimmed) else { return }
        addOpenAITags.append(trimmed)
        addOpenAINewTag = ""
    }

    func removeNewOpenAITag(at offsets: IndexSet) {
        addOpenAITags.remove(atOffsets: offsets)
    }

    func saveOpenAIConnectionEdit() async {
        guard let api = apiClient, let idx = editingOpenAIIndex else { return }
        isSavingEditedOpenAI = true

        // URL
        if openAIConfig.openAIAPIBaseURLs.indices.contains(idx) {
            openAIConfig.openAIAPIBaseURLs[idx] = editOpenAIURL
        }

        // API Key
        while openAIConfig.openAIAPIKeys.count <= idx {
            openAIConfig.openAIAPIKeys.append("")
        }
        openAIConfig.openAIAPIKeys[idx] = editOpenAIKey

        // Config object
        var cfg = openAIConfig.openAIAPIConfigs["\(idx)"] ?? OpenAIConnectionConfig()
        cfg.enable = editOpenAIEnable
        cfg.authType = editOpenAIAuthType
        cfg.connectionType = editOpenAIConnectionType
        cfg.prefixId = editOpenAIPrefixId
        cfg.modelIds = editOpenAIModelIds
        cfg.tags = editOpenAITags.map { OpenAITag(name: $0) }
        cfg.headers = parseHeadersJSON(editOpenAIHeadersJSON)
        cfg.providerType = editOpenAIProviderType
        cfg.apiVersion = editOpenAIAPIVersion
        cfg.apiType = editOpenAIAPIType

        openAIConfig.openAIAPIConfigs["\(idx)"] = cfg

        await saveOpenAIConfig(api: api)
        isSavingEditedOpenAI = false
        editingOpenAIIndex = nil
    }

    func deleteOpenAIConnection(at index: Int) async {
        guard let api = apiClient else { return }
        guard openAIConfig.openAIAPIBaseURLs.indices.contains(index) else { return }

        openAIConfig.openAIAPIBaseURLs.remove(at: index)
        if openAIConfig.openAIAPIKeys.indices.contains(index) {
            openAIConfig.openAIAPIKeys.remove(at: index)
        }

        // Rebuild configs dict with re-indexed keys
        var newConfigs: [String: OpenAIConnectionConfig] = [:]
        for i in openAIConfig.openAIAPIBaseURLs.indices {
            let oldKey = i < index ? "\(i)" : "\(i + 1)"
            newConfigs["\(i)"] = openAIConfig.openAIAPIConfigs[oldKey] ?? OpenAIConnectionConfig()
        }
        openAIConfig.openAIAPIConfigs = newConfigs

        await saveOpenAIConfig(api: api)
    }

    private func saveOpenAIConfig(api: APIClient) async {
        isSavingOpenAI = true
        openAIError = nil
        do {
            openAIConfig = try await api.updateOpenAIConfig(openAIConfig)
        } catch {
            logger.error("Failed to save OpenAI config: \(error)")
            openAIError = error.localizedDescription
        }
        isSavingOpenAI = false
    }

    // MARK: - Ollama

    private func loadOllamaConfig(api: APIClient) async {
        do {
            ollamaConfig = try await api.getOllamaConfig()
        } catch {
            logger.error("Failed to load Ollama config: \(error)")
            ollamaError = error.localizedDescription
        }
    }

    func toggleEnableOllamaAPI() async {
        guard let api = apiClient else { return }
        ollamaConfig.enableOllamaAPI.toggle()
        await saveOllamaConfig(api: api)
    }

    func toggleOllamaConnectionEnabled(at index: Int) async {
        guard let api = apiClient else { return }
        let key = "\(index)"
        if ollamaConfig.ollamaAPIConfigs[key] == nil {
            ollamaConfig.ollamaAPIConfigs[key] = OllamaConnectionConfig()
        }
        ollamaConfig.ollamaAPIConfigs[key]?.enable.toggle()
        await saveOllamaConfig(api: api)
    }

    func beginAddOllamaConnection() {
        addOllamaURL = ""
        addOllamaEnable = true
        addOllamaAuthType = "none"
        addOllamaShowKey = false
        addOllamaKey = ""
        addOllamaHeadersJSON = ""
        addOllamaConnectionType = "external"
        addOlamaPrefixId = ""
        addOllamaModelIds = []
        addOllamaNewModelId = ""
        addOlamaTags = []
        addOlamaNewTag = ""
        isShowingAddOllama = true
    }

    func addOllamaConnection() async {
        guard let api = apiClient else { return }
        isSavingAddOllama = true

        let newIndex = ollamaConfig.ollamaBaseURLs.count
        ollamaConfig.ollamaBaseURLs.append(addOllamaURL)

        var cfg = OllamaConnectionConfig()
        cfg.enable = addOllamaEnable
        cfg.authType = addOllamaAuthType
        cfg.connectionType = addOllamaConnectionType
        cfg.prefixId = addOlamaPrefixId
        cfg.modelIds = addOllamaModelIds
        cfg.tags = addOlamaTags.map { OllamaTag(name: $0) }
        cfg.headers = parseHeadersJSON(addOllamaHeadersJSON)
        ollamaConfig.ollamaAPIConfigs["\(newIndex)"] = cfg

        await saveOllamaConfig(api: api)
        isSavingAddOllama = false
        isShowingAddOllama = false
    }

    // Add/remove helpers for the Ollama Add sheet
    func addNewOllamaModelId() {
        let trimmed = addOllamaNewModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !addOllamaModelIds.contains(trimmed) else { return }
        addOllamaModelIds.append(trimmed)
        addOllamaNewModelId = ""
    }

    func removeNewOllamaModelId(at offsets: IndexSet) {
        addOllamaModelIds.remove(atOffsets: offsets)
    }

    func addNewOllamaTag() {
        let trimmed = addOlamaNewTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !addOlamaTags.contains(trimmed) else { return }
        addOlamaTags.append(trimmed)
        addOlamaNewTag = ""
    }

    func removeNewOllamaTag(at offsets: IndexSet) {
        addOlamaTags.remove(atOffsets: offsets)
    }

    func beginEditOllamaConnection(at index: Int) {
        let connections = ollamaConfig.orderedConnections
        guard let conn = connections.first(where: { $0.index == index }) else { return }
        let cfg = conn.config

        editingOllamaIndex = conn.index
        editOllamaURL = conn.url
        editOllamaEnable = cfg.enable
        editOllamaAuthType = cfg.authType.isEmpty ? "none" : cfg.authType
        editOllamaKey = ""   // keys not stored in Ollama config, start blank
        editOllamaShowKey = false
        editOllamaConnectionType = cfg.connectionType.isEmpty ? "external" : cfg.connectionType
        editOlamaPrefixId = cfg.prefixId
        editOllamaModelIds = cfg.modelIds
        editOlamaTags = cfg.tags.map { $0.name }
        editOllamaNewModelId = ""
        editOlamaNewTag = ""

        if cfg.headers.isEmpty {
            editOllamaHeadersJSON = ""
        } else if let data = try? JSONSerialization.data(withJSONObject: cfg.headers, options: .prettyPrinted),
                  let str = String(data: data, encoding: .utf8) {
            editOllamaHeadersJSON = str
        } else {
            editOllamaHeadersJSON = ""
        }
    }

    func saveOllamaConnectionEdit() async {
        guard let api = apiClient, let idx = editingOllamaIndex else { return }
        isSavingEditedOllama = true

        // URL
        if ollamaConfig.ollamaBaseURLs.indices.contains(idx) {
            ollamaConfig.ollamaBaseURLs[idx] = editOllamaURL
        }

        // Config
        var cfg = ollamaConfig.ollamaAPIConfigs["\(idx)"] ?? OllamaConnectionConfig()
        cfg.enable = editOllamaEnable
        cfg.authType = editOllamaAuthType
        cfg.connectionType = editOllamaConnectionType
        cfg.prefixId = editOlamaPrefixId
        cfg.modelIds = editOllamaModelIds
        cfg.tags = editOlamaTags.map { OllamaTag(name: $0) }
        cfg.headers = parseHeadersJSON(editOllamaHeadersJSON)
        ollamaConfig.ollamaAPIConfigs["\(idx)"] = cfg

        await saveOllamaConfig(api: api)
        isSavingEditedOllama = false
        editingOllamaIndex = nil
    }

    // Add/remove helpers for the Ollama Edit sheet
    func addEditOllamaModelId() {
        let trimmed = editOllamaNewModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !editOllamaModelIds.contains(trimmed) else { return }
        editOllamaModelIds.append(trimmed)
        editOllamaNewModelId = ""
    }

    func removeEditOllamaModelId(at offsets: IndexSet) {
        editOllamaModelIds.remove(atOffsets: offsets)
    }

    func addEditOllamaTag() {
        let trimmed = editOlamaNewTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !editOlamaTags.contains(trimmed) else { return }
        editOlamaTags.append(trimmed)
        editOlamaNewTag = ""
    }

    func removeEditOllamaTag(at offsets: IndexSet) {
        editOlamaTags.remove(atOffsets: offsets)
    }

    func deleteOllamaConnection(at index: Int) async {
        guard let api = apiClient else { return }
        guard ollamaConfig.ollamaBaseURLs.indices.contains(index) else { return }

        ollamaConfig.ollamaBaseURLs.remove(at: index)

        // Rebuild configs dict with re-indexed keys
        var newConfigs: [String: OllamaConnectionConfig] = [:]
        for i in ollamaConfig.ollamaBaseURLs.indices {
            let oldKey = i < index ? "\(i)" : "\(i + 1)"
            newConfigs["\(i)"] = ollamaConfig.ollamaAPIConfigs[oldKey] ?? OllamaConnectionConfig()
        }
        ollamaConfig.ollamaAPIConfigs = newConfigs

        await saveOllamaConfig(api: api)
    }

    private func saveOllamaConfig(api: APIClient) async {
        isSavingOllama = true
        ollamaError = nil
        do {
            ollamaConfig = try await api.updateOllamaConfig(ollamaConfig)
        } catch {
            logger.error("Failed to save Ollama config: \(error)")
            ollamaError = error.localizedDescription
        }
        isSavingOllama = false
    }

    // MARK: - Connections Config

    private func loadConnectionsConfig(api: APIClient) async {
        do {
            connectionsConfig = try await api.getConnectionsConfig()
        } catch {
            logger.error("Failed to load connections config: \(error)")
            connectionsError = error.localizedDescription
        }
    }

    func toggleDirectConnections() async {
        guard let api = apiClient else { return }
        connectionsConfig.enableDirectConnections.toggle()
        await saveConnectionsConfig(api: api)
    }

    func toggleBaseModelsCache() async {
        guard let api = apiClient else { return }
        connectionsConfig.enableBaseModelsCache.toggle()
        await saveConnectionsConfig(api: api)
    }

    private func saveConnectionsConfig(api: APIClient) async {
        isSavingConnections = true
        connectionsError = nil
        do {
            connectionsConfig = try await api.updateConnectionsConfig(connectionsConfig)
        } catch {
            logger.error("Failed to save connections config: \(error)")
            connectionsError = error.localizedDescription
        }
        isSavingConnections = false
    }

    // MARK: - Edit Sheet Helpers (OpenAI)

    func beginEditOpenAIConnection(at index: Int) {
        let connections = openAIConfig.orderedConnections
        guard let conn = connections.first(where: { $0.index == index }) else { return }
        let cfg = conn.config

        editingOpenAIIndex = conn.index
        editOpenAIURL = conn.url
        editOpenAIKey = conn.key
        editOpenAIEnable = cfg.enable
        editOpenAIAuthType = cfg.authType.isEmpty ? "bearer" : cfg.authType
        editOpenAIConnectionType = cfg.connectionType.isEmpty ? "external" : cfg.connectionType
        editOpenAIPrefixId = cfg.prefixId
        editOpenAIModelIds = cfg.modelIds
        editOpenAITags = cfg.tags.map { $0.name }
        editOpenAINewModelId = ""
        editOpenAINewTag = ""
        editOpenAIShowKey = false
        editOpenAIProviderType = cfg.providerType
        editOpenAIAPIVersion = cfg.apiVersion
        editOpenAIAPIType = cfg.apiType.isEmpty ? "chat_completions" : cfg.apiType

        // Serialize headers dict back to JSON string for editing
        if cfg.headers.isEmpty {
            editOpenAIHeadersJSON = ""
        } else if let data = try? JSONSerialization.data(withJSONObject: cfg.headers, options: .prettyPrinted),
                  let str = String(data: data, encoding: .utf8) {
            editOpenAIHeadersJSON = str
        } else {
            editOpenAIHeadersJSON = ""
        }
    }

    func addEditModelId() {
        let trimmed = editOpenAINewModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !editOpenAIModelIds.contains(trimmed) else { return }
        editOpenAIModelIds.append(trimmed)
        editOpenAINewModelId = ""
    }

    func removeEditModelId(at offsets: IndexSet) {
        editOpenAIModelIds.remove(atOffsets: offsets)
    }

    func addEditTag() {
        let trimmed = editOpenAINewTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !editOpenAITags.contains(trimmed) else { return }
        editOpenAITags.append(trimmed)
        editOpenAINewTag = ""
    }

    func removeEditTag(at offsets: IndexSet) {
        editOpenAITags.remove(atOffsets: offsets)
    }

    // MARK: - Private Helpers

    private func parseHeadersJSON(_ json: String) -> [String: String] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8) else { return [:] }

        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return dict
        } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var coerced: [String: String] = [:]
            for (k, v) in dict { coerced[k] = "\(v)" }
            return coerced
        }
        return [:]
    }
}
