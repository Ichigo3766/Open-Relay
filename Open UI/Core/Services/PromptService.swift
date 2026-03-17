import Foundation
import UIKit

// MARK: - Prompt Service

/// Handles parsing, variable extraction, and substitution for Open WebUI prompt templates.
///
/// Implements the full variable system as documented at:
/// https://docs.openwebui.com/features/ai-knowledge/prompts/#prompt-variables
///
/// Variable syntax:
/// - System: `{{CURRENT_DATE}}`, `{{USER_NAME}}`, etc.
/// - Simple custom: `{{variable_name}}`
/// - Typed custom: `{{variable_name | type:property="value":required}}`
enum PromptService {

    // MARK: - Variable Extraction

    /// Extracts all custom input variables from a prompt template string.
    ///
    /// Skips system variables (CURRENT_DATE, USER_NAME, etc.) since those are
    /// auto-resolved and don't require user input.
    ///
    /// Matches the Open WebUI web client's `extractInputVariables()` from `src/lib/utils/index.ts`.
    static func extractCustomVariables(from content: String) -> [PromptVariable] {
        // Regex matches both:
        //   {{variable_name}}
        //   {{variable_name | type:prop="value":required}}
        let pattern = #"\{\{\s*([^|}\s]+)\s*(?:\|\s*([^}]+))?\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        var seenNames = Set<String>()
        var variables: [PromptVariable] = []

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: content) else { continue }
            let name = String(content[nameRange]).trimmingCharacters(in: .whitespaces)
            let fullMatchRange = Range(match.range, in: content)!
            let rawMatch = String(content[fullMatchRange])

            // Skip system variables — they're auto-resolved
            if SystemVariable.allNames.contains(name) { continue }

            // Skip duplicates (same variable name appears multiple times)
            if seenNames.contains(name) { continue }
            seenNames.insert(name)

            // Check if there's a type definition after the pipe
            if match.range(at: 2).location != NSNotFound,
               let defRange = Range(match.range(at: 2), in: content) {
                let definition = String(content[defRange]).trimmingCharacters(in: .whitespaces)
                let variable = parseVariableDefinition(name: name, definition: definition, rawMatch: rawMatch)
                variables.append(variable)
            } else {
                // Simple variable — defaults to text type
                variables.append(.simple(name: name, rawMatch: rawMatch))
            }
        }

        return variables
    }

    /// Parses a variable definition string (everything after the `|`).
    ///
    /// Example: `"text:placeholder=\"Enter name\":required"` →
    /// `PromptVariable(type: .text, placeholder: "Enter name", isRequired: true)`
    ///
    /// Matches the Open WebUI `parseVariableDefinition()` from `src/lib/utils/index.ts`.
    private static func parseVariableDefinition(name: String, definition: String, rawMatch: String) -> PromptVariable {
        let parts = splitProperties(definition, delimiter: ":")
        guard let firstPart = parts.first else {
            return .simple(name: name, rawMatch: rawMatch)
        }

        // First part is the type (or type=value)
        let typeString: String
        if firstPart.hasPrefix("type=") {
            typeString = String(firstPart.dropFirst(5))
        } else {
            typeString = firstPart
        }
        let type = PromptVariable.VariableType(rawValue: typeString) ?? .text

        // Parse remaining properties
        var placeholder: String?
        var defaultValue: String?
        var isRequired = false
        var options: [String]?
        var min: String?
        var max: String?
        var step: String?
        var label: String?

        for part in parts.dropFirst() {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Split on first `=` only
            if let eqIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                let parsedValue = stripQuotes(value)

                switch key {
                case "placeholder": placeholder = parsedValue
                case "default": defaultValue = parsedValue
                case "options": options = parseJSONArray(value)
                case "min": min = parsedValue
                case "max": max = parsedValue
                case "step": step = parsedValue
                case "label": label = parsedValue
                default: break
                }
            } else {
                // Bare flag (e.g., "required")
                if trimmed == "required" {
                    isRequired = true
                }
            }
        }

        let displayName = name.replacingOccurrences(of: "_", with: " ").localizedCapitalized

        return PromptVariable(
            id: name,
            name: name,
            displayName: displayName,
            type: type,
            placeholder: placeholder,
            defaultValue: defaultValue,
            isRequired: isRequired,
            options: options,
            min: min,
            max: max,
            step: step,
            label: label,
            rawMatch: rawMatch
        )
    }

    // MARK: - System Variable Resolution

    /// Replaces all system variables in a prompt template with their current values.
    ///
    /// Called AFTER custom variables are substituted. System variables that can't
    /// be resolved (e.g., USER_LOCATION without HTTPS) are left as-is per the
    /// Open WebUI documentation.
    static func resolveSystemVariables(in content: String, userName: String?, userEmail: String?) -> String {
        var result = content

        let dateFormatter = DateFormatter()

        // {{CURRENT_DATE}} → YYYY-MM-DD
        dateFormatter.dateFormat = "yyyy-MM-dd"
        result = result.replacingOccurrences(of: "{{CURRENT_DATE}}", with: dateFormatter.string(from: Date()))

        // {{CURRENT_TIME}} → HH:MM:SS
        dateFormatter.dateFormat = "HH:mm:ss"
        result = result.replacingOccurrences(of: "{{CURRENT_TIME}}", with: dateFormatter.string(from: Date()))

        // {{CURRENT_DATETIME}} → YYYY-MM-DD HH:MM:SS
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        result = result.replacingOccurrences(of: "{{CURRENT_DATETIME}}", with: dateFormatter.string(from: Date()))

        // {{CURRENT_TIMEZONE}}
        result = result.replacingOccurrences(of: "{{CURRENT_TIMEZONE}}", with: TimeZone.current.identifier)

        // {{CURRENT_WEEKDAY}}
        dateFormatter.dateFormat = "EEEE"
        result = result.replacingOccurrences(of: "{{CURRENT_WEEKDAY}}", with: dateFormatter.string(from: Date()))

        // {{USER_NAME}}
        if let name = userName, !name.isEmpty {
            result = result.replacingOccurrences(of: "{{USER_NAME}}", with: name)
        }

        // {{USER_EMAIL}}
        if let email = userEmail, !email.isEmpty {
            result = result.replacingOccurrences(of: "{{USER_EMAIL}}", with: email)
        }

        // {{USER_LANGUAGE}}
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en"
        let regionCode = Locale.current.region?.identifier ?? ""
        let locale = regionCode.isEmpty ? languageCode : "\(languageCode)-\(regionCode)"
        result = result.replacingOccurrences(of: "{{USER_LANGUAGE}}", with: locale)

        // {{CLIPBOARD}} — requires clipboard access
        if result.contains("{{CLIPBOARD}}") {
            let clipboardContent = UIPasteboard.general.string ?? ""
            result = result.replacingOccurrences(of: "{{CLIPBOARD}}", with: clipboardContent)
        }

        // NOTE: The following variables are left as-is if not available,
        // matching Open WebUI's documented behavior:
        // {{USER_BIO}}, {{USER_GENDER}}, {{USER_BIRTH_DATE}}, {{USER_AGE}}, {{USER_LOCATION}}
        // These require user profile data we don't have on the client side.

        return result
    }

    // MARK: - Variable Substitution

    /// Replaces custom variable placeholders in the content with user-provided values.
    ///
    /// For each variable, replaces ALL occurrences of its `rawMatch` pattern
    /// with the corresponding value. If a value is empty (optional field left blank),
    /// the placeholder is replaced with an empty string.
    static func substituteCustomVariables(in content: String, values: [String: String], variables: [PromptVariable]) -> String {
        var result = content

        for variable in variables {
            let value = values[variable.name] ?? ""
            result = result.replacingOccurrences(of: variable.rawMatch, with: value)
        }

        // Clean up any remaining unresolved custom variables (malformed syntax, etc.)
        // by leaving them as-is (don't strip — user might want to see them)

        return result
    }

    /// Complete prompt processing pipeline: extracts variables, substitutes user values,
    /// then resolves system variables.
    static func processPrompt(
        content: String,
        userValues: [String: String],
        variables: [PromptVariable],
        userName: String?,
        userEmail: String?
    ) -> String {
        var result = substituteCustomVariables(in: content, values: userValues, variables: variables)
        result = resolveSystemVariables(in: result, userName: userName, userEmail: userEmail)
        return result
    }

    // MARK: - Property Parsing Helpers

    /// Splits a string by a delimiter, respecting quoted strings and brackets.
    ///
    /// Matches the Open WebUI `splitProperties()` from `src/lib/utils/index.ts`.
    /// Handles nested JSON arrays in property values (e.g., `options=["High","Low"]`).
    private static func splitProperties(_ str: String, delimiter: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var escapeNext = false

        for char in str {
            if escapeNext {
                current.append(char)
                escapeNext = false
                continue
            }

            if char == "\\" {
                current.append(char)
                escapeNext = true
                continue
            }

            if char == "\"" && !escapeNext {
                inString.toggle()
                current.append(char)
                continue
            }

            if !inString {
                if char == "{" || char == "[" {
                    depth += 1
                } else if char == "}" || char == "]" {
                    depth -= 1
                }

                if char == delimiter && depth == 0 {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        result.append(trimmed)
                    }
                    current = ""
                    continue
                }
            }

            current.append(char)
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            result.append(trimmed)
        }

        return result
    }

    /// Strips surrounding double quotes from a string value.
    private static func stripQuotes(_ value: String) -> String {
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Parses a JSON array string (e.g., `["High","Medium","Low"]`) into a Swift array.
    private static func parseJSONArray(_ value: String) -> [String]? {
        guard let data = value.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        return array.compactMap { item -> String? in
            if let str = item as? String { return str }
            return "\(item)"
        }
    }
}
