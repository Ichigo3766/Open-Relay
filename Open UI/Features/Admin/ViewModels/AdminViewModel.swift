import Foundation
import os.log

/// Manages the admin console state: user list, search, edit, delete, and chat viewing.
@Observable
final class AdminViewModel {
    // MARK: - User List State

    var users: [AdminUser] = []
    var isLoading = false
    var isLoadingMore = false
    var searchQuery = ""
    var currentPage = 1
    var hasMorePages = true
    var errorMessage: String?
    var sortField: SortField = {
        if let raw = UserDefaults.standard.string(forKey: "admin.sortField"),
           let field = SortField(rawValue: raw) { return field }
        return .createdAt
    }() {
        didSet { UserDefaults.standard.set(sortField.rawValue, forKey: "admin.sortField") }
    }
    var sortDirection: SortDirection = {
        if let raw = UserDefaults.standard.string(forKey: "admin.sortDirection"),
           let dir = SortDirection(rawValue: raw) { return dir }
        return .desc
    }() {
        didSet { UserDefaults.standard.set(sortDirection.rawValue, forKey: "admin.sortDirection") }
    }
    var userCount: Int { users.count }

    // MARK: - Edit User State

    var editingUser: AdminUser?
    var editRole: User.UserRole = .user
    var editName = ""
    var editEmail = ""
    var editPassword = ""
    var isSaving = false
    var saveError: String?
    var saveSuccess = false

    // MARK: - Add User State

    var isAddingUser = false
    var addName = ""
    var addEmail = ""
    var addPassword = ""
    var addRole: User.UserRole = .user
    var addError: String?

    // MARK: - Delete State

    var userToDelete: AdminUser?
    var isDeleting = false
    var deleteError: String?

    // MARK: - Chat View State

    var viewingChatsForUser: AdminUser?
    var userChats: [AdminChatItem] = []
    var isLoadingChats = false
    var chatSearchQuery = ""
    var chatError: String?

    // MARK: - Chat Detail State (view / clone / delete)

    var selectedChatDetail: Conversation?
    var isLoadingChatDetail = false
    var chatDetailError: String?

    var isCloning = false
    var clonedConversation: Conversation?

    var chatToDelete: AdminChatItem?
    var isDeletingChat = false
    var deleteChatError: String?

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "Admin")
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    // MARK: - Enums

    enum SortField: String, CaseIterable {
        case createdAt = "created_at"
        case name = "name"
        case lastActiveAt = "last_active_at"

        var displayName: String {
            switch self {
            case .createdAt: return "Created"
            case .name: return "Name"
            case .lastActiveAt: return "Last Active"
            }
        }
    }

    enum SortDirection: String {
        case asc, desc

        var icon: String {
            self == .asc ? "arrow.up" : "arrow.down"
        }

        mutating func toggle() {
            self = self == .asc ? .desc : .asc
        }
    }

    // MARK: - Init

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load Users

    /// Loads the first page of users. Cancels any in-flight load to prevent
    /// overlapping requests (which cause "Request was cancelled" errors).
    func loadUsers() async {
        // Cancel any previous in-flight load
        loadTask?.cancel()

        guard let api = apiClient else {
            errorMessage = "No server connection."
            return
        }

        isLoading = true
        errorMessage = nil
        currentPage = 1

        let task = Task {
            do {
                let result = try await api.getAdminUsers(
                    page: 1,
                    query: searchQuery.isEmpty ? nil : searchQuery,
                    orderBy: sortField.rawValue,
                    direction: sortDirection.rawValue
                )
                guard !Task.isCancelled else { return }
                users = result
                hasMorePages = result.count >= 20
                currentPage = 1
                logger.info("Loaded \(result.count) users")
            } catch is CancellationError {
                // Silently ignore — a newer request replaced this one
                return
            } catch {
                guard !Task.isCancelled else { return }
                let apiError = APIError.from(error)
                // Ignore URLError.cancelled (code -999) — happens when a new request replaces the old one
                if case .networkError(let underlying) = apiError,
                   (underlying as NSError).code == NSURLErrorCancelled {
                    return
                }
                if case .httpError(let code, let msg, _) = apiError, code == 403 {
                    errorMessage = msg ?? "You don't have admin permissions."
                } else {
                    errorMessage = apiError.errorDescription ?? "Failed to load users."
                }
                logger.error("Failed to load users: \(error.localizedDescription)")
            }

            if !Task.isCancelled {
                isLoading = false
            }
        }
        loadTask = task
        await task.value
        isLoading = false
    }

    /// Loads the next page of users (pagination).
    func loadMoreUsers() async {
        guard !isLoadingMore, hasMorePages, let api = apiClient else { return }

        isLoadingMore = true
        let nextPage = currentPage + 1

        do {
            let result = try await api.getAdminUsers(
                page: nextPage,
                query: searchQuery.isEmpty ? nil : searchQuery,
                orderBy: sortField.rawValue,
                direction: sortDirection.rawValue
            )
            if result.isEmpty {
                hasMorePages = false
            } else {
                users.append(contentsOf: result)
                currentPage = nextPage
                hasMorePages = result.count >= 20
            }
        } catch {
            logger.error("Failed to load more users: \(error.localizedDescription)")
        }

        isLoadingMore = false
    }

    /// Debounced search — waits 300ms after typing stops before making the API call.
    func performSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }
            await loadUsers()
        }
    }

    /// Toggles sort direction and reloads.
    func toggleSortDirection() async {
        sortDirection.toggle()
        await loadUsers()
    }

    /// Changes sort field and reloads.
    func changeSortField(_ field: SortField) async {
        sortField = field
        await loadUsers()
    }

    // MARK: - Edit User

    /// Prepares the edit state for a user.
    func startEditing(_ user: AdminUser) {
        editingUser = user
        editRole = user.role
        editName = user.name
        editEmail = user.email
        editPassword = ""
        saveError = nil
        saveSuccess = false
    }

    /// Saves the edited user to the server.
    func saveUser() async {
        guard let user = editingUser, let api = apiClient else { return }

        isSaving = true
        saveError = nil
        saveSuccess = false

        let form = AdminUserUpdateForm(
            role: editRole.rawValue,
            name: editName,
            email: editEmail,
            profileImageURL: user.profileImageURL ?? "/user.png",
            password: editPassword.isEmpty ? nil : editPassword
        )

        do {
            let updated = try await api.updateAdminUser(userId: user.id, form: form)
            // Update the user in our local list
            if let index = users.firstIndex(where: { $0.id == user.id }) {
                users[index] = updated
            }
            saveSuccess = true
            logger.info("Updated user \(user.email) — role: \(self.editRole.rawValue)")
        } catch {
            let apiError = APIError.from(error)
            saveError = apiError.errorDescription ?? "Failed to save changes."
            logger.error("Failed to update user \(user.id): \(error.localizedDescription)")
        }

        isSaving = false
    }

    /// Quick role change directly from the list (tap the role badge).
    func cycleRole(for user: AdminUser) async {
        guard let api = apiClient else { return }

        let nextRole: User.UserRole
        switch user.role {
        case .pending: nextRole = .user
        case .user: nextRole = .admin
        case .admin: nextRole = .user
        }

        let form = AdminUserUpdateForm(
            role: nextRole.rawValue,
            name: user.name,
            email: user.email,
            profileImageURL: user.profileImageURL ?? "/user.png",
            password: nil
        )

        do {
            let updated = try await api.updateAdminUser(userId: user.id, form: form)
            if let index = users.firstIndex(where: { $0.id == user.id }) {
                users[index] = updated
            }
            logger.info("Changed \(user.email) role: \(user.role.rawValue) → \(nextRole.rawValue)")
        } catch {
            errorMessage = "Failed to change role."
            logger.error("Role change failed for \(user.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Delete User

    /// Deletes the specified user.
    func deleteUser(_ user: AdminUser) async {
        guard let api = apiClient else { return }

        isDeleting = true
        deleteError = nil

        do {
            try await api.deleteAdminUser(userId: user.id)
            users.removeAll { $0.id == user.id }
            userToDelete = nil
            logger.info("Deleted user \(user.email)")
        } catch {
            let apiError = APIError.from(error)
            deleteError = apiError.errorDescription ?? "Failed to delete user."
            logger.error("Failed to delete user \(user.id): \(error.localizedDescription)")
        }

        isDeleting = false
    }

    // MARK: - Add User

    /// Resets the add user form.
    func resetAddForm() {
        addName = ""
        addEmail = ""
        addPassword = ""
        addRole = .user
        addError = nil
    }

    /// Creates a new user on the server.
    func addUser() async {
        guard let api = apiClient else { return }

        guard !addName.isEmpty, !addEmail.isEmpty, !addPassword.isEmpty else {
            addError = "All fields are required."
            return
        }

        isAddingUser = true
        addError = nil

        let form = AdminAddUserForm(
            name: addName,
            email: addEmail,
            password: addPassword,
            role: addRole.rawValue,
            profileImageURL: "/user.png"
        )

        do {
            let newUser = try await api.addAdminUser(form: form)
            users.insert(newUser, at: 0)
            resetAddForm()
            logger.info("Added new user: \(newUser.email)")
        } catch {
            let apiError = APIError.from(error)
            if case .httpError(let code, let msg, _) = apiError, code == 400 {
                addError = msg ?? "This email is already registered."
            } else {
                addError = apiError.errorDescription ?? "Failed to add user."
            }
            logger.error("Failed to add user: \(error.localizedDescription)")
        }

        isAddingUser = false
    }

    // MARK: - View User Chats

    /// Loads chats for a specific user.
    func loadUserChats(for user: AdminUser) async {
        guard let api = apiClient else { return }

        viewingChatsForUser = user
        isLoadingChats = true
        chatError = nil
        userChats = []

        do {
            let chats = try await api.getAdminUserChats(
                userId: user.id,
                page: 1,
                orderBy: "updated_at",
                direction: "desc"
            )
            userChats = chats
            logger.info("Loaded \(chats.count) chats for user \(user.email)")
        } catch {
            let apiError = APIError.from(error)
            chatError = apiError.errorDescription ?? "Failed to load chats."
            logger.error("Failed to load chats for \(user.id): \(error.localizedDescription)")
        }

        isLoadingChats = false
    }

    /// Searches chats for the currently viewed user.
    func searchUserChats() async {
        guard let user = viewingChatsForUser, let api = apiClient else { return }

        isLoadingChats = true
        chatError = nil

        do {
            let chats = try await api.getAdminUserChats(
                userId: user.id,
                page: 1,
                query: chatSearchQuery.isEmpty ? nil : chatSearchQuery,
                orderBy: "updated_at",
                direction: "desc"
            )
            userChats = chats
        } catch {
            chatError = "Search failed."
        }

        isLoadingChats = false
    }

    // MARK: - Chat Detail (View / Clone / Delete)

    /// Loads the full conversation detail for a user's chat.
    /// Admin access to any chat is granted by the server when
    /// `enable_admin_chat_access` is enabled.
    func loadChatDetail(chatId: String) async {
        guard let api = apiClient else { return }

        isLoadingChatDetail = true
        chatDetailError = nil
        selectedChatDetail = nil

        do {
            let conversation = try await api.getAdminChatById(chatId: chatId)
            selectedChatDetail = conversation
            logger.info("Loaded chat detail: \(conversation.title) (\(conversation.messages.count) messages)")
        } catch {
            let apiError = APIError.from(error)
            if case .tokenExpired = apiError {
                chatDetailError = "Unable to access this chat. Ensure admin chat access is enabled on your server."
            } else {
                chatDetailError = apiError.errorDescription ?? "Failed to load chat."
            }
            logger.error("Failed to load chat detail \(chatId): \(error.localizedDescription)")
        }

        isLoadingChatDetail = false
    }

    /// Clones a user's chat to the admin's own chat list.
    /// The server creates a copy owned by the requesting admin user.
    func cloneUserChat(chatId: String) async {
        guard let api = apiClient else { return }

        isCloning = true
        clonedConversation = nil

        do {
            let cloned = try await api.cloneAdminChat(chatId: chatId)
            clonedConversation = cloned
            logger.info("Cloned chat \(chatId) → \(cloned.id)")
        } catch {
            let apiError = APIError.from(error)
            if case .tokenExpired = apiError {
                chatDetailError = "Unable to clone this chat. Ensure admin chat access is enabled."
            } else {
                chatDetailError = apiError.errorDescription ?? "Failed to clone chat."
            }
            logger.error("Failed to clone chat \(chatId): \(error.localizedDescription)")
        }

        isCloning = false
    }

    /// Deletes a user's chat. Removes it from the local list on success.
    func deleteUserChat(_ chat: AdminChatItem) async {
        guard let api = apiClient else { return }

        isDeletingChat = true
        deleteChatError = nil

        do {
            try await api.deleteAdminChat(chatId: chat.id)
            userChats.removeAll { $0.id == chat.id }
            // If the deleted chat was the one being viewed in detail, clear it
            if selectedChatDetail?.id == chat.id {
                selectedChatDetail = nil
            }
            logger.info("Deleted user chat: \(chat.title) (\(chat.id))")
        } catch {
            let apiError = APIError.from(error)
            deleteChatError = apiError.errorDescription ?? "Failed to delete chat."
            logger.error("Failed to delete chat \(chat.id): \(error.localizedDescription)")
        }

        isDeletingChat = false
    }
}
