import Foundation
import os.log

// MARK: - External Knowledge Models

struct ExternalKnowledgeConnection: Identifiable {
    var id: String
    var name: String
    var provider: String
    var endpoint: String
    var enabled: Bool
    var config: [String: Any]

    init(from json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        name = json["name"] as? String ?? ""
        provider = json["provider"] as? String ?? "qdrant"
        endpoint = json["endpoint"] as? String ?? ""
        enabled = json["enabled"] as? Bool ?? true
        config = json["config"] as? [String: Any] ?? [:]
    }
}

struct ExternalKnowledgeItem: Identifiable {
    var id: String
    var name: String
    var description: String
    var connectionId: String?
    var provider: String?
    var sourceName: String?

    init(from json: [String: Any]) {
        id = json["id"] as? String ?? UUID().uuidString
        name = json["name"] as? String ?? ""
        description = json["description"] as? String ?? ""
        if let meta = json["meta"] as? [String: Any],
           let external = meta["external"] as? [String: Any] {
            connectionId = external["connection_id"] as? String
            provider = external["provider"] as? String
            if let source = external["source"] as? [String: Any] {
                sourceName = source["name"] as? String
            }
        }
    }
}

// MARK: - AdminExternalKnowledgeViewModel

@Observable
final class AdminExternalKnowledgeViewModel {

    // MARK: - State

    var isLoading = false
    var error: String?

    var connections: [ExternalKnowledgeConnection] = []
    var items: [ExternalKnowledgeItem] = []

    // Editor
    var showEditor = false
    var editingItemId: String? = nil

    // Form fields
    var formName = ""
    var formDescription = ""
    var formProvider = "qdrant"
    var formEndpoint = ""
    var formAPIKey = ""
    var showAPIKey = false
    var formTimeout = "30"
    var formDbName = ""
    var formSourceName = ""
    var formContentField = "payload.text"
    var formVectorField = ""
    var formMetadataField = "payload.metadata"
    var formDocumentIdField = "id"
    var formTableName = "document_chunk"
    var formCollectionField = "collection_name"
    var formTestQuery = ""

    var testResult: [String: Any]? = nil
    var isTesting = false
    var isCreating = false

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminExternalKnowledge")

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
            async let connectionsTask = api.getExternalKnowledgeConnections()
            async let itemsTask = api.getExternalKnowledgeItems()
            let (connsRaw, itemsRaw) = try await (connectionsTask, itemsTask)
            connections = connsRaw.map { ExternalKnowledgeConnection(from: $0) }
            items = itemsRaw.map { ExternalKnowledgeItem(from: $0) }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Editor

    func openCreate() {
        editingItemId = nil
        resetForm()
        showEditor = true
    }

    func openEdit(item: ExternalKnowledgeItem) {
        editingItemId = item.id
        formName = item.name
        formDescription = item.description
        formSourceName = item.sourceName ?? ""
        formProvider = item.provider ?? "qdrant"
        testResult = nil

        if let connId = item.connectionId,
           let conn = connections.first(where: { $0.id == connId }) {
            formEndpoint = conn.endpoint
            formAPIKey = ""
            if let timeout = conn.config["timeout"] as? Int { formTimeout = "\(timeout)" }
            if let db = conn.config["db_name"] as? String { formDbName = db }
        }
        applyProviderDefaults()
        showEditor = true
    }

    func resetForm() {
        formName = ""
        formDescription = ""
        formProvider = "qdrant"
        formEndpoint = ""
        formAPIKey = ""
        showAPIKey = false
        formTimeout = "30"
        formDbName = ""
        formSourceName = ""
        formTestQuery = ""
        testResult = nil
        applyProviderDefaults()
    }

    func applyProviderDefaults() {
        switch formProvider {
        case "milvus":
            formContentField = "data.text"
            formVectorField = "vector"
            formMetadataField = "metadata"
            formDocumentIdField = "id"
            formTableName = "document_chunk"
            formCollectionField = "collection_name"
        case "pgvector":
            formContentField = "text"
            formVectorField = "vector"
            formMetadataField = "vmetadata"
            formDocumentIdField = "id"
            formTableName = "document_chunk"
            formCollectionField = "collection_name"
        default: // qdrant
            formContentField = "payload.text"
            formVectorField = ""
            formMetadataField = "payload.metadata"
            formDocumentIdField = "id"
            formTableName = "document_chunk"
            formCollectionField = "collection_name"
        }
    }

    func testSource() async {
        guard let api = apiClient else { return }
        isTesting = true
        testResult = nil
        error = nil
        let payload = buildTestPayload()
        do {
            let result = try await api.testExternalKnowledgeSource(payload)
            testResult = result
        } catch {
            self.error = error.localizedDescription
        }
        isTesting = false
    }

    func saveSource() async {
        guard let api = apiClient else { return }
        isCreating = true
        error = nil
        let payload = buildCreatePayload()
        do {
            if let id = editingItemId {
                _ = try await api.updateExternalKnowledgeSource(id: id, payload)
            } else {
                _ = try await api.createExternalKnowledgeSource(payload)
            }
            showEditor = false
            await load()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }

    func toggleSource(item: ExternalKnowledgeItem) async {
        guard let api = apiClient,
              let connId = item.connectionId,
              let conn = connections.first(where: { $0.id == connId }) else { return }
        let payload: [String: Any] = [
            "name": conn.name,
            "provider": conn.provider,
            "endpoint": conn.endpoint,
            "auth_config": NSNull(),
            "config": conn.config,
            "capabilities": ["retrieve": true],
            "enabled": !conn.enabled
        ]
        do {
            try await api.updateExternalKnowledgeConnection(id: connId, payload)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteSource(id: String) async {
        guard let api = apiClient else { return }
        do {
            try await api.deleteExternalKnowledgeConnection(id: id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Computed Helpers

    var formIsValid: Bool {
        !formName.isEmpty && !formEndpoint.isEmpty && !formSourceName.isEmpty
            && !formContentField.isEmpty && !formTestQuery.isEmpty
            && (formProvider == "qdrant" || !formVectorField.isEmpty)
    }

    var testPassed: Bool {
        if let docs = testResult?["documents"] as? [Any] { return !docs.isEmpty }
        return false
    }

    func connectionForItem(_ item: ExternalKnowledgeItem) -> ExternalKnowledgeConnection? {
        guard let connId = item.connectionId else { return nil }
        return connections.first { $0.id == connId }
    }

    // MARK: - Payload Builders

    private func buildConnectionPayload() -> [String: Any] {
        var config: [String: Any] = ["timeout": Int(formTimeout) ?? 30]
        if formProvider == "milvus" && !formDbName.isEmpty { config["db_name"] = formDbName }

        var authConfig: Any = NSNull()
        if formProvider != "pgvector" && !formAPIKey.isEmpty {
            authConfig = ["type": "bearer", "api_key": formAPIKey]
        }

        return [
            "name": formName.isEmpty ? formSourceName : formName,
            "provider": formProvider,
            "endpoint": formEndpoint,
            "auth_config": authConfig,
            "config": config,
            "capabilities": ["retrieve": true],
            "enabled": true
        ]
    }

    private func buildSourcePayload() -> [String: Any] {
        var config: [String: String] = ["content_field": formContentField]
        if !formVectorField.isEmpty { config["vector_field"] = formVectorField }
        if !formMetadataField.isEmpty { config["metadata_field"] = formMetadataField }
        if !formDocumentIdField.isEmpty { config["document_id_field"] = formDocumentIdField }
        if formProvider == "pgvector" {
            config["table_name"] = formTableName
            config["collection_field"] = formCollectionField
        }
        return ["type": "collection", "name": formSourceName, "config": config]
    }

    private func buildTestPayload() -> [String: Any] {
        return [
            "connection": buildConnectionPayload(),
            "source": buildSourcePayload(),
            "query": formTestQuery,
            "count": 5
        ]
    }

    private func buildCreatePayload() -> [String: Any] {
        return [
            "name": formName,
            "description": formDescription,
            "connection": buildConnectionPayload(),
            "source": buildSourcePayload(),
            "access_grants": [] as [Any],
            "test_query": formTestQuery,
            "test_count": 5
        ]
    }
}
