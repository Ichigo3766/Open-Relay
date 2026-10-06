import SwiftUI

// MARK: - Per-language translations (meta.i18n)
//
// Mirrors the web editor: `meta.i18n[locale]` holds `name`, `description` and
// `suggestion_prompts`. Empty values are pruned on save (`pruneEmptyLocaleEntries`),
// and locales left with no fields are dropped.

typealias LocalizedMap = [String: [String: Any]]

enum LocalizedContent {
    /// Parses `meta.i18n` out of a raw meta dictionary.
    static func read(_ meta: [String: Any]) -> LocalizedMap {
        (meta["i18n"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    /// Mirrors `pruneEmptyLocaleEntries`: drop blank strings/null, keep arrays,
    /// and remove locales that end up empty.
    static func prune(_ map: LocalizedMap) -> LocalizedMap {
        var out: LocalizedMap = [:]
        for (locale, entry) in map {
            let kept = entry.filter { _, value in
                if let s = value as? String { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if value is NSNull { return false }
                return true
            }
            if !kept.isEmpty { out[locale] = kept }
        }
        return out
    }
}

/// Searchable language picker (the 64 locales the server knows).
struct LocalePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selected: String
    let onPick: (String) -> Void
    @State private var search = ""

    private var filtered: [(code: String, title: String)] {
        search.isEmpty ? OpenWebUILanguages.all
            : OpenWebUILanguages.all.filter {
                $0.title.localizedCaseInsensitiveContains(search) || $0.code.localizedCaseInsensitiveContains(search)
            }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.code) { lang in
                Button { onPick(lang.code) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(lang.title)
                            Text(lang.code).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if lang.code == selected { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search)
            .navigationTitle("Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }
}
