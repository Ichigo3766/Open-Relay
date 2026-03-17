import Foundation

// MARK: - Prompt Model

/// Represents a prompt from the Open WebUI Prompt Library.
/// Matches the server's `PromptModel` schema from `GET /api/v1/prompts/`.
struct PromptItem: Identifiable, Hashable, Sendable {
    let id: String
    let command: String
    let userId: String
    let name: String
    let content: String
    let isActive: Bool
    let tags: [String]
    let createdAt: Date?
    let updatedAt: Date?

    /// Initializes from a server JSON dictionary.
    init?(json: [String: Any]) {
        guard let command = json["command"] as? String,
              let name = json["name"] as? String,
              let content = json["content"] as? String else { return nil }

        self.id = json["id"] as? String ?? UUID().uuidString
        self.command = command
        self.userId = json["user_id"] as? String ?? ""
        self.name = name
        self.content = content
        self.isActive = json["is_active"] as? Bool ?? true
        self.tags = json["tags"] as? [String] ?? []

        if let ts = json["created_at"] as? Double {
            self.createdAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["created_at"] as? Int {
            self.createdAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.createdAt = nil
        }

        if let ts = json["updated_at"] as? Double {
            self.updatedAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["updated_at"] as? Int {
            self.updatedAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.updatedAt = nil
        }
    }

    /// The slash command as displayed to the user (e.g., "/summarize").
    var displayCommand: String {
        "/\(command)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PromptItem, rhs: PromptItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Prompt Variable

/// Represents a parsed variable from a prompt template.
///
/// Handles both simple `{{variable_name}}` and typed `{{variable_name | type:prop="val"}}` formats.
struct PromptVariable: Identifiable, Sendable {
    let id: String // Same as name
    let name: String
    let displayName: String
    let type: VariableType
    let placeholder: String?
    let defaultValue: String?
    let isRequired: Bool
    let options: [String]? // For select type
    let min: String?
    let max: String?
    let step: String?
    let label: String? // For checkbox

    /// The full match string in the template (e.g., "{{name | text:required}}")
    let rawMatch: String

    enum VariableType: String, Sendable {
        case text
        case textarea
        case select
        case number
        case checkbox
        case date
        case datetimeLocal = "datetime-local"
        case color
        case email
        case month
        case range
        case tel
        case time
        case url
        case map

        /// Whether this type typically uses multiline input.
        var isMultiline: Bool {
            self == .textarea
        }
    }

    /// Creates a default simple text variable.
    static func simple(name: String, rawMatch: String) -> PromptVariable {
        PromptVariable(
            id: name,
            name: name,
            displayName: name.replacingOccurrences(of: "_", with: " ").localizedCapitalized,
            type: .text,
            placeholder: nil,
            defaultValue: nil,
            isRequired: false,
            options: nil,
            min: nil,
            max: nil,
            step: nil,
            label: nil,
            rawMatch: rawMatch
        )
    }
}

// MARK: - System Variable Names

/// Known system variables that are auto-resolved (not user-input).
enum SystemVariable: String, CaseIterable {
    case clipboard = "CLIPBOARD"
    case currentDate = "CURRENT_DATE"
    case currentDatetime = "CURRENT_DATETIME"
    case currentTime = "CURRENT_TIME"
    case currentTimezone = "CURRENT_TIMEZONE"
    case currentWeekday = "CURRENT_WEEKDAY"
    case userName = "USER_NAME"
    case userEmail = "USER_EMAIL"
    case userBio = "USER_BIO"
    case userGender = "USER_GENDER"
    case userBirthDate = "USER_BIRTH_DATE"
    case userAge = "USER_AGE"
    case userLanguage = "USER_LANGUAGE"
    case userLocation = "USER_LOCATION"

    /// All system variable placeholder strings (e.g., "CURRENT_DATE").
    static var allNames: Set<String> {
        Set(allCases.map(\.rawValue))
    }
}
