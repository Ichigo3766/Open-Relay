import Foundation
import Security
import LocalAuthentication

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
    /// Returns the raw stored token string. Token validity is determined by the server (401 response).
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

    // MARK: - Account-Scoped Token Storage (Multi-Account)

    /// Saves a JWT token for a specific user account on a server.
    /// Key format: `token:{normalizedServerURL}::{userId}`
    @discardableResult
    func saveToken(_ token: String, forServer serverURL: String, userId: String) -> Bool {
        guard let tokenData = token.data(using: .utf8) else { return false }
        let account = accountKey(for: serverURL, userId: userId)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

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

    /// Retrieves the JWT token for a specific user account on a server.
    /// Returns the raw stored token string. Token validity is determined by the server (401 response).
    func getToken(forServer serverURL: String, userId: String) -> String? {
        let account = accountKey(for: serverURL, userId: userId)

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

    /// Removes the JWT token for a specific user account on a server.
    @discardableResult
    func deleteToken(forServer serverURL: String, userId: String) -> Bool {
        let account = accountKey(for: serverURL, userId: userId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Checks whether a token exists for a specific user account on a server.
    func hasToken(forServer serverURL: String, userId: String) -> Bool {
        getToken(forServer: serverURL, userId: userId) != nil
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

    // MARK: - Biometric Credential Storage

    /// Saves email + password for a server, protected by biometric authentication
    /// (Face ID / Touch ID). The item requires `.userPresence` — the OS will
    /// show the Face ID / Touch ID prompt before allowing reads.
    ///
    /// Returns `true` on success. Returns `false` if the device doesn't support
    /// biometrics or if saving fails.
    @discardableResult
    func saveBiometricCredentials(email: String, password: String, forServer serverURL: String) -> Bool {
        let key = biometricCredentialKey(for: serverURL)
        let payload = "\(email)\n\(password)"
        guard let data = payload.data(using: .utf8) else { return false }

        // Delete existing item first (update is not supported with .userPresence access control)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Create access control requiring biometric or device passcode
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &error
        ) else { return false }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieves the saved biometric credentials for a server.
    ///
    /// This call will trigger a Face ID / Touch ID prompt (or passcode fallback).
    /// `prompt` is the string shown in the system biometric dialog.
    ///
    /// Returns `(email, password)` on success, `nil` on failure or cancellation.
    func loadBiometricCredentials(forServer serverURL: String, prompt: String = "Sign in to Open Relay") -> (email: String, password: String)? {
        let key = biometricCredentialKey(for: serverURL)

        let context = LAContext()
        context.localizedReason = prompt
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let payload = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parts = payload.components(separatedBy: "\n")
        guard parts.count >= 2 else { return nil }
        return (email: parts[0], password: parts[1...].joined(separator: "\n"))
    }

    /// Checks whether biometric credentials are saved for a server (no biometric prompt).
    func hasBiometricCredentials(forServer serverURL: String) -> Bool {
        let key = biometricCredentialKey(for: serverURL)
        // Use kSecUseAuthenticationUIFail so the system doesn't show a prompt —
        // we just want to know if the item exists.
        let noInteractionContext = LAContext()
        noInteractionContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecUseAuthenticationContext as String: noInteractionContext
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed means item exists but requires auth (what we want)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Deletes saved biometric credentials for a server.
    @discardableResult
    func deleteBiometricCredentials(forServer serverURL: String) -> Bool {
        let key = biometricCredentialKey(for: serverURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Whether the current device supports biometric authentication (Face ID / Touch ID).
    var isBiometricsAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// The human-readable name for the available biometric type ("Face ID", "Touch ID", or nil).
    var biometricTypeName: String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    // MARK: - Private

    /// Derives a stable Keychain account key from a server URL.
    private func accountKey(for serverURL: String) -> String {
        let normalized = normalizeURL(serverURL)
        return "token:\(normalized)"
    }

    /// Derives a stable Keychain account key scoped to a specific user account.
    private func accountKey(for serverURL: String, userId: String) -> String {
        let normalized = normalizeURL(serverURL)
        return "token:\(normalized)::\(userId)"
    }

    /// Derives the Keychain account key for biometric credentials.
    private func biometricCredentialKey(for serverURL: String) -> String {
        let normalized = normalizeURL(serverURL)
        return "biometric_creds:\(normalized)"
    }

    /// Normalizes a URL for use as a Keychain key component.
    private func normalizeURL(_ serverURL: String) -> String {
        serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }

}
