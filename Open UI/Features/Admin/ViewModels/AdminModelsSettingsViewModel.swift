import Foundation
import os.log

/// ViewModel for the Admin Models Settings screen.
/// Uses listWorkspaceModels() so ALL models show (including hidden ones).
@Observable
final class AdminModelsSettingsViewModel {

    // MARK: - Loading / Error

    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    // MARK: - Models List (from /api/v1/models/list — includes hidden models)

    var models: [ModelItem] = []

    // MARK: - Ollama Manage State

    var ollamaConfig = OllamaConfig()
    var ollamaTagsError: String?
    var isFetchingOllamaTags = false

    // MARK: - Settings: Defaults Tab

    var defaultModelId: String = ""
    var defaultPinnedModelIds: [String] = []
    var modelOrderList: [String] = []

    // Prompt Suggestions
    var suggestions: [SuggestionPrompt] = []

    // Model Capabilities
    var capVision = true
    var capFileUpload = true
    var capFileContext = true
    var capWebSearch = true
    var capImageGeneration = true
    var capCodeInterpreter = true
    var capTerminal = false
    var capUsage = false
    var capCitations = true
    var capStatusUpdates = true
    var capBuiltinTools = true

    // Default Features
    var defWebSearch = true
    var defImageGeneration = true
    var defCodeInterpreter = false

    // Builtin Tools
    var btTime = true
    var btMemory = true
    var btChats = true
    var btNotes = true
    var btKnowledge = true
    var btChannels = true
    var btWebSearch = true
    var btImageGeneration = true
    var btCodeInterpreter = true
    var btTaskManagement = true
    var btAutomations = true
    var btCalendar = true
    var btFiles = true
    var btNotifications = true
    var btSubagents = true

    // Model Params (nil = Default)
    var streamChat: Bool? = nil
    var streamDeltaChunkSize: Int? = nil
    var functionCalling: String? = nil  // "native" or ""
    var reasoningTags: [String]? = nil

    // Extended Model Params (nil = Default)
    var paramTemperature: Double? = nil
    var paramSeed: Int? = nil
    var paramMaxTokens: Int? = nil
    var paramTopK: Int? = nil
    var paramTopP: Double? = nil
    var paramMinP: Double? = nil
    var paramFrequencyPenalty: Double? = nil
    var paramPresencePenalty: Double? = nil
    var paramMirostat: Int? = nil
    var paramMirostatEta: Double? = nil
    var paramMirostatTau: Double? = nil
    var paramRepeatLastN: Int? = nil
    var paramTfsZ: Double? = nil
    var paramRepeatPenalty: Double? = nil
    var paramNumKeep: Int? = nil
    var paramNumCtx: Int? = nil
    var paramNumBatch: Int? = nil
    var paramReasoningEffort: String? = nil
    var paramFormat: String? = nil
    // think (Ollama) stored as ThinkMode
    var paramThinkEnabled: Bool? = nil
    var paramThinkCustom: String? = nil

    var paramThinkMode: ThinkMode {
        get {
            if let s = paramThinkCustom, !s.isEmpty { return .custom(s) }
            switch paramThinkEnabled {
            case .none:        return .default
            case .some(true):  return .on
            case .some(false): return .off
            }
        }
        set {
            switch newValue {
            case .default:
                paramThinkEnabled = nil; paramThinkCustom = nil
            case .on:
                paramThinkEnabled = true; paramThinkCustom = nil
            case .off:
                paramThinkEnabled = false; paramThinkCustom = nil
            case .custom(let s):
                paramThinkEnabled = nil; paramThinkCustom = s
            }
        }
    }

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminModels")
    /// Snapshot of suggestions as loaded from the server — used to detect changes before POSTing.
    private var loadedSuggestions: [SuggestionPrompt] = []

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load

    // MARK: - Merged Base Models (mirrors OpenWebUI web UI init() algorithm)
    //
    // Step 1: GET /api/models/base  → raw live models from ENABLED connections only
    //         (is_active absent — defaults true; disabled connections excluded entirely)
    // Step 2: GET /api/v1/models/base → workspace DB records with the per-model is_active toggle
    // Step 3: For each live model, overlay is_active / isHidden / description from the
    //         matching workspace record, if one exists.
    //
    // Result: only models whose connection is active appear, and each carries the correct
    //         is_active state set by the admin toggle.
    private func fetchMergedBaseModels(api: APIClient) async throws -> [ModelItem] {
        async let rawTask = api.listRawBaseModels()
        async let wsTask  = api.listBaseModels()
        let (rawModels, wsModels) = try await (rawTask, wsTask)
        let wsMap = Dictionary(uniqueKeysWithValues: wsModels.map { ($0.id, $0) })
        return rawModels.map { raw in
            guard let ws = wsMap[raw.id] else { return raw }
            var merged = raw
            merged.isActive      = ws.isActive
            merged.isHidden      = ws.isHidden
            merged.description   = ws.description ?? raw.description
            return merged
        }
    }

    /// Full admin model list: base models (merged with workspace records) PLUS
    /// workspace custom models (those that have a base_model_id set).
    /// Custom models are appended after base models, deduped by ID.
    private func fetchMergedModels(api: APIClient) async throws -> [ModelItem] {
        async let baseTask   = fetchMergedBaseModels(api: api)
        async let customTask = api.listWorkspaceModels()
        let (baseModels, allWorkspace) = try await (baseTask, customTask)
        // Custom models are workspace entries that have a base_model_id (they are not raw base models)
        let baseIds = Set(baseModels.map { $0.id })
        let customModels = allWorkspace.filter { $0.baseModelId != nil && !baseIds.contains($0.id) }
        return baseModels + customModels
    }

    func loadAll() async {
        guard let api = apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        async let modelsTask      = fetchMergedModels(api: api)
        async let configTask      = api.getModelsConfig()
        async let suggestionsTask = api.getSuggestionsConfig()
        async let ollamaTask      = api.getOllamaConfig()

        do {
            let (fetchedModels, config, rawSuggestions, ollamaCfg) = try await (
                modelsTask, configTask, suggestionsTask, ollamaTask
            )
            models = fetchedModels
            ollamaConfig = ollamaCfg
            applySuggestionsConfig(rawSuggestions)
            applyModelsConfig(config)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Toggle Model Visibility (eye toggle — sets info.meta.hidden)

    func toggleModelVisibility(id: String) async {
        guard let api = apiClient else { return }
        do {
            // Try to fetch the workspace record. Base models (Ollama, OpenAI, etc.) may not
            // have a workspace record yet — if we get a 404/not-found error, create one first.
            let detail: ModelDetail
            do {
                detail = try await api.getWorkspaceModelDetail(id: id)
            } catch {
                // No workspace record exists for this base model — create a minimal one
                // so we can set its hidden flag, then re-fetch the new record.
                let stub = ModelDetail(id: id, name: id, baseModelId: id)
                _ = try await api.createWorkspaceModel(payload: stub.toCreatePayload())
                detail = try await api.getWorkspaceModelDetail(id: id)
            }

            // Build updated payload with hidden toggled
            var payload = detail.toUpdatePayload()
            var meta = payload["meta"] as? [String: Any] ?? [:]
            let currentHidden = meta["hidden"] as? Bool ?? false
            meta["hidden"] = !currentHidden
            payload["meta"] = meta
            payload["id"] = id

            _ = try await api.updateWorkspaceModel(payload: payload)
            // Refresh list
            models = try await fetchMergedModels(api: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Toggle Model Enabled (toggle — sets is_active)

    func toggleModelEnabled(id: String) async {
        guard let api = apiClient else { return }
        do {
            _ = try await api.toggleWorkspaceModel(id: id)
            // Refresh list (include custom models so they stay visible after toggle)
            models = try await fetchMergedModels(api: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Import / Export

    func importModels(from data: Data) async throws {
        guard let api = apiClient else { return }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "AdminModels", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON format for models import"])
        }
        try await api.importWorkspaceModels(models: array)
        models = try await fetchMergedModels(api: api)
    }

    func exportModels() async throws -> Data {
        guard let api = apiClient else {
            throw NSError(domain: "AdminModels", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        let raw = try await api.exportWorkspaceModels()
        return try JSONSerialization.data(withJSONObject: raw, options: .prettyPrinted)
    }

    // MARK: - Save Settings

    func save() async {
        guard let api = apiClient else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // Build capabilities dict
        let capabilities: [String: Any] = [
            "vision": capVision,
            "file_upload": capFileUpload,
            "file_context": capFileContext,
            "web_search": capWebSearch,
            "image_generation": capImageGeneration,
            "code_interpreter": capCodeInterpreter,
            "terminal": capTerminal,
            "usage": capUsage,
            "citations": capCitations,
            "status_updates": capStatusUpdates,
            "builtin_tools": capBuiltinTools
        ]

        // Build default feature IDs
        var defaultFeatureIds: [String] = []
        if defWebSearch { defaultFeatureIds.append("web_search") }
        if defImageGeneration { defaultFeatureIds.append("image_generation") }
        if defCodeInterpreter { defaultFeatureIds.append("code_interpreter") }

        // Build builtin tools dict
        let builtinTools: [String: Any] = [
            "time": btTime,
            "memory": btMemory,
            "chats": btChats,
            "notes": btNotes,
            "knowledge": btKnowledge,
            "files": btFiles,
            "channels": btChannels,
            "notifications": btNotifications,
            "web_search": btWebSearch,
            "image_generation": btImageGeneration,
            "code_interpreter": btCodeInterpreter,
            "tasks": btTaskManagement,
            "automations": btAutomations,
            "calendar": btCalendar,
            "subagents": btSubagents
        ]

        // Build params dict — only include non-nil values
        var params: [String: Any] = [:]
        if let v = streamChat { params["stream_chat_response"] = v }
        if let v = streamDeltaChunkSize { params["stream_delta_chunk_size"] = v }
        if let v = functionCalling { params["function_calling"] = v }
        if let v = reasoningTags { params["reasoning_tags"] = v }
        // Extended params
        if let v = paramTemperature { params["temperature"] = v }
        if let v = paramSeed { params["seed"] = v }
        if let v = paramMaxTokens { params["max_tokens"] = v }
        if let v = paramTopK { params["top_k"] = v }
        if let v = paramTopP { params["top_p"] = v }
        if let v = paramMinP { params["min_p"] = v }
        if let v = paramFrequencyPenalty { params["frequency_penalty"] = v }
        if let v = paramPresencePenalty { params["presence_penalty"] = v }
        if let v = paramMirostat { params["mirostat"] = v }
        if let v = paramMirostatEta { params["mirostat_eta"] = v }
        if let v = paramMirostatTau { params["mirostat_tau"] = v }
        if let v = paramRepeatLastN { params["repeat_last_n"] = v }
        if let v = paramTfsZ { params["tfs_z"] = v }
        if let v = paramRepeatPenalty { params["repeat_penalty"] = v }
        if let v = paramNumKeep { params["num_keep"] = v }
        if let v = paramNumCtx { params["num_ctx"] = v }
        if let v = paramNumBatch { params["num_batch"] = v }
        if let v = paramReasoningEffort, !v.isEmpty { params["reasoning_effort"] = v }
        if let v = paramFormat, !v.isEmpty { params["format"] = v }
        // think (Ollama)
        switch paramThinkMode {
        case .default: break
        case .on:       params["think"] = true
        case .off:      params["think"] = false
        case .custom(let s): if !s.isEmpty { params["think"] = s }
        }

        let payload: [String: Any] = [
            "DEFAULT_MODELS": defaultModelId,
            "DEFAULT_PINNED_MODELS": defaultPinnedModelIds.joined(separator: ","),
            "MODEL_ORDER_LIST": modelOrderList,
            "DEFAULT_MODEL_METADATA": [
                "capabilities": capabilities,
                "defaultFeatureIds": defaultFeatureIds,
                "builtinTools": builtinTools
            ] as [String: Any],
            "DEFAULT_MODEL_PARAMS": params
        ]

        do {
            // Always save the models config
            try await api.updateModelsConfig(payload)

            // Only POST suggestions if the user actually changed them — the endpoint is
            // a full REPLACE, so an accidental empty POST would wipe all suggestions.
            let currentSuggestions = suggestions.filter {
                !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let currentMatchesLoaded = currentSuggestions == loadedSuggestions.filter {
                !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !currentMatchesLoaded {
                let suggestionsPayload = currentSuggestions.map { $0.toJSON() }
                try await api.updateSuggestionsConfig(suggestions: suggestionsPayload)
                // Update snapshot so subsequent saves without changes are also skipped
                loadedSuggestions = currentSuggestions
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private Helpers

    private func applyModelsConfig(_ config: [String: Any]) {
        defaultModelId = config["DEFAULT_MODELS"] as? String ?? ""

        if let pinned = config["DEFAULT_PINNED_MODELS"] as? String, !pinned.isEmpty {
            defaultPinnedModelIds = pinned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if let pinned = config["DEFAULT_PINNED_MODELS"] as? [String] {
            defaultPinnedModelIds = pinned
        }

        if let order = config["MODEL_ORDER_LIST"] as? [String] {
            modelOrderList = order
        } else {
            modelOrderList = models.map { $0.id }
        }

        if let meta = config["DEFAULT_MODEL_METADATA"] as? [String: Any] {
            if let caps = meta["capabilities"] as? [String: Any] {
                capVision = caps["vision"] as? Bool ?? true
                capFileUpload = caps["file_upload"] as? Bool ?? true
                capFileContext = caps["file_context"] as? Bool ?? true
                capWebSearch = caps["web_search"] as? Bool ?? true
                capImageGeneration = caps["image_generation"] as? Bool ?? true
                capCodeInterpreter = caps["code_interpreter"] as? Bool ?? true
                capTerminal = caps["terminal"] as? Bool ?? false
                capUsage = caps["usage"] as? Bool ?? false
                capCitations = caps["citations"] as? Bool ?? true
                capStatusUpdates = caps["status_updates"] as? Bool ?? true
                capBuiltinTools = caps["builtin_tools"] as? Bool ?? true
            }
            if let defFeatures = meta["defaultFeatureIds"] as? [String] {
                defWebSearch = defFeatures.contains("web_search")
                defImageGeneration = defFeatures.contains("image_generation")
                defCodeInterpreter = defFeatures.contains("code_interpreter")
            }
            if let bt = meta["builtinTools"] as? [String: Any] {
                btTime = bt["time"] as? Bool ?? true
                btMemory = bt["memory"] as? Bool ?? true
                btChats = bt["chats"] as? Bool ?? bt["chat_history"] as? Bool ?? true
                btNotes = bt["notes"] as? Bool ?? true
                btKnowledge = bt["knowledge"] as? Bool ?? bt["knowledge_base"] as? Bool ?? true
                btChannels = bt["channels"] as? Bool ?? true
                btWebSearch = bt["web_search"] as? Bool ?? true
                btImageGeneration = bt["image_generation"] as? Bool ?? true
                btCodeInterpreter = bt["code_interpreter"] as? Bool ?? true
                btTaskManagement = bt["tasks"] as? Bool ?? bt["task_management"] as? Bool ?? true
                btAutomations = bt["automations"] as? Bool ?? true
                btCalendar = bt["calendar"] as? Bool ?? true
                btFiles = bt["files"] as? Bool ?? true
                btNotifications = bt["notifications"] as? Bool ?? true
                btSubagents = bt["subagents"] as? Bool ?? true
            }
        }

        if let p = config["DEFAULT_MODEL_PARAMS"] as? [String: Any], !p.isEmpty {
            streamChat = p["stream_chat_response"] as? Bool
            streamDeltaChunkSize = p["stream_delta_chunk_size"] as? Int
            functionCalling = p["function_calling"] as? String
            reasoningTags = p["reasoning_tags"] as? [String]
            // Extended params
            paramTemperature = p["temperature"] as? Double ?? (p["temperature"] as? Int).map { Double($0) }
            paramSeed = p["seed"] as? Int
            paramMaxTokens = p["max_tokens"] as? Int
            paramTopK = p["top_k"] as? Int
            paramTopP = p["top_p"] as? Double ?? (p["top_p"] as? Int).map { Double($0) }
            paramMinP = p["min_p"] as? Double ?? (p["min_p"] as? Int).map { Double($0) }
            paramFrequencyPenalty = p["frequency_penalty"] as? Double ?? (p["frequency_penalty"] as? Int).map { Double($0) }
            paramPresencePenalty = p["presence_penalty"] as? Double ?? (p["presence_penalty"] as? Int).map { Double($0) }
            paramMirostat = p["mirostat"] as? Int
            paramMirostatEta = p["mirostat_eta"] as? Double ?? (p["mirostat_eta"] as? Int).map { Double($0) }
            paramMirostatTau = p["mirostat_tau"] as? Double ?? (p["mirostat_tau"] as? Int).map { Double($0) }
            paramRepeatLastN = p["repeat_last_n"] as? Int
            paramTfsZ = p["tfs_z"] as? Double ?? (p["tfs_z"] as? Int).map { Double($0) }
            paramRepeatPenalty = p["repeat_penalty"] as? Double ?? (p["repeat_penalty"] as? Int).map { Double($0) }
            paramNumKeep = p["num_keep"] as? Int
            paramNumCtx = p["num_ctx"] as? Int
            paramNumBatch = p["num_batch"] as? Int
            paramReasoningEffort = p["reasoning_effort"] as? String
            paramFormat = p["format"] as? String
            // think
            if let v = p["think"] {
                if let b = v as? Bool {
                    paramThinkMode = b ? .on : .off
                } else if let s = v as? String, !s.isEmpty {
                    paramThinkMode = .custom(s)
                }
            }
        }
    }

    private func applySuggestionsConfig(_ raw: [[String: Any]]) {
        let parsed = raw.compactMap { SuggestionPrompt(json: $0) }
        suggestions = parsed
        loadedSuggestions = parsed
    }
}
