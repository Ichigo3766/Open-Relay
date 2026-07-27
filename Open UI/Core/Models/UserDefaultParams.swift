import Foundation

// MARK: - UserDefaultParams

/// User-level default params stored in `ui.system` and `ui.params` on the server.
/// These are the lowest-priority defaults applied to every chat request when
/// no per-chat or conversation-level overrides are present.
///
/// API endpoint: GET/POST `/api/v1/users/user/settings`
/// Stored under: `{ "ui": { "system": "...", "params": { ... } } }`
struct UserDefaultParams: Codable, Sendable, Equatable {

    // MARK: System Prompt
    var systemPrompt: String?

    // MARK: Basic
    var temperature: Double?
    var seed: Int?
    var maxTokens: Int?

    // MARK: Sampling
    var topK: Int?
    var topP: Double?
    var minP: Double?
    var frequencyPenalty: Double?
    var presencePenalty: Double?

    // MARK: Mirostat
    var mirostat: Int?
    var mirostatEta: Double?
    var mirostatTau: Double?

    // MARK: Repeat / tail-free
    var repeatLastN: Int?
    var tfsZ: Double?
    var repeatPenalty: Double?

    // MARK: Ollama context
    var numKeep: Int?
    var numCtx: Int?
    var numBatch: Int?

    // MARK: Reasoning
    var reasoningEffort: String?

    // MARK: Streaming
    var streamResponse: Bool?

    // MARK: Function calling
    var functionCalling: String?

    // MARK: Format (Ollama)
    var format: String?

    // MARK: Think (Ollama)
    var thinkEnabled: Bool?
    var thinkCustom: String?

    // MARK: Stop sequences
    var stop: [String]?

    // MARK: - ThinkMode helpers (mirrored from ChatAdvancedParams)

    var thinkMode: ThinkMode {
        get {
            if let s = thinkCustom, !s.isEmpty { return .custom(s) }
            switch thinkEnabled {
            case .none:  return .default
            case .some(true):  return .on
            case .some(false): return .off
            }
        }
        set {
            switch newValue {
            case .default:
                thinkEnabled = nil
                thinkCustom = nil
            case .on:
                thinkEnabled = true
                thinkCustom = nil
            case .off:
                thinkEnabled = false
                thinkCustom = nil
            case .custom(let s):
                thinkEnabled = nil
                thinkCustom = s
            }
        }
    }

    // MARK: - Init

    init() {}

    /// Initialise from the raw `ui` dict returned by `GET /api/v1/users/user/settings`.
    /// Reads `ui["system"]` for the system prompt and `ui["params"]` for params.
    init(from uiDict: [String: Any]) {
        // System prompt lives directly under "ui"
        if let v = uiDict["system"] as? String, !v.isEmpty {
            systemPrompt = v
        }

        // All other params live under "ui.params"
        let p = uiDict["params"] as? [String: Any] ?? [:]

        if let v = p["temperature"] as? Double { temperature = v }
        else if let v = p["temperature"] as? Int { temperature = Double(v) }
        if let v = p["seed"] as? Int { seed = v }
        if let v = p["max_tokens"] as? Int { maxTokens = v }

        if let v = p["top_k"] as? Int { topK = v }
        if let v = p["top_p"] as? Double { topP = v }
        else if let v = p["top_p"] as? Int { topP = Double(v) }
        if let v = p["min_p"] as? Double { minP = v }
        else if let v = p["min_p"] as? Int { minP = Double(v) }
        if let v = p["frequency_penalty"] as? Double { frequencyPenalty = v }
        else if let v = p["frequency_penalty"] as? Int { frequencyPenalty = Double(v) }
        if let v = p["presence_penalty"] as? Double { presencePenalty = v }
        else if let v = p["presence_penalty"] as? Int { presencePenalty = Double(v) }

        if let v = p["mirostat"] as? Int { mirostat = v }
        if let v = p["mirostat_eta"] as? Double { mirostatEta = v }
        else if let v = p["mirostat_eta"] as? Int { mirostatEta = Double(v) }
        if let v = p["mirostat_tau"] as? Double { mirostatTau = v }
        else if let v = p["mirostat_tau"] as? Int { mirostatTau = Double(v) }

        if let v = p["repeat_last_n"] as? Int { repeatLastN = v }
        if let v = p["tfs_z"] as? Double { tfsZ = v }
        else if let v = p["tfs_z"] as? Int { tfsZ = Double(v) }
        if let v = p["repeat_penalty"] as? Double { repeatPenalty = v }
        else if let v = p["repeat_penalty"] as? Int { repeatPenalty = Double(v) }

        if let v = p["num_keep"] as? Int { numKeep = v }
        if let v = p["num_ctx"] as? Int { numCtx = v }
        if let v = p["num_batch"] as? Int { numBatch = v }

        if let v = p["reasoning_effort"] as? String, !v.isEmpty { reasoningEffort = v }
        if let v = p["stream_response"] as? Bool { streamResponse = v }
        if let v = p["function_calling"] as? String, !v.isEmpty { functionCalling = v }
        if let v = p["format"] as? String, !v.isEmpty { format = v }

        if let v = p["stop"] as? [String], !v.isEmpty { stop = v }

        if let v = p["think"] {
            if let b = v as? Bool {
                thinkMode = b ? .on : .off
            } else if let s = v as? String, !s.isEmpty {
                thinkMode = .custom(s)
            }
        }
    }

    // MARK: - hasAnyOverride

    var hasAnyOverride: Bool {
        systemPrompt?.isEmpty == false ||
        temperature != nil || seed != nil || maxTokens != nil ||
        topK != nil || topP != nil || minP != nil ||
        frequencyPenalty != nil || presencePenalty != nil ||
        mirostat != nil || mirostatEta != nil || mirostatTau != nil ||
        repeatLastN != nil || tfsZ != nil || repeatPenalty != nil ||
        numKeep != nil || numCtx != nil || numBatch != nil ||
        reasoningEffort != nil || streamResponse != nil ||
        functionCalling != nil || format != nil ||
        thinkEnabled != nil || (thinkCustom != nil && !thinkCustom!.isEmpty) ||
        stop?.isEmpty == false
    }

    // MARK: - toRequestParams()

    /// Produces the `params` dict to inject into a completion request.
    /// Only non-nil values are included. System prompt is NOT included here —
    /// it is injected separately via the `params["system"]` key in the caller.
    func toRequestParams() -> [String: Any] {
        var p: [String: Any] = [:]

        if let v = temperature         { p["temperature"] = v }
        if let v = seed                { p["seed"] = v }
        if let v = maxTokens           { p["max_tokens"] = v }
        if let v = topK                { p["top_k"] = v }
        if let v = topP                { p["top_p"] = v }
        if let v = minP                { p["min_p"] = v }
        if let v = frequencyPenalty    { p["frequency_penalty"] = v }
        if let v = presencePenalty     { p["presence_penalty"] = v }
        if let v = mirostat            { p["mirostat"] = v }
        if let v = mirostatEta         { p["mirostat_eta"] = v }
        if let v = mirostatTau         { p["mirostat_tau"] = v }
        if let v = repeatLastN         { p["repeat_last_n"] = v }
        if let v = tfsZ                { p["tfs_z"] = v }
        if let v = repeatPenalty       { p["repeat_penalty"] = v }
        if let v = numKeep             { p["num_keep"] = v }
        if let v = numCtx              { p["num_ctx"] = v }
        if let v = numBatch            { p["num_batch"] = v }
        if let v = reasoningEffort, !v.isEmpty { p["reasoning_effort"] = v }
        if let v = streamResponse      { p["stream_response"] = v }
        if let v = functionCalling, !v.isEmpty { p["function_calling"] = v }
        if let v = format, !v.isEmpty  { p["format"] = v }
        if let v = stop, !v.isEmpty    { p["stop"] = v }

        switch thinkMode {
        case .default: break
        case .on:       p["think"] = true
        case .off:      p["think"] = false
        case .custom(let s): if !s.isEmpty { p["think"] = s }
        }

        return p
    }

    // MARK: - toUISaveDict()

    /// Produces the `"ui"` portion of the update request body.
    /// - Includes `"system"` key only when systemPrompt is non-empty.
    /// - Includes `"params"` key only when at least one param is set.
    /// The caller merges this dict with the existing `ui` dict before POSTing.
    func toUISaveDict() -> [String: Any] {
        var ui: [String: Any] = [:]

        if let sp = systemPrompt, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            ui["system"] = sp
        } else {
            // systemPrompt is nil or blank — signal the caller to remove the key entirely.
            // The server ignores JSON null; we must omit the key, so NSNull is the sentinel.
            ui["system"] = NSNull()
        }

        let requestParams = toRequestParams()
        if !requestParams.isEmpty {
            ui["params"] = requestParams
        } else {
            // Explicitly clear params if nothing is set
            ui["params"] = [String: Any]()
        }

        return ui
    }
}
