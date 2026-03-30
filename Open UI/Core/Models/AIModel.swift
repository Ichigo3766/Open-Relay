import Foundation

// MARK: - Action Button Info (attached to a model)

/// Describes a single action button configured on a model.
/// Parsed from the `actions` array in the model JSON payload.
/// Example: `{"id": "generate_image", "name": "Generate Image", "description": "...", "icon": "data:image/svg+xml;base64,..."}`
struct AIModelAction: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    /// SVG icon as a data URI (`data:image/svg+xml;base64,...`) or an HTTP URL.
    let icon: String?

    init(id: String, name: String, description: String = "", icon: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        self.name = json["name"] as? String ?? id
        self.description = json["description"] as? String ?? ""
        self.icon = json["icon"] as? String
    }
}

/// Metadata about an AI model available on an OpenWebUI server.
struct AIModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String?
    var isMultimodal: Bool
    var supportsStreaming: Bool
    var supportsRAG: Bool
    var contextLength: Int?
    var capabilities: [String: String]?
    var profileImageURL: String?
    var toolIds: [String]
    /// Feature IDs that should be enabled by default for this model.
    /// Set by admin in the model editor (e.g., `["web_search", "image_generation"]`).
    var defaultFeatureIds: [String]
    /// The function calling mode configured for this model by the admin.
    /// Values: `"native"` for native tool calling, `nil`/absent for default (server-handled).
    /// Sourced from `info.params.function_calling` in the OpenWebUI model payload.
    var functionCallingMode: String?
    /// Builtin tools enabled for this model by the admin.
    /// Keys match OpenWebUI's `meta.builtinTools` object (e.g. `"memory"`, `"time"`,
    /// `"web_search"`, `"image_generation"`, `"code_interpreter"`, etc.).
    /// A `true` value means the tool is available; `false` means it's disabled.
    var builtinTools: [String: Bool]
    /// Tag names extracted from the server's `tags` array (e.g. `["OpenRou", "External"]`).
    /// Used to drive the tag-filter pills in the model selector sheet.
    var tags: [String]
    /// The connection type for this model (e.g. `"external"`, `"internal"`).
    /// Sourced from `connection_type` in the OpenWebUI model payload.
    var connectionType: String?
    /// Whether this is a pipe/function model.
    /// Pipe models require `model_item` + `params`/`tool_servers`/`features`/`variables`
    /// to be sent unconditionally in every request — even when empty — so the backend
    /// pipe function can route the request correctly. Without these fields the backend
    /// hangs waiting for a Redis async task that never completes (~60s timeout).
    var isPipeModel: Bool
    /// Filter IDs associated with this model. Extracted from `filters[*].id` in the
    /// OpenWebUI model payload. Sent as `filter_ids` in chat completion requests so
    /// the backend runs the correct filter pipeline for this model.
    var filterIds: [String]
    /// Raw action IDs from the model's `meta.actionIds` field. Used to resolve
    /// which action functions should show for this model when combined with
    /// global action function state.
    var actionIds: [String]
    /// Action buttons configured for this model. Parsed from `actions` array in
    /// the model payload or resolved from `actionIds` + global function state.
    /// Each entry describes a function-based action button (icon, name, description)
    /// that should appear in the assistant message action bar.
    var actions: [AIModelAction]
    /// Per-model suggestion prompts configured by the admin in the model editor.
    /// Used as a fallback when no admin-level `default_prompt_suggestions` are set.
    /// Format matches `BackendConfig.PromptSuggestion`: `{"title": ["...", "..."], "content": "..."}`.
    var suggestionPrompts: [BackendConfig.PromptSuggestion]
    /// The full raw model JSON from the server. Sent as `model_item` in chat completion
    /// requests for pipe models so the backend can route to the correct pipe function.
    /// Stored as `[String: Any]` (non-Codable) and excluded from Codable synthesis.
    var rawModelItem: [String: Any]?

    init(
        id: String,
        name: String,
        description: String? = nil,
        isMultimodal: Bool = false,
        supportsStreaming: Bool = true,
        supportsRAG: Bool = false,
        contextLength: Int? = nil,
        capabilities: [String: String]? = nil,
        profileImageURL: String? = nil,
        toolIds: [String] = [],
        defaultFeatureIds: [String] = [],
        functionCallingMode: String? = nil,
        builtinTools: [String: Bool] = [:],
        tags: [String] = [],
        connectionType: String? = nil,
        isPipeModel: Bool = false,
        filterIds: [String] = [],
        actionIds: [String] = [],
        actions: [AIModelAction] = [],
        suggestionPrompts: [BackendConfig.PromptSuggestion] = [],
        rawModelItem: [String: Any]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isMultimodal = isMultimodal
        self.supportsStreaming = supportsStreaming
        self.supportsRAG = supportsRAG
        self.contextLength = contextLength
        self.capabilities = capabilities
        self.profileImageURL = profileImageURL
        self.toolIds = toolIds
        self.defaultFeatureIds = defaultFeatureIds
        self.functionCallingMode = functionCallingMode
        self.builtinTools = builtinTools
        self.tags = tags
        self.connectionType = connectionType
        self.isPipeModel = isPipeModel
        self.filterIds = filterIds
        self.actionIds = actionIds
        self.actions = actions
        self.suggestionPrompts = suggestionPrompts
        self.rawModelItem = rawModelItem
    }

    /// Whether the memory builtin tool is enabled for this model.
    var supportsMemory: Bool {
        builtinTools["memory"] == true
    }

    /// A short display name, extracting the model name after any provider prefix.
    var shortName: String {
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }

    // MARK: - Hashable & Equatable (rawModelItem excluded — [String: Any] is not Hashable)

    static func == (lhs: AIModel, rhs: AIModel) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.isPipeModel == rhs.isPipeModel
            && lhs.filterIds == rhs.filterIds
            && lhs.functionCallingMode == rhs.functionCallingMode
            && lhs.toolIds == rhs.toolIds
            && lhs.defaultFeatureIds == rhs.defaultFeatureIds
            && lhs.capabilities == rhs.capabilities
            && lhs.builtinTools == rhs.builtinTools
            && lhs.tags == rhs.tags
            && lhs.actions == rhs.actions
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(isPipeModel)
        hasher.combine(filterIds)
    }

    // MARK: - Codable (rawModelItem excluded — [String: Any] is not Codable)

    enum CodingKeys: String, CodingKey {
        case id, name, description, isMultimodal, supportsStreaming, supportsRAG
        case contextLength, capabilities, profileImageURL, toolIds, defaultFeatureIds
        case functionCallingMode, builtinTools, tags, connectionType, isPipeModel, filterIds, actionIds, actions, suggestionPrompts
        // rawModelItem is intentionally excluded from Codable — it contains
        // [String: Any] which cannot be synthesised. It is populated at runtime
        // from the live model fetch and does not need persistence.
    }

    // MARK: - Avatar URL Resolution

    /// Resolves the avatar URL for this model.
    ///
    /// Always uses the server's per-model endpoint `/api/v1/models/model/profile/image?id=X`.
    /// The server returns the model's custom avatar if one is set, or the default favicon
    /// for models without one. Results are cached by `ImageCacheService` so subsequent
    /// opens of the model picker are instant with zero network requests.
    ///
    /// External HTTP/HTTPS `profileImageURL` values (e.g. OAuth avatars) are used directly.
    func resolveAvatarURL(baseURL: String) -> URL? {
        // External HTTP/HTTPS URL — use directly.
        if let raw = profileImageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        // All other cases (nil, empty, data URI, relative path like "/static/favicon.png"):
        // delegate to the per-model endpoint. The server knows whether this model has a
        // custom avatar and returns the right image — no client-side guessing needed.
        return buildModelAvatarURL(baseURL: baseURL)
    }

    /// Builds the model avatar URL using the OpenWebUI endpoint:
    /// `/api/v1/models/model/profile/image?id={modelId}`
    ///
    /// This endpoint requires authentication (handled by ``AuthenticatedImageView``
    /// or by appending the auth token as a query parameter / header).
    private func buildModelAvatarURL(baseURL: String) -> URL? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !id.isEmpty else { return nil }

        let normalizedBase = trimmedBase.hasSuffix("/")
            ? String(trimmedBase.dropLast())
            : trimmedBase

        var components = URLComponents(string: "\(normalizedBase)/api/v1/models/model/profile/image")
        components?.queryItems = [URLQueryItem(name: "id", value: id)]
        return components?.url
    }
}
