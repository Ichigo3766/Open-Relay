import SwiftUI

// MARK: - Chat variables preview (system prompt)
//
// Mirrors `getChatVariablesPreview` in ModelEditor.svelte: lists `{{chat.variables.x}}` and
// `{{user.variables.x}}` placeholders found in the system prompt and flags common mistakes.
// The server derives the real form from the prompt (`get_chat_variables_schema`); this is
// only an authoring aid.

struct ChatVariablesPreview {
    struct Field: Identifiable { let key: String; let type: String; var id: String { key } }

    var fields: [Field] = []
    var userFields: [Field] = []
    var warnings: [String] = []

    var isEmpty: Bool { fields.isEmpty && userFields.isEmpty && warnings.isEmpty }

    private static let keyPattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9_]*$")

    static func scan(_ prompt: String) -> ChatVariablesPreview {
        var out = ChatVariablesPreview()
        let ns = prompt as NSString
        let all = try! NSRegularExpression(pattern: #"\{\{\s*(chat|user)\.variables\.([a-zA-Z0-9_.\-]+)\s*(?:\|\s*([^}]*?))?\s*\}\}"#)
        var seenChat: [String: String] = [:]
        var seenUser = Set<String>()

        for m in all.matches(in: prompt, range: NSRange(location: 0, length: ns.length)) {
            let scope = ns.substring(with: m.range(at: 1))
            let key = ns.substring(with: m.range(at: 2))
            let def = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces) : nil
            let validKey = keyPattern.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil

            if scope == "user" {
                if def != nil { out.warnings.append("\(key) uses metadata, but User Variables are configured by each user") }
                if !validKey { out.warnings.append("\(key) must be lowercase snake case") }
                if seenUser.insert(key).inserted { out.userFields.append(Field(key: key, type: "text")) }
                continue
            }
            if let previous = seenChat[key], let def, previous != def {
                out.warnings.append("\(key) has conflicting duplicate definitions")
            }
            guard seenChat[key] == nil else { continue }
            seenChat[key] = def ?? ""
            let type = def.flatMap { d in
                d.range(of: #"type\s*=\s*"?([a-z]+)"?"#, options: .regularExpression).map {
                    String(d[$0]).replacingOccurrences(of: #"type\s*=\s*"?"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\"", with: "")
                }
            } ?? "text"
            if !validKey { out.warnings.append("\(key) must be lowercase snake case") }
            else if type == "select", !(def ?? "").contains("options") {
                out.warnings.append("\(key) select needs options=[...]")
            }
            out.fields.append(Field(key: key, type: type))
        }
        return out
    }
}

struct ChatVariablesPreviewView: View {
    @Environment(\.theme) private var theme
    let preview: ChatVariablesPreview

    var body: some View {
        if !preview.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Detected Variables")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                if !preview.fields.isEmpty {
                    group("Chat Variables", preview.fields.map { "\($0.key) · \($0.type)" })
                }
                if !preview.userFields.isEmpty {
                    group("User Variables", preview.userFields.map(\.key))
                }
                ForEach(preview.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .scaledFont(size: 12)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 8)
        }
    }

    private func group(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).scaledFont(size: 11).foregroundStyle(theme.textTertiary)
            Text(items.joined(separator: "   ")).scaledFont(size: 12).foregroundStyle(theme.textSecondary)
        }
    }
}
