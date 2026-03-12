import Foundation

// MARK: - Admin User Model

/// A richer user model returned by admin endpoints (`/api/v1/users/`).
/// Contains fields not present in the basic `User` model, such as
/// `lastActiveAt`, `createdAt`, and OAuth info.
struct AdminUser: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var email: String
    var role: User.UserRole
    var profileImageURL: String?
    var profileBannerImageURL: String?
    var username: String?
    var bio: String?
    var lastActiveAt: Int // Unix timestamp
    var createdAt: Int    // Unix timestamp
    var updatedAt: Int    // Unix timestamp
    var oauth: OAuthInfo?
    var info: UserInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case email
        case role
        case profileImageURL = "profile_image_url"
        case profileBannerImageURL = "profile_banner_image_url"
        case username
        case bio
        case lastActiveAt = "last_active_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case oauth
        case info
    }

    /// Resilient decoder that handles nullable fields, missing fields,
    /// and type mismatches (e.g., timestamps as Int or Double).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        role = try c.decodeIfPresent(User.UserRole.self, forKey: .role) ?? .user
        profileImageURL = try c.decodeIfPresent(String.self, forKey: .profileImageURL)
        profileBannerImageURL = try c.decodeIfPresent(String.self, forKey: .profileBannerImageURL)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        // Handle timestamps as Int or Double
        if let ts = try? c.decode(Int.self, forKey: .lastActiveAt) { lastActiveAt = ts }
        else if let ts = try? c.decode(Double.self, forKey: .lastActiveAt) { lastActiveAt = Int(ts) }
        else { lastActiveAt = 0 }
        if let ts = try? c.decode(Int.self, forKey: .createdAt) { createdAt = ts }
        else if let ts = try? c.decode(Double.self, forKey: .createdAt) { createdAt = Int(ts) }
        else { createdAt = 0 }
        if let ts = try? c.decode(Int.self, forKey: .updatedAt) { updatedAt = ts }
        else if let ts = try? c.decode(Double.self, forKey: .updatedAt) { updatedAt = Int(ts) }
        else { updatedAt = 0 }
        oauth = try? c.decodeIfPresent(OAuthInfo.self, forKey: .oauth)
        info = try? c.decodeIfPresent(UserInfo.self, forKey: .info)
    }

    // MARK: - Computed Properties

    /// Display name, preferring `name` over `username`.
    var displayName: String {
        name.isEmpty ? (username ?? email) : name
    }

    /// Date object from the `lastActiveAt` timestamp.
    var lastActiveDate: Date {
        Date(timeIntervalSince1970: TimeInterval(lastActiveAt))
    }

    /// Date object from the `createdAt` timestamp.
    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }

    /// Whether the user was active within the last 5 minutes.
    var isCurrentlyActive: Bool {
        Date().timeIntervalSince(lastActiveDate) < 300 // 5 minutes
    }

    /// Human-readable "last active" string (e.g. "2 min. ago").
    var lastActiveString: String {
        lastActiveDate.relativeString
    }

    /// Formatted creation date (e.g. "March 17, 2025").
    var createdDateString: String {
        Self._createdDateFormatter.string(from: createdDate)
    }

    /// First OAuth provider name if available (e.g. "google").
    var oauthProviderName: String? {
        oauth?.providers.first?.key
    }

    /// First OAuth provider ID if available.
    var oauthProviderId: String? {
        guard let providers = oauth?.providers, let first = providers.first else { return nil }
        return first.value
    }

    private static let _createdDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()
}

// MARK: - OAuth Info

/// OAuth connection info for a user.
struct OAuthInfo: Codable, Hashable, Sendable {
    /// Dictionary of provider → ID (e.g. ["google": "118024293351753777783"])
    let providers: [String: String]

    init(from decoder: Decoder) throws {
        // The OAuth field can be a dict of provider → ID string
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: String].self) {
            providers = dict
        } else {
            providers = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(providers)
    }
}

// MARK: - User Info

/// Additional user info metadata.
struct UserInfo: Codable, Hashable, Sendable {
    // Flexible dictionary to capture any extra fields
    let data: [String: AnyCodable]?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        data = try? container.decode([String: AnyCodable].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}

/// Type-erased Codable wrapper for flexible JSON values.
struct AnyCodable: Codable, Hashable, Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string = value as? String {
            try container.encode(string)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}

// MARK: - Admin API Response Models

/// Response from `GET /api/v1/users/` — paginated user list with group IDs.
struct AdminUserListResponse: Codable, Sendable {
    let data: [AdminUser]
    let total: Int?
    let page: Int?

    enum CodingKeys: String, CodingKey {
        case data
        case total
        case page
    }

    init(from decoder: Decoder) throws {
        // The API may return the array directly or wrapped in a response object
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            data = (try? container.decode([AdminUser].self, forKey: .data)) ?? []
            total = try? container.decode(Int.self, forKey: .total)
            page = try? container.decode(Int.self, forKey: .page)
        } else {
            // Fallback: direct array
            let container = try decoder.singleValueContainer()
            data = (try? container.decode([AdminUser].self)) ?? []
            total = nil
            page = nil
        }
    }
}

/// Response from `GET /api/v1/chats/list/user/{user_id}` — user's chat list.
struct AdminChatItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let updatedAt: Int
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case updatedAt = "updated_at"
        case createdAt = "created_at"
    }

    var updatedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAt))
    }

    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }
}

/// Form for updating a user via `POST /api/v1/users/{user_id}/update`.
struct AdminUserUpdateForm: Codable, Sendable {
    let role: String
    let name: String
    let email: String
    let profileImageURL: String
    let password: String?

    enum CodingKeys: String, CodingKey {
        case role
        case name
        case email
        case profileImageURL = "profile_image_url"
        case password
    }
}

/// Form for adding a new user via `POST /api/v1/auths/add`.
struct AdminAddUserForm: Codable, Sendable {
    let name: String
    let email: String
    let password: String
    let role: String
    let profileImageURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case email
        case password
        case role
        case profileImageURL = "profile_image_url"
    }
}
