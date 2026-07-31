import Foundation
import os.log

// MARK: - AdminDatabaseViewModel

@Observable
final class AdminDatabaseViewModel {

    // MARK: - State

    var isExportingConfig = false
    var isImportingConfig = false
    var isExportingChats = false
    var error: String?
    var successMessage: String?

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminDatabase")

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Export Config

    func exportConfig() async throws -> Data {
        guard let api = apiClient else {
            throw NSError(domain: "AdminDB", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        isExportingConfig = true
        defer { isExportingConfig = false }
        do {
            let data = try await api.exportAdminConfig()
            logger.info("Exported admin config (\(data.count) bytes)")
            return data
        } catch {
            let msg = (error as? APIError)?.errorDescription ?? error.localizedDescription
            self.error = msg
            throw error
        }
    }

    // MARK: - Import Config

    func importConfig(_ data: Data) async {
        guard let api = apiClient else { return }
        isImportingConfig = true
        error = nil
        successMessage = nil
        do {
            try await api.importAdminConfig(data)
            successMessage = "Configuration imported successfully."
            logger.info("Imported admin config")
            autoHideSuccess()
        } catch {
            let msg = (error as? APIError)?.errorDescription ?? error.localizedDescription
            self.error = msg
            logger.error("Failed to import admin config: \(msg)")
        }
        isImportingConfig = false
    }

    // MARK: - Export All Chats

    func exportAllChats() async throws -> Data {
        guard let api = apiClient else {
            throw NSError(domain: "AdminDB", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        isExportingChats = true
        defer { isExportingChats = false }
        do {
            let data = try await api.exportAllChats()
            logger.info("Exported all chats (\(data.count) bytes)")
            return data
        } catch {
            let msg = (error as? APIError)?.errorDescription ?? error.localizedDescription
            self.error = msg
            throw error
        }
    }

    // MARK: - Helpers

    private func autoHideSuccess() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            successMessage = nil
        }
    }
}
