import SwiftUI

/// Common custom parameter names and typical values.
/// Suggestions only — support depends on the provider and model.
enum CustomParamSuggestions {
    static let all: [(name: String, values: [String])] = [
        ("service_tier", ["auto", "default", "flex", "priority", "fast"]),
        ("reasoning_effort", ["none", "minimal", "low", "medium", "high", "xhigh", "max"]),
        ("reasoning", [#"{"effort":"low"}"#, #"{"effort":"medium"}"#, #"{"effort":"high"}"#]),
        ("verbosity", ["low", "medium", "high"]),
        ("text", [#"{"verbosity":"low"}"#, #"{"verbosity":"medium"}"#, #"{"verbosity":"high"}"#]),
        ("max_completion_tokens", []), ("max_output_tokens", []), ("max_tokens", []),
        ("parallel_tool_calls", ["true", "false"]),
        ("tool_choice", ["auto", "none", "required"]),
        ("response_format", [#"{"type":"text"}"#, #"{"type":"json_object"}"#]),
        ("temperature", []), ("top_p", []), ("top_k", []), ("min_p", []),
        ("frequency_penalty", []), ("presence_penalty", []), ("repetition_penalty", []), ("repeat_penalty", []),
        ("seed", []), ("stop", []),
        ("logprobs", ["true", "false"]), ("top_logprobs", []),
        ("prompt_cache_key", []),
        ("prompt_cache_options", [#"{"mode":"implicit","ttl":"30m"}"#, #"{"mode":"explicit","ttl":"30m"}"#]),
        ("store", ["true", "false"]),
        ("provider", [#"{"sort":"price"}"#, #"{"sort":"throughput"}"#, #"{"sort":"latency"}"#]),
        ("num_ctx", []), ("num_predict", []),
        ("think", ["true", "false"]),
        ("format", ["json"]),
        ("keep_alive", []),
    ]

    static func values(for name: String) -> [String] {
        all.first { $0.name == name }?.values ?? []
    }
}

/// Small menu button that fills a field with a suggestion.
struct SuggestionMenuButton: View {
    let options: [String]
    let onPick: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        if !options.isEmpty {
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) { onPick(option) }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }
}
