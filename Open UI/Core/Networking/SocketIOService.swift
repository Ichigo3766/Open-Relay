import Foundation
import os.log

/// Describes the current state of the Socket.IO connection.
enum SocketConnectionState: Sendable {
    /// No connection; idle.
    case disconnected
    /// Actively attempting to establish a connection.
    case connecting
    /// Connected and ready.
    case connected
    /// Lost connection; automatically retrying (includes attempt count).
    case reconnecting(attempt: Int)
}

extension SocketConnectionState: Equatable {
    nonisolated static func == (lhs: SocketConnectionState, rhs: SocketConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected): return true
        case (.connecting, .connecting): return true
        case (.connected, .connected): return true
        case (.reconnecting(let a), .reconnecting(let b)): return a == b
        default: return false
        }
    }
}

/// Lightweight Socket.IO client built on `URLSessionWebSocketTask`.
///
/// Implements the Engine.IO v4 / Socket.IO v4 protocol on top of native
/// `URLSession` WebSockets, providing real-time event handling for
/// OpenWebUI chat events without requiring an external library.
///
/// Key features:
/// - Automatic handshake and upgrade from polling to WebSocket
/// - Heartbeat/ping-pong keep-alive
/// - Reconnection with exponential backoff
/// - Chat and channel event dispatching with session/conversation filtering
/// - Observable `connectionState` for UI integration
final class SocketIOService: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    // MARK: - Types

    typealias EventHandler = @Sendable (
        _ event: [String: Any],
        _ ack: ((Any?) -> Void)?
    ) -> Void

    // MARK: - Properties

    let serverConfig: ServerConfig
    private let logger = Logger(subsystem: "com.openui", category: "Socket")

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var authToken: String?
    private var pingTimer: Timer?
    private var heartbeatTimer: Timer?
    private var reconnectTimer: Timer?
    private var reconnectAttempt = 0

    /// Whether to use HTTP long-polling transport instead of WebSocket.
    /// Cloudflare Bot Fight Mode blocks WebSocket upgrades, so we must use
    /// the polling transport (which the browser also uses in this scenario).
    private var usePollingTransport: Bool { serverConfig.isCloudflareBotProtected }
    /// Task running the long-poll receive loop.
    private var pollingReceiveTask: Task<Void, Never>?
    /// Tracks monotonically increasing request counter for polling (Engine.IO `t` param).
    private var pollingRequestCounter: Int = 0

    /// Engine.IO session ID received from the handshake.
    private(set) var sid: String?

    /// Monotonically increasing counter, incremented on every `connect()` call.
    /// All async callbacks capture this value and ignore results from older
    /// connection generations, preventing stale disconnect/reconnect races.
    private var connectionGeneration: Int = 0

    /// Whether the socket is currently connected.
    private(set) var isConnected = false

    /// Whether a connection attempt is in progress.
    private(set) var isConnecting = false

    /// Whether `user-join` has been acknowledged by the server for the current
    /// connection. The server only routes chat/channel events to sockets that
    /// are in the `user:{id}` room, which `user-join` (or the auth-carrying
    /// CONNECT handshake) is responsible for joining. Being `isConnected` is
    /// NOT sufficient — there is a window between the Socket.IO CONNECT ack
    /// and the `user-join` ack during which the socket exists but has not yet
    /// joined the room, so events emitted in that window are silently dropped
    /// by the server. Callers that need guaranteed event delivery (sending a
    /// chat message) must wait for `isUserJoined` before proceeding.
    private(set) var isUserJoined = false

    /// Pending client-initiated ack callbacks, keyed by the ack ID we generated
    /// when emitting. Invoked when the server responds with `43<id>[...]`.
    private var pendingAcks: [Int: (Any?) -> Void] = [:]
    private var nextAckId = 0
    private let ackLock = NSLock()


    /// Number of reconnections since creation.
    private(set) var reconnectCount = 0

    /// Observable connection state for UI integration.
    private(set) var connectionState: SocketConnectionState = .disconnected {
        didSet {
            guard connectionState != oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onConnectionStateChange?(self?.connectionState ?? .disconnected)
            }
        }
    }

    /// Heartbeat interval from the server (default 25s).
    private var pingInterval: TimeInterval = 25
    private var pingTimeout: TimeInterval = 20

    /// Whether auto-reconnect is enabled. Disabled on intentional disconnect.
    private var autoReconnectEnabled = true

    /// Whether the app is currently in the background.
    /// While backgrounded, we pause the reconnect backoff timer and reconnect
    /// immediately when the app returns to the foreground.
    private var isAppInBackground = false

    /// Maximum number of reconnection attempts before giving up.
    /// After this, the socket stays disconnected until manually reconnected.
    private let maxReconnectAttempts = 50

    private let maxReconnectDelay: TimeInterval = 30.0
    private let baseReconnectDelay: TimeInterval = 1.0

    // MARK: - Event Handlers

    private var chatHandlers: [String: ChatHandlerRegistration] = [:]
    private var channelHandlers: [String: ChannelHandlerRegistration] = [:]
    private var handlerSeed = 0
    private let handlerLock = NSLock()

    /// Fires when the socket connects or reconnects.
    var onConnect: (() -> Void)?

    /// Fires when the socket disconnects.
    var onDisconnect: ((String?) -> Void)?

    /// Fires after a successful reconnection.
    var onReconnect: (() -> Void)?

    /// Fires when the connection state changes (connected, disconnected, reconnecting).
    var onConnectionStateChange: ((_ state: SocketConnectionState) -> Void)?

    // MARK: - Init

    init(serverConfig: ServerConfig, authToken: String? = nil) {
        self.serverConfig = serverConfig
        self.authToken = authToken
        super.init()
    }

    // MARK: - App Lifecycle

    /// Called when the app moves to the background.
    /// Cancels pending reconnect timers to prevent wasted attempts while
    /// the OS has us suspended.
    func markAppBackground() {
        isAppInBackground = true
        // Cancel any pending reconnect timer — we'll reconnect immediately on foreground
        DispatchQueue.main.async { [weak self] in
            self?.reconnectTimer?.invalidate()
            self?.reconnectTimer = nil
        }
    }

    /// Called when the app returns to the foreground.
    /// If the socket is disconnected, reconnects immediately instead of waiting
    /// out the remaining backoff delay.
    func resetBackoffAndReconnect() {
        isAppInBackground = false
        // Cancel any pending reconnect timer
        DispatchQueue.main.async { [weak self] in
            self?.reconnectTimer?.invalidate()
            self?.reconnectTimer = nil
        }
        // Reset backoff counter so the next reconnect starts from attempt 0
        reconnectAttempt = 0
        guard !isConnected, !isConnecting, autoReconnectEnabled else { return }
        reconnectCount += 1
        connect()
    }

    // MARK: - Connection

    /// Connects to the server's Socket.IO endpoint.
    /// Automatically selects WebSocket or HTTP long-polling transport based on
    /// whether the server is behind Cloudflare Bot Fight Mode.
    func connect(force: Bool = false) {
        if isConnected && !force { return }
        if isConnecting && !force { return }

        // Increment generation so any callbacks from the previous connection
        // can detect they belong to a stale generation and self-discard.
        connectionGeneration += 1

        isConnecting = true
        autoReconnectEnabled = true
        connectionState = .connecting
        stopPing()
        disconnectInternal()

        // STORAGE FIX: Invalidate previous session to prevent leaks.
        session?.invalidateAndCancel()

        // Create session with cookie support (needed for both transports)
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        if serverConfig.allowSelfSignedCertificates {
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        } else {
            session = URLSession(configuration: config)
        }

        if usePollingTransport {
            connectViaPolling()
        } else {
            connectViaWebSocket()
        }
    }

    // MARK: - WebSocket Transport

    private func connectViaWebSocket() {
        var base = serverConfig.url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/$", with: "", options: .regularExpression)

        if base.hasPrefix("https://") {
            base = "wss://" + base.dropFirst(8)
        } else if base.hasPrefix("http://") {
            base = "ws://" + base.dropFirst(7)
        }

        let handshakeURL = "\(base)/ws/socket.io/?EIO=4&transport=websocket"

        guard let url = URL(string: handshakeURL) else {
            logger.error("Invalid socket URL: \(handshakeURL)")
            isConnecting = false
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        applyHeaders(to: &request)

        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveMessage()
        logger.info("Connecting via WebSocket: \(handshakeURL)")
    }

    // MARK: - HTTP Long-Polling Transport (Engine.IO v4)

    /// Connects using Engine.IO HTTP long-polling transport.
    /// This is what the browser uses when Cloudflare blocks WebSocket upgrades.
    /// Each GET request blocks until the server has data → instant delivery.
    private func connectViaPolling() {
        logger.info("Connecting via HTTP long-polling transport")
        pollingRequestCounter = 0

        Task { [weak self] in
            guard let self, let session = self.session else { return }

            // Step 1: Engine.IO handshake — GET with no sid
            let handshakeURL = self.pollingURL(sid: nil)
            guard let url = URL(string: handshakeURL) else {
                self.logger.error("Invalid polling URL: \(handshakeURL)")
                self.isConnecting = false
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            self.applyHeaders(to: &request)

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<400).contains(httpResponse.statusCode) else {
                    self.logger.error("Polling handshake failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    self.handleDisconnect(reason: "Polling handshake failed")
                    return
                }

                // Parse Engine.IO handshake response.
                // Format: "0{...json...}" where 0 = OPEN packet type
                guard let body = String(data: data, encoding: .utf8) else {
                    self.handleDisconnect(reason: "Empty handshake response")
                    return
                }

                // Engine.IO polling can return multiple packets separated by \x1e (record separator)
                // or the body might be a single packet prefixed with length
                let packets = self.parsePollingResponse(body)
                for packet in packets {
                    self.handleEngineIOMessage(packet)
                }

                guard let sid = self.sid else {
                    self.handleDisconnect(reason: "No sid in handshake")
                    return
                }

                // Step 2: Send Socket.IO CONNECT packet via POST
                let connectPayload: String
                if let token = self.authToken, !token.isEmpty,
                   let authData = try? JSONSerialization.data(withJSONObject: ["token": token]),
                   let authStr = String(data: authData, encoding: .utf8) {
                    connectPayload = "40\(authStr)"
                } else {
                    connectPayload = "40"
                }
                try await self.pollingSend(connectPayload, sid: sid)

                // Step 3: First receive — server responds with Socket.IO CONNECT acknowledgment
                let connectResponse = try await self.pollingReceive(sid: sid)
                for packet in connectResponse {
                    self.handleEngineIOMessage(packet)
                }

                // Step 4: Start continuous receive loop.
                // Cancel any previously-running loop BEFORE starting a new one.
                // Without this, a reconnect would overwrite pollingReceiveTask,
                // losing the handle to the old task — leaving two polling loops
                // racing to read packets from the same session simultaneously.
                self.pollingReceiveTask?.cancel()
                self.pollingReceiveTask = Task { [weak self] in
                    await self?.pollingReceiveLoop(sid: sid)
                }

            } catch {
                self.logger.error("Polling connect failed: \(error.localizedDescription)")
                self.handleDisconnect(reason: error.localizedDescription)
            }
        }
    }

    /// Builds the polling URL with query parameters.
    private func pollingURL(sid: String?) -> String {
        let base = serverConfig.url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/$", with: "", options: .regularExpression)

        pollingRequestCounter += 1
        var url = "\(base)/ws/socket.io/?EIO=4&transport=polling&t=\(pollingRequestCounter)"
        if let sid {
            url += "&sid=\(sid)"
        }
        return url
    }

    /// Applies auth headers and custom headers to a request.
    private func applyHeaders(to request: inout URLRequest) {
        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in serverConfig.customHeaders {
            let lower = key.lowercased()
            if lower != "authorization" && lower != "content-type" {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
    }

    /// Sends a message via HTTP POST (polling transport).
    private func pollingSend(_ message: String, sid: String) async throws {
        guard let session else { return }
        let urlString = pollingURL(sid: sid)
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = message.data(using: .utf8)
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        applyHeaders(to: &request)

        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            logger.warning("Polling send failed: HTTP \(httpResponse.statusCode)")
        }
    }

    /// Receives messages via HTTP GET (long-polling — server holds request open until data ready).
    private func pollingReceive(sid: String) async throws -> [String] {
        guard let session else { return [] }
        let urlString = pollingURL(sid: sid)
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 120 // Long-poll — server holds until data available
        applyHeaders(to: &request)

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            throw NSError(domain: "SocketIO", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Polling receive HTTP \(httpResponse.statusCode)"])
        }

        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            return []
        }

        return parsePollingResponse(body)
    }

    /// Continuous long-poll receive loop. Each GET blocks until the server has data,
    /// then returns immediately. We process the data and immediately issue another GET.
    /// This gives real-time latency identical to WebSocket.
    private func pollingReceiveLoop(sid: String) async {
        while !Task.isCancelled && (isConnected || isConnecting) {
            do {
                let packets = try await pollingReceive(sid: sid)
                for packet in packets {
                    handleEngineIOMessage(packet)
                }
            } catch {
                if Task.isCancelled { break }
                logger.warning("Polling receive error: \(error.localizedDescription)")
                // Brief pause before retry to avoid tight loop on transient errors
                try? await Task.sleep(nanoseconds: 500_000_000)
                // If we're no longer connected, break out
                if !isConnected && !isConnecting { break }
            }
        }

        if !Task.isCancelled {
            handleDisconnect(reason: "Polling loop ended")
        }
    }

    /// Parses an Engine.IO polling response body into individual packets.
    /// Packets can be separated by \x1e (record separator) in Engine.IO v4.
    private func parsePollingResponse(_ body: String) -> [String] {
        // Engine.IO v4 uses \x1e as packet separator for multiple packets
        let separator = "\u{001e}"
        if body.contains(separator) {
            return body.components(separatedBy: separator).filter { !$0.isEmpty }
        }
        return [body]
    }

    /// Override send to route through polling when using polling transport.
    private func pollingTransportSend(_ text: String) {
        guard let sid else { return }
        Task { [weak self] in
            try? await self?.pollingSend(text, sid: sid)
        }
    }

    /// Disconnects from the server intentionally.
    /// Disables auto-reconnect so the socket stays down until `connect()` is called again.
    func disconnect() {
        autoReconnectEnabled = false
        stopPing()
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        disconnectInternal()
        isConnected = false
        isConnecting = false
        isUserJoined = false
        connectionState = .disconnected
    }

    /// Updates the auth token. If connected, re-authenticates and waits for the
    /// `user-join` ack before considering the socket ready again.
    func updateAuthToken(_ token: String?) {
        authToken = token
        guard isConnected, let token, !token.isEmpty else { return }
        isUserJoined = false
        Task { [weak self] in
            guard let self else { return }
            let result = await self.emitWithAck("user-join", data: ["auth": ["token": token]], timeout: 5.0)
            guard self.isConnected else { return }
            self.isUserJoined = true
            if result == nil {
                self.logger.warning("updateAuthToken: user-join ack timed out — proceeding optimistically")
            }
        }
    }


    // MARK: - Emit

    /// Emits a Socket.IO event to the server.
    func emit(_ event: String, data: Any? = nil) {
        var payload: [Any] = [event]
        if let data {
            payload.append(data)
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }

        // Socket.IO message packet: "42" prefix for EVENT type
        let message = "42\(jsonString)"
        send(message)
    }

    /// Sends a Socket.IO ACK packet in response to a server event that carried an ack ID.
    /// The server uses `sio.call()` to send events that require a client acknowledgement;
    /// the client must reply with `43<ackId>[responseValue]` so the server's await can resume.
    func emitAck(_ ackId: Int, data: Any?) {
        let payload: [Any]
        if let data {
            payload = [data]
        } else {
            payload = []
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }
        // Engine.IO MESSAGE "4" + Socket.IO ACK "3" + ack ID + payload array
        send("43\(ackId)\(jsonString)")
    }

    /// Emits a Socket.IO event and waits for the server's ACK response, e.g. `user-join`
    /// which the server replies to with `{'id': user.id, 'name': user.name}`.
    ///
    /// This is essential for events where the client must know the server has fully
    /// processed the request (e.g. joined the `user:{id}` room) before proceeding —
    /// simply firing `emit()` and assuming success is what caused chat events to be
    /// silently dropped when a message was sent in the brief window between the
    /// Socket.IO CONNECT ack and the `user-join` ack actually completing server-side.
    ///
    /// Returns `nil` if the ack does not arrive within `timeout` seconds, or if the
    /// socket disconnects while waiting.
    @discardableResult
    func emitWithAck(_ event: String, data: Any? = nil, timeout: TimeInterval = 5.0) async -> Any? {
        var payload: [Any] = [event]
        if let data {
            payload.append(data)
        }

        let ackId: Int = {
            ackLock.lock()
            defer { ackLock.unlock() }
            nextAckId += 1
            return nextAckId
        }()

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else { return nil }

        // Use withTaskCancellationHandler so that if the calling Task is cancelled
        // (e.g. the app backgrounds and the caller is torn down), the pending ack
        // is cleaned up and the continuation is resumed, preventing a continuation leak.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeLock = OSAllocatedUnfairLock(initialState: false)
                func resumeOnce(_ value: Any?) {
                    let shouldResume = resumeLock.withLock { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    guard shouldResume else { return }
                    continuation.resume(returning: value)
                }

                ackLock.lock()
                pendingAcks[ackId] = { data in
                    resumeOnce(data)
                }
                ackLock.unlock()

                // Socket.IO EVENT packet WITH ack ID: "42<ackId>[eventName, payload]"
                send("42\(ackId)\(jsonString)")

                // Use Task.sleep instead of DispatchQueue.main.asyncAfter so the timeout
                // fires reliably regardless of whether the main RunLoop is active (e.g.
                // while the app is backgrounded). DispatchQueue.main.asyncAfter can be
                // delayed or never fire when the main thread is suspended, leaving the
                // Swift continuation alive forever — a guaranteed memory/resource leak.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard let self else { return }
                    self.ackLock.lock()
                    self.pendingAcks.removeValue(forKey: ackId)
                    self.ackLock.unlock()
                    resumeOnce(nil)
                }
            }
        } onCancel: { [weak self] in
            // Task was cancelled — clean up the pending ack so it doesn't linger.
            guard let self else { return }
            self.ackLock.lock()
            self.pendingAcks.removeValue(forKey: ackId)
            self.ackLock.unlock()
        }
    }

    /// Invokes and removes the pending ack callback for the given ID, if present.
    private func resolveAck(_ ackId: Int, data: Any?) {
        ackLock.lock()
        let callback = pendingAcks.removeValue(forKey: ackId)
        ackLock.unlock()
        callback?(data)
    }


    // MARK: - Event Registration

    /// Registers a handler for chat events, optionally scoped to a conversation/session.
    @discardableResult
    func addChatEventHandler(
        conversationId: String? = nil,
        sessionId: String? = nil,
        handler: @escaping EventHandler
    ) -> SocketSubscription {
        let id = nextHandlerId()
        let registration = ChatHandlerRegistration(
            id: id,
            conversationId: conversationId,
            sessionId: sessionId,
            handler: handler
        )

        handlerLock.lock()
        chatHandlers[id] = registration
        handlerLock.unlock()

        return SocketSubscription { [weak self] in
            self?.handlerLock.lock()
            self?.chatHandlers.removeValue(forKey: id)
            self?.handlerLock.unlock()
        }
    }

    /// Registers a handler for channel events.
    @discardableResult
    func addChannelEventHandler(
        conversationId: String? = nil,
        sessionId: String? = nil,
        handler: @escaping EventHandler
    ) -> SocketSubscription {
        let id = nextHandlerId()
        let registration = ChannelHandlerRegistration(
            id: id,
            conversationId: conversationId,
            sessionId: sessionId,
            handler: handler
        )

        handlerLock.lock()
        channelHandlers[id] = registration
        handlerLock.unlock()

        return SocketSubscription { [weak self] in
            self?.handlerLock.lock()
            self?.channelHandlers.removeValue(forKey: id)
            self?.handlerLock.unlock()
        }
    }

    /// Updates the session ID for handlers matching a conversation.
    func updateSessionId(for conversationId: String, newSessionId: String) {
        handlerLock.lock()
        for (key, reg) in chatHandlers where reg.conversationId == conversationId {
            let existingHandler: EventHandler = reg.handler
            chatHandlers[key] = ChatHandlerRegistration(
                id: reg.id,
                conversationId: reg.conversationId,
                sessionId: newSessionId,
                handler: existingHandler
            )
        }
        for (key, reg) in channelHandlers where reg.conversationId == conversationId {
            let existingHandler: EventHandler = reg.handler
            channelHandlers[key] = ChannelHandlerRegistration(
                id: reg.id,
                conversationId: reg.conversationId,
                sessionId: newSessionId,
                handler: existingHandler
            )
        }
        handlerLock.unlock()
    }

    /// Removes all event handlers.
    func clearAllHandlers() {
        handlerLock.lock()
        chatHandlers.removeAll()
        channelHandlers.removeAll()
        handlerLock.unlock()
    }

    /// Ensures the socket is connected AND has successfully joined the user's
    /// room (user-join acknowledged), waiting up to the given timeout.
    ///
    /// Waiting for `isUserJoined` — not just `isConnected` — is critical: a
    /// socket can be "connected" from the Engine.IO/Socket.IO handshake's
    /// perspective while the server has not yet added it to `user:{id}`,
    /// which is the room chat/channel events are emitted to. Proceeding to
    /// send a chat message before that join completes causes the response
    /// to be silently dropped by the server with no error on either side.
    func ensureConnected(timeout: TimeInterval = 2.0) async -> Bool {
        if isConnected && isUserJoined { return true }

        connect()

        // Poll for connection + room join
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isConnected && isUserJoined { return true }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Timed out — if at least connected, allow the caller to proceed
        // (isUserJoined's own timeout logic already defaults to true after
        // 5s to avoid blocking forever on servers that ack slowly).
        return isConnected
    }


    // MARK: - Cleanup

    func dispose() {
        disconnect()
        clearAllHandlers()
        onConnect = nil
        onDisconnect = nil
        onReconnect = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        logger.info("WebSocket opened")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }
        logger.info("WebSocket closed: \(closeCode.rawValue) \(reasonStr ?? "")")
        handleDisconnect(reason: reasonStr)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard serverConfig.allowSelfSignedCertificates,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let baseURL = URL(string: serverConfig.url),
              challenge.protectionSpace.host.lowercased() == baseURL.host?.lowercased()
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    // MARK: - Private: Messaging (routes to correct transport)

    private func send(_ text: String) {
        if usePollingTransport {
            pollingTransportSend(text)
        } else {
            webSocketTask?.send(.string(text)) { [weak self] error in
                if let error {
                    self?.logger.error("Send error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleEngineIOMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleEngineIOMessage(text)
                    }
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveMessage()

            case .failure(let error):
                self.logger.error("Receive error: \(error.localizedDescription)")
                self.handleDisconnect(reason: error.localizedDescription)
            }
        }
    }

    // MARK: - Private: Engine.IO Protocol

    /// Handles raw Engine.IO messages.
    /// Packet types: 0=open, 1=close, 2=ping, 3=pong, 4=message, 5=upgrade, 6=noop
    private func handleEngineIOMessage(_ raw: String) {
        guard let first = raw.first else { return }

        switch first {
        case "0":
            // Engine.IO OPEN - parse handshake
            let jsonStr = String(raw.dropFirst())
            if let data = jsonStr.data(using: .utf8),
               let handshake = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                sid = handshake["sid"] as? String
                if let pi = handshake["pingInterval"] as? Double { pingInterval = pi / 1000.0 }
                if let pt = handshake["pingTimeout"] as? Double { pingTimeout = pt / 1000.0 }
                logger.info("Engine.IO handshake: sid=\(self.sid ?? "nil"), ping=\(self.pingInterval)s")

                // For WebSocket transport: auto-send Socket.IO connect packet.
                // For polling transport: connectViaPolling() sends it explicitly
                // after the handshake (Step 2), so skip auto-send here.
                if !usePollingTransport {
                    if let token = authToken, !token.isEmpty,
                       let authData = try? JSONSerialization.data(withJSONObject: ["token": token]),
                       let authStr = String(data: authData, encoding: .utf8) {
                        send("40\(authStr)")
                    } else {
                        send("40")
                    }
                }
            }

        case "1":
            // Engine.IO CLOSE
            handleDisconnect(reason: "Server closed connection")

        case "2":
            // Engine.IO PING → respond with PONG
            send("3")

        case "3":
            // Engine.IO PONG
            break

        case "4":
            // Engine.IO MESSAGE → Socket.IO packet
            handleSocketIOMessage(String(raw.dropFirst()))

        default:
            break
        }
    }

    /// Handles Socket.IO protocol messages.
    /// Packet types: 0=CONNECT, 1=DISCONNECT, 2=EVENT, 3=ACK, 4=ERROR
    private func handleSocketIOMessage(_ raw: String) {
        guard let first = raw.first else { return }

        switch first {
        case "0":
            // Socket.IO CONNECT - connection confirmed
            isConnected = true
            isConnecting = false
            reconnectAttempt = 0
            connectionState = .connected

            // Parse the connect response for sid
            let jsonStr = String(raw.dropFirst())
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                sid = json["sid"] as? String
            }

            startPing()

            // Start heartbeat
            startHeartbeat()

            logger.info("Socket.IO connected, sid=\(self.sid ?? "nil")")

            // Join the user's room. This MUST complete (ack received) before the
            // socket is considered ready for anything that depends on server-side
            // event delivery (sending a chat message). Firing user-join without
            // waiting for its ack was the root cause of chat responses silently
            // vanishing: sendMessage() would see isConnected == true and proceed
            // immediately, but the server hadn't yet added the socket to the
            // user:{id} room, so all subsequent `events` emissions were dropped.
            isUserJoined = false
            if let token = authToken, !token.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    let result = await self.emitWithAck("user-join", data: ["auth": ["token": token]], timeout: 5.0)
                    // Only mark joined if we're still on the same connection —
                    // a disconnect/reconnect in the meantime should not resurrect this.
                    guard self.isConnected else { return }
                    if result != nil {
                        self.isUserJoined = true
                        self.logger.info("user-join acknowledged, sid=\(self.sid ?? "nil")")
                    } else {
                        // Ack timed out — assume joined anyway rather than blocking
                        // sends forever. Older server versions may not ack promptly,
                        // and the CONNECT handshake itself may have already joined
                        // the room via the auth-carrying handshake payload.
                        self.isUserJoined = true
                        self.logger.warning("user-join ack timed out — proceeding optimistically")
                    }
                }
            } else {
                // No token to join with (shouldn't normally happen) — don't block forever.
                isUserJoined = true
            }

            DispatchQueue.main.async { [weak self] in
                self?.onConnect?()
            }

            if reconnectCount > 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.onReconnect?()
                }
            }


        case "1":
            // Socket.IO DISCONNECT
            handleDisconnect(reason: "Server namespace disconnect")

        case "2":
            // Socket.IO EVENT — may carry a numeric ack ID prefix before the JSON array.
            // Format without ack: `2["eventName", payload]`
            // Format with ack:    `2<digits>["eventName", payload]`
            let rest = String(raw.dropFirst())
            var ackId: Int? = nil
            var jsonStr = rest
            if let bracketIdx = rest.firstIndex(of: "[") {
                let prefix = String(rest[rest.startIndex..<bracketIdx])
                if !prefix.isEmpty, let id = Int(prefix) {
                    ackId = id
                    jsonStr = String(rest[bracketIdx...])
                }
            }
            parseAndDispatchEvent(jsonStr, ackId: ackId)

        case "3":
            // Socket.IO ACK — server responding to a client-initiated emitWithAck().
            // Format: `3<ackId>[responseValue]` or `3<ackId>` with no payload.
            let rest = String(raw.dropFirst())
            var digitsEnd = rest.startIndex
            while digitsEnd < rest.endIndex, rest[digitsEnd].isNumber {
                digitsEnd = rest.index(after: digitsEnd)
            }
            let idStr = String(rest[rest.startIndex..<digitsEnd])
            guard let id = Int(idStr) else { break }
            let jsonPart = String(rest[digitsEnd...])
            var ackValue: Any? = nil
            if let jsonData = jsonPart.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: jsonData) as? [Any] {
                ackValue = array.first
            }
            resolveAck(id, data: ackValue)

        case "4":
            // Socket.IO ERROR
            let errorStr = String(raw.dropFirst())
            logger.error("Socket.IO error: \(errorStr)")


        default:
            // Try parsing as a plain event if prefixed with a digit (e.g., "2[...]")
            if first.isNumber {
                let remaining = String(raw.dropFirst())
                parseAndDispatchEvent(remaining)
            }
        }
    }

    // MARK: - Private: Event Dispatch

    private func parseAndDispatchEvent(_ jsonStr: String, ackId: Int? = nil) {
        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let eventName = array.first as? String
        else { return }

        let payload: [String: Any]
        if array.count > 1, let dict = array[1] as? [String: Any] {
            payload = dict
        } else {
            payload = [:]
        }

        // 🔍 DIAGNOSTIC: log every socket event name + nested type
        let nestedType = (payload["data"] as? [String: Any])?["type"] as? String
            ?? payload["type"] as? String
            ?? "?"
        let chatId = payload["chat_id"] as? String ?? "nil"
        let msgId = payload["message_id"] as? String ?? "nil"
        logger.info("🔌 [Socket] event=\(eventName, privacy: .public) type=\(nestedType, privacy: .public) chat_id=\(chatId, privacy: .public) msg_id=\(msgId, privacy: .public)")

        switch eventName {
        case "events", "chat-events":
            dispatchChatEvent(payload, ackId: ackId)
        case "events:channel", "channel-events":
            dispatchChannelEvent(payload)
        default:
            break
        }
    }

    private func dispatchChatEvent(_ event: [String: Any], ackId: Int? = nil) {
        let chatId = event["chat_id"] as? String
        let eventSessionId = extractSessionId(from: event)
        let eventType = (event["data"] as? [String: Any])?["type"] as? String ?? event["type"] as? String ?? "?"

        handlerLock.lock()
        let handlers = Array(chatHandlers.values)
        handlerLock.unlock()


        var delivered = 0
        for reg in handlers {
            let delivers = shouldDeliver(
                registeredConversationId: reg.conversationId,
                registeredSessionId: reg.sessionId,
                incomingChatId: chatId,
                incomingSessionId: eventSessionId
            )
            if delivers {
                // Construct a real ack callback when the server sent an ack ID,
                // so __event_call__ handlers can reply and unblock sio.call() on the server.
                let ackCallback: ((Any?) -> Void)? = ackId.map { id in
                    { [weak self] data in
                        self?.logger.info("🔁 [Socket] emitAck id=\(id, privacy: .public) data=\(String(describing: data), privacy: .public)")
                        self?.emitAck(id, data: data)
                    }
                }
                reg.handler(event, ackCallback)
                delivered += 1
            }
        }
        if delivered == 0 {
            logger.warning("⚠️ [Socket] dispatchChatEvent — NO handler matched! type=\(eventType, privacy: .public) sessionId=\(eventSessionId ?? "nil", privacy: .public) chatId=\(chatId ?? "nil", privacy: .public)")
        }
    }

    private func dispatchChannelEvent(_ event: [String: Any]) {
        let chatId = event["chat_id"] as? String
        let channelId = event["channel_id"] as? String
            ?? (event["data"] as? [String: Any])?["channel_id"] as? String
        let eventSessionId = extractSessionId(from: event)
        
        // Also check nested data.data for channel_id (some events nest deeply)
        let nestedChannelId: String? = {
            if let inner = (event["data"] as? [String: Any])?["data"] as? [String: Any] {
                return inner["channel_id"] as? String
            }
            return nil
        }()

        handlerLock.lock()
        let handlers = Array(channelHandlers.values)
        handlerLock.unlock()
        
        let eventType = (event["data"] as? [String: Any])?["type"] as? String ?? event["type"] as? String
        logger.debug("dispatchChannelEvent: type=\(eventType ?? "nil"), chatId=\(chatId ?? "nil"), channelId=\(channelId ?? "nil"), handlers=\(handlers.count)")

        for reg in handlers {
            let matchesChatOrChannel = reg.conversationId == nil
                || reg.conversationId == chatId
                || reg.conversationId == channelId
                || reg.conversationId == nestedChannelId
            let matchesSession = reg.sessionId != nil
                && eventSessionId != nil
                && reg.sessionId == eventSessionId

            if matchesChatOrChannel || matchesSession {
                reg.handler(event, nil)
            }
        }
        
        // If no handler matched and we have handlers registered, deliver to all
        // channel handlers as a fallback (the handler itself will check relevance)
        if !handlers.isEmpty && channelId == nil && chatId == nil {
            logger.debug("Channel event with no channel_id/chat_id — broadcasting to all \(handlers.count) channel handlers")
            for reg in handlers {
                reg.handler(event, nil)
            }
        }
    }

    private func shouldDeliver(
        registeredConversationId: String?,
        registeredSessionId: String?,
        incomingChatId: String?,
        incomingSessionId: String?
    ) -> Bool {
        let matchesConversation = registeredConversationId == nil
            || (incomingChatId != nil && registeredConversationId == incomingChatId)
        let matchesSession = registeredSessionId != nil
            && incomingSessionId != nil
            && registeredSessionId == incomingSessionId

        return matchesConversation || matchesSession
    }

    private func extractSessionId(from event: [String: Any]) -> String? {
        if let sid = event["session_id"] as? String { return sid }
        if let data = event["data"] as? [String: Any] {
            if let sid = data["session_id"] as? String { return sid }
            if let sid = data["sessionId"] as? String { return sid }
            if let inner = data["data"] as? [String: Any] {
                return inner["session_id"] as? String ?? inner["sessionId"] as? String
            }
        }
        return nil
    }

    // MARK: - Private: Heartbeat & Ping

    /// Starts the OpenWebUI `heartbeat` Socket.IO event timer.
    ///
    /// Engine.IO v4 heartbeat direction: **server sends PING, client responds PONG**.
    /// The `case "2": send("3")` in `handleEngineIOMessage` already handles that correctly.
    /// We must NOT send Engine.IO "2" packets from the client — that would be the wrong
    /// direction per the EIO4 spec and wastes a connection slot on every tick.
    ///
    /// This timer only sends the Socket.IO-level `heartbeat` event that OpenWebUI uses
    /// to track `last_seen_at` in SESSION_POOL. It does NOT send Engine.IO PINGs.
    private func startPing() {
        stopPing()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // OpenWebUI expects a Socket.IO `heartbeat` event every 30 seconds
            // to update last_seen_at in SESSION_POOL.
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
                guard let self, self.isConnected else {
                    timer.invalidate()
                    return
                }
                self.emit("heartbeat", data: [:] as [String: Any])
            }
        }
    }

    private func startHeartbeat() {
        // No-op: heartbeat is now consolidated into startPing() above.
        // Engine.IO v4 PING/PONG is handled server→client in handleEngineIOMessage.
    }

    private func stopPing() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
            self?.heartbeatTimer?.invalidate()
            self?.heartbeatTimer = nil
        }
    }

    // MARK: - Private: Disconnect & Reconnect

    private func disconnectInternal() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        pollingReceiveTask?.cancel()
        pollingReceiveTask = nil
    }

    private func handleDisconnect(reason: String?) {
        let wasConnected = isConnected
        isConnected = false
        isConnecting = false
        isUserJoined = false
        stopPing()


        if wasConnected {
            logger.warning("Socket disconnected: \(reason ?? "unknown")")
            DispatchQueue.main.async { [weak self] in
                self?.onDisconnect?(reason)
            }
        }

        // Only auto-reconnect if enabled (not an intentional disconnect)
        guard autoReconnectEnabled else {
            connectionState = .disconnected
            return
        }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        // Invalidate on main thread immediately to prevent the race where a
        // rapid second disconnect fires before the first async block runs.
        if Thread.isMainThread {
            reconnectTimer?.invalidate()
            reconnectTimer = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.reconnectTimer?.invalidate()
                self?.reconnectTimer = nil
            }
        }

        guard autoReconnectEnabled else {
            connectionState = .disconnected
            return
        }

        reconnectAttempt += 1

        // Give up after max attempts — stay disconnected until manually reconnected
        if reconnectAttempt > maxReconnectAttempts {
            logger.warning("Max reconnect attempts (\(self.maxReconnectAttempts)) reached, giving up")
            connectionState = .disconnected
            return
        }

        connectionState = .reconnecting(attempt: reconnectAttempt)

        // If the app is backgrounded, don't schedule a timer that won't fire reliably.
        // resetBackoffAndReconnect() will connect immediately when foreground returns.
        if isAppInBackground {
            logger.info("App in background — deferring reconnect until foreground")
            return
        }

        let jitter = Double.random(in: 0...0.5)
        let delay = min(
            baseReconnectDelay * pow(2.0, Double(min(reconnectAttempt - 1, 5))) + jitter,
            maxReconnectDelay
        )

        logger.info("Scheduling reconnect in \(String(format: "%.1f", delay))s (attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts))")

        DispatchQueue.main.async { [weak self] in
            guard let self, self.autoReconnectEnabled, !self.isConnected, !self.isConnecting else { return }
            self.reconnectTimer = Timer.scheduledTimer(
                withTimeInterval: delay,
                repeats: false
            ) { [weak self] _ in
                guard let self else { return }
                // Only reconnect if still genuinely disconnected.
                // Do NOT use force:true here — if something else already
                // connected the socket (e.g., updateAuthToken or foreground
                // handler), force:true would cancel that working connection
                // via disconnectInternal(), causing another disconnect →
                // scheduleReconnect → infinite loop.
                guard !self.isConnected, !self.isConnecting else { return }
                self.reconnectCount += 1
                self.connect()
            }
        }
    }

    // MARK: - Private: Handler IDs

    private func nextHandlerId() -> String {
        handlerLock.lock()
        handlerSeed += 1
        let id = "\(handlerSeed)"
        handlerLock.unlock()
        return id
    }
}

// MARK: - Supporting Types

/// A disposable subscription to a socket event.
///
/// Thread-safe — `dispose()` can be called from any thread without
/// risk of double-execution thanks to an internal lock.
final class SocketSubscription: @unchecked Sendable {
    private var disposeAction: (() -> Void)?
    private var isDisposed = false
    private let lock = NSLock()

    init(_ dispose: @escaping () -> Void) {
        self.disposeAction = dispose
    }

    func dispose() {
        lock.lock()
        guard !isDisposed else {
            lock.unlock()
            return
        }
        isDisposed = true
        let action = disposeAction
        disposeAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        dispose()
    }
}

// MARK: - Handler Registrations

private struct ChatHandlerRegistration: Sendable {
    let id: String
    let conversationId: String?
    let sessionId: String?
    let handler: SocketIOService.EventHandler
}

private struct ChannelHandlerRegistration: Sendable {
    let id: String
    let conversationId: String?
    let sessionId: String?
    let handler: SocketIOService.EventHandler
}
