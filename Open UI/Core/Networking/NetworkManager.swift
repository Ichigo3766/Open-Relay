import Foundation
import os.log

/// Handles low-level HTTP networking — authentication, multipart uploads, and SSE streaming.
final class NetworkManager: NSObject, Sendable {
    let serverConfig: ServerConfig
    private let keychain: KeychainService
    private let logger = Logger(subsystem: "com.openui", category: "Network")

    let session: URLSession
    private let certificateDelegate: CertificateTrustDelegate

    var baseURL: URL? { serverConfig.apiBaseURL }

    var conversationCacheScope: String? {
        ConversationCache.scope(server: serverConfig.url, token: authToken, headers: serverConfig.customHeaders)
    }

    var authToken: String? {
        keychain.getToken(forServer: serverConfig.url)
    }

    /// Callback fired once when a 401 response is received, so the app can
    /// immediately route to the sign-in screen without waiting for the next
    /// API call to fail. Guarded by a one-shot flag so it fires at most once
    /// per session (avoids multiple parallel requests all triggering logout).
    private let _tokenExpiredLock = NSLock()
    private var _tokenExpiredFired = false
    var onTokenExpired: (() -> Void)?

    // MARK: - Native SSO 401 recovery (opt-in)

    /// Silent session-renewal hook, consulted when an authenticated request gets
    /// a 401 — BEFORE the failure surfaces. On `.renewed` a fresh JWT is in the
    /// Keychain and the request is retried exactly once. On `.unavailable` the
    /// renewal couldn't run right now (offline / IdP down), so the request fails
    /// with a non-auth error instead of a sign-out-triggering 401.
    ///
    /// Only registered for servers with native SSO enabled. When `nil` (every
    /// other server), `performRequest` behaves exactly as it always has.
    var onUnauthorizedRecover: (@MainActor @Sendable () async -> NativeSSORenewalOutcome)? {
        get {
            _recoverLock.lock()
            defer { _recoverLock.unlock() }
            return _onUnauthorizedRecover
        }
        set {
            _recoverLock.lock()
            _onUnauthorizedRecover = newValue
            _recoverLock.unlock()
        }
    }

    private let _recoverLock = NSLock()
    private var _onUnauthorizedRecover: (@MainActor @Sendable () async -> NativeSSORenewalOutcome)?
    /// In-flight renewal shared by concurrent 401s (single-flight).
    private var _recoveryTask: Task<NativeSSORenewalOutcome, Never>?

    /// Returns the shared in-flight renewal, starting one if needed.
    /// Lock work stays in this synchronous helper (NSLock must not span `await`).
    private func sharedRecoveryTask() -> Task<NativeSSORenewalOutcome, Never>? {
        _recoverLock.lock()
        defer { _recoverLock.unlock() }
        if let existing = _recoveryTask { return existing }
        guard let hook = _onUnauthorizedRecover else { return nil }
        let task = Task<NativeSSORenewalOutcome, Never> { await hook() }
        _recoveryTask = task
        return task
    }

    private func finishRecovery(_ task: Task<NativeSSORenewalOutcome, Never>) {
        _recoverLock.lock()
        // Only clear the marker if it still refers to this round.
        if _recoveryTask == task { _recoveryTask = nil }
        _recoverLock.unlock()
    }

    private func attemptSilentRecovery() async -> NativeSSORenewalOutcome {
        guard let task = sharedRecoveryTask() else { return .rejected }
        let outcome = await task.value
        finishRecovery(task)
        return outcome
    }

    // MARK: - Initialisation

    init(serverConfig: ServerConfig, keychain: KeychainService = .shared) {
        self.serverConfig = serverConfig
        self.keychain = keychain

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        // Do NOT set waitsForConnectivity = true here.
        // When true, iOS silently suppresses timeoutIntervalForRequest whenever the
        // network path is momentarily "unsatisfied" (which happens briefly after a
        // burst of login traffic as the radio settles). This causes all API calls —
        // getBackendConfig, getCurrentUser, loadModels, etc. — to hang indefinitely
        // rather than failing fast and allowing the connection monitor to recover.
        // Per-request timeouts (used by checkHealthFast and health checks) bypass this
        // behaviour, but regular API calls have no such override and will stall forever.
        // Removing this flag restores the expected 30s timeout behaviour on all calls.

        // Limit per-host connections to 4 (iOS default is 6 for HTTP/1.1).
        // Reserving 2 slots for health-check requests and SSE streams prevents the
        // startup request burst from exhausting the connection pool, which on
        // high-latency LAN paths (e.g. Docker/Gluetun network namespaces) caused
        // FIN_WAIT1 socket accumulation and made both the app and Safari temporarily
        // unable to reach the OpenWebUI origin for ~2 minutes after launch.
        configuration.httpMaximumConnectionsPerHost = 4

        // Disable URLSession HTTP caching — the app is API-driven with its own
        // ImageCacheService, and the default URLCache causes unbounded disk growth.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        // Explicitly set the cookie storage so cf_clearance cookies injected
        // via HTTPCookieStorage.shared are sent on every request.
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true

        // Re-inject persisted cf_clearance cookie on startup. Session cookies
        // (no expiry) vanish when the app is terminated — we persist the value
        // in ServerConfig and re-create the cookie here with the saved expiry.
        if serverConfig.isCloudflareBotProtected,
           let cfValue = serverConfig.cfClearanceValue, !cfValue.isEmpty,
           let cfExpiry = serverConfig.cfClearanceExpiry, cfExpiry > Date() {
            if let url = URL(string: serverConfig.url), let host = url.host {
                let cookieProperties: [HTTPCookiePropertyKey: Any] = [
                    .name: "cf_clearance",
                    .value: cfValue,
                    .domain: host,
                    .path: "/",
                    .secure: url.scheme == "https" ? "TRUE" : "FALSE",
                    .expires: cfExpiry
                ]
                if let cookie = HTTPCookie(properties: cookieProperties) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                    logger.info("☁️ Re-injected persisted cf_clearance cookie for \(host) (expires \(cfExpiry))")
                }
            }
        }

        // Re-inject persisted auth proxy cookies on startup (Authelia, Authentik, etc.).
        // These are session cookies with no expiry — they vanish when the app terminates,
        // so we persist the values in ServerConfig and re-create them here on every launch.
        if serverConfig.isAuthProxyProtected,
           let proxyAuthCookies = serverConfig.proxyAuthCookies,
           !proxyAuthCookies.isEmpty,
           let url = URL(string: serverConfig.url),
           let host = url.host {
            for (name, value) in proxyAuthCookies {
                let cookieProperties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: host,
                    .path: "/",
                    .secure: url.scheme == "https" ? "TRUE" : "FALSE"
                ]
                if let cookie = HTTPCookie(properties: cookieProperties) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
            }
            logger.info("🔐 Re-injected \(proxyAuthCookies.count) persisted proxy auth cookie(s) for \(host)")
        }

        var headers = configuration.httpAdditionalHeaders ?? [:]
        for (key, value) in serverConfig.customHeaders {
            headers[key] = value
        }
        configuration.httpAdditionalHeaders = headers

        // Always attach the TLS delegate: it handles self-signed trust (opt-in) and
        // presents an imported client certificate for mTLS-protected servers.
        // Challenges it doesn't handle fall through to default system behaviour.
        let delegate = CertificateTrustDelegate(serverConfig: serverConfig)
        self.certificateDelegate = delegate
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        super.init()
    }

    // MARK: - Request Building

    func buildRequest(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        contentType: String? = "application/json",
        authenticated: Bool = true,
        timeout: TimeInterval? = nil,
        pathIsEncoded: Bool = false
    ) throws -> URLRequest {
        guard let baseURL else {
            throw APIError.invalidURL(serverConfig.url)
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        if pathIsEncoded {
            // The caller already percent-encoded its segments (e.g. an id containing "/" sent as
            // "%2F"); assigning to `.path` would encode the "%" again.
            let encodedBase = components.percentEncodedPath.hasSuffix("/")
                ? String(components.percentEncodedPath.dropLast())
                : components.percentEncodedPath
            components.percentEncodedPath = encodedBase + path
        } else {
            components.path = basePath + path
        }
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw APIError.invalidURL(components.string ?? path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body

        if let timeout {
            request.timeoutInterval = timeout
        }

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if authenticated, let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        for (key, value) in serverConfig.customHeaders {
            let lower = key.lowercased()
            if lower != "authorization" && lower != "content-type" && lower != "accept" {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        return request
    }

    // MARK: - Simple Requests

    func request<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Encodable? = nil,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        let bodyData: Data?
        if let body {
            do {
                bodyData = try JSONEncoder().encode(body)
            } catch {
                throw APIError.requestEncoding(underlying: error)
            }
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated,
            timeout: timeout
        )

        let (data, response) = try await performRequestWithRetry(urlRequest, maxRetries: 2)
        try validateHTTPResponse(response, data: data)

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.responseDecoding(underlying: error, data: data)
        }
    }

    func requestRaw(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        contentType: String? = "application/json",
        authenticated: Bool = true,
        timeout: TimeInterval? = nil,
        ifNoneMatch: String? = nil,
        deduplicate: Bool = true,
        pathIsEncoded: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: body,
            contentType: contentType,
            authenticated: authenticated,
            timeout: timeout,
            pathIsEncoded: pathIsEncoded
        )

        if let ifNoneMatch { urlRequest.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }

        // Use the deduplicator for bodyless GET requests to prevent duplicate
        // in-flight requests from multiple startup code paths exhausting the
        // iOS per-host TCP connection pool.
        let (data, response): (Data, URLResponse)
        if deduplicate && method == .get && body == nil {
            (data, response) = try await deduplicatedGET(urlRequest)
        } else {
            (data, response) = try await performRequest(urlRequest)
        }
        try validateHTTPResponse(response, data: data)
        return (data, response as! HTTPURLResponse)
    }

    /// Downloads any absolute URL belonging to this server using the stored auth token.
    ///
    /// Used for server-generated file links that don't follow the `/api/v1/files/{id}/content`
    /// pattern — e.g. `/cache/files/...`, `/uploads/...`, `/static/...`.
    /// The auth token is injected so protected endpoints respond correctly.
    func requestRawAbsoluteURL(
        _ url: URL,
        method: HTTPMethod = .get,
        timeout: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in serverConfig.customHeaders {
            let lower = key.lowercased()
            if lower != "authorization" && lower != "content-type" && lower != "accept" {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        let (data, response) = try await performRequest(request)
        try validateHTTPResponse(response, data: data)
        return (data, response as! HTTPURLResponse)
    }

    func requestVoid(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Encodable? = nil,
        authenticated: Bool = true
    ) async throws {
        let bodyData: Data?
        if let body {
            bodyData = try JSONEncoder().encode(body)
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated
        )

        let (data, response) = try await performRequestWithRetry(urlRequest, maxRetries: 2)
        try validateHTTPResponse(response, data: data)
    }

    func requestVoidJSON(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated
        )

        let (data, response) = try await performRequestWithRetry(urlRequest, maxRetries: 2)
        try validateHTTPResponse(response, data: data)
    }

    func requestJSON(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: [String: Any]? = nil,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated,
            timeout: timeout
        )

        let (data, response) = try await performRequestWithRetry(urlRequest, maxRetries: 2)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected JSON object"]
                ),
                data: data
            )
        }
        return json
    }

    /// Like `requestJSON` but tolerates responses that are not a JSON object (e.g. `null`,
    /// an array, or an empty body). Returns an empty dict in those cases instead of throwing.
    /// Use this for endpoints like `/api/chat/actions/{id}` that may return `null`.
    @discardableResult
    func requestJSONOrVoid(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: [String: Any]? = nil,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated,
            timeout: timeout
        )

        let (data, response) = try await performRequestWithRetry(urlRequest, maxRetries: 2)
        try validateHTTPResponse(response, data: data)

        // Tolerate null / array / empty body — return empty dict rather than throwing.
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    func requestJSONArray(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: [String: Any]? = nil,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> [[String: Any]] {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated,
            timeout: timeout
        )

        let (data, response) = try await performRequestWithRetry(urlRequest, maxRetries: 2)
        try validateHTTPResponse(response, data: data)

        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected JSON array"]
                ),
                data: data
            )
        }
        return arr
    }

    // MARK: - Streaming (SSE)

    /// Opens an SSE streaming connection. Uses a dedicated session with extended timeouts
    /// so pauses during tool execution don't kill the connection.
    func streamRequestBytes(
        path: String,
        method: HTTPMethod = .post,
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws -> SSEStream {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        var urlRequest = try buildRequest(
            path: path,
            method: method,
            body: bodyData,
            authenticated: authenticated,
            timeout: 600
        )
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let streamSession = makeStreamingSession()
        let (bytes, response) = try await streamSession.bytes(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count > 4096 { break }
            }
            throw parseHTTPError(statusCode: httpResponse.statusCode, data: errorBody)
        }

        return SSEStream(bytes: bytes)
    }

    /// Invalidates and clears the cached streaming session.
    /// Call this when the server config changes (e.g. user switches servers) so the
    /// next SSE request creates a fresh session pointed at the correct server with
    /// the current auth token, rather than reusing a stale session from a prior server.
    func invalidateStreamingSession() {
        _streamingSessionLock.lock()
        let old = _streamingSessionBacking
        _streamingSessionBacking = nil
        _streamingSessionLock.unlock()
        old?.invalidateAndCancel()
        logger.info("Streaming URLSession invalidated for server switch")
    }

    /// Lock-protected lazy streaming session. Reused across all SSE requests to prevent leaks.
    private let _streamingSessionLock = NSLock()
    private var _streamingSessionBacking: URLSession?
    private var _streamingSession: URLSession {
        _streamingSessionLock.lock()
        defer { _streamingSessionLock.unlock() }
        if let existing = _streamingSessionBacking { return existing }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1200
        // Do NOT set waitsForConnectivity = true — same reasoning as the main
        // session above. When true, iOS silently suppresses the request timeout
        // whenever NWPathMonitor reports the network path as "unsatisfied", which
        // happens routinely for LAN-only servers (no internet gateway) even though
        // the server is perfectly reachable. This caused SSE fallback requests to
        // hang forever instead of failing fast and letting the retry/recovery
        // logic take over.
        config.urlCache = nil

        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Allow cookie jar so cf_clearance is auto-sent (same as main session above)
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true

        var headers = config.httpAdditionalHeaders ?? [:]
        for (key, value) in serverConfig.customHeaders {
            headers[key] = value
        }
        config.httpAdditionalHeaders = headers

        let newSession = URLSession(configuration: config, delegate: certificateDelegate, delegateQueue: nil)
        _streamingSessionBacking = newSession
        return newSession
    }

    private func makeStreamingSession() -> URLSession {
        _streamingSession
    }

    /// Creates a one-off session with the server's TLS handling (self-signed trust +
    /// mTLS client certificate). Callers own the session and must invalidate it.
    func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: certificateDelegate, delegateQueue: nil)
    }

    // MARK: - Multipart Form Data Upload

    func uploadMultipart(
        path: String,
        queryItems: [URLQueryItem]? = nil,
        fileData: Data,
        fileName: String,
        mimeType: String,
        fieldName: String = "file",
        additionalFields: [String: String]? = nil,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil,
        authorization: String? = nil,
        resourceTimeout: TimeInterval? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> [String: Any] {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        if let fields = additionalFields {
            for (key, value) in fields {
                body.append(Data("--\(boundary)\r\n".utf8))
                body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
                body.append(Data("\(value)\r\n".utf8))
            }
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))

        var urlRequest = try buildRequest(
            path: path,
            method: .post,
            queryItems: queryItems,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            authenticated: authenticated,
            timeout: timeout
        )

        if let authorization { urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        if let resourceTimeout {
            // Long batch transcription needs upload/conversion headroom in addition
            // to its server deadline. Other requests keep the existing session limits.
            let configuration = session.configuration
            configuration.timeoutIntervalForResource = resourceTimeout
            let uploadSession = URLSession(configuration: configuration, delegate: certificateDelegate, delegateQueue: nil)
            defer { uploadSession.finishTasksAndInvalidate() }
            (data, response) = try await uploadSession.data(for: urlRequest)
        } else {
            (data, response) = try await performRequest(urlRequest)
        }
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected JSON response from upload"]
                ),
                data: data
            )
        }
        return json
    }

    // MARK: - GET Request Deduplicator

    /// In-flight GET request tasks keyed by URL string.
    /// Prevents the startup burst from making identical parallel GET requests
    /// (e.g. `/api/models`, `/api/v1/chats/`, `/api/v1/folders/` each called
    /// from multiple code paths simultaneously) which exhausted the iOS per-host
    /// TCP connection pool on high-latency LAN paths (Docker/Gluetun namespaces).
    ///
    /// Only GET requests with no body are deduplicated — mutating requests are
    /// always sent independently.
    private let deduplicator = GETDeduplicator()

    /// Performs a GET request, coalescing identical in-flight requests.
    /// If a GET to the same URL is already in progress, waits for that result
    /// instead of opening a new connection. Cleans up automatically on completion.
    func deduplicatedGET(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
        guard urlRequest.httpMethod == "GET" || urlRequest.httpMethod == nil,
              let key = urlRequest.url?.absoluteString
        else {
            // Non-GET or no URL — perform directly
            return try await performRequest(urlRequest)
        }

        // Check for an existing in-flight task (actor-isolated, async-safe)
        if let existing = await deduplicator.existing(for: key) {
            return try await existing.value
        }

        let task = Task<(Data, URLResponse), Error> { [weak self] in
            guard let self else { throw APIError.unknown(underlying: nil) }
            defer { Task { await self.deduplicator.remove(key) } }
            return try await self.performRequest(urlRequest)
        }
        await deduplicator.register(task, for: key)
        return try await task.value
    }

    // MARK: - Auth Token Management

    @discardableResult
    func saveAuthToken(_ token: String) -> Bool {
        keychain.saveToken(token, forServer: serverConfig.url)
    }

    @discardableResult
    func deleteAuthToken() -> Bool {
        keychain.deleteToken(forServer: serverConfig.url)
    }

    // MARK: - Internal Helpers

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let result = try await session.data(for: request)
            // Native SSO only: an authenticated request that got a 401 gets ONE
            // silent renewal attempt (shared across concurrent 401s) and is retried
            // with the fresh token. `onUnauthorizedRecover` is nil for every server
            // without native SSO, so this block is skipped entirely for them.
            if let http = result.1 as? HTTPURLResponse, http.statusCode == 401,
               onUnauthorizedRecover != nil,
               let sentAuth = request.value(forHTTPHeaderField: "Authorization") {
                // Another request already renewed the session while this one was
                // in flight with the old token — just retry with the current one.
                if let current = authToken, sentAuth != "Bearer \(current)" {
                    var retry = request
                    retry.setValue("Bearer \(current)", forHTTPHeaderField: "Authorization")
                    logger.info("Native SSO: retrying request with already-renewed token")
                    return try await session.data(for: retry)
                }
                switch await attemptSilentRecovery() {
                case .renewed:
                    guard let fresh = authToken else { return result }
                    var retry = request
                    retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                    logger.info("Native SSO: retrying request after silent session renewal")
                    return try await session.data(for: retry)
                case .unavailable:
                    // The IdP couldn't be reached — the session may well still be
                    // valid. Fail this request as a transient, non-auth error so
                    // nothing signs the user out.
                    logger.warning("Native SSO: renewal unavailable — deferring, keeping user signed in")
                    throw APIError.sessionRenewalUnavailable
                case .rejected:
                    return result
                }
            }
            return result
        } catch {
            throw APIError.from(error)
        }
    }

    /// Retries up to `maxRetries` times with exponential backoff for network errors and 5xx responses.
    /// Does not retry 4xx, cancelled requests, or SSL errors.
    func performRequestWithRetry(
        _ request: URLRequest,
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 0.5
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                let (data, response) = try await performRequest(request)

                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode >= 500 && attempt < maxRetries {
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    logger.warning("Server error \(httpResponse.statusCode) on attempt \(attempt + 1)/\(maxRetries + 1), retrying in \(delay)s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    lastError = parseHTTPError(statusCode: httpResponse.statusCode, data: data)
                    continue
                }

                return (data, response)
            } catch {
                lastError = error
                let apiError = APIError.from(error)

                guard apiError.isRetryable, attempt < maxRetries else {
                    throw error
                }

                let delay = baseDelay * pow(2.0, Double(attempt))
                logger.warning("Request failed (attempt \(attempt + 1)/\(maxRetries + 1)): \(apiError.localizedDescription), retrying in \(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? APIError.unknown(underlying: nil)
    }

    /// Downloads an explicitly opened file to disk without retaining its bytes in memory.
    func downloadFile(path: String) async throws -> URL {
        let request = try buildRequest(path: path)
        let (url, response) = try await session.download(for: request)
        do {
            try validateHTTPResponse(response, data: Data())
            try Task.checkCancellation()
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }

        let statusCode = httpResponse.statusCode

        if [302, 307, 308].contains(statusCode) {
            let location = httpResponse.value(forHTTPHeaderField: "Location")
            throw APIError.redirectDetected(location: location)
        }

        guard (200..<400).contains(statusCode) else {
            let error = parseHTTPError(statusCode: statusCode, data: data)
            // Fire the 401 auto-sign-out callback once per session so the app
            // immediately routes to sign-in instead of silently failing.
            if statusCode == 401 {
                _tokenExpiredLock.lock()
                let alreadyFired = _tokenExpiredFired
                if !alreadyFired { _tokenExpiredFired = true }
                _tokenExpiredLock.unlock()
                if !alreadyFired {
                    let cb = onTokenExpired
                    DispatchQueue.main.async { cb?() }
                }
            }
            throw error
        }
    }

    private func parseHTTPError(statusCode: Int, data: Data) -> APIError {
        if statusCode == 401 {
            return .tokenExpired
        }

        // mTLS proxy (e.g. Nginx `ssl_verify_client on`) rejected the request because
        // no / an untrusted client certificate was presented.
        if TLSChallengeHandler.isClientCertificateRejectionPage(statusCode: statusCode, body: data) {
            return .sslError(underlying: URLError(.clientCertificateRequired))
        }
        var message: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            message = json["detail"] as? String
                ?? json["error"] as? String
                ?? json["message"] as? String
        }
        if message == nil {
            message = String(data: data, encoding: .utf8)
        }

        return .httpError(statusCode: statusCode, message: message, data: data)
    }
}

// MARK: - HTTP Method

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

// MARK: - GET Deduplicator

/// Actor-isolated store for in-flight GET tasks.
/// Replaces the old NSLock-based approach which was unavailable in async contexts (Swift 6).
actor GETDeduplicator {
    private var inFlight: [String: Task<(Data, URLResponse), Error>] = [:]

    func existing(for key: String) -> Task<(Data, URLResponse), Error>? {
        inFlight[key]
    }

    func register(_ task: Task<(Data, URLResponse), Error>, for key: String) {
        inFlight[key] = task
    }

    func remove(_ key: String) {
        inFlight.removeValue(forKey: key)
    }
}

// MARK: - Certificate Trust Delegate

/// TLS delegate for the server's sessions — self-signed trust (opt-in) and mTLS
/// client certificates. Extracted so `session` can be a `let`.
private final class CertificateTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    let serverConfig: ServerConfig

    init(serverConfig: ServerConfig) {
        self.serverConfig = serverConfig
        super.init()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = TLSChallengeHandler.resolve(challenge, serverConfig: serverConfig)
        completionHandler(disposition, credential)
    }
}
