import SwiftUI

// MARK: - Usage Info Popover

/// A compact, native-feel popover showing token usage statistics.
///
/// Uses `.ultraThinMaterial` for a frosted-glass iOS 18 look and
/// presents as a true popover bubble (never a full-screen sheet)
/// via `.presentationCompactAdaptation(.popover)` at the call site.
struct UsageInfoPopover: View {
    let usage: [String: Any]

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rowsContent
        }
        .frame(minWidth: 260, maxWidth: 300)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "chart.bar.xaxis.ascending.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.brandPrimary)
            }
            Text("Token Usage")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Rows

    private var rowsContent: some View {
        let rows = flattenUsage(usage, indent: 0)
        return VStack(alignment: .leading, spacing: 0) {
            // Thin separator under header
            Divider()
                .padding(.horizontal, 0)
                .opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        if row.isHeader {
                            sectionHeaderRow(row)
                        } else {
                            valueRow(row, isLast: idx == rows.count - 1)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 320)
            .scrollIndicators(.hidden)
        }
    }

    /// Section header row (e.g. "Completion Tokens Details")
    private func sectionHeaderRow(_ row: UsageRow) -> some View {
        Text(row.label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.textTertiary)
            .kerning(0.5)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    /// A single key / value row
    private func valueRow(_ row: UsageRow, isLast: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if row.indent > 0 {
                // Indent accent bar for nested rows
                Capsule()
                    .fill(theme.brandPrimary.opacity(0.25))
                    .frame(width: 2.5, height: 14)
                    .padding(.leading, 16)
            }

            Text(row.label)
                .font(.system(size: row.indent == 0 ? 13.5 : 12.5))
                .foregroundStyle(row.indent == 0 ? theme.textSecondary : theme.textTertiary)
                .lineLimit(1)
                .padding(.leading, row.indent == 0 ? 16 : 5)

            Spacer(minLength: 4)

            Text(row.formattedValue)
                .font(.system(size: row.indent == 0 ? 13.5 : 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(row.indent == 0 ? theme.textPrimary : theme.textSecondary)
                .padding(.trailing, 16)
        }
        .frame(minHeight: row.indent == 0 ? 36 : 30)
        .background(
            row.indent > 0
            ? (colorScheme == .dark
               ? Color.white.opacity(0.04)
               : Color.black.opacity(0.025))
            : Color.clear
        )
        .overlay(alignment: .bottom) {
            // Hair-line divider between rows (not after last)
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.leading, row.indent > 0 ? 32 : 16)
            }
        }
    }

    // MARK: - Data Flattening

    private func flattenUsage(_ dict: [String: Any], indent: Int, parentKey: String? = nil) -> [UsageRow] {
        // Swift dictionaries lose the server's key order, so rebuild the
        // order OpenWebUI's backend emits (see UsageKeyOrder). Nested groups
        // stay in place, exactly like the web UI's JSON view.
        let sortedKeys = UsageKeyOrder.sorted(Array(dict.keys), parentKey: parentKey, siblings: dict)

        var rows: [UsageRow] = []
        for key in sortedKeys {
            guard let value = dict[key] else { continue }
            if let nested = value as? [String: Any], !nested.isEmpty {
                rows.append(UsageRow(label: humanize(key), formattedValue: "", indent: indent, isHeader: true))
                rows += flattenUsage(nested, indent: indent + 1, parentKey: key)
            } else {
                if isNull(value) { continue }
                rows.append(UsageRow(label: humanize(key), formattedValue: formatValue(value), indent: indent, isHeader: false))
            }
        }
        return rows
    }

    private func isNull(_ value: Any) -> Bool {
        return value is NSNull
    }

    private func formatValue(_ value: Any) -> String {
        switch value {
        case let i as Int:
            return formatNumber(i)
        case let d as Double:
            return d == d.rounded() && abs(d) < 1_000_000
                ? formatNumber(Int(d))
                : String(format: "%.2f", d)
        case let f as Float:
            return f == f.rounded() && abs(f) < 1_000_000
                ? formatNumber(Int(f))
                : String(format: "%.2f", f)
        case let b as Bool:
            return b ? "Yes" : "No"
        case let s as String:
            return s
        default:
            return "\(value)"
        }
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func humanize(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: " ")
            .map { word in
                word.isEmpty ? word : (word.prefix(1).uppercased() + word.dropFirst())
            }
            .joined(separator: " ")
    }
}

// MARK: - Usage Key Order

/// Reconstructs the field order OpenWebUI shows in its usage tooltip.
///
/// The web UI renders `JSON.stringify(message.usage)`, i.e. the insertion order
/// produced by the backend (`backend/open_webui/utils/response.py`):
/// - Ollama: `convert_ollama_usage_to_openai` builds a fixed key order.
/// - OpenAI-compatible: the provider's order (`prompt_tokens, completion_tokens,
///   total_tokens, *_details`) followed by `normalize_usage`'s appended
///   `input_tokens, output_tokens`.
/// `JSONSerialization` discards that order, so we re-apply it here. Unknown keys
/// keep a stable alphabetical order after the known ones.
private enum UsageKeyOrder {
    static let ollama: [String] = [
        "input_tokens", "output_tokens", "total_tokens",
        "prompt_tokens", "completion_tokens",
        "response_token/s", "prompt_token/s",
        "total_duration", "load_duration",
        "prompt_eval_count", "prompt_eval_duration",
        "eval_count", "eval_duration",
        "approximate_total",
        "completion_tokens_details",
    ]

    static let openAI: [String] = [
        "prompt_tokens", "completion_tokens", "total_tokens",
        // Common provider extras (OpenRouter / Anthropic-compatible proxies)
        "cost", "is_byok",
        "cache_creation_input_tokens", "cache_read_input_tokens",
        "prompt_tokens_details", "cost_details", "completion_tokens_details",
        // Appended by OpenWebUI's normalize_usage()
        "input_tokens", "output_tokens",
    ]

    static let nested: [String: [String]] = [
        "prompt_tokens_details": ["cached_tokens", "audio_tokens"],
        "input_tokens_details": ["cached_tokens", "audio_tokens"],
        "completion_tokens_details": [
            "reasoning_tokens", "audio_tokens",
            "accepted_prediction_tokens", "rejected_prediction_tokens",
        ],
        "output_tokens_details": [
            "reasoning_tokens", "audio_tokens",
            "accepted_prediction_tokens", "rejected_prediction_tokens",
        ],
    ]

    static func sorted(_ keys: [String], parentKey: String?, siblings: [String: Any]) -> [String] {
        let reference: [String]
        if let parentKey {
            reference = nested[parentKey] ?? []
        } else if siblings["eval_count"] != nil
                    || siblings["response_token/s"] != nil
                    || siblings["prompt_eval_count"] != nil {
            reference = ollama
        } else {
            reference = openAI
        }
        let rank = Dictionary(uniqueKeysWithValues: reference.enumerated().map { ($1, $0) })
        return keys.sorted { a, b in
            switch (rank[a], rank[b]) {
            case let (ra?, rb?): return ra < rb
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
    }
}

// MARK: - Usage Row Model

private struct UsageRow {
    let label: String
    let formattedValue: String
    let indent: Int
    let isHeader: Bool
}

// MARK: - Preview

#Preview {
    let sampleUsage: [String: Any] = [
        "completion_tokens": 72,
        "prompt_tokens": 3107,
        "total_tokens": 3179,
        "input_tokens": 3107,
        "output_tokens": 72,
        "completion_tokens_details": [
            "reasoning_tokens": 46
        ],
        "prompt_tokens_details": [
            "cached_tokens": 2048,
        ],
    ]

    VStack(spacing: 20) {
        UsageInfoPopover(usage: sampleUsage)
            .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 6)
    }
    .padding(40)
    .background(Color(.systemGroupedBackground))
    .themed()
}
