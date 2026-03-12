import Foundation
import Security

/// Securely stores and retrieves authentication tokens using the iOS Keychain.
///
/// Each token is scoped to a server URL so multiple server configurations
/// can store independent credentials.
final class KeychainService: Sendable {
    private let serviceName: String

    /// Shared instance using the default service name.
    static let shared = KeychainService()

    init(serviceName: String = "com.openui.auth") {
        self.serviceName = serviceName
    }

    // MARK: - Token Storage

    /// Saves a JWT token for the given server URL.
    @discardableResult
    func saveToken(_ token: String, forServer serverURL: String) -> Bool {
        guard let tokenData = token.data(using: .utf8) else { return false }
        let account = accountKey(for: serverURL)

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new token
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieves the JWT token for the given server URL.
    func getToken(forServer serverURL: String) -> String? {
        let account = accountKey(for: serverURL)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the JWT token for the given server URL.
    @discardableResult
    func deleteToken(forServer serverURL: String) -> Bool {
        let account = accountKey(for: serverURL)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Checks whether a token exists for the given server URL.
    func hasToken(forServer serverURL: String) -> Bool {
        getToken(forServer: serverURL) != nil
    }

    /// Removes all tokens managed by this service.
    @discardableResult
    func deleteAllTokens() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private

    /// Derives a stable Keychain account key from a server URL.
    private func accountKey(for serverURL: String) -> String {
        // Normalize the URL to avoid duplicates from trailing slashes
        let normalized = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        return "token:\(normalized)"
    }
}
