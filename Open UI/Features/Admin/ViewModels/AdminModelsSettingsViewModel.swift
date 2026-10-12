import Foundation
import SwiftUI
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

    /// `DEFAULT_MODELS` — the server stores a comma-separated list (web allows several).
    var defaultModelIds: [String] = []
    var defaultPinnedModelIds: [String] = []
    var modelOrderList: [String] = []

    // Prompt Suggestions
    var suggestions: [SuggestionPrompt] = []
    /// True = use Open WebUI's built-in starter prompts (`suggestions: null` on the server).
    var useDefaultSuggestions = false

    // Model Capabilities
    var capVision = true
    var capFileUpload = true
    var capFileContext = true
    var capWebSearch = true
    var capImageGeneration = true
    var capCodeInterpreter = true
    var capTerminal = true
    var capUsage = false
    var capCitations = true
    var capStatusUpdates = true
    var capMemory = true
    var capBuiltinTools = true

    // Default Features (web default: none on until the admin picks them)
    var defWebSearch = false
    var defImageGeneration = false
    var defCodeInterpreter = false

    // Builtin Tools
    var btTime = true
    var btUserInput = true
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
    var btSkills = true

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
    private var loadedUseDefaultSuggestions = false
    /// `default_prompt_suggestions_i18n` as loaded — re-sent on save so web-side
    /// translations survive (the server replaces them with whatever is posted).
    private var suggestionsI18n: [String: Any] = [:]
    /// The saved MODEL_ORDER_LIST (nil when never saved) — only re-sent as-is
    /// unless the admin actually reorders.
    private var savedModelOrderList: [String]?
    private var modelOrderEdited = false
    /// Sections that failed to load; save refuses to overwrite them with blank values.
    private(set) var modelsConfigLoaded = false
    private(set) var suggestionsLoaded = false

    /// Called by the reorder list when the admin moves a model.
    func moveModelOrder(fromOffsets source: IndexSet, toOffset destination: Int) {
        modelOrderList.move(fromOffsets: source, toOffset: destination)
        modelOrderEdited = true
    }

    /// Restores Open WebUI's built-in starter prompts.
    func resetSuggestionsToDefaults() {
        useDefaultSuggestions = true
        suggestions = Self.builtInSuggestionPrompts
    }

    static var builtInSuggestionPrompts: [SuggestionPrompt] {
        BackendConfig.builtInPromptSuggestions.map {
            let title = $0.title ?? []
            return SuggestionPrompt(content: $0.content ?? "",
                                    title: title.first ?? "",
                                    subtitle: title.count > 1 ? title[1] : "")
        }
    }

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
        let wsMap = Dictionary(wsModels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
        async let savedBaseTask = api.listBaseModels()
        let (baseModels, allWorkspace) = try await (baseTask, customTask)
        // Custom models are workspace entries that have a base_model_id (they are not raw base models)
        let baseIds = Set(baseModels.map { $0.id })
        let customModels = allWorkspace.filter { $0.baseModelId != nil && !baseIds.contains($0.id) }
        // Saved base-model records no connection offers any more are
        // listed as "Unavailable" leftovers instead of silently disappearing.
        let saved = (try? await savedBaseTask) ?? []
        let customIds = Set(customModels.map(\.id))
        let leftovers = saved.filter { $0.baseModelId == nil && !baseIds.contains($0.id) && !customIds.contains($0.id) }
        unavailableModelIds = Set(leftovers.map(\.id))
        return baseModels + customModels + leftovers
    }

    /// Saved base models that no connection currently offers.
    var unavailableModelIds: Set<String> = []

    func loadAll() async {
        guard let api = apiClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // Each section loads independently — one failing request (e.g. Ollama
        // disabled, a connection timing out) must not blank the whole tab.
        async let modelsTask      = Self.capture { try await self.fetchMergedModels(api: api) }
        async let configTask      = Self.capture { try await api.getModelsConfig() }
        async let suggestionsTask = Self.capture { try await api.getPromptSuggestionsConfig() }
        async let ollamaTask      = Self.capture { try await api.getOllamaConfig() }

        let (modelsRes, configRes, suggestionsRes, ollamaRes) =
            await (modelsTask, configTask, suggestionsTask, ollamaTask)

        var failures: [String] = []
        switch modelsRes {
        case .success(let m): models = m
        case .failure(let e): failures.append("Models: \(e.localizedDescription)")
        }
        switch configRes {
        case .success(let c): applyModelsConfig(c); modelsConfigLoaded = true
        case .failure(let e): failures.append("Model defaults: \(e.localizedDescription)")
        }
        switch suggestionsRes {
        case .success(let s): applySuggestionsConfig(s); suggestionsLoaded = true
        case .failure(let e): failures.append("Prompt suggestions: \(e.localizedDescription)")
        }
        if case .success(let o) = ollamaRes { ollamaConfig = o }
        else if case .failure(let e) = ollamaRes {
            logger.warning("Ollama config unavailable: \(e.localizedDescription)")
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    private static func capture<T>(_ work: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    // MARK: - Base model DB record

    /// Payload that creates a workspace DB record for a connection base model,
    /// mirroring the web admin (`Models.svelte` upsertModelHandler/toggleModelHandler):
    /// real name, `base_model_id: null`, empty meta/params, no grants. Empty meta
    /// matters — admin DEFAULT_MODEL_METADATA only fills keys that are missing.
    private func baseRecordPayload(for model: ModelItem, isActive: Bool, meta: [String: Any] = [:]) -> [String: Any] {
        ["id": model.id, "name": model.name, "base_model_id": NSNull(),
         "meta": meta, "params": [String: Any](), "access_grants": [[String: Any]](),
         "is_active": isActive]
    }

    // MARK: - Toggle Model Visibility (eye toggle — sets meta.hidden)

    func toggleModelVisibility(id: String) async {
        guard let api = apiClient, let model = models.first(where: { $0.id == id }) else { return }
        do {
            if var record = try await api.getWorkspaceModelRecord(id: id) {
                // Flip `hidden` on the stored meta only; everything else is re-sent as-is.
                var meta = decodeOriginalMeta(record.originalMetaJSON)
                meta["hidden"] = !(meta["hidden"] as? Bool ?? false)
                record.originalMetaJSON = try? JSONSerialization.data(withJSONObject: meta)
                var payload = record.toRawUpdatePayload()
                payload["meta"] = meta
                _ = try await api.updateWorkspaceModel(payload: payload)
            } else {
                _ = try await api.createWorkspaceModel(
                    payload: baseRecordPayload(for: model, isActive: model.isActive, meta: ["hidden": !model.isHidden]))
            }
            models = try await fetchMergedModels(api: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Toggle Model Enabled (sets is_active)

    func toggleModelEnabled(id: String) async {
        guard let api = apiClient, let model = models.first(where: { $0.id == id }) else { return }
        do {
            if try await api.getWorkspaceModelRecord(id: id) != nil {
                _ = try await api.toggleWorkspaceModel(id: id)
            } else {
                // No record yet — create it with the flipped state (toggle would 401 NOT_FOUND).
                _ = try await api.createWorkspaceModel(payload: baseRecordPayload(for: model, isActive: !model.isActive))
            }
            models = try await fetchMergedModels(api: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Make Public / Private (web toggleModelPrivacyHandler)

    /// Public = an `{user, "*", read}` grant. Making it private sends `[]`, exactly
    /// like the web; making it public keeps the model's existing grants and adds `*`.
    func toggleModelPrivacy(id: String) async {
        guard let api = apiClient, let model = models.first(where: { $0.id == id }) else { return }
        do {
            let existing = try await api.getWorkspaceModelRecord(id: id)
            var grants: [[String: Any]] = []
            if !model.isPublic {
                grants = existing?.buildGrantsPayload() ?? []
                grants.append(["principal_type": "user", "principal_id": "*", "permission": "read"])
            }
            // The server creates a minimal record for base models that have none.
            _ = try await api.updateModelAccessGrants(id: id, name: model.name, grants: grants)
            models = try await fetchMergedModels(api: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Reset All (DELETE /api/v1/models/delete/all)

    /// Deletes every workspace model record (custom models and per-model overrides).
    func resetAllModels() async {
        guard let api = apiClient else { return }
        do {
            try await api.deleteAllWorkspaceModels()
            await loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Bulk visibility / enablement (filtered set)

    func setActiveForAll(_ active: Bool, in subset: [ModelItem]) async {
        guard let api = apiClient else { return }
        do {
            for m in subset where m.isActive != active {
                if try await api.getWorkspaceModelRecord(id: m.id) != nil {
                    _ = try await api.toggleWorkspaceModel(id: m.id)
                } else {
                    _ = try await api.createWorkspaceModel(payload: baseRecordPayload(for: m, isActive: active))
                }
            }
            models = try await fetchMergedModels(api: api)
        } catch { errorMessage = error.localizedDescription }
    }

    func setHiddenForAll(_ hidden: Bool, in subset: [ModelItem]) async {
        guard let api = apiClient else { return }
        do {
            for m in subset where m.isHidden != hidden {
                if var record = try await api.getWorkspaceModelRecord(id: m.id) {
                    var meta = decodeOriginalMeta(record.originalMetaJSON)
                    meta["hidden"] = hidden
                    record.originalMetaJSON = try? JSONSerialization.data(withJSONObject: meta)
                    var payload = record.toRawUpdatePayload()
                    payload["meta"] = meta
                    _ = try await api.updateWorkspaceModel(payload: payload)
                } else {
                    _ = try await api.createWorkspaceModel(
                        payload: baseRecordPayload(for: m, isActive: m.isActive, meta: ["hidden": hidden]))
                }
            }
            models = try await fetchMergedModels(api: api)
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Import / Export

    func importModels(from data: Data) async throws {
        guard let api = apiClient else { return }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "AdminModels", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON format for models import"])
        }
        try await api.importWorkspaceModels(models: array.map { ($0["info"] as? [String: Any]) ?? $0 })
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
            "memory": capMemory,
            "builtin_tools": capBuiltinTools
        ]

        // Build default feature IDs
        var defaultFeatureIds: [String] = []
        if defWebSearch && capWebSearch { defaultFeatureIds.append("web_search") }
        if defImageGeneration && capImageGeneration { defaultFeatureIds.append("image_generation") }
        if defCodeInterpreter && capCodeInterpreter { defaultFeatureIds.append("code_interpreter") }

        // Build builtin tools dict — web UI stores only disabled tools (`false`) so
        // tools added to the server later default to enabled.
        let allBuiltinTools: [String: Bool] = [
            "time": btTime,
            "user_input": btUserInput,
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
            "subagents": btSubagents,
            "skills": btSkills
        ]
        let builtinTools: [String: Any] = allBuiltinTools.filter { !$0.value }.mapValues { $0 as Any }

        // Build params dict — only include non-nil values
        var params: [String: Any] = [:]
        // Open WebUI's key is `stream_response` (AdvancedParams.svelte / utils/payload.py).
        if let v = streamChat { params["stream_response"] = v }
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
            "DEFAULT_MODELS": defaultModelIds.joined(separator: ","),
            "DEFAULT_PINNED_MODELS": defaultPinnedModelIds.joined(separator: ","),
            // Only send a new order when the admin reordered; otherwise keep what's saved.
            "MODEL_ORDER_LIST": modelOrderEdited ? modelOrderList : (savedModelOrderList ?? []),
            "DEFAULT_MODEL_METADATA": [
                "capabilities": capabilities,
                "defaultFeatureIds": defaultFeatureIds,
                "builtinTools": builtinTools
            ] as [String: Any],
            "DEFAULT_MODEL_PARAMS": params
        ]

        do {
            // Never overwrite the server's defaults with blank values from a failed load.
            if modelsConfigLoaded {
                try await api.updateModelsConfig(payload)
                savedModelOrderList = payload["MODEL_ORDER_LIST"] as? [String]
                modelOrderEdited = false
            }

            // Only POST suggestions if the admin changed them — the endpoint is a full
            // REPLACE, so an accidental empty POST would wipe all suggestions.
            let currentSuggestions = suggestions.filter {
                !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            // Editing the built-in starters turns them into a custom list (web parity).
            if useDefaultSuggestions && suggestions != Self.builtInSuggestionPrompts {
                useDefaultSuggestions = false
            }
            let changed = useDefaultSuggestions != loadedUseDefaultSuggestions
                || (!useDefaultSuggestions && currentSuggestions != loadedSuggestions)
            if suggestionsLoaded && changed {
                try await api.updateSuggestionsConfig(
                    suggestions: useDefaultSuggestions ? nil : currentSuggestions.map { $0.toJSON() },
                    i18n: suggestionsI18n
                )
                loadedSuggestions = currentSuggestions
                loadedUseDefaultSuggestions = useDefaultSuggestions
                if !useDefaultSuggestions { suggestions = currentSuggestions }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private Helpers

    private func applyModelsConfig(_ config: [String: Any]) {
        if let csv = config["DEFAULT_MODELS"] as? String {
            defaultModelIds = csv.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            defaultModelIds = config["DEFAULT_MODELS"] as? [String] ?? []
        }

        if let pinned = config["DEFAULT_PINNED_MODELS"] as? String {
            defaultPinnedModelIds = pinned.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            defaultPinnedModelIds = config["DEFAULT_PINNED_MODELS"] as? [String] ?? []
        }

        // Display order mirrors the web: saved order first (still-existing models),
        // then any remaining models alphabetically. Only sent back if edited.
        savedModelOrderList = config["MODEL_ORDER_LIST"] as? [String]
        modelOrderEdited = false
        let saved = (savedModelOrderList ?? []).filter { id in models.contains { $0.id == id } }
        let rest = models.map(\.id).filter { !saved.contains($0) }.sorted { $0.localizedCompare($1) == .orderedAscending }
        modelOrderList = saved + rest

        if let meta = config["DEFAULT_MODEL_METADATA"] as? [String: Any] {
            if let caps = meta["capabilities"] as? [String: Any] {
                capVision = caps["vision"] as? Bool ?? true
                capFileUpload = caps["file_upload"] as? Bool ?? true
                capFileContext = caps["file_context"] as? Bool ?? true
                capWebSearch = caps["web_search"] as? Bool ?? true
                capImageGeneration = caps["image_generation"] as? Bool ?? true
                capCodeInterpreter = caps["code_interpreter"] as? Bool ?? true
                capTerminal = caps["terminal"] as? Bool ?? true
                capUsage = caps["usage"] as? Bool ?? false
                capCitations = caps["citations"] as? Bool ?? true
                capStatusUpdates = caps["status_updates"] as? Bool ?? true
                capMemory = caps["memory"] as? Bool ?? true
                capBuiltinTools = caps["builtin_tools"] as? Bool ?? true
            }
            if let defFeatures = meta["defaultFeatureIds"] as? [String] {
                defWebSearch = defFeatures.contains("web_search")
                defImageGeneration = defFeatures.contains("image_generation")
                defCodeInterpreter = defFeatures.contains("code_interpreter")
            }
            if let bt = meta["builtinTools"] as? [String: Any] {
                btTime = bt["time"] as? Bool ?? true
                btUserInput = bt["user_input"] as? Bool ?? true
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
                btSkills = bt["skills"] as? Bool ?? true
            }
        }

        if let p = config["DEFAULT_MODEL_PARAMS"] as? [String: Any], !p.isEmpty {
            streamChat = (p["stream_response"] as? Bool) ?? (p["stream_chat_response"] as? Bool)
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

    private func applySuggestionsConfig(_ config: APIClient.PromptSuggestionsConfig) {
        suggestionsI18n = config.i18n
        if let raw = config.suggestions {
            let parsed = raw.compactMap { SuggestionPrompt(json: $0) }
            useDefaultSuggestions = false
            suggestions = parsed
            loadedSuggestions = parsed
        } else {
            // Never configured → the server shows the built-in starters.
            resetSuggestionsToDefaults()
            loadedSuggestions = suggestions
        }
        loadedUseDefaultSuggestions = useDefaultSuggestions
    }
}
