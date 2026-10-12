import Foundation

/// Public control labels and identifiers. Parameter bundles are applied by the server.
struct NamedModelControl: Codable, Hashable, Identifiable, Sendable {
    struct Option: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let label: String
    }
    let id: String
    let label: String
    let description: String?
    let display: String
    let defaultOption: String?
    let options: [Option]

    var defaultLabel: String {
        options.first { $0.id == defaultOption }.map { "Default · \($0.label)" } ?? "Default"
    }

    static func settingsUI(_ settings: [String: Any], modelID: String, controlIDs: [String], selections: [String: String]) -> [String: Any] {
        var ui = settings["ui"] as? [String: Any] ?? [:]
        var params = ui["params"] as? [String: Any] ?? [:]
        var models = params["model_controls"] as? [String: Any] ?? [:]
        var choices = models[modelID] as? [String: Any] ?? [:]
        for id in controlIDs { choices[id] = selections[id] }
        models[modelID] = choices
        params["model_controls"] = models
        ui["params"] = params
        return ui
    }

    /// Preserve JSON insertion order: slider positions follow the server's option order.
    static func decode(_ data: Data, locales: [String]) -> [String: [NamedModelControl]] {
        var parser = OrderedControlJSON.Parser(bytes: Array(data))
        guard let root = try? parser.value() else { return [:] }
        let items = (root["data"] ?? root["models"] ?? root).array ?? [root]
        var result: [String: [NamedModelControl]] = [:]
        for model in items {
            guard let modelID = model["id"]?.string else { continue }
            let info = model["info"] ?? model
            let i18n = info["meta"]?["i18n"]
            func text(_ fallback: String, _ key: String) -> String {
                for locale in locales {
                    if let translated = i18n?[locale]?["model_controls.\(key)"]?.string,
                       !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return translated }
                }
                return fallback
            }
            result[modelID] = (info["params"]?["model_controls"]?.fields ?? []).compactMap { id, control in
                let options = (control["options"]?.fields ?? []).map { key, option in
                    Option(id: key, label: text(option["label"]?.string ?? key, "\(id).options.\(key).label"))
                }
                guard !options.isEmpty else { return nil }
                return NamedModelControl(
                    id: id, label: text(control["label"]?.string ?? id, "\(id).label"),
                    description: text(control["description"]?.string ?? "", "\(id).description"),
                    display: control["display"]?.string ?? "menu",
                    defaultOption: control["default"]?.string, options: options)
            }
        }
        return result
    }
}

/// Only containers and strings are needed to read ordered control definitions.
private indirect enum OrderedControlJSON {
    case object([(String, OrderedControlJSON)]), list([OrderedControlJSON]), text(String), other
    var fields: [(String, OrderedControlJSON)]? { if case .object(let v) = self { return v }; return nil }
    var array: [OrderedControlJSON]? { if case .list(let v) = self { return v }; return nil }
    var string: String? { if case .text(let v) = self { return v }; return nil }
    subscript(_ key: String) -> OrderedControlJSON? { fields?.first { $0.0 == key }?.1 }

    struct Parser {
        let bytes: [UInt8]
        var index = 0
        enum Failure: Error { case invalid }
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) throws {
            whitespace()
            guard index < bytes.count, bytes[index] == byte else { throw Failure.invalid }
            index += 1
        }
        mutating func value(depth: Int = 0) throws -> OrderedControlJSON {
            whitespace()
            guard index < bytes.count, depth < 80 else { throw Failure.invalid }
            let first = bytes[index]
            if first == 34 {
                let start = index
                index += 1
                while index < bytes.count {
                    let byte = bytes[index]
                    index += 1
                    if byte == 92 { index += 1 }
                    else if byte == 34 {
                        return .text(try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])))
                    }
                }
                throw Failure.invalid
            }
            if first == 123 || first == 91 {
                index += 1
                let end: UInt8 = first == 123 ? 125 : 93
                var fields: [(String, OrderedControlJSON)] = []
                var items: [OrderedControlJSON] = []
                whitespace()
                if index < bytes.count, bytes[index] != end {
                    while true {
                        if first == 123 {
                            guard let key = try value(depth: depth + 1).string else { throw Failure.invalid }
                            try take(58)
                            fields.append((key, try value(depth: depth + 1)))
                        } else { items.append(try value(depth: depth + 1)) }
                        whitespace()
                        if index < bytes.count, bytes[index] == end { break }
                        try take(44)
                    }
                }
                try take(end)
                return first == 123 ? .object(fields) : .list(items)
            }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw Failure.invalid }
            return .other
        }
    }
}
