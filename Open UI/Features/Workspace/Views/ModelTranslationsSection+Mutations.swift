import SwiftUI

// Mutation helpers for `ModelTranslationsSection` (kept separate for file size).
extension ModelTranslationsSection {
    var prompts: [SuggestionPrompt]? {
        guard let arr = i18n[locale]?["suggestion_prompts"] as? [[String: Any]] else { return nil }
        return arr.map { SuggestionPrompt(json: $0) ?? SuggestionPrompt() }
    }

    func promptBinding(_ i: Int, _ kp: WritableKeyPath<SuggestionPrompt, String>) -> Binding<String> {
        Binding(
            get: {
                guard let list = prompts, list.indices.contains(i) else { return "" }
                return list[i][keyPath: kp]
            },
            set: { text in
                guard var list = prompts, list.indices.contains(i) else { return }
                list[i][keyPath: kp] = text
                setPrompts(list)
            }
        )
    }

    func setField(_ key: String, _ value: String) {
        var entry = i18n[locale] ?? [:]
        entry[key] = value
        i18n[locale] = entry
    }

    func setPrompts(_ list: [SuggestionPrompt]?) {
        var entry = i18n[locale] ?? [:]
        if let list { entry["suggestion_prompts"] = list.map { $0.toJSON() } }
        else { entry.removeValue(forKey: "suggestion_prompts") }
        i18n[locale] = entry
    }

    func removePrompt(_ i: Int) {
        guard var list = prompts, list.indices.contains(i) else { return }
        list.remove(at: i)
        setPrompts(list)
    }
}
