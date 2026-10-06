import Foundation

// MARK: - Localized model content (web: utils/localizedContent.ts)

extension LocalizedContent {
    /// `getLocaleCandidates`: ["de-DE", "de"] for "de-DE"; ["de"] for "de".
    static func localeCandidates(_ locale: String?) -> [String] {
        guard let locale = locale?.trimmingCharacters(in: .whitespaces), !locale.isEmpty else { return [] }
        let base = locale.split(separator: "-").first.map(String.init) ?? locale
        return base != locale ? [locale, base] : [locale]
    }

    /// Locale keys to try for the current device language, most specific first,
    /// e.g. "de-DE" → ["de-DE", "de"]. Server keys look like `de-DE`, `ar`, `zh-CN`.
    static func deviceLocaleCandidates() -> [String] {
        var out: [String] = []
        for lang in Locale.preferredLanguages.prefix(2) {
            // iOS tags look like "de-DE", "zh-Hans-CN", "en-US"; map script tags to the
            // region codes Open WebUI uses.
            var tag = lang
            if tag.hasPrefix("zh-Hans") { tag = "zh-CN" }
            else if tag.hasPrefix("zh-Hant") { tag = "zh-TW" }
            for c in localeCandidates(tag) where !out.contains(c) { out.append(c) }
        }
        return out
    }

    private static func present(_ value: Any?) -> String? {
        guard let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// `resolveLocalizedString`.
    static func string(_ fallback: String?, i18n: LocalizedMap, key: String, candidates: [String]) -> String? {
        for c in candidates { if let v = present(i18n[c]?[key]) { return v } }
        return fallback
    }

    /// `resolveLocalizedModelPromptSuggestions` — a translated list, if one exists.
    static func promptSuggestions(i18n: LocalizedMap, candidates: [String]) -> [[String: Any]]? {
        for c in candidates {
            if let arr = i18n[c]?["suggestion_prompts"] as? [[String: Any]] { return arr }
        }
        return nil
    }
}
