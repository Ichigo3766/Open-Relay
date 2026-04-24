import Foundation
import os.log

@MainActor @Observable
final class AutomationsViewModel {

    // MARK: - State

    var automations: [Automation] = []
    var isLoading = false
    var errorMessage: String?
    var searchText = ""
    var filterState: FilterState = .all

    /// Controls the create sheet
    var showCreateSheet = false
    /// Automation selected for detail/edit
    var selectedAutomation: Automation?
    /// Confirmation delete
    var deletingAutomation: Automation?
    var showDeleteConfirmation = false
    /// Toast message
    var toastMessage: String?

    enum FilterState: String, CaseIterable {
        case all = "All"
        case active = "Active"
        case paused = "Paused"
    }

    // MARK: - Private

    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "AutomationsVM")

    // MARK: - Init

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Computed

    var filteredAutomations: [Automation] {
        var result = automations
        // Search
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.data.prompt.localizedCaseInsensitiveContains(searchText)
            }
        }
        // Filter
        switch filterState {
        case .all: break
        case .active: result = result.filter { $0.isActive }
        case .paused: result = result.filter { !$0.isActive }
        }
        return result
    }

    // MARK: - Load

    func loadAutomations() async {
        isLoading = true
        errorMessage = nil
        do {
            automations = try await apiClient.getAutomations()
        } catch is CancellationError {
            // Pull-to-refresh or task cancellation — not a real error
            logger.debug("Load automations cancelled")
        } catch let urlError as URLError where urlError.code == .cancelled {
            logger.debug("Load automations URL request cancelled")
        } catch let apiError as APIError {
            if case .cancelled = apiError {
                logger.debug("Load automations API request cancelled")
            } else {
                errorMessage = apiError.localizedDescription
                logger.error("Load automations failed: \(apiError)")
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Load automations failed: \(error)")
        }
        isLoading = false
    }

    // MARK: - Toggle

    func toggle(_ automation: Automation) async {
        // Optimistic update
        guard let idx = automations.firstIndex(where: { $0.id == automation.id }) else { return }
        automations[idx].isActive.toggle()
        Haptics.play(.light)
        do {
            let updated = try await apiClient.toggleAutomation(id: automation.id)
            automations[idx] = updated
        } catch {
            // Revert
            automations[idx].isActive = automation.isActive
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Run Now

    func runNow(_ automation: Automation) async {
        do {
            _ = try await apiClient.runAutomation(id: automation.id)
            Haptics.play(.light)
            toastMessage = "Automation \"\(automation.name)\" started"
            // Refresh to show latest run
            await loadAutomations()
        } catch {
            errorMessage = "Failed to run: \(error.localizedDescription)"
        }
    }

    // MARK: - Create

    func createAutomation(name: String, prompt: String, modelId: String, rrule: String) async -> Automation? {
        do {
            let created = try await apiClient.createAutomation(name: name, prompt: prompt, modelId: modelId, rrule: rrule)
            automations.insert(created, at: 0)
            Haptics.play(.light)
            return created
        } catch {
            errorMessage = "Failed to create: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Update

    func updateAutomation(id: String, name: String, prompt: String, modelId: String, rrule: String) async {
        do {
            let updated = try await apiClient.updateAutomation(id: id, name: name, prompt: prompt, modelId: modelId, rrule: rrule)
            if let idx = automations.firstIndex(where: { $0.id == id }) {
                automations[idx] = updated
            }
            // Also update selectedAutomation
            selectedAutomation = updated
            Haptics.play(.light)
            toastMessage = "Saved"
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    // MARK: - Delete

    func deleteAutomation(_ automation: Automation) async {
        do {
            try await apiClient.deleteAutomation(id: automation.id)
            automations.removeAll { $0.id == automation.id }
            if selectedAutomation?.id == automation.id {
                selectedAutomation = nil
            }
            Haptics.play(.medium)
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    // MARK: - Runs

    func fetchRuns(automationId: String) async throws -> [AutomationRun] {
        try await apiClient.getAutomationRuns(id: automationId, skip: 0, limit: 50)
    }
}
