import Foundation
import os.log

/// High-level client for the OpenWebUI REST API.
///
/// Built on top of `NetworkManager`, this class exposes typed methods
/// for every major OpenWebUI endpoint, matching the Flutter app's
/// `ApiService`.
///
/// Usage:
/// ```swift
/// let client = APIClient(serverConfig: config)
/// let healthy = await client.checkHealth()
/// let user = try await client.login(email: "a@b.com", password: "secret")
/// let models = try await client.getModels()
/// ```
final class APIClient: @unchecked Sendable {
    let network: NetworkManager
    private let logger = Logger(subsystem: "com.openui", category: "API")

    /// Callback invoked when the auth token is rejected (401).
    /// Thread-safe: protected by a lock to prevent data races since this
    /// is set from the MainActor but may be read from network callbacks.
    private let _authCallbackLock = NSLock()
    private var _onAuthTokenInvalid: (() -> Void)?
    var onAuthTokenInvalid: (() -> Void)? {
        get {
            _authCallbackLock.lock()
            defer { _authCallbackLock.unlock() }
            return _onAuthTokenInvalid
        }
        set {
            _authCallbackLock.lock()
            _onAuthTokenInvalid = newValue
            _authCallbackLock.unlock()
        }
    }

    init(serverConfig: ServerConfig, keychain: KeychainService = .shared) {
        self.network = NetworkManager(serverConfig: serverConfig, keychain: keychain)
    }

    /// Convenience accessor for the base URL string.
    var baseURL: String { network.serverConfig.url }

    // MARK: - Health & Configuration

    /// Basic health check – verifies the server is reachable.
    func checkHealth() async -> Bool {
        do {
            let (_, response) = try await network.requestRaw(
                path: "/health",
                authenticated: false
            )
            return response.statusCode == 200
        } catch {
            return false
        }
    }

    /// Health check with proxy detection.
    func checkHealthWithProxyDetection() async -> HealthCheckResult {
        do {
            let request = try network.buildRequest(
                path: "/health",
                authenticated: false,
                timeout: 15
            )
            let (_, response) = try await network.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .unreachable
            }

            let statusCode = httpResponse.statusCode

            // Check for redirects (proxy auth pages)
            if [302, 307, 308].contains(statusCode) {
                return .proxyAuthRequired
            }

            // Check for 401/403 with HTML (proxy login page)
            if [401, 403].contains(statusCode) {
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("text/html") {
                    return .proxyAuthRequired
                }
            }

            if statusCode == 200 {
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("text/html") {
                    return .proxyAuthRequired
                }
                return .healthy
            }

            return .unhealthy
        } catch {
            let apiError = APIError.from(error)
            if case .sslError = apiError { return .unreachable }
            if case .networkError = apiError { return .unreachable }
            return .unreachable
        }
    }

    /// Fetches the backend configuration from `/api/config`.
    func getBackendConfig() async throws -> BackendConfig {
        // Fetch raw data first so we can log it on decode failure
        let (data, _) = try await network.requestRaw(path: "/api/config", authenticated: false)
        do {
            let config = try JSONDecoder().decode(BackendConfig.self, from: data)
            return config
        } catch {
            logger.error("❌ [getBackendConfig] Decode FAILED: \(error)")
            // Try to surface the specific decoding failure
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let ctx):
                    logger.error("  keyNotFound: \(key.stringValue) — \(ctx.debugDescription)")
                case .typeMismatch(let type, let ctx):
                    logger.error("  typeMismatch: \(type) — \(ctx.debugDescription) at \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))")
                case .valueNotFound(let type, let ctx):
                    logger.error("  valueNotFound: \(type) — \(ctx.debugDescription)")
                case .dataCorrupted(let ctx):
                    logger.error("  dataCorrupted: \(ctx.debugDescription)")
                @unknown default:
                    logger.error("  unknown decoding error")
                }
            }
            throw error
        }
    }

    /// Verifies this is a valid OpenWebUI server and returns its config.
    func verifyAndGetConfig() async -> BackendConfig? {
        guard let config = try? await getBackendConfig(),
              config.isValidOpenWebUI
        else { return nil }
        return config
    }

    /// Enhanced server status including model availability.
    func checkServerStatus() async -> [String: Any] {
        var result: [String: Any] = [
            "healthy": false,
            "modelsAvailable": false,
            "modelCount": 0
        ]

        let healthy = await checkHealth()
        result["healthy"] = healthy

        if healthy {
            if let models = try? await getModels() {
                result["modelsAvailable"] = !models.isEmpty
                result["modelCount"] = models.count
            }
        }

        return result
    }

    // MARK: - Authentication

    /// Logs in with email and password. Returns the user and saves the token.
    func login(email: String, password: String) async throws -> User {
        let response = try await network.request(
            AuthResponse.self,
            path: "/api/v1/auths/signin",
            method: .post,
            body: ["email": email, "password": password] as [String: String],
            authenticated: false
        )

        network.saveAuthToken(response.token)

        return User(
            id: response.id ?? "",
            username: response.name ?? email,
            email: response.email ?? email,
            name: response.name,
            profileImageURL: response.profileImageUrl,
            role: User.UserRole(rawValue: response.role ?? "user") ?? .user
        )
    }

    /// LDAP authentication using username.
    func ldapLogin(username: String, password: String) async throws -> User {
        let response = try await network.request(
            AuthResponse.self,
            path: "/api/v1/auths/ldap",
            method: .post,
            body: ["user": username, "password": password] as [String: String],
            authenticated: false
        )

        network.saveAuthToken(response.token)

        return User(
            id: response.id ?? "",
            username: response.name ?? username,
            email: response.email ?? "",
            name: response.name,
            profileImageURL: response.profileImageUrl,
            role: User.UserRole(rawValue: response.role ?? "user") ?? .user
        )
    }

    /// Signs up a new user with name, email, and password.
    func signup(name: String, email: String, password: String) async throws -> User {
        let response = try await network.request(
            AuthResponse.self,
            path: "/api/v1/auths/signup",
            method: .post,
            body: ["name": name, "email": email, "password": password] as [String: String],
            authenticated: false
        )

        network.saveAuthToken(response.token)

        return User(
            id: response.id ?? "",
            username: response.name ?? name,
            email: response.email ?? email,
            name: response.name,
            profileImageURL: response.profileImageUrl,
            role: User.UserRole(rawValue: response.role ?? "user") ?? .user
        )
    }

    /// Signs out the current user.
    func logout() async throws {
        try await network.requestVoid(path: "/api/v1/auths/signout")
        network.deleteAuthToken()
    }

    /// Fetches the current authenticated user.
    func getCurrentUser() async throws -> User {
        try await network.request(User.self, path: "/api/v1/auths/")
    }

    /// Updates the auth token (e.g., after refresh or API key change).
    func updateAuthToken(_ token: String?) {
        if let token {
            network.saveAuthToken(token)
        } else {
            network.deleteAuthToken()
        }
    }

    // MARK: - Models

    /// Fetches available AI models from the server.
    func getModels() async throws -> [AIModel] {
        let (data, _) = try await network.requestRaw(path: "/api/models")

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Try parsing as raw array
            if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return parseModelArray(array)
            }
            return []
        }

        if let modelsArray = payload["data"] as? [[String: Any]] {
            return parseModelArray(modelsArray)
        }
        if let modelsArray = payload["models"] as? [[String: Any]] {
            return parseModelArray(modelsArray)
        }

        return []
    }

    /// Returns the user's default model ID from server settings.
    func getDefaultModel() async -> String? {
        do {
            let settings = try await getUserSettings()
            if let ui = settings["ui"] as? [String: Any],
               let models = ui["models"] as? [String],
               let first = models.first {
                return first
            }
        } catch {}

        // Fallback to first available model
        if let models = try? await getModels(), let first = models.first {
            return first.id
        }
        return nil
    }

    /// Fetches detailed model information.
    func getModelDetails(modelId: String) async throws -> [String: Any] {
        try await network.requestJSON(
            path: "/api/v1/models/model",
            queryItems: [URLQueryItem(name: "id", value: modelId)]
        )
    }

    // MARK: - Conversations

    /// Fetches the conversation list including pinned and archived.
    ///
    /// The `/api/v1/chats/` list endpoint returns `ChatTitleIdResponse` which does NOT
    /// include a `pinned` field — it only has `id`, `title`, `updated_at`, `created_at`.
    /// The `include_pinned=true` parameter only ensures pinned chats appear in the list,
    /// but never marks them as pinned. We therefore parallel-fetch the dedicated
    /// `/api/v1/chats/pinned` endpoint and merge the pinned IDs into the result.
    func getConversations(limit: Int? = nil, skip: Int? = nil) async throws -> [Conversation] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "include_folders", value: "false"),
            URLQueryItem(name: "include_pinned", value: "true")
        ]

        if let limit, limit > 0 {
            let page = ((skip ?? 0) / limit) + 1
            queryItems.append(URLQueryItem(name: "page", value: "\(max(1, page))"))
        }

        // Capture queryItems as a local let to satisfy Swift concurrency rules
        let capturedQueryItems = queryItems

        // Fetch conversation list and pinned IDs concurrently
        async let conversationsRequest = network.requestRaw(
            path: "/api/v1/chats/",
            queryItems: capturedQueryItems
        )
        async let pinnedIdsRequest = getPinnedConversationIds()

        let (data, _) = try await conversationsRequest
        let pinnedIds = (try? await pinnedIdsRequest) ?? Set<String>()

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected array of chats"]
                ),
                data: data
            )
        }

        return array.compactMap { parseConversationSummary($0) }.map { conv in
            guard !pinnedIds.isEmpty, pinnedIds.contains(conv.id) else { return conv }
            var pinned = conv
            pinned.pinned = true
            return pinned
        }
    }

    /// Fetches the set of IDs for all pinned conversations.
    ///
    /// Uses the dedicated `/api/v1/chats/pinned` endpoint which is the only
    /// reliable source of pinned status (the list endpoint's `ChatTitleIdResponse`
    /// schema does not include a `pinned` field).
    func getPinnedConversationIds() async throws -> Set<String> {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/pinned")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let ids = array.compactMap { $0["id"] as? String }
        return Set(ids)
    }

    /// Fetches a single conversation with full message history.
    func getConversation(id: String) async throws -> Conversation {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/\(id)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected chat object"]
                ),
                data: data
            )
        }

        return parseFullConversation(json)
    }

    /// Creates a new conversation.
    func createConversation(
        title: String,
        messages: [ChatMessage],
        model: String? = nil,
        systemPrompt: String? = nil,
        folderId: String? = nil
    ) async throws -> Conversation {
        let chatData = buildChatPayload(
            title: title,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt
        )

        var body: [String: Any] = ["chat": chatData]
        body["folder_id"] = folderId

        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/new",
            method: .post,
            body: try JSONSerialization.data(withJSONObject: body)
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected chat object"]
                ),
                data: data
            )
        }

        return parseFullConversation(json)
    }

    /// Updates conversation metadata (title, system prompt).
    func updateConversation(id: String, title: String? = nil, systemPrompt: String? = nil) async throws {
        var chatPayload: [String: Any] = [:]
        if let title { chatPayload["title"] = title }
        if let systemPrompt { chatPayload["system"] = systemPrompt }

        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(id)",
            method: .post,
            body: ["chat": chatPayload]
        )
    }

    /// Deletes a conversation.
    func deleteConversation(id: String) async throws {
        try await network.requestVoid(path: "/api/v1/chats/\(id)", method: .delete)
    }

    /// Deletes all conversations for the current user.
    func deleteAllConversations() async throws {
        try await network.requestVoid(path: "/api/v1/chats/", method: .delete)
    }

    /// Pins or unpins a conversation.
    func pinConversation(id: String, pinned: Bool) async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/\(id)/pin",
            method: .post,
            body: ["pinned": pinned] as [String: Bool]
        )
    }

    /// Archives or unarchives a conversation.
    func archiveConversation(id: String, archived: Bool) async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/\(id)/archive",
            method: .post,
            body: ["archived": archived] as [String: Bool]
        )
    }

    /// Shares a conversation and returns the share ID.
    func shareConversation(id: String) async throws -> String? {
        let json = try await network.requestJSON(
            path: "/api/v1/chats/\(id)/share",
            method: .post
        )
        return json["share_id"] as? String
    }

    /// Clones a conversation.
    func cloneConversation(id: String) async throws -> Conversation {
        let emptyBody = try JSONSerialization.data(withJSONObject: [String: Any]())
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/\(id)/clone",
            method: .post,
            body: emptyBody
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected chat object"]
                ),
                data: data
            )
        }

        return parseFullConversation(json)
    }

    /// Searches conversations by query string.
    func searchConversations(query: String) async throws -> [Conversation] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/search",
            queryItems: [URLQueryItem(name: "text", value: query)]
        )

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { parseConversationSummary($0) }
    }

    /// Moves a conversation to a folder.
    func moveConversationToFolder(conversationId: String, folderId: String?) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(conversationId)/folder",
            method: .post,
            body: ["folder_id": folderId as Any]
        )
    }

    // MARK: - Chat Completion (Streaming)

    /// Sends a chat completion request using WebSocket-based streaming.
    ///
    /// Returns a stream of SSE events and the generated session/message IDs
    /// needed by the Socket.IO event handlers.
    func sendMessage(
        request: ChatCompletionRequest
    ) async throws -> (json: [String: Any], messageId: String, sessionId: String) {
        let body = request.toJSON()

        let responseJSON = try await network.requestJSON(
            path: "/api/chat/completions",
            method: .post,
            body: body,
            timeout: 30
        )

        return (
            json: responseJSON,
            messageId: request.messageId ?? UUID().uuidString,
            sessionId: request.sessionId ?? UUID().uuidString
        )
    }

    /// Sends a chat completion request and returns an SSE stream for
    /// direct HTTP streaming (non-WebSocket mode).
    func sendMessageStreaming(
        request: ChatCompletionRequest
    ) async throws -> SSEStream {
        try await network.streamRequestBytes(
            path: "/api/chat/completions",
            method: .post,
            body: request.toJSON()
        )
    }

    /// Sends a chat completion request via HTTP POST and returns the JSON response.
    ///
    /// Used for WebSocket-based streaming where the HTTP request returns
    /// immediately (with a `task_id`) and all actual content is delivered
    /// via Socket.IO events. This matches the Flutter/OpenWebUI web client pattern.
    func sendMessageHTTP(
        request: ChatCompletionRequest
    ) async throws -> [String: Any] {
        let body = request.toJSON()
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await network.requestRaw(
            path: "/api/chat/completions",
            method: .post,
            body: bodyData,
            timeout: 30
        )
        // Try to parse as JSON object
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        // If not a JSON object, return empty (server may return just a task_id string)
        if let str = String(data: data, encoding: .utf8), !str.isEmpty {
            return ["raw": str]
        }
        return [:]
    }

    /// Syncs conversation messages to the server.
    ///
    /// Builds the full chat payload (with history tree, parent chains, etc.)
    /// and posts it to the update endpoint. This ensures the server has the
    /// complete message structure for proper rendering in OpenWebUI.
    func syncConversationMessages(
        id: String,
        messages: [ChatMessage],
        model: String?,
        systemPrompt: String? = nil,
        title: String? = nil
    ) async throws {
        let chatData = buildChatPayload(
            title: title ?? "", // Empty string preserves server-side title; non-empty overwrites it
            messages: messages,
            model: model,
            systemPrompt: systemPrompt
        )
        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(id)",
            method: .post,
            body: ["chat": chatData]
        )
    }

    /// Notifies the backend that chat streaming is complete.
    func sendChatCompleted(
        chatId: String,
        messageId: String,
        model: String,
        sessionId: String
    ) async {
        let body: [String: Any] = [
            "model": model,
            "messages": [] as [[String: Any]],
            "chat_id": chatId,
            "session_id": sessionId,
            "id": messageId
        ]

        try? await network.requestVoidJSON(
            path: "/api/chat/completed",
            method: .post,
            body: body
        )
    }

    /// Stops an active task by its ID.
    func stopTask(taskId: String) async throws {
        try await network.requestVoid(
            path: "/api/tasks/stop/\(taskId)",
            method: .post
        )
    }

    /// Returns the task IDs currently active for a given chat.
    ///
    /// Calls `GET /api/tasks/chat/{chat_id}` and returns an array of
    /// task ID strings that can each be passed to `stopTask(taskId:)`.
    func getTasksForChat(chatId: String) async throws -> [String] {
        let (data, _) = try await network.requestRaw(path: "/api/tasks/chat/\(chatId)")
        let parsed = try JSONSerialization.jsonObject(with: data)
        // Response is an array of task objects: [{"id": "...", ...}, ...]
        if let arr = parsed as? [[String: Any]] {
            return arr.compactMap { $0["id"] as? String }
        }
        // Fallback: array of plain strings
        if let arr = parsed as? [String] {
            return arr
        }
        // Fallback: dict with "tasks" key
        if let dict = parsed as? [String: Any] {
            if let arr = dict["tasks"] as? [[String: Any]] {
                return arr.compactMap { $0["id"] as? String }
            }
            if let arr = dict["task_ids"] as? [String] {
                return arr
            }
        }
        return []
    }

    // MARK: - User Settings

    /// Fetches the current user's settings.
    func getUserSettings() async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/users/user/settings")
    }

    /// Updates user settings.
    func updateUserSettings(_ settings: [String: Any]) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/users/user/settings/update",
            method: .post,
            body: settings
        )
    }

    // MARK: - Folders

    /// Fetches all folders. Returns `(folders, featureEnabled)`.
    func getFolders() async throws -> (folders: [[String: Any]], enabled: Bool) {
        do {
            let (data, _) = try await network.requestRaw(path: "/api/v1/folders/")
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return ([], true)
            }
            return (array, true)
        } catch let error as APIError {
            if case .httpError(let code, _, _) = error, code == 403 {
                return ([], false)
            }
            throw error
        }
    }

    /// Creates a new folder.
    func createFolder(name: String, parentId: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["name": name]
        if let parentId { body["parent_id"] = parentId }
        return try await network.requestJSON(
            path: "/api/v1/folders/",
            method: .post,
            body: body
        )
    }

    /// Renames a folder (updates its name).
    func renameFolder(id: String, name: String) async throws -> [String: Any] {
        return try await network.requestJSON(
            path: "/api/v1/folders/\(id)/update",
            method: .post,
            body: ["name": name]
        )
    }

    /// Syncs the expanded/collapsed state of a folder to the server.
    /// Fire-and-forget — failures are silently ignored.
    func setFolderExpanded(id: String, expanded: Bool) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/folders/\(id)/update/expanded",
            method: .post,
            body: ["is_expanded": expanded]
        )
    }

    /// Moves a folder to a new parent (or to the root if parentId is nil).
    func moveFolderParent(id: String, parentId: String?) async throws {
        var body: [String: Any] = [:]
        if let parentId {
            body["parent_id"] = parentId
        } else {
            body["parent_id"] = NSNull()
        }
        try await network.requestVoidJSON(
            path: "/api/v1/folders/\(id)/update/parent",
            method: .post,
            body: body
        )
    }

    /// Deletes a folder.
    func deleteFolder(id: String) async throws {
        try await network.requestVoid(path: "/api/v1/folders/\(id)", method: .delete)
    }

    /// Fetches the list of chats inside a folder (paginated).
    func getChatsInFolder(folderId: String, page: Int = 1) async throws -> [Conversation] {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(page)")
        ]
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/folder/\(folderId)/list",
            queryItems: queryItems
        )

        // The folder list endpoint can return either summary objects or full chat objects.
        // Parse both formats.
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { parseFolderChatItem($0, folderId: folderId) }
        }
        return []
    }

    /// Parses a chat item from the folder list endpoint.
    /// Handles both summary (`title` at root) and full (`chat.title` nested) formats.
    private func parseFolderChatItem(_ json: [String: Any], folderId: String) -> Conversation? {
        guard let id = json["id"] as? String else { return nil }

        // Title: try root first, then nested chat object
        var title = json["title"] as? String ?? ""
        if title.isEmpty, let chat = json["chat"] as? [String: Any] {
            title = chat["title"] as? String ?? ""
        }
        if title.isEmpty { title = "Untitled Chat" }

        var createdAt = Date()
        var updatedAt = Date()
        if let ts = json["created_at"] as? Double { createdAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["created_at"] as? Int { createdAt = Date(timeIntervalSince1970: Double(ts)) }
        if let ts = json["updated_at"] as? Double { updatedAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["updated_at"] as? Int { updatedAt = Date(timeIntervalSince1970: Double(ts)) }

        let pinned = json["pinned"] as? Bool ?? false
        let archived = json["archived"] as? Bool ?? false
        let tags = json["tags"] as? [String] ?? []

        var model: String?
        if let chat = json["chat"] as? [String: Any],
           let models = chat["models"] as? [String],
           let first = models.first {
            model = first
        }

        return Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            pinned: pinned,
            archived: archived,
            folderId: folderId,
            tags: tags
        )
    }

    // MARK: - Tags

    /// Fetches all available tags.
    ///
    /// Uses `GET /api/v1/chats/all/tags` which returns `[TagModel]` objects.
    /// Falls back to parsing plain strings for older server versions.
    func getAllTags() async throws -> [String] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/all/tags")

        // Modern format: array of TagModel objects with "name" field
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { $0["name"] as? String }
        }
        // Legacy fallback: plain string array
        if let array = try JSONSerialization.jsonObject(with: data) as? [String] {
            return array
        }
        return []
    }

    /// Adds a tag to a conversation.
    func addTag(to conversationId: String, tag: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(conversationId)/tags",
            method: .post,
            body: ["tag_name": tag]
        )
    }

    /// Removes a tag from a conversation.
    func removeTag(from conversationId: String, tag: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(conversationId)/tags",
            method: .delete,
            body: ["tag_name": tag]
        )
    }

    // MARK: - Files

    /// Uploads a file with `?process=true` and waits for server-side processing
    /// to complete before returning. This matches the OpenWebUI web client flow:
    ///
    /// 1. POST `/api/v1/files/?process=true` — upload + start processing
    /// 2. GET  `/api/v1/files/{id}/process/status?stream=true` — SSE poll until `completed`
    ///
    /// For images, processing is skipped (they don't need text extraction).
    /// For documents (PDF, txt, etc.), the server extracts text and creates
    /// embeddings, which is required before the file can be used in RAG.
    func uploadFile(data fileData: Data, fileName: String) async throws -> String {
        let mime = mimeType(for: fileName)
        let isImage = mime.hasPrefix("image/")

        // Step 1: Upload with ?process=true for non-image files
        let queryItems: [URLQueryItem]? = isImage ? nil : [
            URLQueryItem(name: "process", value: "true")
        ]

        let response = try await network.uploadMultipart(
            path: "/api/v1/files/",
            queryItems: queryItems,
            fileData: fileData,
            fileName: fileName,
            mimeType: mime,
            timeout: 300 // Large files need more upload time
        )

        guard let fileId = response["id"] as? String else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing file ID in response"]
                ),
                data: nil
            )
        }

        // Step 2: For non-image files, wait for processing to complete via SSE
        if !isImage {
            try await waitForFileProcessing(fileId: fileId)
        }

        return fileId
    }

    /// Polls the file processing status endpoint via SSE until the status
    /// becomes `"completed"` or an error / timeout occurs.
    ///
    /// Matches the web client's:
    /// `GET /api/v1/files/{id}/process/status?stream=true`
    ///
    /// The server sends SSE events like `data: {"status": "pending"}` repeatedly
    /// until processing finishes, then sends `data: {"status": "completed"}`.
    private func waitForFileProcessing(fileId: String, timeout: TimeInterval = 300) async throws {
        let queryItems = [URLQueryItem(name: "stream", value: "true")]

        var request = try network.buildRequest(
            path: "/api/v1/files/\(fileId)/process/status",
            method: .get,
            queryItems: queryItems,
            authenticated: true,
            timeout: timeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Use a session with long timeout for processing (large PDFs can take minutes)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 60
        config.waitsForConnectivity = true

        let session: URLSession
        if network.serverConfig.allowSelfSignedCertificates {
            // Reuse the main session which has the certificate delegate
            session = network.session
        } else {
            session = URLSession(configuration: config)
        }

        let (bytes, response) = try await session.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            // Read error body
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count > 4096 { break }
            }
            logger.error("File processing status check failed with \(httpResponse.statusCode)")
            // Don't throw — file was uploaded successfully, processing may still work
            return
        }

        // Parse SSE lines looking for status: "completed" or "error"
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Parse "data: {...}" SSE format
            let jsonString: String
            if trimmed.hasPrefix("data: ") {
                jsonString = String(trimmed.dropFirst(6))
            } else if trimmed.hasPrefix("{") {
                jsonString = trimmed
            } else {
                continue
            }

            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let status = json["status"] as? String else {
                continue
            }

            logger.debug("File \(fileId) processing status: \(status)")

            switch status {
            case "completed":
                logger.info("File \(fileId) processing completed")
                return
            case "error":
                let errorMsg = json["error"] as? String ?? "File processing failed"
                logger.error("File \(fileId) processing error: \(errorMsg)")
                // Don't throw — file was uploaded, let the user try to use it
                return
            case "pending":
                // Keep waiting for next SSE event
                continue
            default:
                continue
            }
        }

        // Stream ended without explicit completed/error — assume done
        logger.info("File \(fileId) processing stream ended (assuming completed)")
    }

    /// Fetches metadata about a file.
    func getFileInfo(id: String) async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/files/\(id)")
    }

    /// Downloads a file's raw content bytes.
    func getFileContent(id: String) async throws -> (Data, String) {
        let (data, response) = try await network.requestRaw(
            path: "/api/v1/files/\(id)/content"
        )
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, contentType)
    }

    /// Lists the current user's files.
    func getUserFiles() async throws -> [FileInfoResponse] {
        try await network.request([FileInfoResponse].self, path: "/api/v1/files/")
    }

    /// Deletes a file.
    func deleteFile(id: String) async throws {
        try await network.requestVoid(path: "/api/v1/files/\(id)", method: .delete)
    }

    /// Returns the direct URL for a file's content (for playback/download).
    func fileContentURL(for fileId: String) -> URL? {
        network.baseURL?.appendingPathComponent("api/v1/files/\(fileId)/content")
    }

    // MARK: - Audio

    /// Transcribes an audio file.
    func transcribeSpeech(audioData: Data, fileName: String) async throws -> [String: Any] {
        let mime = mimeType(for: fileName)
        return try await network.uploadMultipart(
            path: "/api/v1/audio/transcriptions",
            fileData: audioData,
            fileName: fileName,
            mimeType: mime
        )
    }

    /// Generates speech from text.
    func generateSpeech(text: String, voice: String? = nil) async throws -> (Data, String) {
        var body: [String: Any] = ["input": text]
        if let voice { body["voice"] = voice }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await network.requestRaw(
            path: "/api/v1/audio/speech",
            method: .post,
            body: bodyData
        )
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg"
        return (data, contentType)
    }

    // MARK: - Knowledge Base

    /// Fetches all knowledge bases.
    func getKnowledgeBases() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/knowledge/")
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = dict["items"] as? [[String: Any]] {
            return items
        }
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    /// Fetches knowledge bases parsed into `KnowledgeItem` models.
    ///
    /// Calls `GET /api/v1/knowledge/` which returns a paginated
    /// `{ items: [...], total: N }` response. Each item has `id`, `name`,
    /// `description`, and an optional `files` array.
    func getKnowledgeItems() async throws -> [KnowledgeItem] {
        let raw = try await getKnowledgeBases()
        return raw.compactMap { entry -> KnowledgeItem? in
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String else { return nil }
            let description = entry["description"] as? String
            let files = entry["files"] as? [[String: Any]]
            return KnowledgeItem(
                id: id,
                name: name,
                description: description,
                type: .collection,
                fileCount: files?.count
            )
        }
    }

    /// Fetches knowledge-associated files parsed into `KnowledgeItem` models.
    ///
    /// Calls `GET /api/v1/knowledge/search/files` which returns only files
    /// that belong to knowledge bases — NOT raw user uploads. This matches
    /// the OpenWebUI web client's `#` picker behavior.
    ///
    /// Response is paginated: `{ items: [...], total: N }`.
    func getKnowledgeFileItems() async throws -> [KnowledgeItem] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/knowledge/search/files"
        )
        // Parse paginated response: { items: [...], total: N }
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = dict["items"] as? [[String: Any]] {
            return items.compactMap { entry -> KnowledgeItem? in
                guard let id = entry["id"] as? String else { return nil }
                let filename = entry["filename"] as? String
                let meta = entry["meta"] as? [String: Any]
                let name = meta?["name"] as? String ?? filename ?? id
                return KnowledgeItem(
                    id: id,
                    name: name,
                    description: nil,
                    type: .file,
                    fileCount: nil
                )
            }
        }
        // Fallback: try as plain array
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { entry -> KnowledgeItem? in
                guard let id = entry["id"] as? String else { return nil }
                let filename = entry["filename"] as? String
                let meta = entry["meta"] as? [String: Any]
                let name = meta?["name"] as? String ?? filename ?? id
                return KnowledgeItem(
                    id: id,
                    name: name,
                    description: nil,
                    type: .file,
                    fileCount: nil
                )
            }
        }
        return []
    }

    /// Fetches chat folders parsed into `KnowledgeItem` models.
    ///
    /// Uses the existing `GET /api/v1/folders/` endpoint. Folders appear
    /// at the top of the `#` picker in the OpenWebUI web client.
    func getFolderItems() async throws -> [KnowledgeItem] {
        let (folders, _) = try await getFolders()
        return folders.compactMap { entry -> KnowledgeItem? in
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String else { return nil }
            return KnowledgeItem(
                id: id,
                name: name,
                description: nil,
                type: .folder,
                fileCount: nil
            )
        }
    }

    // MARK: - Prompts

    /// Fetches available prompts.
    func getPrompts() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/prompts/")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    // MARK: - Tools

    /// Fetches available tools.
    func getTools() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/tools/")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    // MARK: - Terminal Servers

    /// Fetches the list of terminal servers available to the authenticated user.
    ///
    /// Calls `GET /api/v1/terminals/` which returns terminal servers the user
    /// has access to. Each server entry contains at minimum an `id` and `name`.
    /// Returns an empty array if the endpoint fails (e.g. server doesn't support terminals).
    func listTerminalServers() async throws -> [TerminalServer] {
        do {
            let (data, _) = try await network.requestRaw(path: "/api/v1/terminals/")
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return array.compactMap { item -> TerminalServer? in
                guard let id = item["id"] as? String else { return nil }
                let name = item["name"] as? String ?? id
                return TerminalServer(id: id, name: name)
            }
        } catch {
            // Terminal servers are optional — don't propagate errors
            return []
        }
    }

    /// Fetches the configuration of a specific terminal server.
    ///
    /// Calls `GET /api/v1/terminals/{serverId}/api/config` which returns
    /// the server's feature flags (e.g. `{"features": {"terminal": true}}`).
    func getTerminalConfig(serverId: String) async throws -> TerminalConfig {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/api/config"
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TerminalConfig(from: [:])
        }
        return TerminalConfig(from: json)
    }

    /// Lists files in a directory on the terminal server.
    ///
    /// Proxied through `GET /api/v1/terminals/{serverId}/files/list?directory=...`
    /// The Open Terminal API returns `{"dir": "...", "entries": [...]}`.
    func terminalListFiles(serverId: String, path: String) async throws -> [TerminalFileItem] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/files/list",
            queryItems: [URLQueryItem(name: "directory", value: path)]
        )
        // Response is {"dir": "/abs/path", "entries": [{name, is_dir, size, modified}, ...]}
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = json["entries"] as? [[String: Any]] {
            let dir = json["dir"] as? String ?? path
            return entries.map { TerminalFileItem(from: $0, basePath: dir) }
        }
        // Fallback: try parsing as raw array for backwards compatibility
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.map { TerminalFileItem(from: $0, basePath: path) }
        }
        return []
    }

    /// Reads a text file from the terminal server.
    ///
    /// Proxied through `GET /api/v1/terminals/{serverId}/files/read?path=...`
    func terminalReadFile(serverId: String, path: String) async throws -> String {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/files/read",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
        // Response can be raw text or JSON with "content" field
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? String {
            return content
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Creates a directory on the terminal server.
    ///
    /// Proxied through `POST /api/v1/terminals/{serverId}/files/mkdir`
    func terminalMkdir(serverId: String, path: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/terminals/\(serverId)/files/mkdir",
            method: .post,
            body: ["path": path]
        )
    }

    /// Deletes a file or directory on the terminal server.
    ///
    /// Proxied through `DELETE /api/v1/terminals/{serverId}/files/delete?path=...`
    func terminalDeleteFile(serverId: String, path: String) async throws {
        try await network.requestVoid(
            path: "/api/v1/terminals/\(serverId)/files/delete",
            method: .delete,
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
    }

    /// Downloads a file from the terminal server as raw bytes.
    ///
    /// Proxied through `GET /api/v1/terminals/{serverId}/files/view?path=...`
    func terminalDownloadFile(serverId: String, path: String) async throws -> (Data, String) {
        let (data, response) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/files/view",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, contentType)
    }

    /// Writes content to a file on the terminal server.
    ///
    /// Proxied through `POST /api/v1/terminals/{serverId}/files/write`
    func terminalWriteFile(serverId: String, path: String, content: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "content": content
        ])
        try await network.requestVoid(
            path: "/api/v1/terminals/\(serverId)/files/write",
            method: .post,
            body: body
        )
    }

    /// Executes a command on the terminal server.
    ///
    /// Proxied through `POST /api/v1/terminals/{serverId}/execute?wait=N`
    /// The `wait` parameter blocks the server for up to N seconds waiting for
    /// the command to finish, enabling synchronous execution for short commands.
    /// Returns the process ID for polling status on long-running commands.
    func terminalExecute(serverId: String, command: String, cwd: String? = nil) async throws -> TerminalCommandResult {
        var body: [String: Any] = ["command": command]
        if let cwd { body["cwd"] = cwd }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        // Use wait=10 so short commands complete inline without needing polling
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/execute",
            method: .post,
            queryItems: [URLQueryItem(name: "wait", value: "10")],
            body: bodyData
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.unknown(underlying: NSError(domain: "Terminal", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid execute response"]))
        }
        return TerminalCommandResult(from: json)
    }

    /// Gets the status/output of a running command on the terminal server.
    ///
    /// Proxied through `GET /api/v1/terminals/{serverId}/execute/{processId}/status`
    /// The `offset` parameter enables incremental output reading (only new output
    /// since the last poll). The `wait` parameter blocks up to N seconds for new output.
    func terminalGetCommandStatus(serverId: String, processId: String, offset: Int = 0) async throws -> TerminalCommandResult {
        var queryItems = [URLQueryItem(name: "offset", value: "\(offset)")]
        // Wait up to 5 seconds for new output on each poll
        queryItems.append(URLQueryItem(name: "wait", value: "5"))
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/execute/\(processId)/status",
            queryItems: queryItems
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.unknown(underlying: NSError(domain: "Terminal", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid status response"]))
        }
        return TerminalCommandResult(from: json)
    }

    /// Uploads a file to the terminal server filesystem.
    ///
    /// Proxied through `POST /api/v1/terminals/{serverId}/files/upload?directory=...`
    /// The Open Terminal API expects `directory` as a query parameter and the file
    /// as a multipart form upload in the `file` field.
    func terminalUploadFile(serverId: String, fileData: Data, fileName: String, destinationPath: String) async throws {
        let boundary = UUID().uuidString
        var body = Data()

        // File field only — directory is sent as a query parameter
        let mime = mimeType(for: fileName)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = try network.buildRequest(
            path: "/api/v1/terminals/\(serverId)/files/upload",
            method: .post,
            queryItems: [URLQueryItem(name: "directory", value: destinationPath)],
            authenticated: true,
            timeout: 120
        )
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await network.session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: "Upload failed", data: nil)
        }
    }

    // MARK: - Notes

    /// Fetches all notes from the server.
    ///
    /// Returns `(notes, featureEnabled)`. When the server returns 401/403
    /// for the notes endpoint, the feature is disabled and `featureEnabled`
    /// is `false`. Matches the Flutter `ApiService.getNotes()` endpoint.
    func getNotes() async throws -> (notes: [[String: Any]], featureEnabled: Bool) {
        do {
            let (data, _) = try await network.requestRaw(path: "/api/v1/notes/")
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return ([], true)
            }
            return (array, true)
        } catch let error as APIError {
            if case .httpError(let code, _, _) = error, code == 401 || code == 403 {
                return ([], false)
            }
            throw error
        }
    }

    /// Fetches a single note by ID.
    func getNoteById(_ id: String) async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/notes/\(id)")
    }

    /// Creates a new note on the server.
    ///
    /// Matches the Flutter `ApiService.createNote()` which posts to
    /// `/api/v1/notes/create` with `title`, `data`, `meta`, `access_control`.
    func createNote(
        title: String,
        markdownContent: String = "",
        htmlContent: String = ""
    ) async throws -> [String: Any] {
        let noteData: [String: Any] = [
            "content": [
                "json": NSNull(),
                "html": htmlContent,
                "md": markdownContent
            ],
            "versions": [] as [Any],
            "files": NSNull()
        ]

        let body: [String: Any] = [
            "title": title,
            "data": noteData,
            "access_control": [String: Any]()
        ]

        return try await network.requestJSON(
            path: "/api/v1/notes/create",
            method: .post,
            body: body
        )
    }

    /// Updates an existing note on the server.
    ///
    /// Matches the Flutter `ApiService.updateNote()` which posts to
    /// `/api/v1/notes/{id}/update`.
    func updateNote(
        id: String,
        title: String? = nil,
        markdownContent: String? = nil,
        htmlContent: String? = nil
    ) async throws -> [String: Any] {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }

        if markdownContent != nil || htmlContent != nil {
            body["data"] = [
                "content": [
                    "json": NSNull(),
                    "html": htmlContent ?? "",
                    "md": markdownContent ?? ""
                ]
            ]
        }

        return try await network.requestJSON(
            path: "/api/v1/notes/\(id)/update",
            method: .post,
            body: body
        )
    }

    /// Deletes a note by ID.
    func deleteNote(id: String) async throws -> Bool {
        do {
            try await network.requestVoid(
                path: "/api/v1/notes/\(id)/delete",
                method: .delete
            )
            return true
        } catch {
            return false
        }
    }

    /// Searches notes on the server.
    ///
    /// Uses `GET /api/v1/notes/search?query=...` for server-side full-text search.
    /// More comprehensive than local cache search since it covers all notes.
    func searchNotes(query: String) async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/notes/search",
            queryItems: [URLQueryItem(name: "query", value: query)]
        )
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    // MARK: - Profile & Account

    /// Updates the current user's profile (name and/or avatar).
    ///
    /// Matches `POST /api/v1/auths/update/profile` from the API spec.
    func updateProfile(name: String, profileImageUrl: String? = nil) async throws {
        var body: [String: String] = ["name": name]
        if let url = profileImageUrl { body["profile_image_url"] = url }
        try await network.requestVoidJSON(
            path: "/api/v1/auths/update/profile",
            method: .post,
            body: body
        )
    }

    /// Changes the current user's password.
    ///
    /// Matches `POST /api/v1/auths/update/password` from the API spec.
    func changePassword(currentPassword: String, newPassword: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/auths/update/password",
            method: .post,
            body: [
                "password": currentPassword,
                "new_password": newPassword
            ]
        )
    }

    /// Sends the user's timezone to the server.
    ///
    /// Called after login/session restore so the server has correct timezone
    /// context for date formatting and analytics. Fire-and-forget.
    func updateTimezone(_ timezone: String) async {
        try? await network.requestVoidJSON(
            path: "/api/v1/auths/update/timezone",
            method: .post,
            body: ["timezone": timezone]
        )
    }

    // MARK: - Audio (Extended)

    /// Fetches available TTS voices from the server.
    ///
    /// Returns the voice options that can be passed to `generateSpeech(voice:)`.
    func getVoices() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/audio/voices")
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let voices = dict["voices"] as? [[String: Any]] {
            return voices
        }
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    // MARK: - Chat Extended Operations

    /// Revokes the share link for a conversation.
    func unshareConversation(id: String) async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/\(id)/share",
            method: .delete
        )
    }

    /// Archives all conversations for the current user.
    func archiveAllConversations() async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/archive/all",
            method: .post
        )
    }

    /// Unarchives all conversations for the current user.
    func unarchiveAllConversations() async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/unarchive/all",
            method: .post
        )
    }

    // MARK: - Memories

    /// Fetches all memories for the current user.
    func getMemories() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/memories/")
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    /// Adds a new memory.
    func addMemory(content: String) async throws -> [String: Any] {
        try await network.requestJSON(
            path: "/api/v1/memories/add",
            method: .post,
            body: ["content": content]
        )
    }

    /// Updates an existing memory.
    func updateMemory(id: String, content: String) async throws -> [String: Any] {
        try await network.requestJSON(
            path: "/api/v1/memories/\(id)/update",
            method: .post,
            body: ["content": content]
        )
    }

    /// Deletes a memory by ID.
    func deleteMemory(id: String) async throws {
        try await network.requestVoid(
            path: "/api/v1/memories/\(id)",
            method: .delete
        )
    }

    /// Deletes all memories for the current user.
    func resetMemories() async throws {
        try await network.requestVoid(
            path: "/api/v1/memories/reset",
            method: .post
        )
    }

    // MARK: - Title Generation

    /// Generates a title for a conversation using the server's title generation task.
    ///
    /// Calls `POST /api/v1/tasks/title/completions` which uses the admin-configured
    /// task model to generate a concise title from the conversation messages.
    func generateTitle(model: String, messages: [[String: Any]], chatId: String? = nil) async throws -> String? {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]
        if let chatId { body["chat_id"] = chatId }

        let json = try await network.requestJSON(
            path: "/api/v1/tasks/title/completions",
            method: .post,
            body: body,
            timeout: 15
        )

        // Extract title from response — can be in various formats
        if let title = json["title"] as? String, !title.isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            // The content may be a JSON string like { "title": "..." }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               let jsonData = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let parsedTitle = parsed["title"] as? String, !parsedTitle.isEmpty {
                return parsedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Otherwise return the content directly (it's the title itself)
            return trimmed
        }
        // Try direct "response" field (some server versions)
        if let response = json["response"] as? String, !response.isEmpty {
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               let jsonData = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let parsedTitle = parsed["title"] as? String {
                return parsedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
        return nil
    }

    // MARK: - Util APIs

    /// Downloads a chat as a PDF document from the server.
    ///
    /// Uses `POST /api/v1/utils/pdf` with the chat title and messages.
    /// The server renders the PDF and returns binary data.
    /// Downloads a chat as a PDF document from the server.
    ///
    /// Fetches the full raw conversation JSON from the server and passes
    /// the native message objects to `/api/v1/utils/pdf`. This ensures the
    /// messages have the exact format the server's PDF renderer expects
    /// (including all fields like id, parentId, model, etc.), matching how
    /// the Open WebUI web client calls this endpoint.
    func downloadChatAsPDF(chatId: String) async throws -> Data {
        // Step 1: Fetch the raw conversation from server
        let (chatData, _) = try await network.requestRaw(path: "/api/v1/chats/\(chatId)")
        guard let chatJson = try JSONSerialization.jsonObject(with: chatData) as? [String: Any] else {
            throw APIError.responseDecoding(underlying: NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid chat data"]), data: chatData)
        }

        // Step 2: Extract title and walk the history tree for ordered messages
        // The flat `chat.messages` array may have empty content summaries.
        // The real content lives in `chat.history.messages` keyed by ID.
        let chat = chatJson["chat"] as? [String: Any] ?? [:]
        let title = chat["title"] as? String ?? chatJson["title"] as? String ?? "Chat"

        var orderedMessages: [[String: Any]] = []

        if let history = chat["history"] as? [String: Any],
           let messagesMap = history["messages"] as? [String: [String: Any]],
           let currentId = history["currentId"] as? String {
            // Walk the parent chain from currentId to root
            var chain: [[String: Any]] = []
            var cursor: String? = currentId
            while let id = cursor, let msg = messagesMap[id] {
                var m = msg
                m["id"] = id
                chain.append(m)
                cursor = msg["parentId"] as? String
            }
            chain.reverse()
            orderedMessages = chain
        } else {
            // Fallback: use flat messages array
            orderedMessages = chat["messages"] as? [[String: Any]] ?? []
        }

        // Step 3: Ensure every message has a non-null content string
        let safeMessages: [[String: Any]] = orderedMessages.map { msg in
            var m = msg
            if m["content"] == nil || m["content"] is NSNull {
                m["content"] = ""
            }
            return m
        }

        // Step 4: Send to PDF endpoint
        let body: [String: Any] = [
            "title": title,
            "messages": safeMessages
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/utils/pdf",
            method: .post,
            body: bodyData,
            timeout: 120
        )
        return data
    }

    // MARK: - AI Note Features

    /// Generates an AI title for note content using chat completions.
    ///
    /// Matches the Flutter `ApiService.generateNoteTitle()` which sends a
    /// prompt to `/api/chat/completions` requesting a concise 3-5 word title.
    func generateNoteTitle(content: String, modelId: String) async throws -> String? {
        let prompt = """
        ### Task:
        Generate a concise, 3-5 word title with an emoji summarizing the content in the content's primary language.
        ### Guidelines:
        - The title should clearly represent the main theme or subject of the content.
        - Use emojis that enhance understanding of the topic, but avoid quotation marks or special formatting.
        - Write the title in the content's primary language.
        - Prioritize accuracy over excessive creativity; keep it clear and simple.
        - Your entire response must consist solely of the JSON object, without any introductory or concluding text.
        - The output must be a single, raw JSON object, without any markdown code fences or other encapsulating text.
        ### Output:
        JSON format: { "title": "your concise title here" }
        ### Content:
        <content>
        \(content)
        </content>
        """

        let body: [String: Any] = [
            "model": modelId,
            "stream": false,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        let json = try await network.requestJSON(
            path: "/api/chat/completions",
            method: .post,
            body: body
        )

        // Parse the AI response
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let responseText = message["content"] as? String
        else { return nil }

        // Extract title from JSON response
        if let jsonStart = responseText.range(of: "{"),
           let jsonEnd = responseText.range(of: "}", options: .backwards) {
            let jsonStr = String(responseText[jsonStart.lowerBound...jsonEnd.lowerBound])
            if let data = jsonStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = parsed["title"] as? String {
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    /// Enhances note content using AI chat completions.
    ///
    /// Matches the Flutter `ApiService.enhanceNoteContent()` which sends content
    /// to `/api/chat/completions` with a system prompt for enhancement.
    func enhanceNoteContent(content: String, modelId: String) async throws -> String? {
        let systemPrompt = """
        Enhance existing notes using the content's primary language. Your task is to make the notes more useful and comprehensive.

        # Output Format

        Provide the enhanced notes in markdown format. Use markdown syntax for headings, lists, task lists ([ ]) where tasks or checklists are strongly implied, and emphasis to improve clarity and presentation. Ensure that all integrated content is accurately reflected. Return only the markdown formatted note.
        """

        let body: [String: Any] = [
            "model": modelId,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "<notes>\(content)</notes>"]
            ]
        ]

        let json = try await network.requestJSON(
            path: "/api/chat/completions",
            method: .post,
            body: body
        )

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let responseText = message["content"] as? String
        else { return nil }

        return responseText
    }

    // MARK: - Private Helpers

    private func parseModelArray(_ models: [[String: Any]]) -> [AIModel] {
        models.compactMap { raw -> AIModel? in
            guard let id = raw["id"] as? String else { return nil }
            let name = raw["name"] as? String ?? id

            // Parse capabilities from nested info.meta.capabilities
            var isMultimodal = false
            var supportsRAG = false
            var capabilities: [String: String]?
            var profileImageURL: String?
            var toolIds: [String] = []
            var defaultFeatureIds: [String] = []

            if let info = raw["info"] as? [String: Any] {
                if let meta = info["meta"] as? [String: Any] {
                    profileImageURL = meta["profile_image_url"] as? String
                    if let caps = meta["capabilities"] as? [String: Any] {
                        isMultimodal = caps["vision"] as? Bool ?? false
                        supportsRAG = caps["citations"] as? Bool ?? false
                        capabilities = caps.compactMapValues { "\($0)" }
                    }
                    if let tools = meta["toolIds"] as? [String] {
                        toolIds = tools
                    }
                    if let defaultFeatures = meta["defaultFeatureIds"] as? [String] {
                        defaultFeatureIds = defaultFeatures
                    }
                }
            }

            return AIModel(
                id: id,
                name: name,
                description: raw["description"] as? String,
                isMultimodal: isMultimodal,
                supportsStreaming: true,
                supportsRAG: supportsRAG,
                contextLength: raw["context_length"] as? Int,
                capabilities: capabilities,
                profileImageURL: profileImageURL,
                toolIds: toolIds,
                defaultFeatureIds: defaultFeatureIds
            )
        }
    }

    private func parseConversationSummary(_ json: [String: Any]) -> Conversation? {
        guard let id = json["id"] as? String else { return nil }
        let title = json["title"] as? String ?? "New Chat"

        var createdAt = Date()
        var updatedAt = Date()
        if let ts = json["created_at"] as? Double { createdAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["created_at"] as? Int { createdAt = Date(timeIntervalSince1970: Double(ts)) }
        if let ts = json["updated_at"] as? Double { updatedAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["updated_at"] as? Int { updatedAt = Date(timeIntervalSince1970: Double(ts)) }

        let pinned = json["pinned"] as? Bool ?? false
        let archived = json["archived"] as? Bool ?? false
        let folderId = json["folder_id"] as? String
        let tags = json["tags"] as? [String] ?? []

        // Extract model from chat data
        var model: String?
        if let chat = json["chat"] as? [String: Any],
           let models = chat["models"] as? [String],
           let first = models.first {
            model = first
        }

        return Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            pinned: pinned,
            archived: archived,
            folderId: folderId,
            tags: tags
        )
    }

    private func parseFullConversation(_ json: [String: Any]) -> Conversation {
        let id = json["id"] as? String ?? UUID().uuidString
        let title = (json["chat"] as? [String: Any])?["title"] as? String
            ?? json["title"] as? String
            ?? "New Chat"

        var createdAt = Date()
        var updatedAt = Date()
        if let ts = json["created_at"] as? Double { createdAt = Date(timeIntervalSince1970: ts) }
        if let ts = json["updated_at"] as? Double { updatedAt = Date(timeIntervalSince1970: ts) }

        let pinned = json["pinned"] as? Bool ?? false
        let archived = json["archived"] as? Bool ?? false
        let folderId = json["folder_id"] as? String
        let shareId = json["share_id"] as? String
        let tags = json["tags"] as? [String] ?? []

        var model: String?
        var systemPrompt: String?
        var messages: [ChatMessage] = []

        if let chat = json["chat"] as? [String: Any] {
            if let models = chat["models"] as? [String], let first = models.first {
                model = first
            }
            systemPrompt = chat["system"] as? String

            // Parse messages from history using parent chain
            messages = parseMessages(from: chat)
        }

        return Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            pinned: pinned,
            archived: archived,
            shareId: shareId,
            folderId: folderId,
            tags: tags
        )
    }

    private func parseMessages(from chat: [String: Any]) -> [ChatMessage] {
        guard let history = chat["history"] as? [String: Any],
              let messagesMap = history["messages"] as? [String: [String: Any]],
              let currentId = history["currentId"] as? String
        else {
            // Fallback to flat messages array
            if let msgArray = chat["messages"] as? [[String: Any]] {
                return msgArray.compactMap { parseSingleMessage($0) }
            }
            return []
        }

        // Walk the parent chain from currentId to root
        var ordered: [[String: Any]] = []
        var cursor: String? = currentId
        while let id = cursor, let msg = messagesMap[id] {
            var msgWithId = msg
            msgWithId["id"] = id
            ordered.append(msgWithId)
            cursor = msg["parentId"] as? String
        }
        ordered.reverse()

        // Parse messages and attach sibling versions (OpenWebUI regeneration history)
        return ordered.compactMap { msgData -> ChatMessage? in
            guard var message = parseSingleMessage(msgData) else { return nil }

            // Find sibling versions: other children of the same parent with the same role
            let parentId = msgData["parentId"] as? String
            let msgId = msgData["id"] as? String
            let msgRole = msgData["role"] as? String

            if let parentId, !parentId.isEmpty,
               let parent = messagesMap[parentId],
               let childrenIds = parent["childrenIds"] as? [String],
               childrenIds.count > 1 {

                var versions: [ChatMessageVersion] = []
                for siblingId in childrenIds {
                    guard siblingId != msgId,
                          let sibling = messagesMap[siblingId],
                          (sibling["role"] as? String) == msgRole
                    else { continue }

                    // Parse sibling as a version snapshot
                    if let version = parseSiblingAsVersion(sibling, id: siblingId) {
                        versions.append(version)
                    }
                }

                if !versions.isEmpty {
                    message.versions = versions
                }
            }

            return message
        }
    }

    /// Parses a sibling message from the OpenWebUI history tree as a version snapshot.
    /// Siblings are alternative responses (e.g., from regeneration on the website)
    /// stored as different children of the same parent message.
    private func parseSiblingAsVersion(_ msg: [String: Any], id: String) -> ChatMessageVersion? {
        let content = msg["content"] as? String ?? ""
        var timestamp = Date()
        if let ts = msg["timestamp"] as? Double {
            timestamp = ts > 1_000_000_000_000
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        }
        let model = msg["model"] as? String

        // Parse error
        var error: ChatMessageError?
        if let errObj = msg["error"] as? [String: Any] {
            error = ChatMessageError(content: errObj["content"] as? String)
        }

        // Parse files
        var files: [ChatMessageFile] = []
        if let rawFiles = msg["files"] as? [[String: Any]] {
            for file in rawFiles {
                let fileType = file["type"] as? String
                let fileUrl = file["url"] as? String ?? file["id"] as? String
                let fileName = file["name"] as? String
                let contentType = file["content_type"] as? String
                    ?? (file["meta"] as? [String: Any])?["content_type"] as? String
                files.append(ChatMessageFile(
                    type: fileType, url: fileUrl, name: fileName, contentType: contentType
                ))
            }
        }

        // Parse sources
        var sources: [ChatSourceReference] = []
        if let rawSources = msg["sources"] as? [[String: Any]] {
            // Use simplified source parsing for versions
            for src in rawSources {
                let srcUrl = (src["url"] as? String) ?? (src["source"] as? String)
                let srcTitle = (src["name"] as? String) ?? (src["title"] as? String)
                let srcId = src["id"] as? String
                sources.append(ChatSourceReference(
                    id: srcId, title: srcTitle, url: srcUrl
                ))
            }
        }

        // Parse follow-ups
        let followUps = msg["followUps"] as? [String]
            ?? msg["follow_ups"] as? [String] ?? []

        return ChatMessageVersion(
            id: id,
            content: content,
            timestamp: timestamp,
            model: model,
            error: error,
            files: files,
            sources: sources,
            followUps: followUps
        )
    }

    private func parseSingleMessage(_ msg: [String: Any]) -> ChatMessage? {
        guard let id = msg["id"] as? String,
              let roleStr = msg["role"] as? String,
              let role = MessageRole(rawValue: roleStr)
        else { return nil }

        let content = msg["content"] as? String ?? ""

        var timestamp = Date()
        if let ts = msg["timestamp"] as? Double {
            // OpenWebUI may send seconds or milliseconds
            timestamp = ts > 1_000_000_000_000
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        }

        let model = msg["model"] as? String ?? msg["modelName"] as? String
        let attachmentIds = msg["attachment_ids"] as? [String] ?? []

        // Parse error
        var error: ChatMessageError?
        if let errObj = msg["error"] as? [String: Any] {
            error = ChatMessageError(content: errObj["content"] as? String)
        }

        // Parse sources from server (OpenWebUI stores them on assistant messages)
        var sources: [ChatSourceReference] = []
        if let rawSources = msg["sources"] as? [[String: Any]] {
            for src in rawSources {
                // Extract nested source/metadata/document like parseOpenWebUISourceList
                var baseSource = (src["source"] as? [String: Any]) ?? [:]
                for key in ["id", "name", "title", "url", "link", "type"] {
                    if let value = src[key], baseSource[key] == nil { baseSource[key] = value }
                }

                let metadataRaw = src["metadata"]
                let metadataList: [[String: Any]]
                if let list = metadataRaw as? [[String: Any]] { metadataList = list }
                else if let single = metadataRaw as? [String: Any] { metadataList = [single] }
                else { metadataList = [] }

                let documents = (src["document"] as? [Any]) ?? []
                let loopCount = max(1, max(documents.count, metadataList.count))

                for i in 0..<loopCount {
                    let meta = i < metadataList.count ? metadataList[i] : [:]
                    let document = i < documents.count ? documents[i] : nil

                    // Resolve URL
                    var url: String?
                    for k in ["source", "url", "link"] {
                        if let v = meta[k] as? String, v.hasPrefix("http") { url = v; break }
                    }
                    if url == nil, let v = baseSource["url"] as? String, v.hasPrefix("http") { url = v }

                    // Resolve title
                    let title: String? = (meta["name"] as? String) ?? (meta["title"] as? String)
                        ?? (baseSource["name"] as? String) ?? (baseSource["title"] as? String)

                    // Snippet from document
                    let snippet: String? = (document as? String)?.trimmingCharacters(in: .whitespaces)

                    // ID
                    let srcId = (meta["source"] as? String) ?? (meta["id"] as? String)
                        ?? (baseSource["id"] as? String)

                    // Avoid duplicates
                    let isDuplicate = sources.contains { ($0.url != nil && $0.url == url) || ($0.id != nil && $0.id == srcId) }
                    if !isDuplicate {
                        var metaDict: [String: String] = [:]
                        for (k, v) in meta { if let s = v as? String { metaDict[k] = s } }

                        sources.append(ChatSourceReference(
                            id: srcId, title: title, url: url,
                            snippet: (snippet?.isEmpty ?? true) ? nil : snippet,
                            type: (baseSource["type"] as? String) ?? (meta["type"] as? String),
                            metadata: metaDict.isEmpty ? nil : metaDict
                        ))
                    }
                }
            }
        }

        // Parse follow-ups
        let followUps = msg["followUps"] as? [String]
            ?? msg["follow_ups"] as? [String] ?? []

        // Parse files (images from tools, uploaded files, etc.)
        var files: [ChatMessageFile] = []
        if let rawFiles = msg["files"] as? [[String: Any]] {
            for file in rawFiles {
                let fileType = file["type"] as? String
                let fileUrl = file["url"] as? String ?? file["id"] as? String
                let fileName = file["name"] as? String
                let contentType = file["content_type"] as? String
                    ?? (file["meta"] as? [String: Any])?["content_type"] as? String
                files.append(ChatMessageFile(
                    type: fileType, url: fileUrl, name: fileName, contentType: contentType
                ))
            }
        }

        return ChatMessage(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            model: model,
            attachmentIds: attachmentIds,
            files: files,
            sources: sources,
            followUps: followUps,
            error: error
        )
    }

    private func buildChatPayload(
        title: String,
        messages: [ChatMessage],
        model: String?,
        systemPrompt: String?
    ) -> [String: Any] {
        var messagesMap: [String: Any] = [:]
        var messagesArray: [[String: Any]] = []
        var previousId: String?
        var lastUserId: String?
        var currentId: String?

        for msg in messages {
            let parentId: String?
            if msg.role == .assistant {
                parentId = lastUserId ?? previousId
            } else {
                parentId = previousId
            }

            var msgDict: [String: Any] = [
                "id": msg.id,
                "parentId": (parentId as Any?) ?? NSNull(),
                "childrenIds": [String](),
                "role": msg.role.rawValue,
                "content": msg.content,
                "timestamp": Int(msg.timestamp.timeIntervalSince1970)
            ]

            if msg.role == .assistant {
                if let m = msg.model { msgDict["model"] = m; msgDict["modelName"] = m }
                msgDict["modelIdx"] = 0
                msgDict["done"] = true
            }

            if msg.role == .user, let m = model {
                msgDict["models"] = [m]
            }

            // Include files from the message (preserves type: "image" vs "file")
            if !msg.files.isEmpty {
                let filesArray: [[String: Any]] = msg.files.compactMap { file -> [String: Any]? in
                    guard let url = file.url else { return nil }
                    var dict: [String: Any] = [
                        "type": file.type ?? "file",
                        "id": url,
                        "url": url
                    ]
                    if let name = file.name { dict["name"] = name }
                    if let ct = file.contentType { dict["content_type"] = ct }
                    return dict
                }
                if !filesArray.isEmpty { msgDict["files"] = filesArray }
            } else if !msg.attachmentIds.isEmpty {
                // Fallback to attachmentIds if no files array
                let filesArray: [[String: Any]] = msg.attachmentIds.map { id in
                    ["type": "file", "id": id, "url": id, "name": "file"]
                }
                msgDict["files"] = filesArray
            }

            // Include sources (web search citations, RAG sources, etc.)
            // These must be preserved on sync so they survive reload from server.
            if !msg.sources.isEmpty {
                let sourcesArray: [[String: Any]] = msg.sources.map { source in
                    var dict: [String: Any] = [:]
                    if let id = source.id { dict["id"] = id }
                    if let title = source.title { dict["name"] = title }
                    if let url = source.url { dict["url"] = url; dict["source"] = url }
                    if let snippet = source.snippet { dict["snippet"] = snippet }
                    if let type = source.type { dict["type"] = type }
                    if let meta = source.metadata {
                        var metaDict: [String: Any] = [:]
                        for (k, v) in meta { metaDict[k] = v }
                        if !metaDict.isEmpty { dict["metadata"] = [metaDict] }
                    }
                    // Include `document` array — the web client's source renderer
                    // iterates over this field and crashes if it's missing.
                    if let snippet = source.snippet, !snippet.isEmpty {
                        dict["document"] = [snippet]
                    } else {
                        dict["document"] = [] as [String]
                    }
                    return dict
                }
                msgDict["sources"] = sourcesArray
            }

            // Include follow-up suggestions
            if !msg.followUps.isEmpty {
                msgDict["followUps"] = msg.followUps
            }

            // Include error information
            if let error = msg.error {
                if let content = error.content {
                    msgDict["error"] = ["content": content]
                } else {
                    msgDict["error"] = ["content": ""]
                }
            }

            messagesMap[msg.id] = msgDict

            // --- Write version siblings into the history tree BEFORE the current message ---
            // OpenWebUI stores regeneration history as sibling messages:
            // multiple children of the same parent with the same role.
            // Each ChatMessageVersion becomes a separate entry in messagesMap
            // with its own ID, sharing the same parentId as the current message.
            //
            // ORDERING: OpenWebUI expects childrenIds to be in chronological order
            // with the **current/active** message as the LAST child. The web UI
            // displays versions as 1/N, 2/N, ..., N/N where N/N is the current.
            // So we add all version siblings first, then the current message last.
            if !msg.versions.isEmpty, let pid = parentId {
                for version in msg.versions {
                    let siblingId = version.id
                    // Skip if this sibling ID already exists (shouldn't happen, but be safe)
                    guard messagesMap[siblingId] == nil else { continue }

                    var siblingDict: [String: Any] = [
                        "id": siblingId,
                        "parentId": pid,
                        "childrenIds": [String](),
                        "role": msg.role.rawValue,
                        "content": version.content,
                        "timestamp": Int(version.timestamp.timeIntervalSince1970),
                        "done": true
                    ]

                    if let m = version.model ?? msg.model {
                        siblingDict["model"] = m
                        siblingDict["modelName"] = m
                    }
                    if msg.role == .assistant {
                        siblingDict["modelIdx"] = 0
                    }

                    // Include version files
                    if !version.files.isEmpty {
                        let filesArr: [[String: Any]] = version.files.compactMap { file -> [String: Any]? in
                            guard let url = file.url else { return nil }
                            var dict: [String: Any] = [
                                "type": file.type ?? "file",
                                "id": url,
                                "url": url
                            ]
                            if let name = file.name { dict["name"] = name }
                            if let ct = file.contentType { dict["content_type"] = ct }
                            return dict
                        }
                        if !filesArr.isEmpty { siblingDict["files"] = filesArr }
                    }

                    // Include version sources
                    if !version.sources.isEmpty {
                        let sourcesArr: [[String: Any]] = version.sources.map { source in
                            var dict: [String: Any] = [:]
                            if let id = source.id { dict["id"] = id }
                            if let title = source.title { dict["name"] = title }
                            if let url = source.url { dict["url"] = url; dict["source"] = url }
                            if let snippet = source.snippet { dict["snippet"] = snippet }
                            if let type = source.type { dict["type"] = type }
                            if let meta = source.metadata {
                                var metaDict: [String: Any] = [:]
                                for (k, v) in meta { metaDict[k] = v }
                                if !metaDict.isEmpty { dict["metadata"] = [metaDict] }
                            }
                            return dict
                        }
                        siblingDict["sources"] = sourcesArr
                    }

                    // Include version follow-ups
                    if !version.followUps.isEmpty {
                        siblingDict["followUps"] = version.followUps
                    }

                    // Include version error
                    if let error = version.error, let content = error.content {
                        siblingDict["error"] = ["content": content]
                    }

                    messagesMap[siblingId] = siblingDict

                    // Add sibling to parent's childrenIds (before the current message)
                    if var parent = messagesMap[pid] as? [String: Any] {
                        var children = parent["childrenIds"] as? [String] ?? []
                        if !children.contains(siblingId) {
                            children.append(siblingId)
                            parent["childrenIds"] = children
                            messagesMap[pid] = parent
                        }
                    }
                }
            }

            // Add the current (active) message to parent's childrenIds LAST
            // so it appears as the latest version (N/N) on the server/web UI.
            if let pid = parentId, var parent = messagesMap[pid] as? [String: Any] {
                var children = parent["childrenIds"] as? [String] ?? []
                children.append(msg.id)
                parent["childrenIds"] = children
                messagesMap[pid] = parent
            }

            messagesArray.append(msgDict)
            previousId = msg.id
            currentId = msg.id
            if msg.role == .user { lastUserId = msg.id }
        }

        var chat: [String: Any] = [
            "id": "",
            "title": title,
            "models": model.map { [$0] } ?? [],
            "params": [String: Any](),
            "history": [
                "messages": messagesMap,
                "currentId": (currentId as Any?) ?? NSNull()
            ],
            "messages": messagesArray,
            "tags": [String](),
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]

        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            chat["system"] = systemPrompt
        }

        return chat
    }

    // MARK: - Task Configuration & AI Tasks

    /// Fetches the server-side task configuration.
    ///
    /// Returns admin-configured settings for title generation, follow-ups,
    /// tags, autocomplete, and other background tasks. The app should respect
    /// these settings and not request disabled tasks.
    func getTaskConfig() async throws -> TaskConfig {
        let json = try await network.requestJSON(path: "/api/v1/tasks/config")
        return TaskConfig(from: json)
    }

    /// Checks which chat IDs have active (in-progress) tasks on the server.
    ///
    /// Calls `POST /api/v1/tasks/active/chats` with an array of chat IDs
    /// and returns the subset that currently have streaming/generation active.
    /// Useful for showing streaming indicators in the sidebar and detecting
    /// in-progress generations when opening a conversation.
    func checkActiveChats(chatIds: [String]) async throws -> Set<String> {
        guard !chatIds.isEmpty else { return [] }
        let json = try await network.requestJSON(
            path: "/api/v1/tasks/active/chats",
            method: .post,
            body: ["chat_ids": chatIds]
        )
        // Response format: { "chat_ids": ["id1", "id2"] } or direct array
        if let activeIds = json["chat_ids"] as? [String] {
            return Set(activeIds)
        }
        // Fallback: try parsing keys of a dict where truthy values mean active
        var active = Set<String>()
        for (key, value) in json {
            if let isActive = value as? Bool, isActive {
                active.insert(key)
            }
        }
        return active
    }

    /// Generates an autocomplete suggestion for the user's current input.
    ///
    /// Calls `POST /api/v1/tasks/auto/completions` with the model, recent
    /// messages context, and the current partial input. Returns the suggested
    /// completion text, or nil if the server couldn't generate one.
    func generateAutocompletion(
        model: String,
        messages: [[String: Any]],
        prompt: String
    ) async throws -> String? {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "prompt": prompt,
            "stream": false
        ]

        let json = try await network.requestJSON(
            path: "/api/v1/tasks/auto/completions",
            method: .post,
            body: body,
            timeout: 10 // Short timeout — autocomplete should be snappy
        )

        // Extract the completion text from the response
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: direct content field
        if let content = json["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    /// Generates a contextually relevant emoji for a message.
    ///
    /// Calls `POST /api/v1/tasks/emoji/completions`. Returns a single emoji
    /// string, or nil if generation failed.
    func generateEmoji(model: String, prompt: String) async throws -> String? {
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]

        let json = try await network.requestJSON(
            path: "/api/v1/tasks/emoji/completions",
            method: .post,
            body: body,
            timeout: 10
        )

        // Extract emoji from response
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let content = json["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    /// Fetches archived conversations (paginated, with optional search/sort).
    func getArchivedChats(
        page: Int = 1,
        query: String? = nil,
        orderBy: String? = nil,
        direction: String? = nil
    ) async throws -> [Conversation] {
        var queryItems = [URLQueryItem(name: "page", value: "\(page)")]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        if let orderBy {
            queryItems.append(URLQueryItem(name: "order_by", value: orderBy))
        }
        if let direction {
            queryItems.append(URLQueryItem(name: "direction", value: direction))
        }
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/archived",
            queryItems: queryItems
        )
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { parseConversationSummary($0) }.map { conv in
            var archived = conv
            archived.archived = true
            return archived
        }
    }

    // MARK: - Admin APIs (requires admin role)

    /// Fetches a paginated list of all users. Admin only.
    /// - Parameters:
    ///   - page: Page number (1-indexed).
    ///   - query: Optional search query to filter by name/email.
    ///   - orderBy: Field to sort by (e.g. "created_at", "name").
    ///   - direction: Sort direction ("asc" or "desc").
    func getAdminUsers(
        page: Int = 1,
        query: String? = nil,
        orderBy: String? = nil,
        direction: String? = nil
    ) async throws -> [AdminUser] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(page)")
        ]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        if let orderBy {
            queryItems.append(URLQueryItem(name: "order_by", value: orderBy))
        }
        if let direction {
            queryItems.append(URLQueryItem(name: "direction", value: direction))
        }

        let capturedQueryItems = queryItems
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/users/",
            queryItems: capturedQueryItems
        )

        let decoder = JSONDecoder()

        // Response is { "users": [...], "total": int }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usersArray = json["users"] {
            let usersData = try JSONSerialization.data(withJSONObject: usersArray)
            if let users = try? decoder.decode([AdminUser].self, from: usersData) {
                return users
            }
        }

        // Fallback: try { "data": [...] } wrapper
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usersArray = json["data"] {
            let usersData = try JSONSerialization.data(withJSONObject: usersArray)
            if let users = try? decoder.decode([AdminUser].self, from: usersData) {
                return users
            }
        }

        // Fallback: try parsing as direct array
        if let users = try? decoder.decode([AdminUser].self, from: data) {
            return users
        }

        // Debug: log what we actually got
        if let rawString = String(data: data, encoding: .utf8) {
            logger.error("Failed to decode admin users. Raw response (first 500 chars): \(String(rawString.prefix(500)))")
        }
        return []
    }

    /// Fetches a single user by ID. Admin only.
    func getAdminUserById(_ userId: String) async throws -> AdminUser {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/users/\(userId)"
        )
        return try JSONDecoder().decode(AdminUser.self, from: data)
    }

    /// Updates a user's role, name, email, and optionally password. Admin only.
    func updateAdminUser(userId: String, form: AdminUserUpdateForm) async throws -> AdminUser {
        // Encode form to dictionary for requestRaw
        let formData = try JSONEncoder().encode(form)
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/users/\(userId)/update",
            method: .post,
            body: formData
        )
        return try JSONDecoder().decode(AdminUser.self, from: data)
    }

    /// Deletes a user by ID. Admin only.
    func deleteAdminUser(userId: String) async throws {
        try await network.requestVoid(
            path: "/api/v1/users/\(userId)",
            method: .delete
        )
    }

    /// Fetches the full conversation detail for a chat. Admin only.
    /// Bypasses the standard `requestRaw` validation to avoid mapping
    /// 401 → tokenExpired (which would trigger a logout). Instead, we
    /// handle the HTTP status manually and provide admin-specific errors.
    func getAdminChatById(chatId: String) async throws -> Conversation {
        let request = try network.buildRequest(
            path: "/api/v1/chats/share/\(chatId)",
            method: .get,
            authenticated: true
        )
        let (data, response) = try await network.session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            if statusCode == 401 || statusCode == 403 {
                throw APIError.httpError(
                    statusCode: statusCode,
                    message: "Unable to access this chat. Ensure admin chat access is enabled on your server (Settings → Admin → Enable Admin Chat Access).",
                    data: data
                )
            }
            if !(200..<400).contains(statusCode) {
                var message: String?
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    message = json["detail"] as? String ?? json["error"] as? String
                }
                throw APIError.httpError(
                    statusCode: statusCode,
                    message: message ?? "Failed to load chat (HTTP \(statusCode)).",
                    data: data
                )
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.httpError(
                statusCode: 500,
                message: "Unable to parse chat data.",
                data: data
            )
        }

        return parseFullConversation(json)
    }

    /// Deletes a chat by ID. Admin only — bypasses tokenExpired mapping.
    func deleteAdminChat(chatId: String) async throws {
        let request = try network.buildRequest(
            path: "/api/v1/chats/\(chatId)",
            method: .delete,
            authenticated: true
        )
        let (data, response) = try await network.session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            let statusCode = httpResponse.statusCode
            var message: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = json["detail"] as? String ?? json["error"] as? String
            }
            throw APIError.httpError(
                statusCode: statusCode,
                message: message ?? "Failed to delete chat.",
                data: data
            )
        }
    }

    /// Clones a chat by ID. Admin only — uses the shared clone endpoint
    /// (`/api/v1/chats/{id}/clone/shared`) which works for any user's chat.
    func cloneAdminChat(chatId: String) async throws -> Conversation {
        let request = try network.buildRequest(
            path: "/api/v1/chats/\(chatId)/clone/shared",
            method: .post,
            authenticated: true
        )
        let (data, response) = try await network.session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            let statusCode = httpResponse.statusCode
            var message: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = json["detail"] as? String ?? json["error"] as? String
            }
            throw APIError.httpError(
                statusCode: statusCode,
                message: message ?? "Failed to clone chat.",
                data: data
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.httpError(
                statusCode: 500,
                message: "Failed to parse cloned chat.",
                data: data
            )
        }

        return parseFullConversation(json)
    }

    /// Fetches a user's chat list. Admin only.
    /// Response is an array of `ChatTitleIdResponse`: `[{id, title, updated_at, created_at}]`
    func getAdminUserChats(
        userId: String,
        page: Int = 1,
        query: String? = nil,
        orderBy: String? = nil,
        direction: String? = nil
    ) async throws -> [AdminChatItem] {
        var queryItems: [URLQueryItem] = []
        queryItems.append(URLQueryItem(name: "page", value: "\(page)"))
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        if let orderBy {
            queryItems.append(URLQueryItem(name: "order_by", value: orderBy))
        }
        if let direction {
            queryItems.append(URLQueryItem(name: "direction", value: direction))
        }

        let capturedQueryItems = queryItems
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/list/user/\(userId)",
            queryItems: capturedQueryItems
        )

        // Parse as array of chat objects manually for resilience
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { json -> AdminChatItem? in
            guard let id = json["id"] as? String,
                  let title = json["title"] as? String else { return nil }
            // Handle both Int and Double timestamps
            let updatedAt: Int
            if let ts = json["updated_at"] as? Int { updatedAt = ts }
            else if let ts = json["updated_at"] as? Double { updatedAt = Int(ts) }
            else { updatedAt = 0 }
            let createdAt: Int
            if let ts = json["created_at"] as? Int { createdAt = ts }
            else if let ts = json["created_at"] as? Double { createdAt = Int(ts) }
            else { createdAt = 0 }
            return AdminChatItem(id: id, title: title, updatedAt: updatedAt, createdAt: createdAt)
        }
    }

    /// Adds a new user. Admin only.
    func addAdminUser(form: AdminAddUserForm) async throws -> AdminUser {
        // Encode the Codable form to a [String: Any] dictionary
        let formData = try JSONEncoder().encode(form)
        guard let formDict = try JSONSerialization.jsonObject(with: formData) as? [String: Any] else {
            throw APIError.unknown(underlying: NSError(domain: "APIError", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode add user form"]))
        }

        // The response wraps the user in a different shape; we decode flexibly.
        let response = try await network.requestJSON(
            path: "/api/v1/auths/add",
            method: .post,
            body: formDict
        )

        // The add endpoint returns a sign-in response with user info embedded
        let jsonData = try JSONSerialization.data(withJSONObject: response)
        return try JSONDecoder().decode(AdminUser.self, from: jsonData)
    }
}
