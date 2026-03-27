import Foundation
import os.log

/// Manages Functions CRUD operations for the admin console.
@Observable
final class FunctionsManager {
    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "Functions")

    // MARK: - State

    var functions: [FunctionItem] = []
    var isLoading = false
    var error: String?

    // MARK: - Init

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch All

    func fetchAll() async {
        isLoading = true
        error = nil
        do {
            functions = try await apiClient.getFunctions()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Get Detail

    func getDetail(id: String) async throws -> FunctionDetail {
        return try await apiClient.getFunctionDetail(id: id)
    }

    /// Returns the raw JSON data for a function (for export).
    func getDetailRaw(id: String) async throws -> Data {
        return try await apiClient.getFunctionDetailRaw(id: id)
    }

    // MARK: - Create

    @discardableResult
    func createFunction(from detail: FunctionDetail) async throws -> FunctionDetail {
        let created = try await apiClient.createFunction(detail: detail)
        if let item = created.toFunctionItem() {
            functions.append(item)
        }
        return created
    }

    // MARK: - Update

    @discardableResult
    func updateFunction(_ detail: FunctionDetail) async throws -> FunctionDetail {
        let updated = try await apiClient.updateFunction(detail: detail)
        if let item = updated.toFunctionItem(),
           let idx = functions.firstIndex(where: { $0.id == detail.id }) {
            functions[idx] = item
        }
        return updated
    }

    // MARK: - Delete

    func deleteFunction(id: String) async throws {
        try await apiClient.deleteFunction(id: id)
        functions.removeAll { $0.id == id }
    }

    // MARK: - Toggle Active

    @discardableResult
    func toggleActive(id: String) async throws -> FunctionDetail {
        let toggled = try await apiClient.toggleFunction(id: id)
        if let item = toggled.toFunctionItem(),
           let idx = functions.firstIndex(where: { $0.id == id }) {
            functions[idx] = item
        }
        return toggled
    }

    // MARK: - Toggle Global

    @discardableResult
    func toggleGlobal(id: String) async throws -> FunctionDetail {
        let toggled = try await apiClient.toggleFunctionGlobal(id: id)
        if let item = toggled.toFunctionItem(),
           let idx = functions.firstIndex(where: { $0.id == id }) {
            functions[idx] = item
        }
        return toggled
    }

    // MARK: - Clone

    @discardableResult
    func cloneFunction(id: String) async throws -> FunctionDetail {
        let source = try await getDetail(id: id)
        let cloneId = (source.id + "_clone").replacingOccurrences(of: " ", with: "_")
        let cloneDetail = FunctionDetail(
            id: cloneId,
            name: source.name + " (Clone)",
            type: source.type,
            content: source.content,
            description: source.description,
            manifest: source.manifest
        )
        let created = try await createFunction(from: cloneDetail)
        return created
    }

    // MARK: - Export All

    func exportAll() async throws -> Data {
        return try await apiClient.exportFunctions()
    }

    // MARK: - Valves

    func getValves(id: String) async throws -> [String: Any] {
        return try await apiClient.getFunctionValves(id: id)
    }

    func getValvesSpec(id: String) async throws -> [String: Any] {
        return try await apiClient.getFunctionValvesSpec(id: id)
    }

    func getValvesSpecWithOrder(id: String) async throws -> ([String: Any], [String]) {
        return try await apiClient.getFunctionValvesSpecOrdered(id: id)
    }

    func updateValves(id: String, values: [String: Any]) async throws -> [String: Any] {
        return try await apiClient.updateFunctionValves(id: id, values: values)
    }
}
