import Foundation

nonisolated struct ServerConfig: Sendable {
    var url = "https://relay.example/base"
    var customHeaders = ["X-Test": "synthetic-header"]
    var apiBaseURL: URL? { URL(string: url) }
    var allowSelfSignedCertificates = false
    var isCloudflareBotProtected = false
    var cfClearanceValue: String? = nil
    var cfClearanceExpiry: Date? = nil
    var isAuthProxyProtected = false
    var proxyAuthCookies: [String: String]? = nil
}
final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()
    private let lock = NSLock()
    private var token: String? = "synthetic-session"
    func getToken(forServer: String) -> String? { lock.withLock { token } }
    func saveToken(_ value: String, forServer: String) -> Bool { lock.withLock { token = value }; return true }
    func deleteToken(forServer: String) -> Bool { lock.withLock { token = nil }; return true }
}
final class ProbeProtocol: URLProtocol, @unchecked Sendable {
    static let server = HTTPFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            let (data, response) = await Self.server.respond(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
actor HTTPFixture {
    var requests: [URLRequest] = []
    var version = 1
    var status = 200
    var mutationGate: Gate?
    func setStatus(_ value: Int) { status = value }
    func blockMutation(_ gate: Gate?) { mutationGate = gate }
    func respond(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
        requests.append(request)
        if request.httpMethod != "GET" {
            await mutationGate?.wait()
            version += 1
        }
        let accountVersion = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-other" ? 99 : version
        let etag = "\"v\(accountVersion)\""
        let code = status == 200 && request.value(forHTTPHeaderField: "If-None-Match") == etag ? 304 : status
        let data = code == 304 ? Data() : Server.payload(id: "chat", version: accountVersion)
        return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["ETag": etag])!)
    }
}

@main enum NetworkChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "relay-network-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let cache = ConversationCache(directory: directory, defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = NetworkManager(serverConfig: ServerConfig(), session: session, cache: cache)
        let scope = client.conversationCacheScope!
        let fetch: @Sendable (String?) async throws -> (Data, HTTPURLResponse) = { tag in
            try await client.requestRaw(path: "/api/v1/chats/chat", ifNoneMatch: tag, deduplicate: false)
        }
        let first = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        let checked = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(first == checked, "real URLSession 304 should reuse the saved bytes")
        let requests = await ProbeProtocol.server.requests
        try check(requests.count == 2 && requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"", "conditional header must reach the HTTP transport")
        try check(requests[0].url?.path == "/base/api/v1/chats/chat" && requests[0].value(forHTTPHeaderField: "X-Test") == "synthetic-header", "base path and custom headers must survive")
        try check(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session", "request must use the scoped session")

        let gate = Gate()
        await ProbeProtocol.server.blockMutation(gate)
        let mutation = Task { try await client.requestVoidJSON(path: "/api/v1/chats/chat", method: .post, body: ["chat": ["title": "Synthetic update"]]) }
        await gate.waitUntilStarted()
        try check(await cache.cached(scope: scope, id: "chat") == nil, "POST must invalidate before the HTTP response")
        _ = try await cache.load(scope: scope, id: "chat") { _ in Server.response(id: "chat") }
        await gate.release()
        try await mutation.value
        try check(await cache.cached(scope: scope, id: "chat") == nil, "POST must invalidate copies fetched while it was pending")
        await ProbeProtocol.server.blockMutation(nil)

        let updated = try await cache.load(scope: scope, id: "chat", fetch: fetch)
        try check(updated != first, "mutation must be followed by a new representation")
        _ = client.saveAuthToken("synthetic-other")
        let otherScope = client.conversationCacheScope!
        let other = try await cache.load(scope: otherScope, id: "chat", preferRecent: true, fetch: fetch)
        try check(otherScope != scope && other != updated, "token rotation must not reuse another account's response")
        await ProbeProtocol.server.setStatus(401)
        do {
            _ = try await cache.load(scope: otherScope, id: "chat", fetch: fetch)
            throw Failure(message: "401 was accepted")
        } catch APIError.tokenExpired {}
        try check(await cache.cached(scope: otherScope, id: "chat") == nil, "actual HTTP 401 must purge the rejected session")
        try check(await cache.cached(scope: scope, id: "chat") != nil, "rejected session must not purge a different scope")
        print("PASS: actual NetworkManager and URLSession transport, headers, 200/304, POST invalidation, token rotation and HTTP 401; all requests intercepted locally")
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
