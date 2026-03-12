import Foundation

/// Configuration for connecting to an OpenWebUI server instance.
///
/// **Security:** The `apiKey` is intentionally excluded from `Codable`
/// serialisation so it is never persisted in plaintext UserDefaults.
/// Use ``KeychainService`` to store/retrieve API keys instead.
struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var url: String
    var customHeaders: [String: String]
    var lastConnected: Date?
    var isActive: Bool
    var allowSelfSignedCertificates: Bool

    /// API key — stored in Keychain, NOT serialised to UserDefaults.
    /// Populated transiently at runtime via ``KeychainService``.
    var apiKey: String?

    // Exclude apiKey from Codable to prevent plaintext storage in UserDefaults.
    enum CodingKeys: String, CodingKey {
        case id, name, url, customHeaders, lastConnected, isActive, allowSelfSignedCertificates
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        url: String,
        apiKey: String? = nil,
        customHeaders: [String: String] = [:],
        lastConnected: Date? = nil,
        isActive: Bool = false,
        allowSelfSignedCertificates: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.apiKey = apiKey
        self.customHeaders = customHeaders
        self.lastConnected = lastConnected
        self.isActive = isActive
        self.allowSelfSignedCertificates = allowSelfSignedCertificates
    }

    /// The base API URL derived from the server URL.
    var apiBaseURL: URL? {
        URL(string: url)
    }
}
