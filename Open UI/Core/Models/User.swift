import Foundation

/// Represents an authenticated user from the OpenWebUI server.
struct User: Codable, Identifiable, Sendable {
    let id: String
    var username: String
    var email: String
    var name: String?
    var profileImageURL: String?
    var role: UserRole
    var isActive: Bool
    var bio: String?
    var gender: String?
    var dateOfBirth: String?
    var permissions: GroupPermissions?

    enum UserRole: String, Codable, Sendable {
        case user
        case admin
        case pending
    }

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case email
        case name
        case profileImageURL = "profile_image_url"
        case role
        case isActive = "is_active"
        case bio
        case gender
        case dateOfBirth = "date_of_birth"
        case permissions
    }

    init(
        id: String,
        username: String,
        email: String,
        name: String? = nil,
        profileImageURL: String? = nil,
        role: UserRole = .user,
        isActive: Bool = true,
        bio: String? = nil,
        gender: String? = nil,
        dateOfBirth: String? = nil,
        permissions: GroupPermissions? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.name = name
        self.profileImageURL = profileImageURL
        self.role = role
        self.isActive = isActive
        self.bio = bio
        self.gender = gender
        self.dateOfBirth = dateOfBirth
        self.permissions = permissions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        // username may fall back to name
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? name ?? ""
        // profile image might come as profile_image_url or profileImage
        profileImageURL = try container.decodeIfPresent(String.self, forKey: .profileImageURL)
        role = try container.decodeIfPresent(UserRole.self, forKey: .role) ?? .user
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        gender = try container.decodeIfPresent(String.self, forKey: .gender)
        dateOfBirth = try container.decodeIfPresent(String.self, forKey: .dateOfBirth)
        permissions = try container.decodeIfPresent(GroupPermissions.self, forKey: .permissions)
    }

    /// Display name, preferring `name` over `username`.
    var displayName: String {
        name ?? username
    }
}

extension User: Hashable {
    static func == (lhs: User, rhs: User) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
