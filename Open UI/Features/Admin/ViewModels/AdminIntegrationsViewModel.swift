import Foundation
import SwiftUI
import os.log

/// ViewModel for the Admin Integrations tab.
/// Manages Tool Servers (OpenAPI/MCP) and Terminal Server connections,
/// including CRUD, enable/disable, verify, and access control.
@Observable
final class AdminIntegrationsViewModel {

    // MARK: - Loading / Error

    var isLoading = false
    var errorMessage: String?

    // MARK: - Tool Servers

    var toolServersConfig = ToolServersConfigForm()
    var isSavingToolServers = false
    var toolServersError: String?

    // MARK: - Terminal Servers

    var terminalServersConfig = TerminalServersConfigForm()
    var isSavingTerminalServers = false
    var terminalServersError: String?

    // MARK: - Edit Tool Server Sheet

    var editingToolServerIndex: Int?

    var editToolType = "openapi"
    var editToolName = ""
    var editToolId = ""
    var editToolDescription = ""
    var editToolURL = ""
    var editToolEnable = true
    var editToolAuthType = "none"
    var editToolKey = ""
    var editToolShowKey = false
    var editToolSpecType = "url"
    var editToolSpecPath = "openapi.json"
    var editToolSpecJSON = ""
    var editToolHeadersJSON = ""
    var editToolFunctionFilter = ""
    var editToolClientId = ""
    var editToolClientSecret = ""

    var isSavingEditedToolServer = false
    var showDeleteToolServerConfirmation = false
    var isVerifyingToolServer = false
    var verifyToolServerResult: String?

    // MARK: - Add Tool Server Sheet

    var isShowingAddToolServer = false

    var addToolType = "openapi"
    var addToolName = ""
    var addToolId = ""
    var addToolDescription = ""
    var addToolURL = ""
    var addToolEnable = true
    var addToolAuthType = "none"
    var addToolKey = ""
    var addToolShowKey = false
    var addToolSpecType = "url"
    var addToolSpecPath = "openapi.json"
    var addToolSpecJSON = ""
    var addToolHeadersJSON = ""
    var addToolFunctionFilter = ""
    var addToolClientId = ""
    var addToolClientSecret = ""

    var isSavingAddToolServer = false
    var isVerifyingAddToolServer = false
    var verifyAddToolServerResult: String?

    // MARK: - Edit Terminal Server Sheet

    var editingTerminalIndex: Int?

    var editTermName = ""
    var editTermId = ""
    var editTermURL = ""
    var editTermAuthType = "bearer"
    var editTermKey = ""
    var editTermShowKey = false
    var editTermPath = "/openapi.json"

    var isSavingEditedTerminal = false
    var showDeleteTerminalConfirmation = false

    // MARK: - Add Terminal Server Sheet

    var isShowingAddTerminal = false

    var addTermName = ""
    var addTermId = ""
    var addTermURL = ""
    var addTermAuthType = "bearer"
    var addTermKey = ""
    var addTermShowKey = false
    var addTermPath = "/openapi.json"

    var isSavingAddTerminal = false

    // MARK: - Access Control Sheet

    var isShowingAccessControl = false
    /// "tool" or "terminal"
    var accessControlTarget: String = "tool"
    /// Index of the connection being edited for access
    var accessControlIndex: Int = 0

    /// Current access grants for the active access control sheet
    var currentAccessGrants: [ToolAccessGrant] = []

    /// Whether we're in "add access" mode
    var isShowingAddAccess = false
    var addAccessSearchQuery = ""
    var addAccessSearchResults: [ChannelMember] = []
    var addAccessGroups: [GroupResponse] = []
    var addAccessTab: AddAccessTab = .users
    var isSearchingUsers = false

    enum AddAccessTab: String, CaseIterable {
        case users = "Users"
        case groups = "Groups"
    }

    /// Resolved user names for access grant display
    var resolvedUsers: [String: ChannelMember] = [:]
    /// Resolved group info for access grant display
    var resolvedGroups: [String: GroupResponse] = [:]

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminIntegrations")

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
            group.addTask { await self.loadToolServers(api: api) }
            group.addTask { await self.loadTerminalServers(api: api) }
            group.addTask { await self.loadGroupsForAccess() }
        }

        // Resolve user names for existing access grants
        await resolveAccessGrantUsers()

        isLoading = false
    }

    // MARK: - Tool Servers

    private func loadToolServers(api: APIClient) async {
        do {
            toolServersConfig = try await api.getToolServersConfig()
        } catch {
            logger.error("Failed to load tool servers: \(error)")
            toolServersError = error.localizedDescription
        }
    }

    func toggleToolServerEnabled(at index: Int) async {
        guard let api = apiClient else { return }
        guard toolServersConfig.TOOL_SERVER_CONNECTIONS.indices.contains(index) else { return }

        let current = toolServersConfig.TOOL_SERVER_CONNECTIONS[index].config?.enable ?? true
        toolServersConfig.TOOL_SERVER_CONNECTIONS[index].config?.enable = !current
        await saveToolServersConfig(api: api)
    }

    func beginAddToolServer() {
        addToolType = "openapi"
        addToolName = ""
        addToolId = ""
        addToolDescription = ""
        addToolURL = ""
        addToolEnable = true
        addToolAuthType = "none"
        addToolKey = ""
        addToolShowKey = false
        addToolSpecType = "url"
        addToolSpecPath = "openapi.json"
        addToolSpecJSON = ""
        addToolHeadersJSON = ""
        addToolFunctionFilter = ""
        addToolClientId = ""
        addToolClientSecret = ""
        isVerifyingAddToolServer = false
        verifyAddToolServerResult = nil
        isShowingAddToolServer = true
    }

    func addToolServer() async {
        guard let api = apiClient else { return }
        isSavingAddToolServer = true

        var conn = ToolServerConnection()
        conn.url = addToolURL
        conn.path = addToolSpecPath
        conn.type = addToolType
        conn.auth_type = addToolAuthType
        conn.key = addToolKey
        conn.spec_type = addToolSpecType
        conn.spec = ""
        conn.headers = parseHeadersToAnyCodable(addToolHeadersJSON)
        conn.config = ToolServerConnectionConfig(
            enable: addToolEnable,
            function_name_filter_list: addToolFunctionFilter.isEmpty ? nil : addToolFunctionFilter,
            access_grants: currentAccessGrants
        )
        conn.info = ToolServerInfo(
            id: addToolId.isEmpty ? nil : addToolId,
            name: addToolName.isEmpty ? nil : addToolName,
            description: addToolDescription.isEmpty ? nil : addToolDescription
        )

        toolServersConfig.TOOL_SERVER_CONNECTIONS.append(conn)
        await saveToolServersConfig(api: api)
        isSavingAddToolServer = false
        isShowingAddToolServer = false
    }

    func beginEditToolServer(at index: Int) {
        guard toolServersConfig.TOOL_SERVER_CONNECTIONS.indices.contains(index) else { return }
        let conn = toolServersConfig.TOOL_SERVER_CONNECTIONS[index]

        editingToolServerIndex = index
        editToolType = conn.type ?? "openapi"
        editToolName = conn.info?.name ?? ""
        editToolId = conn.info?.id ?? ""
        editToolDescription = conn.info?.description ?? ""
        editToolURL = conn.url
        editToolEnable = conn.config?.enable ?? true
        editToolAuthType = conn.auth_type ?? "none"
        editToolKey = conn.key ?? ""
        editToolShowKey = false
        editToolSpecType = conn.spec_type ?? "url"
        editToolSpecPath = conn.path
        editToolSpecJSON = conn.spec ?? ""
        editToolFunctionFilter = conn.config?.function_name_filter_list ?? ""
        editToolClientId = ""
        editToolClientSecret = ""

        if let headers = conn.headers?.dictionaryValue, !headers.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: headers, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            editToolHeadersJSON = str
        } else {
            editToolHeadersJSON = ""
        }

        // Pre-load access grants for this connection
        currentAccessGrants = conn.config?.access_grants ?? []

        verifyToolServerResult = nil
    }

    func saveToolServerEdit() async {
        guard let api = apiClient, let idx = editingToolServerIndex else { return }
        guard toolServersConfig.TOOL_SERVER_CONNECTIONS.indices.contains(idx) else { return }
        isSavingEditedToolServer = true

        var conn = toolServersConfig.TOOL_SERVER_CONNECTIONS[idx]
        conn.url = editToolURL
        conn.path = editToolSpecPath
        conn.type = editToolType
        conn.auth_type = editToolAuthType
        conn.key = editToolKey
        conn.spec_type = editToolSpecType
        conn.headers = parseHeadersToAnyCodable(editToolHeadersJSON)
        conn.config?.enable = editToolEnable
        conn.config?.function_name_filter_list = editToolFunctionFilter.isEmpty ? nil : editToolFunctionFilter
        conn.config?.access_grants = currentAccessGrants
        conn.info = ToolServerInfo(
            id: editToolId.isEmpty ? nil : editToolId,
            name: editToolName.isEmpty ? nil : editToolName,
            description: editToolDescription.isEmpty ? nil : editToolDescription
        )

        toolServersConfig.TOOL_SERVER_CONNECTIONS[idx] = conn
        await saveToolServersConfig(api: api)
        isSavingEditedToolServer = false
        editingToolServerIndex = nil
    }

    func deleteToolServer(at index: Int) async {
        guard let api = apiClient else { return }
        guard toolServersConfig.TOOL_SERVER_CONNECTIONS.indices.contains(index) else { return }
        toolServersConfig.TOOL_SERVER_CONNECTIONS.remove(at: index)
        await saveToolServersConfig(api: api)
    }

    func verifyToolServer() async {
        guard let api = apiClient, let idx = editingToolServerIndex else { return }
        guard toolServersConfig.TOOL_SERVER_CONNECTIONS.indices.contains(idx) else { return }

        isVerifyingToolServer = true
        verifyToolServerResult = nil

        var conn = toolServersConfig.TOOL_SERVER_CONNECTIONS[idx]
        conn.url = editToolURL
        conn.path = editToolSpecPath
        conn.type = editToolType
        conn.auth_type = editToolAuthType
        conn.key = editToolKey

        do {
            try await api.verifyToolServerConnection(conn)
            verifyToolServerResult = "✅ Connection verified"
        } catch {
            verifyToolServerResult = "❌ \(error.localizedDescription)"
        }
        isVerifyingToolServer = false
    }

    /// Verify from the Add sheet (no existing index needed)
    func verifyToolServerFromAdd() async {
        guard let api = apiClient else { return }

        isVerifyingAddToolServer = true
        verifyAddToolServerResult = nil

        var conn = ToolServerConnection()
        conn.url = addToolURL
        conn.path = addToolSpecPath
        conn.type = addToolType
        conn.auth_type = addToolAuthType
        conn.key = addToolKey
        conn.spec_type = addToolSpecType

        do {
            try await api.verifyToolServerConnection(conn)
            verifyAddToolServerResult = "✅ Connection verified"
        } catch {
            verifyAddToolServerResult = "❌ \(error.localizedDescription)"
        }
        isVerifyingAddToolServer = false
    }

    private func saveToolServersConfig(api: APIClient) async {
        isSavingToolServers = true
        toolServersError = nil
        do {
            toolServersConfig = try await api.updateToolServersConfig(toolServersConfig)
        } catch {
            logger.error("Failed to save tool servers: \(error)")
            toolServersError = error.localizedDescription
        }
        isSavingToolServers = false
    }

    // MARK: - Terminal Servers

    private func loadTerminalServers(api: APIClient) async {
        do {
            terminalServersConfig = try await api.getTerminalServersConfig()
        } catch {
            logger.error("Failed to load terminal servers: \(error)")
            terminalServersError = error.localizedDescription
        }
    }

    func toggleTerminalEnabled(at index: Int) async {
        guard let api = apiClient else { return }
        guard terminalServersConfig.TERMINAL_SERVER_CONNECTIONS.indices.contains(index) else { return }

        let current = terminalServersConfig.TERMINAL_SERVER_CONNECTIONS[index].enabled ?? true
        terminalServersConfig.TERMINAL_SERVER_CONNECTIONS[index].enabled = !current
        await saveTerminalServersConfig(api: api)
    }

    func beginAddTerminal() {
        addTermName = ""
        addTermId = ""
        addTermURL = ""
        addTermAuthType = "bearer"
        addTermKey = ""
        addTermShowKey = false
        addTermPath = "/openapi.json"
        isShowingAddTerminal = true
    }

    func addTerminal() async {
        guard let api = apiClient else { return }
        isSavingAddTerminal = true

        let conn = TerminalServerConnection(
            id: addTermId.isEmpty ? nil : addTermId,
            name: addTermName.isEmpty ? nil : addTermName,
            enabled: true,
            url: addTermURL,
            path: addTermPath,
            key: addTermKey,
            auth_type: addTermAuthType,
            config: TerminalServerConnectionConfig()
        )

        terminalServersConfig.TERMINAL_SERVER_CONNECTIONS.append(conn)
        await saveTerminalServersConfig(api: api)
        isSavingAddTerminal = false
        isShowingAddTerminal = false
    }

    func beginEditTerminal(at index: Int) {
        guard terminalServersConfig.TERMINAL_SERVER_CONNECTIONS.indices.contains(index) else { return }
        let conn = terminalServersConfig.TERMINAL_SERVER_CONNECTIONS[index]

        editingTerminalIndex = index
        editTermName = conn.name ?? ""
        editTermId = conn.id ?? ""
        editTermURL = conn.url
        editTermAuthType = conn.auth_type ?? "bearer"
        editTermKey = conn.key ?? ""
        editTermShowKey = false
        editTermPath = conn.path ?? "/openapi.json"
    }

    func saveTerminalEdit() async {
        guard let api = apiClient, let idx = editingTerminalIndex else { return }
        guard terminalServersConfig.TERMINAL_SERVER_CONNECTIONS.indices.contains(idx) else { return }
        isSavingEditedTerminal = true

        var conn = terminalServersConfig.TERMINAL_SERVER_CONNECTIONS[idx]
        conn.name = editTermName.isEmpty ? nil : editTermName
        conn.id = editTermId.isEmpty ? nil : editTermId
        conn.url = editTermURL
        conn.auth_type = editTermAuthType
        conn.key = editTermKey
        conn.path = editTermPath

        terminalServersConfig.TERMINAL_SERVER_CONNECTIONS[idx] = conn
        await saveTerminalServersConfig(api: api)
        isSavingEditedTerminal = false
        editingTerminalIndex = nil
    }

    func deleteTerminal(at index: Int) async {
        guard let api = apiClient else { return }
        guard terminalServersConfig.TERMINAL_SERVER_CONNECTIONS.indices.contains(index) else { return }
        terminalServersConfig.TERMINAL_SERVER_CONNECTIONS.remove(at: index)
        await saveTerminalServersConfig(api: api)
    }

    private func saveTerminalServersConfig(api: APIClient) async {
        isSavingTerminalServers = true
        terminalServersError = nil
        do {
            terminalServersConfig = try await api.updateTerminalServersConfig(terminalServersConfig)
        } catch {
            logger.error("Failed to save terminal servers: \(error)")
            terminalServersError = error.localizedDescription
        }
        isSavingTerminalServers = false
    }

    // MARK: - Access Control

    func openAccessControl(target: String, index: Int) {
        accessControlTarget = target
        accessControlIndex = index

        if target == "tool", toolServersConfig.TOOL_SERVER_CONNECTIONS.indices.contains(index) {
            currentAccessGrants = toolServersConfig.TOOL_SERVER_CONNECTIONS[index].config?.access_grants ?? []
        } else if target == "terminal", terminalServersConfig.TERMINAL_SERVER_CONNECTIONS.indices.contains(index) {
            currentAccessGrants = terminalServersConfig.TERMINAL_SERVER_CONNECTIONS[index].config?.access_grants ?? []
        }

        isShowingAccessControl = true
    }

    var isCurrentAccessPublic: Bool {
        currentAccessGrants.contains { $0.principal_id == "*" }
    }

    var currentSpecificGrants: [ToolAccessGrant] {
        currentAccessGrants.filter { $0.principal_id != "*" }
    }

    func toggleAccessMode() {
        if isCurrentAccessPublic {
            // Remove wildcard (make private)
            currentAccessGrants.removeAll { $0.principal_id == "*" }
        } else {
            // Add wildcard (make public)
            currentAccessGrants.append(.publicWildcard)
        }
    }

    func removeAccessGrant(_ grant: ToolAccessGrant) {
        currentAccessGrants.removeAll { $0 == grant }
    }

    func addAccessGrant(principalType: String, principalId: String) {
        let grant = ToolAccessGrant(principal_type: principalType, principal_id: principalId, permission: "read")
        guard !currentAccessGrants.contains(grant) else { return }
        currentAccessGrants.append(grant)
    }

    func saveAccessControl() async {
        guard let api = apiClient else { return }

        if accessControlTarget == "tool",
           toolServersConfig.TOOL_SERVER_CONNECTIONS.indices.contains(accessControlIndex) {
            toolServersConfig.TOOL_SERVER_CONNECTIONS[accessControlIndex].config?.access_grants = currentAccessGrants
            await saveToolServersConfig(api: api)
        } else if accessControlTarget == "terminal",
                  terminalServersConfig.TERMINAL_SERVER_CONNECTIONS.indices.contains(accessControlIndex) {
            terminalServersConfig.TERMINAL_SERVER_CONNECTIONS[accessControlIndex].config?.access_grants = currentAccessGrants
            await saveTerminalServersConfig(api: api)
        }

        isShowingAccessControl = false
    }

    // MARK: - User/Group Search for Access

    func searchUsersForAccess() async {
        guard let api = apiClient else { return }
        isSearchingUsers = true
        do {
            addAccessSearchResults = try await api.searchUsers(query: addAccessSearchQuery.isEmpty ? nil : addAccessSearchQuery)
        } catch {
            logger.error("Failed to search users: \(error)")
        }
        isSearchingUsers = false
    }

    func loadGroupsForAccess() async {
        guard let api = apiClient else { return }
        do {
            addAccessGroups = try await api.getGroups()
            // Cache group info for name resolution
            for group in addAccessGroups {
                resolvedGroups[group.id] = group
            }
        } catch {
            logger.error("Failed to load groups: \(error)")
        }
    }

    // MARK: - Resolve Users

    func resolveAccessGrantUsers() async {
        guard let api = apiClient else { return }

        // Collect all unique user IDs from both tool and terminal access grants
        var userIds = Set<String>()
        for conn in toolServersConfig.TOOL_SERVER_CONNECTIONS {
            for grant in conn.config?.access_grants ?? [] where grant.principal_type == "user" && grant.principal_id != "*" {
                userIds.insert(grant.principal_id)
            }
        }
        for conn in terminalServersConfig.TERMINAL_SERVER_CONNECTIONS {
            for grant in conn.config?.access_grants ?? [] where grant.principal_type == "user" && grant.principal_id != "*" {
                userIds.insert(grant.principal_id)
            }
        }

        guard !userIds.isEmpty else { return }

        // Use search to resolve — this is a simple approach
        do {
            let allUsers = try await api.searchUsers()
            for user in allUsers {
                resolvedUsers[user.id] = user
            }
        } catch {
            logger.error("Failed to resolve access grant users: \(error)")
        }
    }

    func resolvedName(for grant: ToolAccessGrant) -> String {
        if grant.principal_id == "*" { return "Everyone" }
        if grant.principal_type == "group" {
            if let group = resolvedGroups[grant.principal_id] {
                let count = group.member_count ?? 0
                return "\(group.name) (\(count) \(count == 1 ? "member" : "members"))"
            }
            // Try from the loaded addAccessGroups list
            if let group = addAccessGroups.first(where: { $0.id == grant.principal_id }) {
                resolvedGroups[grant.principal_id] = group
                let count = group.member_count ?? 0
                return "\(group.name) (\(count) \(count == 1 ? "member" : "members"))"
            }
            return "Group"
        }
        if let user = resolvedUsers[grant.principal_id] {
            return user.name ?? "Unknown"
        }
        return String(grant.principal_id.prefix(8)) + "…"
    }

    // MARK: - Helpers

    private func parseHeadersToAnyCodable(_ json: String) -> AnyCodableValue? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }

        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return .dict(dict)
        }
        return nil
    }
}
