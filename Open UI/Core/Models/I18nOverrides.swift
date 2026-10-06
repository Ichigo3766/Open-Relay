import Foundation

/// Admin → General → Translations (`I18N`): per-language overrides of UI strings.
/// Shape on the server: `{ "<locale>": { "<original text>": "<translation>" } }`.
/// The editor works on rows (one original text, many translations) exactly like the web
/// (`utils/translationDictionary.ts`) and enforces the server's rules so a save cannot 422.
struct I18nRow: Identifiable, Equatable {
    let id = UUID()
    var original: String
    var translations: [String: String]   // locale → text
}

enum I18nOverrides {
    private static let unsafe: Set<String> = ["__proto__", "prototype", "constructor"]

    static func rows(from value: [String: Any]) -> [I18nRow] {
        var byOriginal: [String: [String: String]] = [:]
        var order: [String] = []
        for (locale, dict) in value.sorted(by: { $0.key < $1.key }) {
            guard let dict = dict as? [String: Any] else { continue }
            for (orig, text) in dict.sorted(by: { $0.key < $1.key }) {
                guard let text = text as? String else { continue }
                if byOriginal[orig] == nil { order.append(orig); byOriginal[orig] = [:] }
                byOriginal[orig]?[locale] = text
            }
        }
        return order.map { I18nRow(original: $0, translations: byOriginal[$0] ?? [:]) }
    }

    /// Interpolation placeholders: `{{name}}`, `{{- name}}`, `{{name, format}}` (same regex as the server).
    static func placeholders(_ text: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"\{\{\s*-?\s*([^},]+)(?:,[^}]+)?\s*\}\}"#) else { return [] }
        let ns = text as NSString
        return Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        })
    }

    struct ValidationError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Builds the payload; throws the same errors the web shows (and the server would 422 on).
    static func payload(from rows: [I18nRow]) throws -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var seen = Set<String>()
        for row in rows {
            let translations = row.translations.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            if row.original.trimmingCharacters(in: .whitespaces).isEmpty {
                if !translations.isEmpty { throw ValidationError(message: "Original text is required for translated rows.") }
                continue
            }
            guard !unsafe.contains(row.original) else { throw ValidationError(message: "Invalid translation key: \(row.original)") }
            guard seen.insert(row.original).inserted else {
                throw ValidationError(message: "Duplicate original text: \(row.original)")
            }
            for (locale, text) in translations {
                guard !locale.trimmingCharacters(in: .whitespaces).isEmpty, !unsafe.contains(locale) else {
                    throw ValidationError(message: "Invalid language: \(locale)")
                }
                guard placeholders(row.original) == placeholders(text) else {
                    throw ValidationError(message: "Interpolation placeholders do not match: \(row.original)")
                }
                out[locale, default: [:]][row.original] = text
            }
        }
        return out
    }
}
