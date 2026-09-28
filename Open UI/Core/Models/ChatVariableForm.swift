import Foundation

/// A snapshot of model-defined inputs and the conversation/account they belong to.
struct ChatVariableForm: Identifiable {
    let id = UUID()
    let modelID: String
    let modelName: String
    let chatID: String?
    let scope: String?
    let draftGeneration: Int
    let fields: [PromptVariable]

    init(model: AIModel, values: [String: Any], chatID: String?, scope: String?, draftGeneration: Int = 0) {
        modelID = model.id
        modelName = model.name
        self.chatID = chatID
        self.scope = scope
        self.draftGeneration = draftGeneration
        let schema = model.chatVariablesSchema.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        var seen = Set<String>()
        fields = (schema?["fields"] as? [[String: Any]] ?? []).compactMap { field in
            guard let key = field["key"] as? String, !key.isEmpty, seen.insert(key).inserted else { return nil }
            let value = Self.hasValue(values[key]) ? values[key] : field["default"]
            return PromptVariable(
                id: key, name: key, displayName: field["label"] as? String ?? key,
                type: PromptVariable.VariableType(rawValue: field["type"] as? String ?? "text") ?? .textarea,
                placeholder: field["placeholder"] as? String, defaultValue: Self.text(value),
                isRequired: field["required"] as? Bool ?? false, options: field["options"] as? [String],
                min: Self.text(field["min"]), max: Self.text(field["max"]), step: Self.text(field["step"]),
                label: field["label"] as? String, rawMatch: ""
            )
        }
    }

    var needsInput: Bool {
        !fields.isEmpty && (fields.allSatisfy { !Self.hasValue($0.defaultValue) }
            || fields.contains { $0.isRequired && !Self.hasValue($0.defaultValue) })
    }

    /// Convert form strings to the native JSON types without dropping unrelated keys.
    func merging(_ input: [String: String], into saved: [String: Any]) throws -> [String: Any] {
        var result = saved
        for field in fields {
            let value = (input[field.name] ?? field.defaultValue ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            func invalid(_ reason: String) -> NSError {
                NSError(domain: "ChatVariables", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(field.displayName): \(reason)"])
            }
            if field.isRequired && value.isEmpty { throw invalid("A value is required.") }
            switch field.type {
            case .checkbox:
                result[field.name] = value.isEmpty ? "" : (value == "true") as Any
            case .number, .range:
                if value.isEmpty { result[field.name] = "" }
                else {
                    guard let number = Double(value), number.isFinite else { throw invalid("Enter a number.") }
                    if let min = field.min.flatMap(Double.init), number < min { throw invalid("The minimum is \(min).") }
                    if let max = field.max.flatMap(Double.init), number > max { throw invalid("The maximum is \(max).") }
                    result[field.name] = number
                }
            default: result[field.name] = value
            }
        }
        return result
    }

    private static func hasValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        return (value as? String) != ""
    }

    private static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string }
        guard value is NSNumber, let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
