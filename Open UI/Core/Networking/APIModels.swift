import Foundation

// MARK: - Authentication

/// Response from `/api/v1/auths/signin`.
struct AuthResponse: Codable, Sendable {
    let token: String
    let tokenType: String?
    let id: String?
    let email: String?
    let name: String?
    let role: String?
    let profileImageUrl: String?

    enum CodingKeys: String, CodingKey {
        case token
        case tokenType = "token_type"
        case id, email, name, role
        case profileImageUrl = "profile_image_url"
    }
}

// MARK: - OAuth Providers

/// Represents the available OAuth providers configured on the server.
struct OAuthProviders: Codable, Sendable {
    let google: String?
    let microsoft: String?
    let github: String?
    let oidc: String?
    let feishu: String?

    /// Whether any OAuth provider is enabled.
    var hasAnyProvider: Bool {
        google != nil || microsoft != nil || github != nil
            || oidc != nil || feishu != nil
    }

    /// Returns the list of enabled provider keys.
    var enabledProviders: [String] {
        var providers: [String] = []
        if google != nil { providers.append("google") }
        if microsoft != nil { providers.append("microsoft") }
        if github != nil { providers.append("github") }
        if oidc != nil { providers.append("oidc") }
        if feishu != nil { providers.append("feishu") }
        return providers
    }

    /// Returns the display name for a provider key.
    func displayName(for key: String) -> String {
        switch key {
        case "google": return google ?? "Google"
        case "microsoft": return microsoft ?? "Microsoft"
        case "github": return github ?? "GitHub"
        case "oidc": return oidc ?? "SSO"
        case "feishu": return feishu ?? "Feishu"
        default: return key
        }
    }

    /// Returns the SF Symbol icon name for a provider key.
    static func iconName(for key: String) -> String {
        switch key {
        case "google": return "g.circle.fill"
        case "microsoft": return "rectangle.grid.2x2.fill"
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "oidc": return "lock.shield.fill"
        case "feishu": return "bubble.left.fill"
        default: return "arrow.right.circle.fill"
        }
    }
}

/// Wrapper for the `oauth` field in the backend config response.
struct OAuthConfig: Codable, Sendable {
    let providers: OAuthProviders?
}

// MARK: - Backend Configuration

/// Response from `/api/config` containing server version and features.
///
/// Uses a custom `init(from:)` so that unknown top-level keys
/// (e.g. `user_count`, `code`, `file`, `permissions`, etc.)
/// and nested decoding failures never prevent the config from loading.
struct BackendConfig: Codable, Sendable {
    let status: Bool?
    let version: String?
    let name: String?
    let features: BackendFeatures?
    let defaultModels: [String]?
    let defaultPromptSuggestions: [PromptSuggestion]?
    let audio: AudioConfig?
    let oauth: OAuthConfig?

    struct BackendFeatures: Codable, Sendable {
        let auth: Bool?
        let authTrustedHeader: Bool?
        let enableSignup: Bool?
        let enableSignupPasswordConfirmation: Bool?
        let enableLoginForm: Bool?
        let enableWebSearch: Bool?
        let enableImageGeneration: Bool?
        let enableCommunitySharing: Bool?
        let enableAdminExport: Bool?
        let enableAdminChatAccess: Bool?
        let enableLdap: Bool?
        let enableFolders: Bool?
        let enableNotes: Bool?
        let enableChannels: Bool?
        let enableCodeExecution: Bool?
        let enableCodeInterpreter: Bool?
        let enableWebsocket: Bool?

        // Backward compat aliases
        var authTrustedHeaderAuth: Bool? { authTrustedHeader }
        var enableLogin: Bool? { enableLoginForm }
        var enableAdminChat: Bool? { enableAdminChatAccess }

        enum CodingKeys: String, CodingKey {
            case auth
            case authTrustedHeader = "auth_trusted_header"
            case enableSignup = "enable_signup"
            case enableSignupPasswordConfirmation = "enable_signup_password_confirmation"
            case enableLoginForm = "enable_login_form"
            case enableWebSearch = "enable_web_search"
            case enableImageGeneration = "enable_image_generation"
            case enableCommunitySharing = "enable_community_sharing"
            case enableAdminExport = "enable_admin_export"
            case enableAdminChatAccess = "enable_admin_chat_access"
            case enableLdap = "enable_ldap"
            case enableFolders = "enable_folders"
            case enableNotes = "enable_notes"
            case enableChannels = "enable_channels"
            case enableCodeExecution = "enable_code_execution"
            case enableCodeInterpreter = "enable_code_interpreter"
            case enableWebsocket = "enable_websocket"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            auth = try container.decodeIfPresent(Bool.self, forKey: .auth)
            authTrustedHeader = try container.decodeIfPresent(Bool.self, forKey: .authTrustedHeader)
            enableSignup = try container.decodeIfPresent(Bool.self, forKey: .enableSignup)
            enableSignupPasswordConfirmation = try container.decodeIfPresent(Bool.self, forKey: .enableSignupPasswordConfirmation)
            enableLoginForm = try container.decodeIfPresent(Bool.self, forKey: .enableLoginForm)
            enableWebSearch = try container.decodeIfPresent(Bool.self, forKey: .enableWebSearch)
            enableImageGeneration = try container.decodeIfPresent(Bool.self, forKey: .enableImageGeneration)
            enableCommunitySharing = try container.decodeIfPresent(Bool.self, forKey: .enableCommunitySharing)
            enableAdminExport = try container.decodeIfPresent(Bool.self, forKey: .enableAdminExport)
            enableAdminChatAccess = try container.decodeIfPresent(Bool.self, forKey: .enableAdminChatAccess)
            enableLdap = try container.decodeIfPresent(Bool.self, forKey: .enableLdap)
            enableFolders = try container.decodeIfPresent(Bool.self, forKey: .enableFolders)
            enableNotes = try container.decodeIfPresent(Bool.self, forKey: .enableNotes)
            enableChannels = try container.decodeIfPresent(Bool.self, forKey: .enableChannels)
            enableCodeExecution = try container.decodeIfPresent(Bool.self, forKey: .enableCodeExecution)
            enableCodeInterpreter = try container.decodeIfPresent(Bool.self, forKey: .enableCodeInterpreter)
            enableWebsocket = try container.decodeIfPresent(Bool.self, forKey: .enableWebsocket)
        }
    }

    struct PromptSuggestion: Codable, Sendable {
        let title: [String]?
        let content: String?
    }

    struct AudioConfig: Codable, Sendable {
        let tts: TTSConfig?
        let stt: STTConfig?

        struct TTSConfig: Codable, Sendable {
            let engine: String?
            let voice: String?
            let splitOn: String?

            enum CodingKeys: String, CodingKey {
                case engine, voice
                case splitOn = "split_on"
            }
        }

        struct STTConfig: Codable, Sendable {
            let engine: String?
        }
    }

    enum CodingKeys: String, CodingKey {
        case status, version, name, features, audio, oauth
        case defaultModels = "default_models"
        case defaultPromptSuggestions = "default_prompt_suggestions"
    }

    /// Custom decoder that gracefully handles missing/malformed nested objects.
    /// If `features`, `audio`, `oauth`, or `defaultPromptSuggestions` fail to
    /// decode (e.g. due to unexpected field types from newer server versions),
    /// they are set to nil instead of failing the entire config.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(Bool.self, forKey: .status)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        features = try? container.decodeIfPresent(BackendFeatures.self, forKey: .features)
        defaultModels = try? container.decodeIfPresent([String].self, forKey: .defaultModels)
        defaultPromptSuggestions = try? container.decodeIfPresent([PromptSuggestion].self, forKey: .defaultPromptSuggestions)
        audio = try? container.decodeIfPresent(AudioConfig.self, forKey: .audio)
        oauth = try? container.decodeIfPresent(OAuthConfig.self, forKey: .oauth)
    }

    /// Whether this response looks like a valid OpenWebUI server.
    var isValidOpenWebUI: Bool {
        status == true
            && version != nil
            && !(version?.isEmpty ?? true)
            && features != nil
    }

    /// OAuth providers configured on the server.
    var oauthProviders: OAuthProviders? {
        oauth?.providers
    }

    /// Whether any OAuth/SSO provider is available.
    var hasSsoEnabled: Bool {
        oauth?.providers?.hasAnyProvider == true
    }

    /// Whether the login form (email/password) is enabled on the server.
    var isLoginFormEnabled: Bool {
        features?.enableLoginForm ?? features?.enableLogin ?? true
    }
}

// MARK: - Chat Completion

/// Request body for `/api/chat/completions`.
struct ChatCompletionRequest: Sendable {
    var model: String
    var messages: [[String: Any]]
    var stream: Bool = true
    var chatId: String?
    var sessionId: String?
    var messageId: String?
    var parentId: String?
    /// When `true`, this request targets a pipe/function model.
    /// Pipe models must NOT send `session_id`, `chat_id`, or `id` — their
    /// presence together triggers the Redis async-task queue (~60s delay).
    /// Pipe model responses are streamed directly from the HTTP response body.
    var isPipeModel: Bool = false
    var skillIds: [String]?
    var toolIds: [String]?
    var filterIds: [String]?
    var features: ChatFeatures?
    var files: [[String: Any]]?
    var streamOptions: [String: Any]?
    var backgroundTasks: [String: Any]?
    /// The terminal server ID to enable Open Terminal tools for this request.
    /// When set, the backend injects terminal tools (execute_command, file management, etc.)
    /// into the model's tool-calling pipeline.
    var terminalId: String?
    /// OpenWebUI server-side parameters sent alongside the request.
    /// The server's `apply_params_to_form_data()` consumes these before forwarding
    /// to the LLM. Key use: `function_calling` — controls native vs default tool mode.
    /// Example: `["function_calling": "native"]` enables native tool calling.
    var params: [String: Any]?
    /// Template variables (e.g. `{{USER_NAME}}`) resolved before the request is
    /// forwarded to the LLM. Always sent as an object (empty `{}` when no vars),
    /// matching web-client behaviour. Required for pipe model compatibility.
    var variables: [String: Any]?
    /// Full model JSON from the server. Sent as `model_item` so the backend can
    /// route the request to the correct pipe function. Required for pipe models;
    /// should be sent for ALL models so the backend has full routing context.
    var modelItem: [String: Any]?
    /// Tool server configurations. Always sent as an array (empty `[]` when none),
    /// matching web-client behaviour. Required for pipe model compatibility.
    var toolServers: [[String: Any]]?
    /// The user message node sent to the server so it can correctly insert it into
    /// the chat's history tree. Required by updated OpenWebUI servers — without this
    /// the server doesn't link the user message into the history and it disappears
    /// when the chat is re-opened. Matches the web client's `user_message` field.
    var userMessage: [String: Any]?

    struct ChatFeatures: Sendable {
        var webSearch: Bool = false
        var imageGeneration: Bool = false
        var codeInterpreter: Bool = false
        var memory: Bool = false

        /// Whether any feature is enabled. Used to decide whether to include
        /// the `features` object in the request at all.
        var hasAnyEnabled: Bool {
            webSearch || imageGeneration || codeInterpreter || memory
        }
    }

    /// Serialises the request to a JSON dictionary.
    func toJSON() -> [String: Any] {
        var data: [String: Any] = [
            "stream": stream,
            "model": model,
            "messages": messages
        ]

        // Pipe models must NOT send session_id, chat_id, or id together —
        // their combined presence triggers the Redis async-task queue (~60s delay).
        // Pipe responses arrive directly in the HTTP response body as SSE.
        if !isPipeModel {
            if let chatId { data["chat_id"] = chatId }
            if let sessionId { data["session_id"] = sessionId }
            if let messageId { data["id"] = messageId }
        }
        if let parentId { data["parent_id"] = parentId }
        if let skillIds, !skillIds.isEmpty { data["skill_ids"] = skillIds }
        if let toolIds, !toolIds.isEmpty { data["tool_ids"] = toolIds }
        if let filterIds, !filterIds.isEmpty { data["filter_ids"] = filterIds }
        if let files, !files.isEmpty { data["files"] = files }
        if let streamOptions { data["stream_options"] = streamOptions }
        if let terminalId, !terminalId.isEmpty { data["terminal_id"] = terminalId }

        // --- Pipe model compatibility fields ---
        // These MUST always be sent as their empty equivalents when absent so
        // the OpenWebUI pipe function receives a consistent request shape.
        // Omitting them causes the backend to route through the Redis async-task
        // queue (requires session_id + chat_id + id all present) which hangs ~60s.

        // params: always send (empty {} when nil/empty)
        data["params"] = params ?? [String: Any]()

        // background_tasks: always send (empty {} when nil/empty)
        data["background_tasks"] = backgroundTasks ?? [String: Any]()

        // tool_servers: always send (empty [] when nil/empty)
        data["tool_servers"] = toolServers ?? [[String: Any]]()

        // variables: always send (empty {} when nil/empty)
        // Also nest inside `metadata.variables` — this is where the server's
        // apply_system_prompt_to_body() reads them (metadata.get('variables', {})).
        // The top-level `variables` key is kept for pipe model compatibility.
        let resolvedVars = variables ?? [String: Any]()
        data["variables"] = resolvedVars
        data["metadata"] = ["variables": resolvedVars]

        // model_item: send when available (critical for pipe routing)
        if let modelItem { data["model_item"] = modelItem }

        // user_message: required by updated OpenWebUI servers to correctly insert
        // the user message node into the chat's history tree. Without this field
        // the server doesn't link the user message and it disappears on re-open.
        if let userMessage { data["user_message"] = userMessage }

        // Always send all feature keys with explicit true/false values,
        // matching the web client behavior. If we only send `true` keys
        // (or omit `features` entirely when all are off), the server falls
        // back to the model's `defaultFeatureIds` and enables features the
        // user explicitly toggled OFF.
        var feat: [String: Any] = [:]
        let f = features ?? ChatFeatures()
        feat["web_search"] = f.webSearch
        feat["image_generation"] = f.imageGeneration
        feat["code_interpreter"] = f.codeInterpreter
        // Always send memory explicitly (true/false) so the server never
        // falls back to model defaults. Matches web client behavior where
        // memory is sent based purely on the user's account setting.
        feat["memory"] = f.memory
        data["features"] = feat

        return data
    }
}

// MARK: - File Info

/// Metadata about an uploaded file.
struct FileInfoResponse: Codable, Sendable {
    let id: String
    let filename: String?
    let contentType: String?
    let size: Int?
    let createdAt: Double?
    let updatedAt: Double?
    let hash: String?
    let path: String?

    enum CodingKeys: String, CodingKey {
        case id, filename, size, hash, path
        case contentType = "content_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Folder

/// A folder for organising conversations.
struct FolderResponse: Codable, Sendable {
    let id: String
    let name: String
    let parentId: String?
    let userId: String?
    let createdAt: Double?
    let updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentId = "parent_id"
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Task Configuration

/// Server-side task configuration from `GET /api/v1/tasks/config`.
///
/// Controls which AI-powered background tasks are enabled globally
/// by the admin. The app should respect these settings and not request
/// disabled tasks in `background_tasks`.
struct TaskConfig: Sendable {
    let taskModel: String?
    let taskModelExternal: String?
    let enableTitleGeneration: Bool
    let enableFollowUpGeneration: Bool
    let enableTagsGeneration: Bool
    let enableAutocompleteGeneration: Bool
    let autocompleteMaxInputLength: Int
    let enableSearchQueryGeneration: Bool
    let enableRetrievalQueryGeneration: Bool
    let titleGenerationPromptTemplate: String?
    let followUpGenerationPromptTemplate: String?
    let tagsGenerationPromptTemplate: String?
    let voiceModePromptTemplate: String?

    /// Creates a TaskConfig from a raw JSON dictionary (flexible parsing).
    init(from json: [String: Any]) {
        taskModel = json["TASK_MODEL"] as? String
        taskModelExternal = json["TASK_MODEL_EXTERNAL"] as? String
        enableTitleGeneration = json["ENABLE_TITLE_GENERATION"] as? Bool ?? true
        enableFollowUpGeneration = json["ENABLE_FOLLOW_UP_GENERATION"] as? Bool ?? true
        enableTagsGeneration = json["ENABLE_TAGS_GENERATION"] as? Bool ?? true
        enableAutocompleteGeneration = json["ENABLE_AUTOCOMPLETE_GENERATION"] as? Bool ?? false
        autocompleteMaxInputLength = json["AUTOCOMPLETE_GENERATION_INPUT_MAX_LENGTH"] as? Int ?? 256
        enableSearchQueryGeneration = json["ENABLE_SEARCH_QUERY_GENERATION"] as? Bool ?? true
        enableRetrievalQueryGeneration = json["ENABLE_RETRIEVAL_QUERY_GENERATION"] as? Bool ?? true
        titleGenerationPromptTemplate = json["TITLE_GENERATION_PROMPT_TEMPLATE"] as? String
        followUpGenerationPromptTemplate = json["FOLLOW_UP_GENERATION_PROMPT_TEMPLATE"] as? String
        tagsGenerationPromptTemplate = json["TAGS_GENERATION_PROMPT_TEMPLATE"] as? String
        voiceModePromptTemplate = json["VOICE_MODE_PROMPT_TEMPLATE"] as? String
    }

    /// Default config when the server endpoint is unavailable.
    static let `default` = TaskConfig(from: [:])
}

// MARK: - Admin Task Config (Interface Tab)

/// Mutable Codable struct for the admin "Interface" tab.
/// GET `/api/v1/tasks/config`  •  POST `/api/v1/tasks/config/update`
/// Keys are SCREAMING_SNAKE_CASE to match the server JSON.
struct AdminTaskConfig: Codable, Sendable {
    var taskModel: String
    var taskModelExternal: String
    var enableTitleGeneration: Bool
    var enableFollowUpGeneration: Bool
    var enableTagsGeneration: Bool
    var enableAutocompleteGeneration: Bool
    var autocompleteGenerationInputMaxLength: Int
    var enableSearchQueryGeneration: Bool
    var enableRetrievalQueryGeneration: Bool
    var titleGenerationPromptTemplate: String
    var followUpGenerationPromptTemplate: String
    var tagsGenerationPromptTemplate: String
    var queryGenerationPromptTemplate: String
    var imagePromptGenerationPromptTemplate: String
    var toolsFunctionCallingPromptTemplate: String
    var voiceModePromptTemplate: String

    enum CodingKeys: String, CodingKey {
        case taskModel = "TASK_MODEL"
        case taskModelExternal = "TASK_MODEL_EXTERNAL"
        case enableTitleGeneration = "ENABLE_TITLE_GENERATION"
        case enableFollowUpGeneration = "ENABLE_FOLLOW_UP_GENERATION"
        case enableTagsGeneration = "ENABLE_TAGS_GENERATION"
        case enableAutocompleteGeneration = "ENABLE_AUTOCOMPLETE_GENERATION"
        case autocompleteGenerationInputMaxLength = "AUTOCOMPLETE_GENERATION_INPUT_MAX_LENGTH"
        case enableSearchQueryGeneration = "ENABLE_SEARCH_QUERY_GENERATION"
        case enableRetrievalQueryGeneration = "ENABLE_RETRIEVAL_QUERY_GENERATION"
        case titleGenerationPromptTemplate = "TITLE_GENERATION_PROMPT_TEMPLATE"
        case followUpGenerationPromptTemplate = "FOLLOW_UP_GENERATION_PROMPT_TEMPLATE"
        case tagsGenerationPromptTemplate = "TAGS_GENERATION_PROMPT_TEMPLATE"
        case queryGenerationPromptTemplate = "QUERY_GENERATION_PROMPT_TEMPLATE"
        case imagePromptGenerationPromptTemplate = "IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE"
        case toolsFunctionCallingPromptTemplate = "TOOLS_FUNCTION_CALLING_PROMPT_TEMPLATE"
        case voiceModePromptTemplate = "VOICE_MODE_PROMPT_TEMPLATE"
    }

    init() {
        taskModel = ""
        taskModelExternal = ""
        enableTitleGeneration = true
        enableFollowUpGeneration = true
        enableTagsGeneration = true
        enableAutocompleteGeneration = false
        autocompleteGenerationInputMaxLength = 256
        enableSearchQueryGeneration = true
        enableRetrievalQueryGeneration = true
        titleGenerationPromptTemplate = ""
        followUpGenerationPromptTemplate = ""
        tagsGenerationPromptTemplate = ""
        queryGenerationPromptTemplate = ""
        imagePromptGenerationPromptTemplate = ""
        toolsFunctionCallingPromptTemplate = ""
        voiceModePromptTemplate = ""
    }
}

// MARK: - Admin General Settings Models

/// Full auth/general config — GET/POST `/api/v1/auths/admin/config`.
struct AdminAuthConfig: Codable, Sendable {
    var showAdminDetails: Bool
    var adminEmail: String
    var webuiURL: String
    var enableSignup: Bool
    var enableAPIKeys: Bool
    var enableAPIKeysEndpointRestrictions: Bool
    var apiKeysAllowedEndpoints: String
    var defaultUserRole: String
    var defaultGroupID: String
    var jwtExpiresIn: String
    var enableCommunitySharing: Bool
    var enableMessageRating: Bool
    var enableFolders: Bool
    var folderMaxFileCount: String
    var enableChannels: Bool
    var enableMemories: Bool
    var enableNotes: Bool
    var enableUserWebhooks: Bool
    var enableUserStatus: Bool
    var pendingUserOverlayTitle: String
    var pendingUserOverlayContent: String
    var responseWatermark: String

    enum CodingKeys: String, CodingKey {
        case showAdminDetails              = "SHOW_ADMIN_DETAILS"
        case adminEmail                    = "ADMIN_EMAIL"
        case webuiURL                      = "WEBUI_URL"
        case enableSignup                  = "ENABLE_SIGNUP"
        case enableAPIKeys                 = "ENABLE_API_KEYS"
        case enableAPIKeysEndpointRestrictions = "ENABLE_API_KEYS_ENDPOINT_RESTRICTIONS"
        case apiKeysAllowedEndpoints       = "API_KEYS_ALLOWED_ENDPOINTS"
        case defaultUserRole               = "DEFAULT_USER_ROLE"
        case defaultGroupID                = "DEFAULT_GROUP_ID"
        case jwtExpiresIn                  = "JWT_EXPIRES_IN"
        case enableCommunitySharing        = "ENABLE_COMMUNITY_SHARING"
        case enableMessageRating           = "ENABLE_MESSAGE_RATING"
        case enableFolders                 = "ENABLE_FOLDERS"
        case folderMaxFileCount            = "FOLDER_MAX_FILE_COUNT"
        case enableChannels                = "ENABLE_CHANNELS"
        case enableMemories                = "ENABLE_MEMORIES"
        case enableNotes                   = "ENABLE_NOTES"
        case enableUserWebhooks            = "ENABLE_USER_WEBHOOKS"
        case enableUserStatus              = "ENABLE_USER_STATUS"
        case pendingUserOverlayTitle       = "PENDING_USER_OVERLAY_TITLE"
        case pendingUserOverlayContent     = "PENDING_USER_OVERLAY_CONTENT"
        case responseWatermark             = "RESPONSE_WATERMARK"
    }

    /// Failable decoder — treats missing keys as their zero/false defaults so
    /// older server versions don't crash the decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showAdminDetails              = (try? c.decode(Bool.self,   forKey: .showAdminDetails))              ?? true
        adminEmail                    = (try? c.decode(String.self, forKey: .adminEmail))                    ?? ""
        webuiURL                      = (try? c.decode(String.self, forKey: .webuiURL))                      ?? ""
        enableSignup                  = (try? c.decode(Bool.self,   forKey: .enableSignup))                  ?? false
        enableAPIKeys                 = (try? c.decode(Bool.self,   forKey: .enableAPIKeys))                 ?? false
        enableAPIKeysEndpointRestrictions = (try? c.decode(Bool.self, forKey: .enableAPIKeysEndpointRestrictions)) ?? false
        apiKeysAllowedEndpoints       = (try? c.decode(String.self, forKey: .apiKeysAllowedEndpoints))       ?? ""
        defaultUserRole               = (try? c.decode(String.self, forKey: .defaultUserRole))               ?? "pending"
        defaultGroupID                = (try? c.decode(String.self, forKey: .defaultGroupID))                ?? ""
        jwtExpiresIn                  = (try? c.decode(String.self, forKey: .jwtExpiresIn))                  ?? "-1"
        enableCommunitySharing        = (try? c.decode(Bool.self,   forKey: .enableCommunitySharing))        ?? false
        enableMessageRating           = (try? c.decode(Bool.self,   forKey: .enableMessageRating))           ?? false
        enableFolders                 = (try? c.decode(Bool.self,   forKey: .enableFolders))                 ?? true
        folderMaxFileCount            = (try? c.decode(String.self, forKey: .folderMaxFileCount))            ?? ""
        enableChannels                = (try? c.decode(Bool.self,   forKey: .enableChannels))                ?? true
        enableMemories                = (try? c.decode(Bool.self,   forKey: .enableMemories))                ?? true
        enableNotes                   = (try? c.decode(Bool.self,   forKey: .enableNotes))                   ?? true
        enableUserWebhooks            = (try? c.decode(Bool.self,   forKey: .enableUserWebhooks))            ?? true
        enableUserStatus              = (try? c.decode(Bool.self,   forKey: .enableUserStatus))              ?? true
        pendingUserOverlayTitle       = (try? c.decode(String.self, forKey: .pendingUserOverlayTitle))       ?? ""
        pendingUserOverlayContent     = (try? c.decode(String.self, forKey: .pendingUserOverlayContent))     ?? ""
        responseWatermark             = (try? c.decode(String.self, forKey: .responseWatermark))             ?? ""
    }

    init(
        showAdminDetails: Bool = true, adminEmail: String = "", webuiURL: String = "",
        enableSignup: Bool = false, enableAPIKeys: Bool = false, enableAPIKeysEndpointRestrictions: Bool = false,
        apiKeysAllowedEndpoints: String = "", defaultUserRole: String = "pending", defaultGroupID: String = "",
        jwtExpiresIn: String = "-1", enableCommunitySharing: Bool = false, enableMessageRating: Bool = false,
        enableFolders: Bool = true, folderMaxFileCount: String = "", enableChannels: Bool = true,
        enableMemories: Bool = true, enableNotes: Bool = true, enableUserWebhooks: Bool = true,
        enableUserStatus: Bool = true, pendingUserOverlayTitle: String = "", pendingUserOverlayContent: String = "",
        responseWatermark: String = ""
    ) {
        self.showAdminDetails = showAdminDetails; self.adminEmail = adminEmail; self.webuiURL = webuiURL
        self.enableSignup = enableSignup; self.enableAPIKeys = enableAPIKeys
        self.enableAPIKeysEndpointRestrictions = enableAPIKeysEndpointRestrictions
        self.apiKeysAllowedEndpoints = apiKeysAllowedEndpoints; self.defaultUserRole = defaultUserRole
        self.defaultGroupID = defaultGroupID; self.jwtExpiresIn = jwtExpiresIn
        self.enableCommunitySharing = enableCommunitySharing; self.enableMessageRating = enableMessageRating
        self.enableFolders = enableFolders; self.folderMaxFileCount = folderMaxFileCount
        self.enableChannels = enableChannels; self.enableMemories = enableMemories; self.enableNotes = enableNotes
        self.enableUserWebhooks = enableUserWebhooks; self.enableUserStatus = enableUserStatus
        self.pendingUserOverlayTitle = pendingUserOverlayTitle; self.pendingUserOverlayContent = pendingUserOverlayContent
        self.responseWatermark = responseWatermark
    }
}

/// LDAP toggle config — GET/POST `/api/v1/auths/admin/config/ldap`.
struct AdminLdapConfig: Codable, Sendable {
    var enableLdap: Bool?

    enum CodingKeys: String, CodingKey {
        case enableLdap = "enable_ldap"
    }
}

/// Full LDAP server config — GET/POST `/api/v1/auths/admin/config/ldap/server`.
struct AdminLdapServerConfig: Codable, Sendable {
    var label: String
    var host: String
    var port: Int?
    var attributeForMail: String
    var attributeForUsername: String
    var appDN: String
    var appDNPassword: String
    var searchBase: String
    var searchFilters: String
    var useTLS: Bool
    var certificatePath: String?
    var validateCert: Bool
    var ciphers: String?

    enum CodingKeys: String, CodingKey {
        case label, host, port
        case attributeForMail       = "attribute_for_mail"
        case attributeForUsername   = "attribute_for_username"
        case appDN                  = "app_dn"
        case appDNPassword          = "app_dn_password"
        case searchBase             = "search_base"
        case searchFilters          = "search_filters"
        case useTLS                 = "use_tls"
        case certificatePath        = "certificate_path"
        case validateCert           = "validate_cert"
        case ciphers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label              = (try? c.decode(String.self, forKey: .label))              ?? ""
        host               = (try? c.decode(String.self, forKey: .host))               ?? ""
        port               = try? c.decode(Int.self,    forKey: .port)
        attributeForMail   = (try? c.decode(String.self, forKey: .attributeForMail))   ?? "mail"
        attributeForUsername = (try? c.decode(String.self, forKey: .attributeForUsername)) ?? "uid"
        appDN              = (try? c.decode(String.self, forKey: .appDN))              ?? ""
        appDNPassword      = (try? c.decode(String.self, forKey: .appDNPassword))      ?? ""
        searchBase         = (try? c.decode(String.self, forKey: .searchBase))         ?? ""
        searchFilters      = (try? c.decode(String.self, forKey: .searchFilters))      ?? ""
        useTLS             = (try? c.decode(Bool.self,   forKey: .useTLS))             ?? true
        certificatePath    = try? c.decode(String.self, forKey: .certificatePath)
        validateCert       = (try? c.decode(Bool.self,   forKey: .validateCert))       ?? true
        ciphers            = try? c.decode(String.self, forKey: .ciphers)
    }

    init(
        label: String = "", host: String = "", port: Int? = nil,
        attributeForMail: String = "mail", attributeForUsername: String = "uid",
        appDN: String = "", appDNPassword: String = "", searchBase: String = "",
        searchFilters: String = "", useTLS: Bool = true, certificatePath: String? = nil,
        validateCert: Bool = true, ciphers: String? = "ALL"
    ) {
        self.label = label; self.host = host; self.port = port
        self.attributeForMail = attributeForMail; self.attributeForUsername = attributeForUsername
        self.appDN = appDN; self.appDNPassword = appDNPassword; self.searchBase = searchBase
        self.searchFilters = searchFilters; self.useTLS = useTLS; self.certificatePath = certificatePath
        self.validateCert = validateCert; self.ciphers = ciphers
    }
}

/// A single banner item — GET/POST `/api/v1/configs/banners`.
struct AdminBannerItem: Codable, Identifiable, Sendable {
    var id: String
    var type: String          // "info" | "warning" | "error" | "success"
    var title: String?
    var content: String
    var dismissible: Bool
    var timestamp: Int

    enum CodingKeys: String, CodingKey {
        case id, type, title, content, dismissible, timestamp
    }

    init(id: String = UUID().uuidString, type: String = "info", title: String? = nil,
         content: String = "", dismissible: Bool = true, timestamp: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id; self.type = type; self.title = title; self.content = content
        self.dismissible = dismissible; self.timestamp = timestamp
    }
}

/// POST body for saving banners.
struct AdminBannersUpdateBody: Codable, Sendable {
    let banners: [AdminBannerItem]
}

/// A group entry from GET `/api/v1/groups/`.
struct AdminGroupItem: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case memberCount = "member_count"
    }
}

// MARK: - Code Execution Config

/// GET/POST `/api/v1/configs/code_execution`
/// Keys are SCREAMING_SNAKE_CASE — must decode with a plain JSONDecoder (no .convertFromSnakeCase).
struct CodeExecutionConfig: Codable, Sendable {
    var enableCodeExecution: Bool
    var codeExecutionEngine: String
    var codeExecutionJupyterURL: String
    var codeExecutionJupyterAuth: String
    var codeExecutionJupyterAuthToken: String
    var codeExecutionJupyterAuthPassword: String
    var codeExecutionJupyterTimeout: Int
    var enableCodeInterpreter: Bool
    var codeInterpreterEngine: String
    var codeInterpreterPromptTemplate: String
    var codeInterpreterJupyterURL: String
    var codeInterpreterJupyterAuth: String
    var codeInterpreterJupyterAuthToken: String
    var codeInterpreterJupyterAuthPassword: String
    var codeInterpreterJupyterTimeout: Int

    enum CodingKeys: String, CodingKey {
        case enableCodeExecution            = "ENABLE_CODE_EXECUTION"
        case codeExecutionEngine            = "CODE_EXECUTION_ENGINE"
        case codeExecutionJupyterURL        = "CODE_EXECUTION_JUPYTER_URL"
        case codeExecutionJupyterAuth       = "CODE_EXECUTION_JUPYTER_AUTH"
        case codeExecutionJupyterAuthToken  = "CODE_EXECUTION_JUPYTER_AUTH_TOKEN"
        case codeExecutionJupyterAuthPassword = "CODE_EXECUTION_JUPYTER_AUTH_PASSWORD"
        case codeExecutionJupyterTimeout    = "CODE_EXECUTION_JUPYTER_TIMEOUT"
        case enableCodeInterpreter          = "ENABLE_CODE_INTERPRETER"
        case codeInterpreterEngine          = "CODE_INTERPRETER_ENGINE"
        case codeInterpreterPromptTemplate  = "CODE_INTERPRETER_PROMPT_TEMPLATE"
        case codeInterpreterJupyterURL      = "CODE_INTERPRETER_JUPYTER_URL"
        case codeInterpreterJupyterAuth     = "CODE_INTERPRETER_JUPYTER_AUTH"
        case codeInterpreterJupyterAuthToken = "CODE_INTERPRETER_JUPYTER_AUTH_TOKEN"
        case codeInterpreterJupyterAuthPassword = "CODE_INTERPRETER_JUPYTER_AUTH_PASSWORD"
        case codeInterpreterJupyterTimeout  = "CODE_INTERPRETER_JUPYTER_TIMEOUT"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enableCodeExecution            = (try? c.decode(Bool.self,   forKey: .enableCodeExecution))            ?? false
        codeExecutionEngine            = (try? c.decode(String.self, forKey: .codeExecutionEngine))            ?? "pyodide"
        codeExecutionJupyterURL        = (try? c.decode(String.self, forKey: .codeExecutionJupyterURL))        ?? ""
        codeExecutionJupyterAuth       = (try? c.decode(String.self, forKey: .codeExecutionJupyterAuth))       ?? ""
        codeExecutionJupyterAuthToken  = (try? c.decode(String.self, forKey: .codeExecutionJupyterAuthToken))  ?? ""
        codeExecutionJupyterAuthPassword = (try? c.decode(String.self, forKey: .codeExecutionJupyterAuthPassword)) ?? ""
        codeExecutionJupyterTimeout    = (try? c.decode(Int.self,    forKey: .codeExecutionJupyterTimeout))    ?? 60
        enableCodeInterpreter          = (try? c.decode(Bool.self,   forKey: .enableCodeInterpreter))          ?? true
        codeInterpreterEngine          = (try? c.decode(String.self, forKey: .codeInterpreterEngine))          ?? "pyodide"
        codeInterpreterPromptTemplate  = (try? c.decode(String.self, forKey: .codeInterpreterPromptTemplate))  ?? ""
        codeInterpreterJupyterURL      = (try? c.decode(String.self, forKey: .codeInterpreterJupyterURL))      ?? ""
        codeInterpreterJupyterAuth     = (try? c.decode(String.self, forKey: .codeInterpreterJupyterAuth))     ?? ""
        codeInterpreterJupyterAuthToken = (try? c.decode(String.self, forKey: .codeInterpreterJupyterAuthToken)) ?? ""
        codeInterpreterJupyterAuthPassword = (try? c.decode(String.self, forKey: .codeInterpreterJupyterAuthPassword)) ?? ""
        codeInterpreterJupyterTimeout  = (try? c.decode(Int.self,    forKey: .codeInterpreterJupyterTimeout))  ?? 60
    }

    init(
        enableCodeExecution: Bool = false,
        codeExecutionEngine: String = "pyodide",
        codeExecutionJupyterURL: String = "",
        codeExecutionJupyterAuth: String = "",
        codeExecutionJupyterAuthToken: String = "",
        codeExecutionJupyterAuthPassword: String = "",
        codeExecutionJupyterTimeout: Int = 60,
        enableCodeInterpreter: Bool = true,
        codeInterpreterEngine: String = "pyodide",
        codeInterpreterPromptTemplate: String = "",
        codeInterpreterJupyterURL: String = "",
        codeInterpreterJupyterAuth: String = "",
        codeInterpreterJupyterAuthToken: String = "",
        codeInterpreterJupyterAuthPassword: String = "",
        codeInterpreterJupyterTimeout: Int = 60
    ) {
        self.enableCodeExecution = enableCodeExecution
        self.codeExecutionEngine = codeExecutionEngine
        self.codeExecutionJupyterURL = codeExecutionJupyterURL
        self.codeExecutionJupyterAuth = codeExecutionJupyterAuth
        self.codeExecutionJupyterAuthToken = codeExecutionJupyterAuthToken
        self.codeExecutionJupyterAuthPassword = codeExecutionJupyterAuthPassword
        self.codeExecutionJupyterTimeout = codeExecutionJupyterTimeout
        self.enableCodeInterpreter = enableCodeInterpreter
        self.codeInterpreterEngine = codeInterpreterEngine
        self.codeInterpreterPromptTemplate = codeInterpreterPromptTemplate
        self.codeInterpreterJupyterURL = codeInterpreterJupyterURL
        self.codeInterpreterJupyterAuth = codeInterpreterJupyterAuth
        self.codeInterpreterJupyterAuthToken = codeInterpreterJupyterAuthToken
        self.codeInterpreterJupyterAuthPassword = codeInterpreterJupyterAuthPassword
        self.codeInterpreterJupyterTimeout = codeInterpreterJupyterTimeout
    }
}

// MARK: - Image Config

/// Workflow node mapping for ComfyUI workflows.
struct ImageWorkflowNode: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var type: String
    var key: String
    var nodeIds: [String]

    enum CodingKeys: String, CodingKey {
        case type, key
        case nodeIds = "node_ids"
    }

    init(type: String = "", key: String = "", nodeIds: [String] = []) {
        self.type = type
        self.key = key
        self.nodeIds = nodeIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        key = (try? c.decode(String.self, forKey: .key)) ?? ""
        nodeIds = (try? c.decode([String].self, forKey: .nodeIds)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(key, forKey: .key)
        try c.encode(nodeIds, forKey: .nodeIds)
    }
}

/// A model available for image generation.
struct ImageModelItem: Codable, Sendable, Identifiable {
    var id: String
    var name: String

    init(id: String = "", name: String = "") {
        self.id = id
        self.name = name
    }
}

/// GET/POST `/api/v1/images/config`
/// Keys are SCREAMING_SNAKE_CASE — must decode with a plain JSONDecoder.
struct ImageConfig: Codable, Sendable {
    // Create Image
    var enableImageGeneration: Bool
    var enableImagePromptGeneration: Bool
    var imageGenerationEngine: String
    var imageGenerationModel: String
    var imageSize: String
    var imageSteps: Int

    // OpenAI
    var imagesOpenAIAPIBaseURL: String
    var imagesOpenAIAPIKey: String
    var imagesOpenAIAPIVersion: String
    var imagesOpenAIAPIParamsJSON: String

    // Automatic1111
    var automatic1111BaseURL: String
    var automatic1111APIAuth: String
    var automatic1111ParamsJSON: String

    // ComfyUI
    var comfyUIBaseURL: String
    var comfyUIAPIKey: String
    var comfyUIWorkflow: String
    var comfyUIWorkflowNodes: [ImageWorkflowNode]

    // Gemini
    var imagesGeminiAPIBaseURL: String
    var imagesGeminiAPIKey: String
    var imagesGeminiEndpointMethod: String

    // Edit Image
    var enableImageEdit: Bool
    var imageEditEngine: String
    var imageEditModel: String
    var imageEditSize: String

    // Edit OpenAI
    var imagesEditOpenAIAPIBaseURL: String
    var imagesEditOpenAIAPIKey: String
    var imagesEditOpenAIAPIVersion: String

    // Edit Gemini
    var imagesEditGeminiAPIBaseURL: String
    var imagesEditGeminiAPIKey: String

    // Edit ComfyUI
    var imagesEditComfyUIBaseURL: String
    var imagesEditComfyUIAPIKey: String
    var imagesEditComfyUIWorkflow: String
    var imagesEditComfyUIWorkflowNodes: [ImageWorkflowNode]

    enum CodingKeys: String, CodingKey {
        case enableImageGeneration         = "ENABLE_IMAGE_GENERATION"
        case enableImagePromptGeneration   = "ENABLE_IMAGE_PROMPT_GENERATION"
        case imageGenerationEngine         = "IMAGE_GENERATION_ENGINE"
        case imageGenerationModel          = "IMAGE_GENERATION_MODEL"
        case imageSize                     = "IMAGE_SIZE"
        case imageSteps                    = "IMAGE_STEPS"
        case imagesOpenAIAPIBaseURL        = "IMAGES_OPENAI_API_BASE_URL"
        case imagesOpenAIAPIKey            = "IMAGES_OPENAI_API_KEY"
        case imagesOpenAIAPIVersion        = "IMAGES_OPENAI_API_VERSION"
        case imagesOpenAIAPIParams         = "IMAGES_OPENAI_API_PARAMS"
        case automatic1111BaseURL          = "AUTOMATIC1111_BASE_URL"
        case automatic1111APIAuth          = "AUTOMATIC1111_API_AUTH"
        case automatic1111Params           = "AUTOMATIC1111_PARAMS"
        case comfyUIBaseURL                = "COMFYUI_BASE_URL"
        case comfyUIAPIKey                 = "COMFYUI_API_KEY"
        case comfyUIWorkflow               = "COMFYUI_WORKFLOW"
        case comfyUIWorkflowNodes          = "COMFYUI_WORKFLOW_NODES"
        case imagesGeminiAPIBaseURL        = "IMAGES_GEMINI_API_BASE_URL"
        case imagesGeminiAPIKey            = "IMAGES_GEMINI_API_KEY"
        case imagesGeminiEndpointMethod    = "IMAGES_GEMINI_ENDPOINT_METHOD"
        case enableImageEdit               = "ENABLE_IMAGE_EDIT"
        case imageEditEngine               = "IMAGE_EDIT_ENGINE"
        case imageEditModel                = "IMAGE_EDIT_MODEL"
        case imageEditSize                 = "IMAGE_EDIT_SIZE"
        case imagesEditOpenAIAPIBaseURL    = "IMAGES_EDIT_OPENAI_API_BASE_URL"
        case imagesEditOpenAIAPIKey        = "IMAGES_EDIT_OPENAI_API_KEY"
        case imagesEditOpenAIAPIVersion    = "IMAGES_EDIT_OPENAI_API_VERSION"
        case imagesEditGeminiAPIBaseURL    = "IMAGES_EDIT_GEMINI_API_BASE_URL"
        case imagesEditGeminiAPIKey        = "IMAGES_EDIT_GEMINI_API_KEY"
        case imagesEditComfyUIBaseURL      = "IMAGES_EDIT_COMFYUI_BASE_URL"
        case imagesEditComfyUIAPIKey       = "IMAGES_EDIT_COMFYUI_API_KEY"
        case imagesEditComfyUIWorkflow     = "IMAGES_EDIT_COMFYUI_WORKFLOW"
        case imagesEditComfyUIWorkflowNodes = "IMAGES_EDIT_COMFYUI_WORKFLOW_NODES"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enableImageGeneration       = (try? c.decode(Bool.self, forKey: .enableImageGeneration)) ?? false
        enableImagePromptGeneration = (try? c.decode(Bool.self, forKey: .enableImagePromptGeneration)) ?? true
        imageGenerationEngine       = (try? c.decode(String.self, forKey: .imageGenerationEngine)) ?? "openai"
        imageGenerationModel        = (try? c.decode(String.self, forKey: .imageGenerationModel)) ?? ""
        imageSize                   = (try? c.decode(String.self, forKey: .imageSize)) ?? "1024x1024"
        imageSteps                  = (try? c.decode(Int.self, forKey: .imageSteps)) ?? 4
        imagesOpenAIAPIBaseURL      = (try? c.decode(String.self, forKey: .imagesOpenAIAPIBaseURL)) ?? "https://api.openai.com/v1"
        imagesOpenAIAPIKey          = (try? c.decode(String.self, forKey: .imagesOpenAIAPIKey)) ?? ""
        imagesOpenAIAPIVersion      = (try? c.decode(String.self, forKey: .imagesOpenAIAPIVersion)) ?? ""
        // IMAGES_OPENAI_API_PARAMS comes as a JSON object — serialize to string
        if let paramsData = try? c.decode([String: JSONAnyCodable].self, forKey: .imagesOpenAIAPIParams),
           let data = try? JSONSerialization.data(withJSONObject: paramsData.mapValues { $0.value }, options: [.sortedKeys, .prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            imagesOpenAIAPIParamsJSON = str
        } else {
            imagesOpenAIAPIParamsJSON = "{}"
        }
        automatic1111BaseURL        = (try? c.decode(String.self, forKey: .automatic1111BaseURL)) ?? ""
        automatic1111APIAuth        = (try? c.decode(String.self, forKey: .automatic1111APIAuth)) ?? ""
        // AUTOMATIC1111_PARAMS comes as a JSON object — serialize to string
        if let paramsData = try? c.decode([String: JSONAnyCodable].self, forKey: .automatic1111Params),
           let data = try? JSONSerialization.data(withJSONObject: paramsData.mapValues { $0.value }, options: [.sortedKeys, .prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            automatic1111ParamsJSON = str
        } else {
            automatic1111ParamsJSON = "{}"
        }
        comfyUIBaseURL              = (try? c.decode(String.self, forKey: .comfyUIBaseURL)) ?? ""
        comfyUIAPIKey               = (try? c.decode(String.self, forKey: .comfyUIAPIKey)) ?? ""
        comfyUIWorkflow             = (try? c.decode(String.self, forKey: .comfyUIWorkflow)) ?? ""
        comfyUIWorkflowNodes        = (try? c.decode([ImageWorkflowNode].self, forKey: .comfyUIWorkflowNodes)) ?? []
        imagesGeminiAPIBaseURL      = (try? c.decode(String.self, forKey: .imagesGeminiAPIBaseURL)) ?? ""
        imagesGeminiAPIKey          = (try? c.decode(String.self, forKey: .imagesGeminiAPIKey)) ?? ""
        imagesGeminiEndpointMethod  = (try? c.decode(String.self, forKey: .imagesGeminiEndpointMethod)) ?? ""
        enableImageEdit             = (try? c.decode(Bool.self, forKey: .enableImageEdit)) ?? false
        imageEditEngine             = (try? c.decode(String.self, forKey: .imageEditEngine)) ?? "openai"
        imageEditModel              = (try? c.decode(String.self, forKey: .imageEditModel)) ?? ""
        imageEditSize               = (try? c.decode(String.self, forKey: .imageEditSize)) ?? ""
        imagesEditOpenAIAPIBaseURL  = (try? c.decode(String.self, forKey: .imagesEditOpenAIAPIBaseURL)) ?? "https://api.openai.com/v1"
        imagesEditOpenAIAPIKey      = (try? c.decode(String.self, forKey: .imagesEditOpenAIAPIKey)) ?? ""
        imagesEditOpenAIAPIVersion  = (try? c.decode(String.self, forKey: .imagesEditOpenAIAPIVersion)) ?? ""
        imagesEditGeminiAPIBaseURL  = (try? c.decode(String.self, forKey: .imagesEditGeminiAPIBaseURL)) ?? ""
        imagesEditGeminiAPIKey      = (try? c.decode(String.self, forKey: .imagesEditGeminiAPIKey)) ?? ""
        imagesEditComfyUIBaseURL    = (try? c.decode(String.self, forKey: .imagesEditComfyUIBaseURL)) ?? ""
        imagesEditComfyUIAPIKey     = (try? c.decode(String.self, forKey: .imagesEditComfyUIAPIKey)) ?? ""
        imagesEditComfyUIWorkflow   = (try? c.decode(String.self, forKey: .imagesEditComfyUIWorkflow)) ?? ""
        imagesEditComfyUIWorkflowNodes = (try? c.decode([ImageWorkflowNode].self, forKey: .imagesEditComfyUIWorkflowNodes)) ?? []
    }

    /// Custom encode that serializes JSON string fields back to JSON objects for the API.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enableImageGeneration, forKey: .enableImageGeneration)
        try c.encode(enableImagePromptGeneration, forKey: .enableImagePromptGeneration)
        try c.encode(imageGenerationEngine, forKey: .imageGenerationEngine)
        try c.encode(imageGenerationModel, forKey: .imageGenerationModel)
        try c.encode(imageSize, forKey: .imageSize)
        try c.encode(imageSteps, forKey: .imageSteps)
        try c.encode(imagesOpenAIAPIBaseURL, forKey: .imagesOpenAIAPIBaseURL)
        try c.encode(imagesOpenAIAPIKey, forKey: .imagesOpenAIAPIKey)
        try c.encode(imagesOpenAIAPIVersion, forKey: .imagesOpenAIAPIVersion)
        // Encode IMAGES_OPENAI_API_PARAMS as JSON object
        if let data = imagesOpenAIAPIParamsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try c.encode(obj.mapValues { JSONAnyCodable($0) }, forKey: .imagesOpenAIAPIParams)
        } else {
            try c.encode([String: JSONAnyCodable](), forKey: .imagesOpenAIAPIParams)
        }
        try c.encode(automatic1111BaseURL, forKey: .automatic1111BaseURL)
        try c.encode(automatic1111APIAuth, forKey: .automatic1111APIAuth)
        // Encode AUTOMATIC1111_PARAMS as JSON object
        if let data = automatic1111ParamsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try c.encode(obj.mapValues { JSONAnyCodable($0) }, forKey: .automatic1111Params)
        } else {
            try c.encode([String: JSONAnyCodable](), forKey: .automatic1111Params)
        }
        try c.encode(comfyUIBaseURL, forKey: .comfyUIBaseURL)
        try c.encode(comfyUIAPIKey, forKey: .comfyUIAPIKey)
        try c.encode(comfyUIWorkflow, forKey: .comfyUIWorkflow)
        try c.encode(comfyUIWorkflowNodes, forKey: .comfyUIWorkflowNodes)
        try c.encode(imagesGeminiAPIBaseURL, forKey: .imagesGeminiAPIBaseURL)
        try c.encode(imagesGeminiAPIKey, forKey: .imagesGeminiAPIKey)
        try c.encode(imagesGeminiEndpointMethod, forKey: .imagesGeminiEndpointMethod)
        try c.encode(enableImageEdit, forKey: .enableImageEdit)
        try c.encode(imageEditEngine, forKey: .imageEditEngine)
        try c.encode(imageEditModel, forKey: .imageEditModel)
        try c.encode(imageEditSize, forKey: .imageEditSize)
        try c.encode(imagesEditOpenAIAPIBaseURL, forKey: .imagesEditOpenAIAPIBaseURL)
        try c.encode(imagesEditOpenAIAPIKey, forKey: .imagesEditOpenAIAPIKey)
        try c.encode(imagesEditOpenAIAPIVersion, forKey: .imagesEditOpenAIAPIVersion)
        try c.encode(imagesEditGeminiAPIBaseURL, forKey: .imagesEditGeminiAPIBaseURL)
        try c.encode(imagesEditGeminiAPIKey, forKey: .imagesEditGeminiAPIKey)
        try c.encode(imagesEditComfyUIBaseURL, forKey: .imagesEditComfyUIBaseURL)
        try c.encode(imagesEditComfyUIAPIKey, forKey: .imagesEditComfyUIAPIKey)
        try c.encode(imagesEditComfyUIWorkflow, forKey: .imagesEditComfyUIWorkflow)
        try c.encode(imagesEditComfyUIWorkflowNodes, forKey: .imagesEditComfyUIWorkflowNodes)
    }

    init() {
        enableImageGeneration = false
        enableImagePromptGeneration = true
        imageGenerationEngine = "openai"
        imageGenerationModel = ""
        imageSize = "1024x1024"
        imageSteps = 4
        imagesOpenAIAPIBaseURL = "https://api.openai.com/v1"
        imagesOpenAIAPIKey = ""
        imagesOpenAIAPIVersion = ""
        imagesOpenAIAPIParamsJSON = "{}"
        automatic1111BaseURL = ""
        automatic1111APIAuth = ""
        automatic1111ParamsJSON = "{}"
        comfyUIBaseURL = ""
        comfyUIAPIKey = ""
        comfyUIWorkflow = ""
        comfyUIWorkflowNodes = []
        imagesGeminiAPIBaseURL = ""
        imagesGeminiAPIKey = ""
        imagesGeminiEndpointMethod = ""
        enableImageEdit = false
        imageEditEngine = "openai"
        imageEditModel = ""
        imageEditSize = ""
        imagesEditOpenAIAPIBaseURL = "https://api.openai.com/v1"
        imagesEditOpenAIAPIKey = ""
        imagesEditOpenAIAPIVersion = ""
        imagesEditGeminiAPIBaseURL = ""
        imagesEditGeminiAPIKey = ""
        imagesEditComfyUIBaseURL = ""
        imagesEditComfyUIAPIKey = ""
        imagesEditComfyUIWorkflow = ""
        imagesEditComfyUIWorkflowNodes = []
    }
}

// MARK: - Admin Audio Config

/// GET `/api/v1/audio/config`  POST `/api/v1/audio/config/update`
/// Top-level has `tts` and `stt` nested objects with SCREAMING_SNAKE_CASE keys.
struct AdminAudioConfig: Codable, Sendable {
    var tts: AdminTTSConfig
    var stt: AdminSTTConfig

    init(tts: AdminTTSConfig = AdminTTSConfig(), stt: AdminSTTConfig = AdminSTTConfig()) {
        self.tts = tts
        self.stt = stt
    }
}

/// TTS sub-config inside `AdminAudioConfig`.
struct AdminTTSConfig: Codable, Sendable {
    var openAIAPIBaseURL: String
    var openAIAPIKey: String
    var openAIParamsJSON: String   // Stored as string, encoded as JSON object
    var apiKey: String
    var engine: String
    var model: String
    var voice: String
    var splitOn: String
    var azureSpeechRegion: String
    var azureSpeechBaseURL: String
    var azureSpeechOutputFormat: String

    enum CodingKeys: String, CodingKey {
        case openAIAPIBaseURL       = "OPENAI_API_BASE_URL"
        case openAIAPIKey           = "OPENAI_API_KEY"
        case openAIParams           = "OPENAI_PARAMS"
        case apiKey                 = "API_KEY"
        case engine                 = "ENGINE"
        case model                  = "MODEL"
        case voice                  = "VOICE"
        case splitOn                = "SPLIT_ON"
        case azureSpeechRegion      = "AZURE_SPEECH_REGION"
        case azureSpeechBaseURL     = "AZURE_SPEECH_BASE_URL"
        case azureSpeechOutputFormat = "AZURE_SPEECH_OUTPUT_FORMAT"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openAIAPIBaseURL       = (try? c.decode(String.self, forKey: .openAIAPIBaseURL))       ?? ""
        openAIAPIKey           = (try? c.decode(String.self, forKey: .openAIAPIKey))           ?? ""
        // OPENAI_PARAMS comes as a JSON object — serialize to string
        if let paramsData = try? c.decode([String: JSONAnyCodable].self, forKey: .openAIParams),
           let data = try? JSONSerialization.data(withJSONObject: paramsData.mapValues { $0.value }, options: [.sortedKeys, .prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            openAIParamsJSON = str
        } else {
            openAIParamsJSON = "{}"
        }
        apiKey                 = (try? c.decode(String.self, forKey: .apiKey))                 ?? ""
        engine                 = (try? c.decode(String.self, forKey: .engine))                 ?? ""
        model                  = (try? c.decode(String.self, forKey: .model))                  ?? ""
        voice                  = (try? c.decode(String.self, forKey: .voice))                  ?? ""
        splitOn                = (try? c.decode(String.self, forKey: .splitOn))                ?? "punctuation"
        azureSpeechRegion      = (try? c.decode(String.self, forKey: .azureSpeechRegion))      ?? ""
        azureSpeechBaseURL     = (try? c.decode(String.self, forKey: .azureSpeechBaseURL))     ?? ""
        azureSpeechOutputFormat = (try? c.decode(String.self, forKey: .azureSpeechOutputFormat)) ?? "audio-24khz-160kbitrate-mono-mp3"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(openAIAPIBaseURL, forKey: .openAIAPIBaseURL)
        try c.encode(openAIAPIKey, forKey: .openAIAPIKey)
        // Encode OPENAI_PARAMS as JSON object
        if let data = openAIParamsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try c.encode(obj.mapValues { JSONAnyCodable($0) }, forKey: .openAIParams)
        } else {
            try c.encode([String: JSONAnyCodable](), forKey: .openAIParams)
        }
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(engine, forKey: .engine)
        try c.encode(model, forKey: .model)
        try c.encode(voice, forKey: .voice)
        try c.encode(splitOn, forKey: .splitOn)
        try c.encode(azureSpeechRegion, forKey: .azureSpeechRegion)
        try c.encode(azureSpeechBaseURL, forKey: .azureSpeechBaseURL)
        try c.encode(azureSpeechOutputFormat, forKey: .azureSpeechOutputFormat)
    }

    init(
        openAIAPIBaseURL: String = "", openAIAPIKey: String = "", openAIParamsJSON: String = "{}",
        apiKey: String = "", engine: String = "", model: String = "", voice: String = "",
        splitOn: String = "punctuation", azureSpeechRegion: String = "",
        azureSpeechBaseURL: String = "", azureSpeechOutputFormat: String = "audio-24khz-160kbitrate-mono-mp3"
    ) {
        self.openAIAPIBaseURL = openAIAPIBaseURL; self.openAIAPIKey = openAIAPIKey
        self.openAIParamsJSON = openAIParamsJSON; self.apiKey = apiKey; self.engine = engine
        self.model = model; self.voice = voice; self.splitOn = splitOn
        self.azureSpeechRegion = azureSpeechRegion; self.azureSpeechBaseURL = azureSpeechBaseURL
        self.azureSpeechOutputFormat = azureSpeechOutputFormat
    }
}

/// STT sub-config inside `AdminAudioConfig`.
struct AdminSTTConfig: Codable, Sendable {
    var openAIAPIBaseURL: String
    var openAIAPIKey: String
    var engine: String
    var model: String
    var supportedContentTypes: [String]
    var whisperModel: String
    var deepgramAPIKey: String
    var azureAPIKey: String
    var azureRegion: String
    var azureLocales: String
    var azureBaseURL: String
    var azureMaxSpeakers: String
    var mistralAPIKey: String
    var mistralAPIBaseURL: String
    var mistralUseChatCompletions: Bool

    enum CodingKeys: String, CodingKey {
        case openAIAPIBaseURL           = "OPENAI_API_BASE_URL"
        case openAIAPIKey               = "OPENAI_API_KEY"
        case engine                     = "ENGINE"
        case model                      = "MODEL"
        case supportedContentTypes      = "SUPPORTED_CONTENT_TYPES"
        case whisperModel               = "WHISPER_MODEL"
        case deepgramAPIKey             = "DEEPGRAM_API_KEY"
        case azureAPIKey                = "AZURE_API_KEY"
        case azureRegion                = "AZURE_REGION"
        case azureLocales               = "AZURE_LOCALES"
        case azureBaseURL               = "AZURE_BASE_URL"
        case azureMaxSpeakers           = "AZURE_MAX_SPEAKERS"
        case mistralAPIKey              = "MISTRAL_API_KEY"
        case mistralAPIBaseURL          = "MISTRAL_API_BASE_URL"
        case mistralUseChatCompletions  = "MISTRAL_USE_CHAT_COMPLETIONS"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openAIAPIBaseURL          = (try? c.decode(String.self, forKey: .openAIAPIBaseURL))          ?? ""
        openAIAPIKey              = (try? c.decode(String.self, forKey: .openAIAPIKey))              ?? ""
        engine                    = (try? c.decode(String.self, forKey: .engine))                    ?? ""
        model                     = (try? c.decode(String.self, forKey: .model))                     ?? ""
        supportedContentTypes     = (try? c.decode([String].self, forKey: .supportedContentTypes))   ?? []
        whisperModel              = (try? c.decode(String.self, forKey: .whisperModel))              ?? "base"
        deepgramAPIKey            = (try? c.decode(String.self, forKey: .deepgramAPIKey))            ?? ""
        azureAPIKey               = (try? c.decode(String.self, forKey: .azureAPIKey))               ?? ""
        azureRegion               = (try? c.decode(String.self, forKey: .azureRegion))               ?? ""
        azureLocales              = (try? c.decode(String.self, forKey: .azureLocales))              ?? ""
        azureBaseURL              = (try? c.decode(String.self, forKey: .azureBaseURL))              ?? ""
        azureMaxSpeakers          = (try? c.decode(String.self, forKey: .azureMaxSpeakers))         ?? ""
        mistralAPIKey             = (try? c.decode(String.self, forKey: .mistralAPIKey))             ?? ""
        mistralAPIBaseURL         = (try? c.decode(String.self, forKey: .mistralAPIBaseURL))         ?? "https://api.mistral.ai/v1"
        mistralUseChatCompletions = (try? c.decode(Bool.self, forKey: .mistralUseChatCompletions))   ?? false
    }

    init(
        openAIAPIBaseURL: String = "", openAIAPIKey: String = "", engine: String = "",
        model: String = "", supportedContentTypes: [String] = [], whisperModel: String = "base",
        deepgramAPIKey: String = "", azureAPIKey: String = "", azureRegion: String = "",
        azureLocales: String = "", azureBaseURL: String = "", azureMaxSpeakers: String = "",
        mistralAPIKey: String = "", mistralAPIBaseURL: String = "https://api.mistral.ai/v1",
        mistralUseChatCompletions: Bool = false
    ) {
        self.openAIAPIBaseURL = openAIAPIBaseURL; self.openAIAPIKey = openAIAPIKey
        self.engine = engine; self.model = model; self.supportedContentTypes = supportedContentTypes
        self.whisperModel = whisperModel; self.deepgramAPIKey = deepgramAPIKey
        self.azureAPIKey = azureAPIKey; self.azureRegion = azureRegion
        self.azureLocales = azureLocales; self.azureBaseURL = azureBaseURL
        self.azureMaxSpeakers = azureMaxSpeakers; self.mistralAPIKey = mistralAPIKey
        self.mistralAPIBaseURL = mistralAPIBaseURL; self.mistralUseChatCompletions = mistralUseChatCompletions
    }
}

// MARK: - Connections Config

/// GET/POST `/api/v1/configs/connections`
/// Keys are SCREAMING_SNAKE_CASE — must decode with a plain JSONDecoder (no .convertFromSnakeCase).
struct ConnectionsConfig: Codable, Sendable {
    var enableDirectConnections: Bool
    var enableBaseModelsCache: Bool

    enum CodingKeys: String, CodingKey {
        case enableDirectConnections = "ENABLE_DIRECT_CONNECTIONS"
        case enableBaseModelsCache   = "ENABLE_BASE_MODELS_CACHE"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enableDirectConnections = (try? c.decode(Bool.self, forKey: .enableDirectConnections)) ?? false
        enableBaseModelsCache   = (try? c.decode(Bool.self, forKey: .enableBaseModelsCache))   ?? false
    }

    init(enableDirectConnections: Bool = false, enableBaseModelsCache: Bool = false) {
        self.enableDirectConnections = enableDirectConnections
        self.enableBaseModelsCache   = enableBaseModelsCache
    }
}

// MARK: - OpenAI Connections Config

/// A tag attached to an OpenAI connection.
struct OpenAITag: Codable, Sendable {
    var name: String
    init(name: String = "") { self.name = name }
}

/// Per-connection settings inside `OPENAI_API_CONFIGS`.
struct OpenAIConnectionConfig: Codable, Sendable {
    var enable: Bool
    var tags: [OpenAITag]
    var prefixId: String
    var modelIds: [String]
    var connectionType: String
    var authType: String
    /// Additional headers as a key-value dictionary (displayed as JSON in the UI).
    var headers: [String: String]
    /// Provider type: "" = standard OpenAI-compatible, "azure" = Azure OpenAI.
    var providerType: String
    /// API version string (only used when providerType == "azure").
    var apiVersion: String
    /// API type: "chat_completions" (default) or "responses" (experimental).
    var apiType: String

    enum CodingKeys: String, CodingKey {
        case enable, tags, headers
        case prefixId       = "prefix_id"
        case modelIds       = "model_ids"
        case connectionType = "connection_type"
        case authType       = "auth_type"
        case providerType   = "provider_type"
        case apiVersion     = "api_version"
        case apiType        = "api_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enable         = (try? c.decode(Bool.self,               forKey: .enable))         ?? true
        tags           = (try? c.decode([OpenAITag].self,        forKey: .tags))           ?? []
        prefixId       = (try? c.decode(String.self,             forKey: .prefixId))       ?? ""
        modelIds       = (try? c.decode([String].self,           forKey: .modelIds))       ?? []
        connectionType = (try? c.decode(String.self,             forKey: .connectionType)) ?? "external"
        authType       = (try? c.decode(String.self,             forKey: .authType))       ?? "bearer"
        headers        = (try? c.decode([String: String].self,   forKey: .headers))        ?? [:]
        providerType   = (try? c.decode(String.self,             forKey: .providerType))   ?? ""
        apiVersion     = (try? c.decode(String.self,             forKey: .apiVersion))     ?? ""
        apiType        = (try? c.decode(String.self,             forKey: .apiType))        ?? ""
    }

    init(enable: Bool = true, tags: [OpenAITag] = [], prefixId: String = "",
         modelIds: [String] = [], connectionType: String = "external",
         authType: String = "bearer", headers: [String: String] = [:],
         providerType: String = "", apiVersion: String = "", apiType: String = "") {
        self.enable = enable; self.tags = tags; self.prefixId = prefixId
        self.modelIds = modelIds; self.connectionType = connectionType
        self.authType = authType; self.headers = headers
        self.providerType = providerType; self.apiVersion = apiVersion; self.apiType = apiType
    }
}

/// GET `/openai/config`  POST `/openai/config/update`
/// SCREAMING_SNAKE_CASE top-level keys.
struct OpenAIConfig: Codable, Sendable {
    var enableOpenAIAPI: Bool
    var openAIAPIBaseURLs: [String]
    var openAIAPIKeys: [String]
    /// Keyed by string index ("0", "1", …).
    var openAIAPIConfigs: [String: OpenAIConnectionConfig]

    enum CodingKeys: String, CodingKey {
        case enableOpenAIAPI    = "ENABLE_OPENAI_API"
        case openAIAPIBaseURLs  = "OPENAI_API_BASE_URLS"
        case openAIAPIKeys      = "OPENAI_API_KEYS"
        case openAIAPIConfigs   = "OPENAI_API_CONFIGS"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enableOpenAIAPI   = (try? c.decode(Bool.self,                               forKey: .enableOpenAIAPI))   ?? true
        openAIAPIBaseURLs = (try? c.decode([String].self,                           forKey: .openAIAPIBaseURLs)) ?? []
        openAIAPIKeys     = (try? c.decode([String].self,                           forKey: .openAIAPIKeys))     ?? []
        openAIAPIConfigs  = (try? c.decode([String: OpenAIConnectionConfig].self,   forKey: .openAIAPIConfigs))  ?? [:]
    }

    init(enableOpenAIAPI: Bool = true, openAIAPIBaseURLs: [String] = [],
         openAIAPIKeys: [String] = [], openAIAPIConfigs: [String: OpenAIConnectionConfig] = [:]) {
        self.enableOpenAIAPI   = enableOpenAIAPI
        self.openAIAPIBaseURLs = openAIAPIBaseURLs
        self.openAIAPIKeys     = openAIAPIKeys
        self.openAIAPIConfigs  = openAIAPIConfigs
    }

    /// Returns ordered connections by index key.
    var orderedConnections: [(index: Int, url: String, key: String, config: OpenAIConnectionConfig)] {
        openAIAPIBaseURLs.enumerated().map { (i, url) in
            let key = openAIAPIKeys.indices.contains(i) ? openAIAPIKeys[i] : ""
            let cfg = openAIAPIConfigs["\(i)"] ?? OpenAIConnectionConfig()
            return (index: i, url: url, key: key, config: cfg)
        }
    }
}

// MARK: - Ollama Connections Config

/// A tag attached to an Ollama connection.
struct OllamaTag: Codable, Sendable {
    var name: String
    init(name: String = "") { self.name = name }
}

/// Per-connection settings inside `OLLAMA_API_CONFIGS`.
struct OllamaConnectionConfig: Codable, Sendable {
    var enable: Bool
    var tags: [OllamaTag]
    var prefixId: String
    var modelIds: [String]
    var connectionType: String
    var authType: String
    var headers: [String: String]

    enum CodingKeys: String, CodingKey {
        case enable, tags, headers
        case prefixId       = "prefix_id"
        case modelIds       = "model_ids"
        case connectionType = "connection_type"
        case authType       = "auth_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enable         = (try? c.decode(Bool.self,               forKey: .enable))         ?? true
        tags           = (try? c.decode([OllamaTag].self,        forKey: .tags))           ?? []
        prefixId       = (try? c.decode(String.self,             forKey: .prefixId))       ?? ""
        modelIds       = (try? c.decode([String].self,           forKey: .modelIds))       ?? []
        connectionType = (try? c.decode(String.self,             forKey: .connectionType)) ?? "external"
        authType       = (try? c.decode(String.self,             forKey: .authType))       ?? "none"
        headers        = (try? c.decode([String: String].self,   forKey: .headers))        ?? [:]
    }

    init(enable: Bool = true, tags: [OllamaTag] = [], prefixId: String = "",
         modelIds: [String] = [], connectionType: String = "external",
         authType: String = "none", headers: [String: String] = [:]) {
        self.enable = enable; self.tags = tags; self.prefixId = prefixId
        self.modelIds = modelIds; self.connectionType = connectionType
        self.authType = authType; self.headers = headers
    }
}

/// GET `/ollama/config`  POST `/ollama/config/update`
struct OllamaConfig: Codable, Sendable {
    var enableOllamaAPI: Bool
    var ollamaBaseURLs: [String]
    var ollamaAPIConfigs: [String: OllamaConnectionConfig]

    enum CodingKeys: String, CodingKey {
        case enableOllamaAPI  = "ENABLE_OLLAMA_API"
        case ollamaBaseURLs   = "OLLAMA_BASE_URLS"
        case ollamaAPIConfigs = "OLLAMA_API_CONFIGS"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enableOllamaAPI  = (try? c.decode(Bool.self,                                forKey: .enableOllamaAPI))  ?? false
        ollamaBaseURLs   = (try? c.decode([String].self,                            forKey: .ollamaBaseURLs))   ?? []
        ollamaAPIConfigs = (try? c.decode([String: OllamaConnectionConfig].self,    forKey: .ollamaAPIConfigs)) ?? [:]
    }

    init(enableOllamaAPI: Bool = false, ollamaBaseURLs: [String] = [],
         ollamaAPIConfigs: [String: OllamaConnectionConfig] = [:]) {
        self.enableOllamaAPI  = enableOllamaAPI
        self.ollamaBaseURLs   = ollamaBaseURLs
        self.ollamaAPIConfigs = ollamaAPIConfigs
    }

    var orderedConnections: [(index: Int, url: String, config: OllamaConnectionConfig)] {
        ollamaBaseURLs.enumerated().map { (i, url) in
            let cfg = ollamaAPIConfigs["\(i)"] ?? OllamaConnectionConfig()
            return (index: i, url: url, config: cfg)
        }
    }
}

// MARK: - Tool Server Config

/// Access grant for tool/terminal server access control.
/// Named `ToolAccessGrant` to avoid conflict with the existing `AccessGrant` in Channel.swift.
struct ToolAccessGrant: Codable, Sendable, Equatable, Hashable {
    var principal_type: String   // "user" or "group"
    var principal_id: String     // UUID or "*" for public
    var permission: String       // "read"

    init(principal_type: String = "user", principal_id: String, permission: String = "read") {
        self.principal_type = principal_type
        self.principal_id = principal_id
        self.permission = permission
    }

    /// Wildcard grant that makes a tool public.
    static let publicWildcard = ToolAccessGrant(principal_type: "user", principal_id: "*", permission: "read")
}

/// Info block embedded in a tool server connection.
struct ToolServerInfo: Codable, Sendable {
    var id: String?
    var name: String?
    var description: String?

    init(id: String? = nil, name: String? = nil, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// Config block embedded in a tool server connection.
struct ToolServerConnectionConfig: Codable, Sendable {
    var enable: Bool
    var function_name_filter_list: String?
    var access_grants: [ToolAccessGrant]

    init(enable: Bool = true, function_name_filter_list: String? = nil, access_grants: [ToolAccessGrant] = []) {
        self.enable = enable
        self.function_name_filter_list = function_name_filter_list
        self.access_grants = access_grants
    }

    /// Whether this tool is public (has wildcard grant).
    var isPublic: Bool {
        access_grants.contains { $0.principal_id == "*" }
    }

    /// Access grants excluding the wildcard.
    var specificGrants: [ToolAccessGrant] {
        access_grants.filter { $0.principal_id != "*" }
    }
}

/// A single tool server connection (OpenAPI or MCP).
struct ToolServerConnection: Codable, Sendable {
    var url: String
    var path: String
    var type: String?          // "openapi" or "mcp"
    var auth_type: String?     // "none", "bearer", "session", "oauth"
    var headers: AnyCodableValue?
    var key: String?
    var config: ToolServerConnectionConfig?
    var spec_type: String?     // "url" or "text"
    var spec: String?
    var info: ToolServerInfo?

    init(
        url: String = "",
        path: String = "openapi.json",
        type: String? = "openapi",
        auth_type: String? = "none",
        headers: AnyCodableValue? = nil,
        key: String? = "",
        config: ToolServerConnectionConfig? = ToolServerConnectionConfig(),
        spec_type: String? = "url",
        spec: String? = "",
        info: ToolServerInfo? = ToolServerInfo()
    ) {
        self.url = url
        self.path = path
        self.type = type
        self.auth_type = auth_type
        self.headers = headers
        self.key = key
        self.config = config
        self.spec_type = spec_type
        self.spec = spec
        self.info = info
    }

    /// Display name, falls back to URL.
    var displayName: String {
        info?.name?.isEmpty == false ? info!.name! : url
    }

    /// Display ID string.
    var displayId: String {
        info?.id ?? ""
    }
}

/// Top-level form for GET/POST `/api/v1/configs/tool_servers`.
struct ToolServersConfigForm: Codable, Sendable {
    var TOOL_SERVER_CONNECTIONS: [ToolServerConnection]

    init(TOOL_SERVER_CONNECTIONS: [ToolServerConnection] = []) {
        self.TOOL_SERVER_CONNECTIONS = TOOL_SERVER_CONNECTIONS
    }
}

// MARK: - Terminal Server Config

/// Config block embedded in a terminal server connection.
struct TerminalServerConnectionConfig: Codable, Sendable {
    var access_grants: [ToolAccessGrant]

    init(access_grants: [ToolAccessGrant] = []) {
        self.access_grants = access_grants
    }

    var isPublic: Bool {
        access_grants.contains { $0.principal_id == "*" }
    }

    var specificGrants: [ToolAccessGrant] {
        access_grants.filter { $0.principal_id != "*" }
    }
}

/// A single terminal server connection.
struct TerminalServerConnection: Codable, Sendable {
    var id: String?
    var name: String?
    var enabled: Bool?
    var url: String
    var path: String?
    var key: String?
    var auth_type: String?
    var config: TerminalServerConnectionConfig?

    init(
        id: String? = "",
        name: String? = "",
        enabled: Bool? = true,
        url: String = "",
        path: String? = "/openapi.json",
        key: String? = "",
        auth_type: String? = "bearer",
        config: TerminalServerConnectionConfig? = TerminalServerConnectionConfig()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.url = url
        self.path = path
        self.key = key
        self.auth_type = auth_type
        self.config = config
    }

    var displayName: String {
        name?.isEmpty == false ? name! : url
    }
}

/// Top-level form for GET/POST `/api/v1/configs/terminal_servers`.
struct TerminalServersConfigForm: Codable, Sendable {
    var TERMINAL_SERVER_CONNECTIONS: [TerminalServerConnection]

    init(TERMINAL_SERVER_CONNECTIONS: [TerminalServerConnection] = []) {
        self.TERMINAL_SERVER_CONNECTIONS = TERMINAL_SERVER_CONNECTIONS
    }
}

// MARK: - Group Response

/// Minimal group model for access control.
struct GroupResponse: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let member_count: Int?
}

/// A type-erased Codable value for arbitrary JSON (used for headers which can be dict, string, or null).
enum AnyCodableValue: Codable, Sendable {
    case dict([String: String])
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let dict = try? container.decode([String: String].self) {
            self = .dict(dict)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .dict(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .null: try container.encodeNil()
        }
    }

    var dictionaryValue: [String: String]? {
        if case .dict(let d) = self { return d }
        return nil
    }
}

// MARK: - MIME Type Helper

// MARK: - Retrieval / Documents Config

/// GET/POST `/api/v1/retrieval/config`
/// Keys are SCREAMING_SNAKE_CASE — must decode with a plain JSONDecoder (no .convertFromSnakeCase).
/// The `web` nested object is preserved but not edited in the Documents tab.
struct RetrievalConfig: Codable, Sendable {
    // General
    var contentExtractionEngine: String
    var pdfExtractImages: Bool
    var pdfLoaderMode: String
    var bypassEmbeddingAndRetrieval: Bool

    // External document loader
    var externalDocumentLoaderURL: String
    var externalDocumentLoaderAPIKey: String

    // Tika
    var tikaServerURL: String

    // Docling
    var doclingServerURL: String
    var doclingAPIKey: String
    var doclingParams: String // JSON string for the {} object

    // Datalab Marker
    var datalabMarkerAPIKey: String
    var datalabMarkerAPIBaseURL: String
    var datalabMarkerAdditionalConfig: String
    var datalabMarkerSkipCache: Bool
    var datalabMarkerForceOCR: Bool
    var datalabMarkerPaginate: Bool
    var datalabMarkerStripExistingOCR: Bool
    var datalabMarkerDisableImageExtraction: Bool
    var datalabMarkerFormatLines: Bool
    var datalabMarkerUseLLM: Bool
    var datalabMarkerOutputFormat: String

    // Document Intelligence
    var documentIntelligenceEndpoint: String
    var documentIntelligenceKey: String
    var documentIntelligenceModel: String

    // Mistral OCR
    var mistralOCRAPIBaseURL: String
    var mistralOCRAPIKey: String

    // MinerU
    var mineruAPIMode: String
    var mineruAPIURL: String
    var mineruAPIKey: String
    var mineruAPITimeout: String
    var mineruParams: String // JSON string for the {} object

    // Text Splitting
    var textSplitter: String
    var enableMarkdownHeaderTextSplitter: Bool
    var chunkSize: Int
    var chunkOverlap: Int
    var chunkMinSizeTarget: Int

    // Retrieval
    var ragFullContext: Bool
    var ragTemplate: String
    var topK: Int
    var relevanceThreshold: Double
    var enableRagHybridSearch: Bool
    var enableRagHybridSearchEnrichedTexts: Bool
    var topKReranker: Int
    var hybridBM25Weight: Double
    var ragRerankingModel: String
    var ragRerankingEngine: String
    var ragExternalRerankerURL: String
    var ragExternalRerankerAPIKey: String
    var ragExternalRerankerTimeout: String

    // Files
    var allowedFileExtensions: [String]
    var fileMaxSize: Int?
    var fileMaxCount: Int?
    var fileImageCompressionWidth: Int?
    var fileImageCompressionHeight: Int?

    // Integration
    var enableGoogleDriveIntegration: Bool
    var enableOneDriveIntegration: Bool

    // Web Search config (edited in the Web Search tab)
    var web: WebSearchConfig

    enum CodingKeys: String, CodingKey {
        case contentExtractionEngine = "CONTENT_EXTRACTION_ENGINE"
        case pdfExtractImages = "PDF_EXTRACT_IMAGES"
        case pdfLoaderMode = "PDF_LOADER_MODE"
        case bypassEmbeddingAndRetrieval = "BYPASS_EMBEDDING_AND_RETRIEVAL"
        case externalDocumentLoaderURL = "EXTERNAL_DOCUMENT_LOADER_URL"
        case externalDocumentLoaderAPIKey = "EXTERNAL_DOCUMENT_LOADER_API_KEY"
        case tikaServerURL = "TIKA_SERVER_URL"
        case doclingServerURL = "DOCLING_SERVER_URL"
        case doclingAPIKey = "DOCLING_API_KEY"
        case doclingParams = "DOCLING_PARAMS"
        case datalabMarkerAPIKey = "DATALAB_MARKER_API_KEY"
        case datalabMarkerAPIBaseURL = "DATALAB_MARKER_API_BASE_URL"
        case datalabMarkerAdditionalConfig = "DATALAB_MARKER_ADDITIONAL_CONFIG"
        case datalabMarkerSkipCache = "DATALAB_MARKER_SKIP_CACHE"
        case datalabMarkerForceOCR = "DATALAB_MARKER_FORCE_OCR"
        case datalabMarkerPaginate = "DATALAB_MARKER_PAGINATE"
        case datalabMarkerStripExistingOCR = "DATALAB_MARKER_STRIP_EXISTING_OCR"
        case datalabMarkerDisableImageExtraction = "DATALAB_MARKER_DISABLE_IMAGE_EXTRACTION"
        case datalabMarkerFormatLines = "DATALAB_MARKER_FORMAT_LINES"
        case datalabMarkerUseLLM = "DATALAB_MARKER_USE_LLM"
        case datalabMarkerOutputFormat = "DATALAB_MARKER_OUTPUT_FORMAT"
        case documentIntelligenceEndpoint = "DOCUMENT_INTELLIGENCE_ENDPOINT"
        case documentIntelligenceKey = "DOCUMENT_INTELLIGENCE_KEY"
        case documentIntelligenceModel = "DOCUMENT_INTELLIGENCE_MODEL"
        case mistralOCRAPIBaseURL = "MISTRAL_OCR_API_BASE_URL"
        case mistralOCRAPIKey = "MISTRAL_OCR_API_KEY"
        case mineruAPIMode = "MINERU_API_MODE"
        case mineruAPIURL = "MINERU_API_URL"
        case mineruAPIKey = "MINERU_API_KEY"
        case mineruAPITimeout = "MINERU_API_TIMEOUT"
        case mineruParams = "MINERU_PARAMS"
        case textSplitter = "TEXT_SPLITTER"
        case enableMarkdownHeaderTextSplitter = "ENABLE_MARKDOWN_HEADER_TEXT_SPLITTER"
        case chunkSize = "CHUNK_SIZE"
        case chunkOverlap = "CHUNK_OVERLAP"
        case chunkMinSizeTarget = "CHUNK_MIN_SIZE_TARGET"
        case ragFullContext = "RAG_FULL_CONTEXT"
        case ragTemplate = "RAG_TEMPLATE"
        case topK = "TOP_K"
        case relevanceThreshold = "RELEVANCE_THRESHOLD"
        case enableRagHybridSearch = "ENABLE_RAG_HYBRID_SEARCH"
        case enableRagHybridSearchEnrichedTexts = "ENABLE_RAG_HYBRID_SEARCH_ENRICHED_TEXTS"
        case topKReranker = "TOP_K_RERANKER"
        case hybridBM25Weight = "HYBRID_BM25_WEIGHT"
        case ragRerankingModel = "RAG_RERANKING_MODEL"
        case ragRerankingEngine = "RAG_RERANKING_ENGINE"
        case ragExternalRerankerURL = "RAG_EXTERNAL_RERANKER_URL"
        case ragExternalRerankerAPIKey = "RAG_EXTERNAL_RERANKER_API_KEY"
        case ragExternalRerankerTimeout = "RAG_EXTERNAL_RERANKER_TIMEOUT"
        case allowedFileExtensions = "ALLOWED_FILE_EXTENSIONS"
        case fileMaxSize = "FILE_MAX_SIZE"
        case fileMaxCount = "FILE_MAX_COUNT"
        case fileImageCompressionWidth = "FILE_IMAGE_COMPRESSION_WIDTH"
        case fileImageCompressionHeight = "FILE_IMAGE_COMPRESSION_HEIGHT"
        case enableGoogleDriveIntegration = "ENABLE_GOOGLE_DRIVE_INTEGRATION"
        case enableOneDriveIntegration = "ENABLE_ONEDRIVE_INTEGRATION"
        case web
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentExtractionEngine = (try? c.decode(String.self, forKey: .contentExtractionEngine)) ?? ""
        pdfExtractImages = (try? c.decode(Bool.self, forKey: .pdfExtractImages)) ?? true
        pdfLoaderMode = (try? c.decode(String.self, forKey: .pdfLoaderMode)) ?? "single"
        bypassEmbeddingAndRetrieval = (try? c.decode(Bool.self, forKey: .bypassEmbeddingAndRetrieval)) ?? false

        externalDocumentLoaderURL = (try? c.decode(String.self, forKey: .externalDocumentLoaderURL)) ?? ""
        externalDocumentLoaderAPIKey = (try? c.decode(String.self, forKey: .externalDocumentLoaderAPIKey)) ?? ""
        tikaServerURL = (try? c.decode(String.self, forKey: .tikaServerURL)) ?? ""
        doclingServerURL = (try? c.decode(String.self, forKey: .doclingServerURL)) ?? ""
        doclingAPIKey = (try? c.decode(String.self, forKey: .doclingAPIKey)) ?? ""
        // DOCLING_PARAMS can be an object — serialize to string
        if let paramsObj = try? c.decode([String: JSONAnyCodable].self, forKey: .doclingParams) {
            if let data = try? JSONSerialization.data(withJSONObject: paramsObj.mapValues { $0.value }, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                doclingParams = str
            } else { doclingParams = "{}" }
        } else {
            doclingParams = (try? c.decode(String.self, forKey: .doclingParams)) ?? "{}"
        }

        datalabMarkerAPIKey = (try? c.decode(String.self, forKey: .datalabMarkerAPIKey)) ?? ""
        datalabMarkerAPIBaseURL = (try? c.decode(String.self, forKey: .datalabMarkerAPIBaseURL)) ?? ""
        datalabMarkerAdditionalConfig = (try? c.decode(String.self, forKey: .datalabMarkerAdditionalConfig)) ?? ""
        datalabMarkerSkipCache = (try? c.decode(Bool.self, forKey: .datalabMarkerSkipCache)) ?? false
        datalabMarkerForceOCR = (try? c.decode(Bool.self, forKey: .datalabMarkerForceOCR)) ?? false
        datalabMarkerPaginate = (try? c.decode(Bool.self, forKey: .datalabMarkerPaginate)) ?? false
        datalabMarkerStripExistingOCR = (try? c.decode(Bool.self, forKey: .datalabMarkerStripExistingOCR)) ?? false
        datalabMarkerDisableImageExtraction = (try? c.decode(Bool.self, forKey: .datalabMarkerDisableImageExtraction)) ?? false
        datalabMarkerFormatLines = (try? c.decode(Bool.self, forKey: .datalabMarkerFormatLines)) ?? false
        datalabMarkerUseLLM = (try? c.decode(Bool.self, forKey: .datalabMarkerUseLLM)) ?? false
        datalabMarkerOutputFormat = (try? c.decode(String.self, forKey: .datalabMarkerOutputFormat)) ?? "markdown"

        documentIntelligenceEndpoint = (try? c.decode(String.self, forKey: .documentIntelligenceEndpoint)) ?? ""
        documentIntelligenceKey = (try? c.decode(String.self, forKey: .documentIntelligenceKey)) ?? ""
        documentIntelligenceModel = (try? c.decode(String.self, forKey: .documentIntelligenceModel)) ?? "prebuilt-layout"

        mistralOCRAPIBaseURL = (try? c.decode(String.self, forKey: .mistralOCRAPIBaseURL)) ?? "https://api.mistral.ai/v1"
        mistralOCRAPIKey = (try? c.decode(String.self, forKey: .mistralOCRAPIKey)) ?? ""

        mineruAPIMode = (try? c.decode(String.self, forKey: .mineruAPIMode)) ?? "local"
        mineruAPIURL = (try? c.decode(String.self, forKey: .mineruAPIURL)) ?? "http://localhost:8000"
        mineruAPIKey = (try? c.decode(String.self, forKey: .mineruAPIKey)) ?? ""
        mineruAPITimeout = (try? c.decode(String.self, forKey: .mineruAPITimeout)) ?? "300"
        // MINERU_PARAMS can be an object
        if let paramsObj = try? c.decode([String: JSONAnyCodable].self, forKey: .mineruParams) {
            if let data = try? JSONSerialization.data(withJSONObject: paramsObj.mapValues { $0.value }, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                mineruParams = str
            } else { mineruParams = "{}" }
        } else {
            mineruParams = (try? c.decode(String.self, forKey: .mineruParams)) ?? "{}"
        }

        textSplitter = (try? c.decode(String.self, forKey: .textSplitter)) ?? ""
        enableMarkdownHeaderTextSplitter = (try? c.decode(Bool.self, forKey: .enableMarkdownHeaderTextSplitter)) ?? false
        chunkSize = (try? c.decode(Int.self, forKey: .chunkSize)) ?? 1024
        chunkOverlap = (try? c.decode(Int.self, forKey: .chunkOverlap)) ?? 200
        chunkMinSizeTarget = (try? c.decode(Int.self, forKey: .chunkMinSizeTarget)) ?? 0

        ragFullContext = (try? c.decode(Bool.self, forKey: .ragFullContext)) ?? false
        ragTemplate = (try? c.decode(String.self, forKey: .ragTemplate)) ?? ""
        topK = (try? c.decode(Int.self, forKey: .topK)) ?? 10
        relevanceThreshold = (try? c.decode(Double.self, forKey: .relevanceThreshold)) ?? 0.0
        enableRagHybridSearch = (try? c.decode(Bool.self, forKey: .enableRagHybridSearch)) ?? false
        enableRagHybridSearchEnrichedTexts = (try? c.decode(Bool.self, forKey: .enableRagHybridSearchEnrichedTexts)) ?? false
        topKReranker = (try? c.decode(Int.self, forKey: .topKReranker)) ?? 5
        hybridBM25Weight = (try? c.decode(Double.self, forKey: .hybridBM25Weight)) ?? 0.5
        ragRerankingModel = (try? c.decode(String.self, forKey: .ragRerankingModel)) ?? ""
        ragRerankingEngine = (try? c.decode(String.self, forKey: .ragRerankingEngine)) ?? ""
        ragExternalRerankerURL = (try? c.decode(String.self, forKey: .ragExternalRerankerURL)) ?? ""
        ragExternalRerankerAPIKey = (try? c.decode(String.self, forKey: .ragExternalRerankerAPIKey)) ?? ""
        ragExternalRerankerTimeout = (try? c.decode(String.self, forKey: .ragExternalRerankerTimeout)) ?? ""

        allowedFileExtensions = (try? c.decode([String].self, forKey: .allowedFileExtensions)) ?? []
        fileMaxSize = try? c.decode(Int.self, forKey: .fileMaxSize)
        fileMaxCount = try? c.decode(Int.self, forKey: .fileMaxCount)
        fileImageCompressionWidth = try? c.decode(Int.self, forKey: .fileImageCompressionWidth)
        fileImageCompressionHeight = try? c.decode(Int.self, forKey: .fileImageCompressionHeight)

        enableGoogleDriveIntegration = (try? c.decode(Bool.self, forKey: .enableGoogleDriveIntegration)) ?? false
        enableOneDriveIntegration = (try? c.decode(Bool.self, forKey: .enableOneDriveIntegration)) ?? false

        web = (try? c.decode(WebSearchConfig.self, forKey: .web)) ?? WebSearchConfig()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contentExtractionEngine, forKey: .contentExtractionEngine)
        try c.encode(pdfExtractImages, forKey: .pdfExtractImages)
        try c.encode(pdfLoaderMode, forKey: .pdfLoaderMode)
        try c.encode(bypassEmbeddingAndRetrieval, forKey: .bypassEmbeddingAndRetrieval)
        try c.encode(externalDocumentLoaderURL, forKey: .externalDocumentLoaderURL)
        try c.encode(externalDocumentLoaderAPIKey, forKey: .externalDocumentLoaderAPIKey)
        try c.encode(tikaServerURL, forKey: .tikaServerURL)
        try c.encode(doclingServerURL, forKey: .doclingServerURL)
        try c.encode(doclingAPIKey, forKey: .doclingAPIKey)
        // Encode DOCLING_PARAMS as JSON object
        if let data = doclingParams.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try c.encode(obj.mapValues { JSONAnyCodable($0) }, forKey: .doclingParams)
        } else {
            try c.encode([String: JSONAnyCodable](), forKey: .doclingParams)
        }
        try c.encode(datalabMarkerAPIKey, forKey: .datalabMarkerAPIKey)
        try c.encode(datalabMarkerAPIBaseURL, forKey: .datalabMarkerAPIBaseURL)
        try c.encode(datalabMarkerAdditionalConfig, forKey: .datalabMarkerAdditionalConfig)
        try c.encode(datalabMarkerSkipCache, forKey: .datalabMarkerSkipCache)
        try c.encode(datalabMarkerForceOCR, forKey: .datalabMarkerForceOCR)
        try c.encode(datalabMarkerPaginate, forKey: .datalabMarkerPaginate)
        try c.encode(datalabMarkerStripExistingOCR, forKey: .datalabMarkerStripExistingOCR)
        try c.encode(datalabMarkerDisableImageExtraction, forKey: .datalabMarkerDisableImageExtraction)
        try c.encode(datalabMarkerFormatLines, forKey: .datalabMarkerFormatLines)
        try c.encode(datalabMarkerUseLLM, forKey: .datalabMarkerUseLLM)
        try c.encode(datalabMarkerOutputFormat, forKey: .datalabMarkerOutputFormat)
        try c.encode(documentIntelligenceEndpoint, forKey: .documentIntelligenceEndpoint)
        try c.encode(documentIntelligenceKey, forKey: .documentIntelligenceKey)
        try c.encode(documentIntelligenceModel, forKey: .documentIntelligenceModel)
        try c.encode(mistralOCRAPIBaseURL, forKey: .mistralOCRAPIBaseURL)
        try c.encode(mistralOCRAPIKey, forKey: .mistralOCRAPIKey)
        try c.encode(mineruAPIMode, forKey: .mineruAPIMode)
        try c.encode(mineruAPIURL, forKey: .mineruAPIURL)
        try c.encode(mineruAPIKey, forKey: .mineruAPIKey)
        try c.encode(mineruAPITimeout, forKey: .mineruAPITimeout)
        // Encode MINERU_PARAMS as JSON object
        if let data = mineruParams.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try c.encode(obj.mapValues { JSONAnyCodable($0) }, forKey: .mineruParams)
        } else {
            try c.encode([String: JSONAnyCodable](), forKey: .mineruParams)
        }
        try c.encode(textSplitter, forKey: .textSplitter)
        try c.encode(enableMarkdownHeaderTextSplitter, forKey: .enableMarkdownHeaderTextSplitter)
        try c.encode(chunkSize, forKey: .chunkSize)
        try c.encode(chunkOverlap, forKey: .chunkOverlap)
        try c.encode(chunkMinSizeTarget, forKey: .chunkMinSizeTarget)
        try c.encode(ragFullContext, forKey: .ragFullContext)
        try c.encode(ragTemplate, forKey: .ragTemplate)
        try c.encode(topK, forKey: .topK)
        try c.encode(relevanceThreshold, forKey: .relevanceThreshold)
        try c.encode(enableRagHybridSearch, forKey: .enableRagHybridSearch)
        try c.encode(enableRagHybridSearchEnrichedTexts, forKey: .enableRagHybridSearchEnrichedTexts)
        try c.encode(topKReranker, forKey: .topKReranker)
        try c.encode(hybridBM25Weight, forKey: .hybridBM25Weight)
        try c.encode(ragRerankingModel, forKey: .ragRerankingModel)
        try c.encode(ragRerankingEngine, forKey: .ragRerankingEngine)
        try c.encode(ragExternalRerankerURL, forKey: .ragExternalRerankerURL)
        try c.encode(ragExternalRerankerAPIKey, forKey: .ragExternalRerankerAPIKey)
        try c.encode(ragExternalRerankerTimeout, forKey: .ragExternalRerankerTimeout)
        try c.encode(allowedFileExtensions, forKey: .allowedFileExtensions)
        try c.encode(fileMaxSize, forKey: .fileMaxSize)
        try c.encode(fileMaxCount, forKey: .fileMaxCount)
        try c.encode(fileImageCompressionWidth, forKey: .fileImageCompressionWidth)
        try c.encode(fileImageCompressionHeight, forKey: .fileImageCompressionHeight)
        try c.encode(enableGoogleDriveIntegration, forKey: .enableGoogleDriveIntegration)
        try c.encode(enableOneDriveIntegration, forKey: .enableOneDriveIntegration)
        try c.encode(web, forKey: .web)
    }

    init() {
        contentExtractionEngine = ""
        pdfExtractImages = true
        pdfLoaderMode = "single"
        bypassEmbeddingAndRetrieval = false
        externalDocumentLoaderURL = ""
        externalDocumentLoaderAPIKey = ""
        tikaServerURL = ""
        doclingServerURL = ""
        doclingAPIKey = ""
        doclingParams = "{}"
        datalabMarkerAPIKey = ""
        datalabMarkerAPIBaseURL = ""
        datalabMarkerAdditionalConfig = ""
        datalabMarkerSkipCache = false
        datalabMarkerForceOCR = false
        datalabMarkerPaginate = false
        datalabMarkerStripExistingOCR = false
        datalabMarkerDisableImageExtraction = false
        datalabMarkerFormatLines = false
        datalabMarkerUseLLM = false
        datalabMarkerOutputFormat = "markdown"
        documentIntelligenceEndpoint = ""
        documentIntelligenceKey = ""
        documentIntelligenceModel = "prebuilt-layout"
        mistralOCRAPIBaseURL = "https://api.mistral.ai/v1"
        mistralOCRAPIKey = ""
        mineruAPIMode = "local"
        mineruAPIURL = "http://localhost:8000"
        mineruAPIKey = ""
        mineruAPITimeout = "300"
        mineruParams = "{}"
        textSplitter = ""
        enableMarkdownHeaderTextSplitter = false
        chunkSize = 1024
        chunkOverlap = 200
        chunkMinSizeTarget = 0
        ragFullContext = false
        ragTemplate = ""
        topK = 10
        relevanceThreshold = 0.0
        enableRagHybridSearch = false
        enableRagHybridSearchEnrichedTexts = false
        topKReranker = 5
        hybridBM25Weight = 0.5
        ragRerankingModel = ""
        ragRerankingEngine = ""
        ragExternalRerankerURL = ""
        ragExternalRerankerAPIKey = ""
        ragExternalRerankerTimeout = ""
        allowedFileExtensions = []
        fileMaxSize = nil
        fileMaxCount = nil
        fileImageCompressionWidth = nil
        fileImageCompressionHeight = nil
        enableGoogleDriveIntegration = false
        enableOneDriveIntegration = false
        web = WebSearchConfig()
    }
}

/// Type-erased Codable wrapper for pass-through JSON values (supports nested arrays/dicts).
/// Named `JSONAnyCodable` to avoid conflict with the simpler `AnyCodable` in AdminUser.swift.
struct JSONAnyCodable: Codable, Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let arr = try? container.decode([JSONAnyCodable].self) { value = arr.map(\.value) }
        else if let dict = try? container.decode([String: JSONAnyCodable].self) { value = dict.mapValues(\.value) }
        else if container.decodeNil() { value = NSNull() }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let arr as [Any]: try container.encode(arr.map { JSONAnyCodable($0) })
        case let dict as [String: Any]: try container.encode(dict.mapValues { JSONAnyCodable($0) })
        case is NSNull: try container.encodeNil()
        default: try container.encodeNil()
        }
    }
}

// MARK: - Embedding Config

/// Nested engine config for embedding endpoints.
struct EmbeddingEngineSubConfig: Codable, Sendable {
    var url: String
    var key: String

    init(url: String = "", key: String = "") {
        self.url = url
        self.key = key
    }
}

/// Azure variant with an extra `version` field.
struct AzureEmbeddingSubConfig: Codable, Sendable {
    var url: String
    var key: String
    var version: String

    init(url: String = "", key: String = "", version: String = "") {
        self.url = url
        self.key = key
        self.version = version
    }
}

/// GET/POST `/api/v1/retrieval/embedding`
/// Top-level keys are SCREAMING_SNAKE_CASE; nested configs are lowercase.
struct EmbeddingConfig: Codable, Sendable {
    var ragEmbeddingEngine: String
    var ragEmbeddingModel: String
    var ragEmbeddingBatchSize: Int
    var enableAsyncEmbedding: Bool
    var ragEmbeddingConcurrentRequests: Int
    var openaiConfig: EmbeddingEngineSubConfig
    var ollamaConfig: EmbeddingEngineSubConfig
    var azureOpenAIConfig: AzureEmbeddingSubConfig

    enum CodingKeys: String, CodingKey {
        case ragEmbeddingEngine = "RAG_EMBEDDING_ENGINE"
        case ragEmbeddingModel = "RAG_EMBEDDING_MODEL"
        case ragEmbeddingBatchSize = "RAG_EMBEDDING_BATCH_SIZE"
        case enableAsyncEmbedding = "ENABLE_ASYNC_EMBEDDING"
        case ragEmbeddingConcurrentRequests = "RAG_EMBEDDING_CONCURRENT_REQUESTS"
        case openaiConfig = "openai_config"
        case ollamaConfig = "ollama_config"
        case azureOpenAIConfig = "azure_openai_config"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ragEmbeddingEngine = (try? c.decode(String.self, forKey: .ragEmbeddingEngine)) ?? ""
        ragEmbeddingModel = (try? c.decode(String.self, forKey: .ragEmbeddingModel)) ?? ""
        ragEmbeddingBatchSize = (try? c.decode(Int.self, forKey: .ragEmbeddingBatchSize)) ?? 64
        enableAsyncEmbedding = (try? c.decode(Bool.self, forKey: .enableAsyncEmbedding)) ?? true
        ragEmbeddingConcurrentRequests = (try? c.decode(Int.self, forKey: .ragEmbeddingConcurrentRequests)) ?? 0
        openaiConfig = (try? c.decode(EmbeddingEngineSubConfig.self, forKey: .openaiConfig)) ?? EmbeddingEngineSubConfig()
        ollamaConfig = (try? c.decode(EmbeddingEngineSubConfig.self, forKey: .ollamaConfig)) ?? EmbeddingEngineSubConfig()
        azureOpenAIConfig = (try? c.decode(AzureEmbeddingSubConfig.self, forKey: .azureOpenAIConfig)) ?? AzureEmbeddingSubConfig()
    }

    init() {
        ragEmbeddingEngine = ""
        ragEmbeddingModel = ""
        ragEmbeddingBatchSize = 64
        enableAsyncEmbedding = true
        ragEmbeddingConcurrentRequests = 0
        openaiConfig = EmbeddingEngineSubConfig()
        ollamaConfig = EmbeddingEngineSubConfig()
        azureOpenAIConfig = AzureEmbeddingSubConfig()
    }
}

// MARK: - Group Models (Admin)

/// The sharing permission for a group ("no_one", "members", "anyone").
enum GroupSharePermission: String, Codable, CaseIterable, Sendable {
    case noOne = "no_one"
    case members = "members"
    case anyone = "anyone"

    var displayName: String {
        switch self {
        case .noOne: return "No one"
        case .members: return "Members"
        case .anyone: return "Anyone"
        }
    }
}

/// Workspace-level permissions within a group.
struct GroupWorkspacePermissions: Codable, Sendable {
    var models: Bool
    var knowledge: Bool
    var prompts: Bool
    var tools: Bool
    var skills: Bool
    var modelsImport: Bool
    var modelsExport: Bool
    var promptsImport: Bool
    var promptsExport: Bool
    var toolsImport: Bool
    var toolsExport: Bool

    enum CodingKeys: String, CodingKey {
        case models, knowledge, prompts, tools, skills
        case modelsImport = "models_import"
        case modelsExport = "models_export"
        case promptsImport = "prompts_import"
        case promptsExport = "prompts_export"
        case toolsImport = "tools_import"
        case toolsExport = "tools_export"
    }

    init(models: Bool = true, knowledge: Bool = true, prompts: Bool = false, tools: Bool = false,
         skills: Bool = false, modelsImport: Bool = false, modelsExport: Bool = false,
         promptsImport: Bool = false, promptsExport: Bool = false,
         toolsImport: Bool = false, toolsExport: Bool = false) {
        self.models = models; self.knowledge = knowledge; self.prompts = prompts
        self.tools = tools; self.skills = skills; self.modelsImport = modelsImport
        self.modelsExport = modelsExport; self.promptsImport = promptsImport
        self.promptsExport = promptsExport; self.toolsImport = toolsImport
        self.toolsExport = toolsExport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = (try? c.decode(Bool.self, forKey: .models)) ?? true
        knowledge = (try? c.decode(Bool.self, forKey: .knowledge)) ?? true
        prompts = (try? c.decode(Bool.self, forKey: .prompts)) ?? false
        tools = (try? c.decode(Bool.self, forKey: .tools)) ?? false
        skills = (try? c.decode(Bool.self, forKey: .skills)) ?? false
        modelsImport = (try? c.decode(Bool.self, forKey: .modelsImport)) ?? false
        modelsExport = (try? c.decode(Bool.self, forKey: .modelsExport)) ?? false
        promptsImport = (try? c.decode(Bool.self, forKey: .promptsImport)) ?? false
        promptsExport = (try? c.decode(Bool.self, forKey: .promptsExport)) ?? false
        toolsImport = (try? c.decode(Bool.self, forKey: .toolsImport)) ?? false
        toolsExport = (try? c.decode(Bool.self, forKey: .toolsExport)) ?? false
    }
}

/// Sharing-level permissions within a group.
struct GroupSharingPermissions: Codable, Sendable {
    var models: Bool
    var publicModels: Bool
    var knowledge: Bool
    var publicKnowledge: Bool
    var prompts: Bool
    var publicPrompts: Bool
    var tools: Bool
    var publicTools: Bool
    var skills: Bool
    var publicSkills: Bool
    var notes: Bool
    var publicNotes: Bool

    enum CodingKeys: String, CodingKey {
        case models, knowledge, prompts, tools, skills, notes
        case publicModels = "public_models"
        case publicKnowledge = "public_knowledge"
        case publicPrompts = "public_prompts"
        case publicTools = "public_tools"
        case publicSkills = "public_skills"
        case publicNotes = "public_notes"
    }

    init(models: Bool = false, publicModels: Bool = false, knowledge: Bool = false,
         publicKnowledge: Bool = false, prompts: Bool = false, publicPrompts: Bool = false,
         tools: Bool = false, publicTools: Bool = false, skills: Bool = false,
         publicSkills: Bool = false, notes: Bool = false, publicNotes: Bool = false) {
        self.models = models; self.publicModels = publicModels; self.knowledge = knowledge
        self.publicKnowledge = publicKnowledge; self.prompts = prompts; self.publicPrompts = publicPrompts
        self.tools = tools; self.publicTools = publicTools; self.skills = skills
        self.publicSkills = publicSkills; self.notes = notes; self.publicNotes = publicNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = (try? c.decode(Bool.self, forKey: .models)) ?? false
        publicModels = (try? c.decode(Bool.self, forKey: .publicModels)) ?? false
        knowledge = (try? c.decode(Bool.self, forKey: .knowledge)) ?? false
        publicKnowledge = (try? c.decode(Bool.self, forKey: .publicKnowledge)) ?? false
        prompts = (try? c.decode(Bool.self, forKey: .prompts)) ?? false
        publicPrompts = (try? c.decode(Bool.self, forKey: .publicPrompts)) ?? false
        tools = (try? c.decode(Bool.self, forKey: .tools)) ?? false
        publicTools = (try? c.decode(Bool.self, forKey: .publicTools)) ?? false
        skills = (try? c.decode(Bool.self, forKey: .skills)) ?? false
        publicSkills = (try? c.decode(Bool.self, forKey: .publicSkills)) ?? false
        notes = (try? c.decode(Bool.self, forKey: .notes)) ?? false
        publicNotes = (try? c.decode(Bool.self, forKey: .publicNotes)) ?? false
    }
}

/// Access-grant permissions.
struct GroupAccessGrantPermissions: Codable, Sendable {
    var allowUsers: Bool

    enum CodingKeys: String, CodingKey {
        case allowUsers = "allow_users"
    }

    init(allowUsers: Bool = true) { self.allowUsers = allowUsers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowUsers = (try? c.decode(Bool.self, forKey: .allowUsers)) ?? true
    }
}

/// Chat-level permissions within a group.
struct GroupChatPermissions: Codable, Sendable {
    var controls: Bool
    var valves: Bool
    var systemPrompt: Bool
    var params: Bool
    var fileUpload: Bool
    var webUpload: Bool
    var delete: Bool
    var deleteMessage: Bool
    var continueResponse: Bool
    var regenerateResponse: Bool
    var rateResponse: Bool
    var edit: Bool
    var share: Bool
    var export: Bool
    var stt: Bool
    var tts: Bool
    var call: Bool
    var multipleModels: Bool
    var temporary: Bool
    var temporaryEnforced: Bool

    enum CodingKeys: String, CodingKey {
        case controls, valves, params, edit, share, export, stt, tts, call, temporary
        case systemPrompt = "system_prompt"
        case fileUpload = "file_upload"
        case webUpload = "web_upload"
        case delete
        case deleteMessage = "delete_message"
        case continueResponse = "continue_response"
        case regenerateResponse = "regenerate_response"
        case rateResponse = "rate_response"
        case multipleModels = "multiple_models"
        case temporaryEnforced = "temporary_enforced"
    }

    init(controls: Bool = true, valves: Bool = true, systemPrompt: Bool = true, params: Bool = true,
         fileUpload: Bool = true, webUpload: Bool = true, delete: Bool = true,
         deleteMessage: Bool = true, continueResponse: Bool = true, regenerateResponse: Bool = true,
         rateResponse: Bool = true, edit: Bool = true, share: Bool = true, export: Bool = true,
         stt: Bool = true, tts: Bool = true, call: Bool = true, multipleModels: Bool = true,
         temporary: Bool = true, temporaryEnforced: Bool = false) {
        self.controls = controls; self.valves = valves; self.systemPrompt = systemPrompt
        self.params = params; self.fileUpload = fileUpload; self.webUpload = webUpload
        self.delete = delete; self.deleteMessage = deleteMessage
        self.continueResponse = continueResponse; self.regenerateResponse = regenerateResponse
        self.rateResponse = rateResponse; self.edit = edit; self.share = share; self.export = export
        self.stt = stt; self.tts = tts; self.call = call; self.multipleModels = multipleModels
        self.temporary = temporary; self.temporaryEnforced = temporaryEnforced
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controls = (try? c.decode(Bool.self, forKey: .controls)) ?? true
        valves = (try? c.decode(Bool.self, forKey: .valves)) ?? true
        systemPrompt = (try? c.decode(Bool.self, forKey: .systemPrompt)) ?? true
        params = (try? c.decode(Bool.self, forKey: .params)) ?? true
        fileUpload = (try? c.decode(Bool.self, forKey: .fileUpload)) ?? true
        webUpload = (try? c.decode(Bool.self, forKey: .webUpload)) ?? true
        delete = (try? c.decode(Bool.self, forKey: .delete)) ?? true
        deleteMessage = (try? c.decode(Bool.self, forKey: .deleteMessage)) ?? true
        continueResponse = (try? c.decode(Bool.self, forKey: .continueResponse)) ?? true
        regenerateResponse = (try? c.decode(Bool.self, forKey: .regenerateResponse)) ?? true
        rateResponse = (try? c.decode(Bool.self, forKey: .rateResponse)) ?? true
        edit = (try? c.decode(Bool.self, forKey: .edit)) ?? true
        share = (try? c.decode(Bool.self, forKey: .share)) ?? true
        export = (try? c.decode(Bool.self, forKey: .export)) ?? true
        stt = (try? c.decode(Bool.self, forKey: .stt)) ?? true
        tts = (try? c.decode(Bool.self, forKey: .tts)) ?? true
        call = (try? c.decode(Bool.self, forKey: .call)) ?? true
        multipleModels = (try? c.decode(Bool.self, forKey: .multipleModels)) ?? true
        temporary = (try? c.decode(Bool.self, forKey: .temporary)) ?? true
        temporaryEnforced = (try? c.decode(Bool.self, forKey: .temporaryEnforced)) ?? false
    }
}

/// Feature permissions within a group.
struct GroupFeaturePermissions: Codable, Sendable {
    var apiKeys: Bool
    var notes: Bool
    var channels: Bool
    var folders: Bool
    var directToolServers: Bool
    var webSearch: Bool
    var imageGeneration: Bool
    var codeInterpreter: Bool
    var memories: Bool

    enum CodingKeys: String, CodingKey {
        case notes, channels, folders, memories
        case apiKeys = "api_keys"
        case directToolServers = "direct_tool_servers"
        case webSearch = "web_search"
        case imageGeneration = "image_generation"
        case codeInterpreter = "code_interpreter"
    }

    init(apiKeys: Bool = false, notes: Bool = true, channels: Bool = true, folders: Bool = true,
         directToolServers: Bool = false, webSearch: Bool = true, imageGeneration: Bool = true,
         codeInterpreter: Bool = false, memories: Bool = true) {
        self.apiKeys = apiKeys; self.notes = notes; self.channels = channels
        self.folders = folders; self.directToolServers = directToolServers
        self.webSearch = webSearch; self.imageGeneration = imageGeneration
        self.codeInterpreter = codeInterpreter; self.memories = memories
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKeys = (try? c.decode(Bool.self, forKey: .apiKeys)) ?? false
        notes = (try? c.decode(Bool.self, forKey: .notes)) ?? true
        channels = (try? c.decode(Bool.self, forKey: .channels)) ?? true
        folders = (try? c.decode(Bool.self, forKey: .folders)) ?? true
        directToolServers = (try? c.decode(Bool.self, forKey: .directToolServers)) ?? false
        webSearch = (try? c.decode(Bool.self, forKey: .webSearch)) ?? true
        imageGeneration = (try? c.decode(Bool.self, forKey: .imageGeneration)) ?? true
        codeInterpreter = (try? c.decode(Bool.self, forKey: .codeInterpreter)) ?? false
        memories = (try? c.decode(Bool.self, forKey: .memories)) ?? true
    }
}

/// Settings permissions within a group.
struct GroupSettingsPermissions: Codable, Sendable {
    var interface: Bool

    init(interface: Bool = true) { self.interface = interface }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interface = (try? c.decode(Bool.self, forKey: .interface)) ?? true
    }

    enum CodingKeys: String, CodingKey { case interface }
}

/// Top-level permissions object used in group create/update/default permissions.
struct GroupPermissions: Codable, Sendable {
    var workspace: GroupWorkspacePermissions
    var sharing: GroupSharingPermissions
    var accessGrants: GroupAccessGrantPermissions
    var chat: GroupChatPermissions
    var features: GroupFeaturePermissions
    var settings: GroupSettingsPermissions

    enum CodingKeys: String, CodingKey {
        case workspace, sharing, chat, features, settings
        case accessGrants = "access_grants"
    }

    init(workspace: GroupWorkspacePermissions = GroupWorkspacePermissions(),
         sharing: GroupSharingPermissions = GroupSharingPermissions(),
         accessGrants: GroupAccessGrantPermissions = GroupAccessGrantPermissions(),
         chat: GroupChatPermissions = GroupChatPermissions(),
         features: GroupFeaturePermissions = GroupFeaturePermissions(),
         settings: GroupSettingsPermissions = GroupSettingsPermissions()) {
        self.workspace = workspace; self.sharing = sharing; self.accessGrants = accessGrants
        self.chat = chat; self.features = features; self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspace = (try? c.decode(GroupWorkspacePermissions.self, forKey: .workspace)) ?? GroupWorkspacePermissions()
        sharing = (try? c.decode(GroupSharingPermissions.self, forKey: .sharing)) ?? GroupSharingPermissions()
        accessGrants = (try? c.decode(GroupAccessGrantPermissions.self, forKey: .accessGrants)) ?? GroupAccessGrantPermissions()
        chat = (try? c.decode(GroupChatPermissions.self, forKey: .chat)) ?? GroupChatPermissions()
        features = (try? c.decode(GroupFeaturePermissions.self, forKey: .features)) ?? GroupFeaturePermissions()
        settings = (try? c.decode(GroupSettingsPermissions.self, forKey: .settings)) ?? GroupSettingsPermissions()
    }
}

/// The `data` field of a group, contains config like share permission.
struct GroupData: Codable, Sendable {
    var config: GroupDataConfig?

    init(config: GroupDataConfig? = nil) { self.config = config }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try? c.decodeIfPresent(GroupDataConfig.self, forKey: .config)
    }

    enum CodingKeys: String, CodingKey { case config }
}

struct GroupDataConfig: Codable, Sendable {
    var share: String?

    init(share: String? = "members") { self.share = share }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        share = try? c.decodeIfPresent(String.self, forKey: .share)
    }

    enum CodingKeys: String, CodingKey { case share }
}

/// Full group detail returned by `GET /api/v1/groups/` and related endpoints.
struct GroupDetail: Codable, Identifiable, Sendable {
    let id: String
    let userId: String
    var name: String
    var description: String
    var data: GroupData?
    var permissions: GroupPermissions?
    let createdAt: Int
    let updatedAt: Int
    var memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, description, data, permissions
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case memberCount = "member_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        userId = (try? c.decode(String.self, forKey: .userId)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        data = try? c.decodeIfPresent(GroupData.self, forKey: .data)
        permissions = try? c.decodeIfPresent(GroupPermissions.self, forKey: .permissions)
        if let ts = try? c.decode(Int.self, forKey: .createdAt) { createdAt = ts }
        else if let ts = try? c.decode(Double.self, forKey: .createdAt) { createdAt = Int(ts) }
        else { createdAt = 0 }
        if let ts = try? c.decode(Int.self, forKey: .updatedAt) { updatedAt = ts }
        else if let ts = try? c.decode(Double.self, forKey: .updatedAt) { updatedAt = Int(ts) }
        else { updatedAt = 0 }
        memberCount = try? c.decodeIfPresent(Int.self, forKey: .memberCount)
    }
}

/// Form for creating or updating a group.
struct GroupForm: Codable, Sendable {
    var name: String
    var description: String
    var permissions: GroupPermissions?
    var data: GroupData?

    init(name: String, description: String, permissions: GroupPermissions? = nil, data: GroupData? = nil) {
        self.name = name; self.description = description
        self.permissions = permissions; self.data = data
    }
}

/// Form to add/remove users from a group.
struct UserIdsForm: Codable, Sendable {
    let userIds: [String]

    enum CodingKeys: String, CodingKey {
        case userIds = "user_ids"
    }
}

/// Returns the MIME type for a given file extension.
func mimeType(for fileName: String) -> String {
    let ext = (fileName as NSString).pathExtension.lowercased()
    switch ext {
    case "m4a": return "audio/mp4"
    case "mp3": return "audio/mpeg"
    case "wav": return "audio/wav"
    case "aac": return "audio/aac"
    case "ogg": return "audio/ogg"
    case "webm": return "audio/webm"
    case "mp4": return "video/mp4"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic", "heif": return "image/jpeg" // Converted to JPEG before upload
    case "dng", "raw", "arw", "cr2", "cr3", "nef", "orf", "raf", "rw2": return "image/jpeg"
    case "pdf": return "application/pdf"
    case "txt": return "text/plain"
    case "json": return "application/json"
    default: return "application/octet-stream"
    }
}
