import Foundation

/// Represents a saved user account on a specific server.
///
/// Multiple accounts can be stored per server, each with its own
/// Keychain token and cached user data. This enables instant switching
/// between accounts without re-entering credentials.
struct SavedAccount: Codable, Identifiable, Hashable, Sendable {
    /// Stable compound key: `{normalizedServerURL}::{userId}`
    let id: String

    /// The OpenWebUI user ID from the server.
    let userId: String

    /// Display name of the user.
    var userName: String

    /// Email address of the user.
    var userEmail: String

    /// Profile image URL (relative to server).
    var profileImageURL: String?

    /// User role on the server.
    var role: User.UserRole

    /// How the user authenticated (credentials, LDAP, SSO, apiKey).
    var authType: AuthType?

    /// When this account was last actively used.
    var lastUsed: Date

    /// Creates a stable account ID from server URL and user ID.
    static func makeId(serverURL: String, userId: String) -> String {
        let normalized = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        return "\(normalized)::\(userId)"
    }

    init(
        serverURL: String,
        userId: String,
        userName: String,
        userEmail: String,
        profileImageURL: String? = nil,
        role: User.UserRole = .user,
        authType: AuthType? = nil,
        lastUsed: Date = .now
    ) {
        self.id = Self.makeId(serverURL: serverURL, userId: userId)
        self.userId = userId
        self.userName = userName
        self.userEmail = userEmail
        self.profileImageURL = profileImageURL
        self.role = role
        self.authType = authType
        self.lastUsed = lastUsed
    }

    /// Display name, preferring userName.
    var displayName: String {
        userName.isEmpty ? userEmail : userName
    }
}
