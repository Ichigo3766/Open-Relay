import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import os.log

// MARK: - Native SSO Settings

/// Per-server, opt-in settings for signing in through the **system browser**
/// (`ASWebAuthenticationSession`) instead of the embedded web view.
///
/// The embedded WKWebView can't offer passkeys for a self-hosted identity
/// provider (needs Associated Domains + AASA on a domain the app controls) and
/// can't reuse the user's Safari SSO session. The system browser can do both, but
/// never hands the app Open WebUI's session cookie. So instead the app signs in
/// with the IdP directly as its own public OIDC client (PKCE), then trades the IdP
/// access token for an Open WebUI session via Open WebUI's token-exchange endpoint.
///
/// Scope: only ever used for the **generic OIDC** provider (`"oidc"` — Keycloak,
/// Authentik, Zitadel, …). Google, Microsoft, GitHub and Feishu always keep the
/// embedded flow, regardless of what is saved here.
///
/// Server prerequisites (Open WebUI 0.8+, 0.11+ recommended):
/// `ENABLE_OAUTH_TOKEN_EXCHANGE=true`, ``clientID`` listed in
/// `OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS`, and a public PKCE client at the IdP
/// with redirect URI `openui://oauth-callback`.
nonisolated struct NativeSSOSettings: Codable, Hashable, Sendable {
    /// Default native-app client ID expected at the IdP.
    static let defaultClientID = "openrelay-mobile"
    /// The only Open WebUI OAuth provider the native flow may be used for.
    static let providerKey = "oidc"

    /// OIDC issuer URL (e.g. `https://kc.example.com/realms/main`).
    /// Empty means "auto-detect from the server at sign-in".
    var issuerURL: String
    /// Public (native-app) OIDC client registered at the IdP.
    var clientID: String

    init(issuerURL: String = "", clientID: String = Self.defaultClientID) {
        self.issuerURL = issuerURL
        self.clientID = clientID
    }

    var trimmedIssuer: String { issuerURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedClientID: String {
        let value = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? Self.defaultClientID : value
    }

    /// Builds settings from raw form input. Returns nil when the option is off.
    static func from(enabled: Bool, issuer: String, clientID: String) -> NativeSSOSettings? {
        guard enabled else { return nil }
        let raw = NativeSSOSettings(issuerURL: issuer, clientID: clientID)
        return NativeSSOSettings(issuerURL: raw.trimmedIssuer, clientID: raw.trimmedClientID)
    }

    // MARK: Refresh-token storage (per server AND per account)

    /// Keychain key for an account's IdP refresh token. Scoped to the user ID so
    /// one account's refresh token can never be used to renew another account.
    static func refreshTokenKey(serverURL: String, userId: String) -> String {
        "native_sso_refresh_\(serverURL)::\(userId)"
    }

    /// Removes the stored refresh tokens of every saved account on `server`.
    @MainActor
    static func deleteRefreshTokens(for server: ServerConfig) {
        for account in server.savedAccounts {
            KeychainService.shared.deleteToken(
                forServer: refreshTokenKey(serverURL: server.url, userId: account.userId)
            )
        }
    }
}

// MARK: - Errors

nonisolated enum NativeOIDCAuthError: LocalizedError, Sendable {
    case issuerNotFound
    case invalidIssuer
    case discoveryFailed(statusCode: Int)
    case missingEndpoints
    case couldNotStart
    case cancelled
    case providerError(description: String)
    case stateMismatch
    case missingAuthorizationCode
    /// `oauthError` is the RFC 6749 `error` code (e.g. `invalid_grant`), when the
    /// IdP returned a proper OAuth error body.
    case tokenRequestFailed(statusCode: Int, oauthError: String?, detail: String?)
    case exchangeFailed(statusCode: Int, detail: String?)

    var errorDescription: String? {
        switch self {
        case .issuerNotFound:
            return "Couldn't find your identity provider automatically. Enter its issuer URL in the server's Advanced settings."
        case .invalidIssuer:
            return "The identity provider's issuer URL is invalid."
        case .discoveryFailed(let code):
            return "Couldn't reach your identity provider (HTTP \(code)). Check the issuer URL."
        case .missingEndpoints:
            return "Your identity provider's configuration is missing its sign-in endpoints."
        case .couldNotStart:
            return "Couldn't open the sign-in page. Please try again."
        case .cancelled:
            return "Sign-in was cancelled."
        case .providerError(let description):
            return "Your identity provider rejected the sign-in: \(description)"
        case .stateMismatch:
            return "The sign-in response failed validation. Please try again."
        case .missingAuthorizationCode:
            return "Your identity provider didn't return an authorization code."
        case .tokenRequestFailed(_, let oauthError, let detail):
            let reason = detail ?? oauthError
            return "Your identity provider didn't issue a token.\(reason.map { " \($0)" } ?? "")"
        case .exchangeFailed(let code, let detail):
            if let detail, !detail.isEmpty { return "Open WebUI rejected the sign-in: \(detail)" }
            return "Open WebUI rejected the sign-in (HTTP \(code)). Token exchange may not be enabled on this server."
        }
    }

    /// True ONLY when the IdP explicitly rejected the refresh token itself
    /// (`invalid_grant` — the offline session expired, was revoked, or the token
    /// is stale). This is the one signal that the user must sign in again and the
    /// stored refresh token should be discarded.
    var isRefreshTokenRejected: Bool {
        if case .tokenRequestFailed(let status, let code, _) = self {
            return (status == 400 || status == 401) && code == "invalid_grant"
        }
        return false
    }

    /// True when the IdP returned a well-formed OAuth error other than
    /// `invalid_grant` (e.g. `invalid_client`, `unauthorized_client`). These are
    /// configuration problems — retrying won't help.
    var isTokenEndpointConfigurationError: Bool {
        if case .tokenRequestFailed(let status, let code, _) = self, let code, !code.isEmpty {
            return (400..<500).contains(status) && code != "invalid_grant"
        }
        return false
    }

    /// True when Open WebUI's token exchange explicitly refused the IdP token.
    var isExchangeRejected: Bool {
        if case .exchangeFailed(let status, _) = self { return (400..<500).contains(status) && status != 408 && status != 429 }
        return false
    }

    /// True for failures that are likely temporary — the network wasn't ready yet,
    /// the IdP / server hiccupped (5xx, 429), or something in between (captive
    /// portal, proxy) answered with a non-OAuth body. Worth retrying, and never a
    /// reason to sign the user out.
    var isTransient: Bool {
        func transientStatus(_ s: Int) -> Bool { s < 0 || s >= 500 || s == 408 || s == 429 }
        switch self {
        case .discoveryFailed:
            // Discovery worked at sign-in, so a failure now is almost always a
            // network / proxy hiccup rather than a real configuration change.
            return true
        case .missingEndpoints:
            // Usually a captive portal / proxy page instead of real discovery JSON.
            return true
        case .tokenRequestFailed(let status, let code, _):
            return transientStatus(status) || code == nil || code?.isEmpty == true
        case .exchangeFailed(let status, _):
            return transientStatus(status)
        default:
            return false
        }
    }
}

// MARK: - Renewal outcome

/// Reads the `exp` claim of an Open WebUI JWT without verifying it — used only
/// to decide whether to renew proactively. The server stays the authority.
nonisolated enum JWTExpiry {
    static func expirationDate(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let exp = json["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        if let exp = json["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(exp)) }
        return nil
    }

    /// True when the token has an `exp` claim that is past (or within `leeway`).
    /// Tokens without `exp` (non-expiring) are never considered expiring.
    static func isExpiring(_ jwt: String, within leeway: TimeInterval) -> Bool {
        guard let exp = expirationDate(of: jwt) else { return false }
        return exp.timeIntervalSinceNow <= leeway
    }
}

/// Result of a silent native-SSO renewal attempt.
nonisolated enum NativeSSORenewalOutcome: Sendable, Equatable {
    /// A fresh Open WebUI JWT was installed — retry the request.
    case renewed
    /// The session is genuinely gone (IdP said `invalid_grant`, the server refused
    /// the exchange, or there is no refresh token) — let the 401 surface.
    case rejected
    /// Renewal couldn't complete right now (offline, timeouts, 5xx). The session
    /// may still be valid — keep the user signed in and try again later.
    case unavailable
}

// MARK: - Session result

/// Result of a successful native sign-in or silent renewal.
nonisolated struct NativeSSOSession: Sendable {
    /// Fresh Open WebUI session JWT.
    let jwt: String
    /// Open WebUI user ID the session belongs to (from the exchange response).
    let userId: String?
    /// IdP refresh token to persist — `nil` when the IdP didn't issue one.
    let refreshToken: String?
}

// MARK: - Authenticator

/// Runs the native OIDC flow for one server:
/// 1. OIDC discovery at the issuer.
/// 2. Authorization Code + PKCE (S256) in `ASWebAuthenticationSession`.
/// 3. Code → IdP access (+ refresh) token (public client, no secret).
/// 4. Access token → Open WebUI JWT via `POST /api/v1/auths/oauth/oidc/token/exchange`.
///
/// Step 4 is sent on the server's own `URLSession` so custom headers, proxy /
/// Cloudflare cookies and self-signed trust apply exactly as for other requests,
/// but it deliberately bypasses the app's 401 recovery and auto-sign-out paths.
@MainActor
final class NativeOIDCAuthenticator {
    static let callbackScheme = "openui"
    static let callbackHost = "oauth-callback"
    static let redirectURI = "openui://oauth-callback"
    /// `offline_access` asks the IdP for a long-lived refresh token so an expired
    /// Open WebUI session can be renewed silently.
    static let scopes = "openid email profile offline_access"

    private let server: ServerConfig
    private let client: APIClient
    private var webSession: ASWebAuthenticationSession?
    private let anchorProvider = WebAuthPresentationAnchorProvider()
    private let logger = Logger(subsystem: "com.openui", category: "NativeSSO")

    init(server: ServerConfig, client: APIClient) {
        self.server = server
        self.client = client
    }

    // MARK: Public flows

    /// Interactive sign-in through the system browser.
    func signIn(issuerURL: String, clientID: String) async throws -> NativeSSOSession {
        let metadata = try await Self.fetchDiscovery(issuer: issuerURL, allowSelfSigned: server.allowSelfSignedCertificates, clientCertificateServerURL: server.url)

        let verifier = Self.randomBase64URL(bytes: 32)
        let state = Self.randomBase64URL(bytes: 32)
        let startURL = try Self.authorizeURL(
            endpoint: metadata.authorizationEndpoint,
            clientID: clientID,
            state: state,
            codeChallenge: Self.codeChallenge(for: verifier)
        )

        let callbackURL = try await presentBrowser(startURL)
        let code = try Self.parseCallback(callbackURL, expectedState: state)

        let tokens = try await tokenRequest(endpoint: metadata.tokenEndpoint, form: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", Self.redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ])

        let exchanged = try await exchange(accessToken: tokens.accessToken)
        logger.info("Native SSO: sign-in exchange succeeded (refresh token \(tokens.refreshToken != nil ? "issued" : "absent", privacy: .public))")
        return NativeSSOSession(jwt: exchanged.token, userId: exchanged.userId, refreshToken: tokens.refreshToken)
    }

    /// Silent renewal — no UI. Refreshes the IdP access token and re-runs the
    /// Open WebUI exchange. The input refresh token is echoed back when the IdP
    /// doesn't rotate it, so the caller can always overwrite its stored value.
    ///
    /// `onRefreshTokenRotated` fires the moment the IdP hands back a NEW refresh
    /// token — before the Open WebUI exchange runs — so a rotated token is never
    /// lost if the exchange (or the app) dies afterwards. Losing it would leave
    /// only the old, already-revoked token and force a real sign-out next time.
    func renew(
        issuerURL: String,
        clientID: String,
        refreshToken: String,
        onRefreshTokenRotated: (String) -> Void = { _ in }
    ) async throws -> NativeSSOSession {
        let metadata = try await Self.cachedDiscovery(
            issuer: issuerURL,
            allowSelfSigned: server.allowSelfSignedCertificates,
            clientCertificateServerURL: server.url
        )
        let tokens: TokenResponse
        do {
            tokens = try await tokenRequest(endpoint: metadata.tokenEndpoint, form: [
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
                ("client_id", clientID),
            ], waitForConnectivity: true)
        } catch {
            // A stale cached endpoint is possible (IdP moved) — re-discover next time
            // unless the IdP clearly answered with an OAuth error.
            if let authError = error as? NativeOIDCAuthError,
               authError.isRefreshTokenRejected || authError.isTokenEndpointConfigurationError {
                throw error
            }
            Self.discoveryCache[Self.discoveryCacheKey(issuerURL)] = nil
            throw error
        }
        if let rotated = tokens.refreshToken, rotated != refreshToken {
            onRefreshTokenRotated(rotated)
        }
        let exchanged = try await exchange(accessToken: tokens.accessToken)
        logger.info("Native SSO: silent renewal succeeded")
        return NativeSSOSession(jwt: exchanged.token, userId: exchanged.userId, refreshToken: tokens.refreshToken ?? refreshToken)
    }

    // MARK: Issuer detection

    /// Detects the IdP issuer without any UI: asks Open WebUI for its OIDC login
    /// redirect (`GET /oauth/oidc/login`, redirects not followed), then probes
    /// `.well-known/openid-configuration` on successively shorter path prefixes of
    /// the IdP URL (e.g. Keycloak `/realms/x/protocol/openid-connect/auth` → `/realms/x`).
    /// Returns nil if the server doesn't redirect to an IdP or the IdP has no discovery.
    func detectIssuer() async -> String? {
        guard var request = try? client.network.buildRequest(
            path: "/oauth/\(NativeSSOSettings.providerKey)/login",
            authenticated: false,
            timeout: 15
        ), let serverHost = request.url?.host?.lowercased() else { return nil }
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        // Carry proxy / Cloudflare cookies for the server (the ephemeral session has none).
        if let url = request.url, let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Follow same-origin hops (e.g. http→https) manually; stop at the first
        // redirect that leaves the Open WebUI origin — that's the IdP hand-off.
        var landing: URL?
        for _ in 0..<3 {
            guard let (_, response) = try? await Self.send(
                request,
                trustHosts: [serverHost],
                allowSelfSigned: server.allowSelfSignedCertificates,
                clientCertificateServerURL: server.url,
                followRedirects: false
            ),
                  [301, 302, 303, 307, 308].contains(response.statusCode),
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let target = URL(string: location, relativeTo: request.url)?.absoluteURL
            else { return nil }

            if target.host?.lowercased() == serverHost {
                request.url = target
                continue
            }
            landing = target
            break
        }
        guard let landing else { return nil }
        let issuer = await Self.probeDiscovery(from: landing, allowSelfSigned: server.allowSelfSignedCertificates, clientCertificateServerURL: server.url)
        logger.info("Native SSO: issuer detection \(issuer == nil ? "failed" : "succeeded", privacy: .public)")
        return issuer
    }

    private static func probeDiscovery(from url: URL, allowSelfSigned: Bool, clientCertificateServerURL: String?) async -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        let segments = url.path.split(separator: "/").map(String.init)
        for depth in stride(from: min(segments.count, 6), through: 0, by: -1) {
            let prefix = segments.prefix(depth).map { "/\($0)" }.joined()
            let candidate = "\(scheme)://\(host)\(port)\(prefix)"
            if let metadata = try? await fetchDiscovery(issuer: candidate, allowSelfSigned: allowSelfSigned, clientCertificateServerURL: clientCertificateServerURL) {
                if let declared = metadata.issuer?.trimmingCharacters(in: .whitespacesAndNewlines), !declared.isEmpty {
                    return declared
                }
                return candidate
            }
        }
        return nil
    }

    // MARK: Discovery

    /// In-memory discovery cache (per issuer) so silent renewal is two requests
    /// (token + exchange) instead of three. Cleared when a renewal fails oddly.
    private static var discoveryCache: [String: OIDCMetadata] = [:]

    private static func discoveryCacheKey(_ issuer: String) -> String {
        var key = issuer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    private static func cachedDiscovery(issuer: String, allowSelfSigned: Bool, clientCertificateServerURL: String?) async throws -> OIDCMetadata {
        let key = discoveryCacheKey(issuer)
        if let cached = discoveryCache[key] { return cached }
        let metadata = try await fetchDiscovery(
            issuer: issuer,
            allowSelfSigned: allowSelfSigned,
            clientCertificateServerURL: clientCertificateServerURL,
            waitForConnectivity: true
        )
        discoveryCache[key] = metadata
        return metadata
    }

    fileprivate struct OIDCMetadata: Decodable, Sendable {
        let authorizationEndpoint: String
        let tokenEndpoint: String
        let issuer: String?

        enum CodingKeys: String, CodingKey {
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case issuer
        }
    }

    private static func fetchDiscovery(issuer: String, allowSelfSigned: Bool, clientCertificateServerURL: String?, waitForConnectivity: Bool = false) async throws -> OIDCMetadata {
        let trimmed = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased()
        else { throw NativeOIDCAuthError.invalidIssuer }

        let suffix = "/.well-known/openid-configuration"
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path.hasSuffix(suffix) ? path : path + suffix
        components.query = nil
        guard let url = components.url else { throw NativeOIDCAuthError.invalidIssuer }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request, trustHosts: [host], allowSelfSigned: allowSelfSigned, clientCertificateServerURL: clientCertificateServerURL, waitForConnectivity: waitForConnectivity)
        guard response.statusCode == 200 else {
            throw NativeOIDCAuthError.discoveryFailed(statusCode: response.statusCode)
        }
        guard let metadata = try? JSONDecoder().decode(OIDCMetadata.self, from: data),
              !metadata.authorizationEndpoint.isEmpty, !metadata.tokenEndpoint.isEmpty
        else { throw NativeOIDCAuthError.missingEndpoints }
        return metadata
    }

    // MARK: Authorize (system browser)

    private static func authorizeURL(endpoint: String, clientID: String, state: String, codeChallenge: String) throws -> URL {
        guard var components = URLComponents(string: endpoint) else { throw NativeOIDCAuthError.missingEndpoints }
        var query = components.queryItems ?? []
        query.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ])
        components.queryItems = query
        guard let url = components.url else { throw NativeOIDCAuthError.missingEndpoints }
        return url
    }

    private func presentBrowser(_ url: URL) async throws -> URL {
        defer { webSession = nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let box = ResumeOnce(continuation)
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        box.resume(.failure(NativeOIDCAuthError.cancelled))
                    } else {
                        box.resume(.failure(error))
                    }
                } else if let callbackURL {
                    box.resume(.success(callbackURL))
                } else {
                    box.resume(.failure(NativeOIDCAuthError.cancelled))
                }
            }
            session.presentationContextProvider = anchorProvider
            // Shared browser session: reuses an existing Safari sign-in at the IdP
            // and offers saved passkeys.
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                logger.error("Native SSO: ASWebAuthenticationSession failed to start")
                box.resume(.failure(NativeOIDCAuthError.couldNotStart))
            }
        }
    }

    private static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw NativeOIDCAuthError.providerError(description: value("error_description") ?? error)
        }
        // State is mandatory — a missing or different value is rejected.
        guard value("state") == expectedState else { throw NativeOIDCAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw NativeOIDCAuthError.missingAuthorizationCode }
        return code
    }

    // MARK: IdP token endpoint

    private struct TokenResponse: Sendable {
        let accessToken: String
        let refreshToken: String?
    }

    private struct TokenWire: Decodable, Sendable {
        let access_token: String?
        let refresh_token: String?
        let error: String?
        let error_description: String?
    }

    private func tokenRequest(endpoint: String, form: [(String, String)], waitForConnectivity: Bool = false) async throws -> TokenResponse {
        guard let url = URL(string: endpoint), let host = url.host?.lowercased() else {
            throw NativeOIDCAuthError.missingEndpoints
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let (data, response) = try await Self.send(request, trustHosts: [host], allowSelfSigned: server.allowSelfSignedCertificates, clientCertificateServerURL: server.url, waitForConnectivity: waitForConnectivity)
        let wire = try? JSONDecoder().decode(TokenWire.self, from: data)
        guard response.statusCode == 200, let access = wire?.access_token, !access.isEmpty else {
            let oauthError = wire?.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.warning("Native SSO: token endpoint returned HTTP \(response.statusCode, privacy: .public) error=\(oauthError ?? "none", privacy: .public)")
            throw NativeOIDCAuthError.tokenRequestFailed(
                statusCode: response.statusCode,
                oauthError: (oauthError?.isEmpty == false) ? oauthError : nil,
                detail: wire?.error_description ?? wire?.error
            )
        }
        let refresh = wire?.refresh_token
        return TokenResponse(accessToken: access, refreshToken: (refresh?.isEmpty == false) ? refresh : nil)
    }

    // MARK: Open WebUI token exchange

    private struct ExchangeWire: Decodable, Sendable {
        let token: String?
        let id: String?
        let detail: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try? c.decode(String.self, forKey: .token)
            id = try? c.decode(String.self, forKey: .id)
            // FastAPI validation errors return `detail` as an array — ignore those.
            detail = try? c.decode(String.self, forKey: .detail)
        }

        enum CodingKeys: String, CodingKey { case token, id, detail }
    }

    private func exchange(accessToken: String) async throws -> (token: String, userId: String?) {
        let body = try JSONSerialization.data(withJSONObject: ["token": accessToken])
        let request = try client.network.buildRequest(
            path: "/api/v1/auths/oauth/\(NativeSSOSettings.providerKey)/token/exchange",
            method: .post,
            body: body,
            authenticated: false,
            timeout: 30
        )

        let data: Data
        let response: URLResponse
        do {
            // Direct on the server session: gets custom headers / cookies / trust,
            // but never triggers 401 recovery or the auto-sign-out callback.
            (data, response) = try await client.network.session.data(for: request)
        } catch {
            throw APIError.from(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let wire = try? JSONDecoder().decode(ExchangeWire.self, from: data)
        guard status == 200, let token = wire?.token, !token.isEmpty else {
            logger.warning("Native SSO: token exchange returned HTTP \(status, privacy: .public)")
            throw NativeOIDCAuthError.exchangeFailed(statusCode: status, detail: wire?.detail)
        }
        return (token, wire?.id)
    }

    // MARK: HTTP plumbing (IdP + detection)

    /// Sends a request on a throwaway ephemeral session — no shared cookies, no
    /// cache. Self-signed certificates are accepted only for `trustHosts`, and only
    /// when the server itself opted into self-signed certificates.
    private static func send(
        _ request: URLRequest,
        trustHosts: Set<String>,
        allowSelfSigned: Bool,
        clientCertificateServerURL: String? = nil,
        followRedirects: Bool = true,
        waitForConnectivity: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        if waitForConnectivity {
            // Silent renewal often runs the instant the app wakes, before Wi-Fi /
            // cellular is fully back. Wait for a usable path instead of failing
            // straight away, but cap the total so renewal can't hang forever.
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForResource = 45
        }
        let delegate = IdPSessionDelegate(
            trustHosts: allowSelfSigned ? trustHosts : [],
            clientCertificateServerURL: clientCertificateServerURL,
            followRedirects: followRedirects
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NativeOIDCAuthError.discoveryFailed(statusCode: -1)
        }
        return (data, http)
    }

    /// `application/x-www-form-urlencoded` encoding (RFC 3986 unreserved set).
    private static func formEncode(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    // MARK: PKCE helpers

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomBase64URL(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return base64URL(data)
    }

    /// RFC 7636 §5 base64url encoding without padding.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Continuation guard

/// Resumes a continuation at most once — the browser completion handler and a
/// failed `start()` must never both resume it.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

// MARK: - Presentation anchor

/// Supplies the key window for `ASWebAuthenticationSession`.
final class WebAuthPresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first {
            return window
        }
        return ASPresentationAnchor()
    }
}

// MARK: - URLSession delegate (trust + redirects)

private nonisolated final class IdPSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let trustHosts: Set<String>
    /// Open WebUI server whose imported mTLS client certificate may also be presented
    /// to the identity provider (commonly behind the same client-cert proxy).
    let clientCertificateServerURL: String?
    let followRedirects: Bool

    init(trustHosts: Set<String>, clientCertificateServerURL: String?, followRedirects: Bool) {
        self.trustHosts = trustHosts
        self.clientCertificateServerURL = clientCertificateServerURL
        self.followRedirects = followRedirects
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            if let credential = TLSChallengeHandler.clientCertificateCredential(
                for: challenge,
                fallbackServerURL: clientCertificateServerURL
            ) {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              trustHosts.contains(challenge.protectionSpace.host.lowercased())
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(followRedirects ? request : nil)
    }
}
