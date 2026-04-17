import Foundation
import os.log

/// Manages the admin Groups tab: list, create, update, delete, members, and default permissions.
@Observable
final class AdminGroupsViewModel {

    // MARK: - Groups List State

    var groups: [GroupDetail] = []
    var isLoading = false
    var errorMessage: String?
    var searchQuery = ""

    var filteredGroups: [GroupDetail] {
        guard !searchQuery.isEmpty else { return groups }
        return groups.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
            || ($0.description.localizedCaseInsensitiveContains(searchQuery))
        }
    }

    // MARK: - Default Permissions State

    var defaultPermissions = GroupPermissions()
    var isLoadingDefaults = false
    var isSavingDefaults = false
    var defaultsSaveError: String?
    var defaultsSaveSuccess = false

    // MARK: - Create/Edit Group State

    var isCreating = false
    var isSaving = false
    var saveError: String?
    var saveSuccess = false

    // Form fields
    var editName = ""
    var editDescription = ""
    var editSharePermission: GroupSharePermission = .members
    var editPermissions = GroupPermissions()

    // Edit target (nil = creating new)
    var editingGroup: GroupDetail?

    // MARK: - Group Users State

    var groupUsers: [AdminUser] = []
    var allUsers: [AdminUser] = []
    var isLoadingUsers = false
    var isSavingUsers = false
    var usersError: String?

    // MARK: - Delete State

    var groupToDelete: GroupDetail?
    var isDeleting = false
    var deleteError: String?

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminGroups")

    // MARK: - Init

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load Groups

    func loadGroups() async {
        guard let api = apiClient else {
            errorMessage = "No server connection."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            groups = try await api.getGroupDetails()
            logger.info("Loaded \(self.groups.count) groups")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to load groups: \(error)")
        }
        isLoading = false
    }

    // MARK: - Load Default Permissions

    func loadDefaultPermissions() async {
        guard let api = apiClient else { return }
        isLoadingDefaults = true
        defaultsSaveError = nil
        do {
            defaultPermissions = try await api.getDefaultPermissions()
            logger.info("Loaded default permissions")
        } catch {
            logger.error("Failed to load default permissions: \(error)")
        }
        isLoadingDefaults = false
    }

    // MARK: - Save Default Permissions

    func saveDefaultPermissions() async {
        guard let api = apiClient else { return }
        isSavingDefaults = true
        defaultsSaveError = nil
        defaultsSaveSuccess = false
        do {
            defaultPermissions = try await api.updateDefaultPermissions(defaultPermissions)
            defaultsSaveSuccess = true
            logger.info("Saved default permissions")
        } catch {
            defaultsSaveError = error.localizedDescription
            logger.error("Failed to save default permissions: \(error)")
        }
        isSavingDefaults = false
    }

    // MARK: - Prepare Create Form

    func prepareCreate() {
        editingGroup = nil
        editName = ""
        editDescription = ""
        editSharePermission = .members
        editPermissions = GroupPermissions()
        saveError = nil
        saveSuccess = false
    }

    // MARK: - Prepare Edit Form

    func prepareEdit(_ group: GroupDetail) {
        editingGroup = group
        editName = group.name
        editDescription = group.description
        editSharePermission = GroupSharePermission(rawValue: group.data?.config?.share ?? "members") ?? .members
        editPermissions = group.permissions ?? GroupPermissions()
        saveError = nil
        saveSuccess = false
    }

    // MARK: - Create Group

    func createGroup() async {
        guard let api = apiClient else { return }
        guard !editName.isEmpty else {
            saveError = "Name is required."
            return
        }
        isCreating = true
        saveError = nil
        do {
            let data = GroupData(config: GroupDataConfig(share: editSharePermission.rawValue))
            let form = GroupForm(
                name: editName.trimmingCharacters(in: .whitespaces),
                description: editDescription,
                permissions: editPermissions,
                data: data
            )
            let created = try await api.createGroup(form)
            groups.append(created)
            saveSuccess = true
            logger.info("Created group \(created.name)")
        } catch {
            saveError = error.localizedDescription
            logger.error("Failed to create group: \(error)")
        }
        isCreating = false
    }

    // MARK: - Update Group

    func updateGroup() async {
        guard let api = apiClient, let group = editingGroup else { return }
        isSaving = true
        saveError = nil
        do {
            let data = GroupData(config: GroupDataConfig(share: editSharePermission.rawValue))
            let form = GroupForm(
                name: editName.trimmingCharacters(in: .whitespaces),
                description: editDescription,
                permissions: editPermissions,
                data: data
            )
            let updated = try await api.updateGroup(id: group.id, form: form)
            if let idx = groups.firstIndex(where: { $0.id == group.id }) {
                groups[idx] = updated
            }
            editingGroup = updated
            saveSuccess = true
            logger.info("Updated group \(updated.name)")
        } catch {
            saveError = error.localizedDescription
            logger.error("Failed to update group: \(error)")
        }
        isSaving = false
    }

    // MARK: - Delete Group

    func deleteGroup(_ group: GroupDetail) async {
        guard let api = apiClient else { return }
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteGroup(id: group.id)
            groups.removeAll { $0.id == group.id }
            groupToDelete = nil
            logger.info("Deleted group \(group.name)")
        } catch {
            deleteError = error.localizedDescription
            logger.error("Failed to delete group: \(error)")
        }
        isDeleting = false
    }

    // MARK: - Load Group Users

    /// Loads both the current group members and all users (for the member management UI).
    func loadGroupUsers(groupId: String) async {
        guard let api = apiClient else { return }
        isLoadingUsers = true
        usersError = nil
        async let groupUsersTask = api.getUsersInGroup(groupId: groupId)
        async let allUsersTask = api.getAdminUsers(page: 1)
        do {
            let (gUsers, aUsers) = try await (groupUsersTask, allUsersTask)
            groupUsers = gUsers
            allUsers = aUsers
            logger.info("Loaded \(gUsers.count) group members, \(aUsers.count) total users")
        } catch {
            usersError = error.localizedDescription
            logger.error("Failed to load users: \(error)")
        }
        isLoadingUsers = false
    }

    /// Whether a user is currently a member of the editing group.
    func isMember(_ user: AdminUser) -> Bool {
        groupUsers.contains { $0.id == user.id }
    }

    /// Toggles a user's membership in the current editing group.
    func toggleMembership(user: AdminUser, groupId: String) async {
        guard let api = apiClient else { return }
        isSavingUsers = true
        do {
            if isMember(user) {
                let updated = try await api.removeUsersFromGroup(groupId: groupId, userIds: [user.id])
                groupUsers.removeAll { $0.id == user.id }
                // Update member count in groups list
                if let idx = groups.firstIndex(where: { $0.id == groupId }) {
                    var g = groups[idx]
                    g.memberCount = updated.memberCount ?? (g.memberCount.map { $0 - 1 })
                    groups[idx] = g
                }
                logger.info("Removed \(user.displayName) from group \(groupId)")
            } else {
                let updated = try await api.addUsersToGroup(groupId: groupId, userIds: [user.id])
                groupUsers.append(user)
                // Update member count in groups list
                if let idx = groups.firstIndex(where: { $0.id == groupId }) {
                    var g = groups[idx]
                    g.memberCount = updated.memberCount ?? (g.memberCount.map { $0 + 1 })
                    groups[idx] = g
                }
                logger.info("Added \(user.displayName) to group \(groupId)")
            }
        } catch {
            usersError = error.localizedDescription
            logger.error("Failed to toggle membership: \(error)")
        }
        isSavingUsers = false
    }
}
