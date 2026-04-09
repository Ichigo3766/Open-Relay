import Foundation

// MARK: - ThinkMode

/// 4-state think parameter (Ollama).
/// - default: nil — don't send, let server decide
/// - on: true — always think
/// - off: false — never think
/// - custom: budget string (e.g. "medium", "8192")
enum ThinkMode: Equatable, Sendable {
    case `default`
    case on
    case off
    case custom(String)

    /// Value to encode into the JSON params dict, or nil when default.
    var paramValue: Any? {
        switch self {
        case .default: return nil
        case .on: return true
        case .off: return false
        case .custom(let s): return s.isEmpty ? nil : s
        }
    }

    /// Display label for the picker.
    var label: String {
        switch self {
        case .default: return "Default"
        case .on: return "On"
        case .off: return "Off"
        case .custom(let s): return s.isEmpty ? "Custom" : s
        }
    }
}

// MARK: - ChatAdvancedParams

/// Per-chat override params. All fields are optional (nil = use model/server default).
/// Stored in `Conversation.chatParams` and persisted alongside the conversation.
struct ChatAdvancedParams: Codable, Sendable, Equatable {

    // MARK: Basic
    var systemPrompt: String?
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
    var functionCalling: String?   // "native" | nil

    // MARK: Format (Ollama)
    var format: String?

    // MARK: Think (Ollama) — stored as a lightweight enum-like raw value
    // We store as a 3-field combo so it survives Codable without custom coding.
    var thinkEnabled: Bool?        // nil=default, true=on, false=off
    var thinkCustom: String?       // non-nil = custom string mode

    // MARK: - ThinkMode helpers

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

    /// Initialise from a server-side `params` dict (e.g. `chat["params"]` in a conversation JSON).
    /// All unknown keys are silently ignored.
    init(from params: [String: Any]) {
        // Basic
        if let v = params["system"] as? String, !v.isEmpty { systemPrompt = v }
        if let v = params["temperature"] as? Double { temperature = v }
        else if let v = params["temperature"] as? Int { temperature = Double(v) }
        if let v = params["seed"] as? Int { seed = v }
        if let v = params["max_tokens"] as? Int { maxTokens = v }

        // Sampling
        if let v = params["top_k"] as? Int { topK = v }
        if let v = params["top_p"] as? Double { topP = v }
        else if let v = params["top_p"] as? Int { topP = Double(v) }
        if let v = params["min_p"] as? Double { minP = v }
        else if let v = params["min_p"] as? Int { minP = Double(v) }
        if let v = params["frequency_penalty"] as? Double { frequencyPenalty = v }
        else if let v = params["frequency_penalty"] as? Int { frequencyPenalty = Double(v) }
        if let v = params["presence_penalty"] as? Double { presencePenalty = v }
        else if let v = params["presence_penalty"] as? Int { presencePenalty = Double(v) }

        // Mirostat
        if let v = params["mirostat"] as? Int { mirostat = v }
        if let v = params["mirostat_eta"] as? Double { mirostatEta = v }
        else if let v = params["mirostat_eta"] as? Int { mirostatEta = Double(v) }
        if let v = params["mirostat_tau"] as? Double { mirostatTau = v }
        else if let v = params["mirostat_tau"] as? Int { mirostatTau = Double(v) }

        // Repeat / tail-free
        if let v = params["repeat_last_n"] as? Int { repeatLastN = v }
        if let v = params["tfs_z"] as? Double { tfsZ = v }
        else if let v = params["tfs_z"] as? Int { tfsZ = Double(v) }
        if let v = params["repeat_penalty"] as? Double { repeatPenalty = v }
        else if let v = params["repeat_penalty"] as? Int { repeatPenalty = Double(v) }

        // Ollama context
        if let v = params["num_keep"] as? Int { numKeep = v }
        if let v = params["num_ctx"] as? Int { numCtx = v }
        if let v = params["num_batch"] as? Int { numBatch = v }

        // Reasoning
        if let v = params["reasoning_effort"] as? String, !v.isEmpty { reasoningEffort = v }

        // Streaming
        if let v = params["stream_response"] as? Bool { streamResponse = v }

        // Function calling
        if let v = params["function_calling"] as? String, !v.isEmpty { functionCalling = v }

        // Format
        if let v = params["format"] as? String, !v.isEmpty { format = v }

        // Think (Ollama) — 3 possible types: Bool, String, or absent
        if let v = params["think"] {
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
        thinkEnabled != nil || (thinkCustom != nil && !thinkCustom!.isEmpty)
    }

    // MARK: - toRequestParams()

    /// Converts this struct into the `params` dict for an API request.
    /// Only non-nil values (or explicitly set values) are included.
    /// Pass `systemPrompt` separately if the effective system prompt comes from
    /// the conversation — this method only emits params-level overrides.
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

        // think: 4-state
        switch thinkMode {
        case .default: break
        case .on:       p["think"] = true
        case .off:      p["think"] = false
        case .custom(let s): if !s.isEmpty { p["think"] = s }
        }

        return p
    }

    // MARK: - Merging

    /// Returns a merged params dict starting from `base`, then overlaying
    /// non-nil values from `self`. Also injects system prompt if set.
    func mergedOver(base: [String: Any]) -> [String: Any] {
        var result = base
        for (k, v) in toRequestParams() {
            result[k] = v
        }
        if let sp = systemPrompt, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            result["system"] = sp
        }
        return result
    }
}
