import Foundation
import UIKit
import SwiftTerm
import os.log

/// Drives one interactive PTY session over the Open WebUI terminal WebSocket.
///
/// Protocol (identical to the web `XTerminal` component):
///   1. `POST /api/v1/terminals/{server}/api/terminals` (with `X-Session-Id`) → `{"id": …}`
///   2. `WS   /api/v1/terminals/{server}/api/terminals/{id}`
///   3. first frame: `{"type":"auth","token":…,"chat_id":…}`
///   4. `{"type":"resize","cols":N,"rows":M}` whenever the view resizes
///   5. binary frames both ways; `{"type":"ping"}` every 25 s
///
/// Close codes 4001/4003/4004 are authorisation failures and are surfaced
/// instead of retried. A normal close means the shell exited.
@MainActor @Observable
final class TerminalShellViewModel {

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int)
        /// The shell process exited (e.g. the user typed `exit`).
        case ended
        case failed(String)

        var isLive: Bool { self == .connected }
        var isBusy: Bool {
            switch self { case .connecting, .reconnecting: return true; default: return false }
        }
    }

    // MARK: Observable state

    private(set) var state: ConnectionState = .idle
    /// Title set by the shell via OSC escape sequences (e.g. `user@host: ~/dir`).
    private(set) var title: String = ""

    /// The emulator currently showing this session. Output that arrives while
    /// no view is attached is buffered and replayed on attach.
    weak var terminalView: TerminalView? {
        didSet { if terminalView != nil, terminalView !== oldValue { flushPendingOutput() } }
    }

    // MARK: Configuration

    @ObservationIgnored private var apiClient: APIClient?
    @ObservationIgnored private var serverId = ""
    @ObservationIgnored private var chatId: String?
    @ObservationIgnored private let logger = Logger(subsystem: "com.openui", category: "TerminalShell")

    // MARK: Socket state

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var ptyId: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var receivedData = false
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var pendingOutput: [UInt8] = []
    @ObservationIgnored private var cols = 80
    @ObservationIgnored private var rows = 24
    /// Keys waiting to be sent (held while offline, coalesced while typing).
    @ObservationIgnored private var outbox: [UInt8] = []
    @ObservationIgnored private var flushScheduled = false
    private static let outboxLimit = 64 * 1024
    /// Local line editor (see `TerminalLineEditor`).
    @ObservationIgnored let lineEditor = TerminalLineEditor()
    /// Bytes typed while not connected (drives the "queued" status).
    private(set) var queuedCount = 0
    /// True when the terminal is showing a full-screen app or password prompt.
    private(set) var liveModeDetected = false
    /// User preference: edit lines locally and send on Return.
    var lineModeEnabled: Bool = UserDefaults.standard.object(forKey: "terminal.lineMode") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lineModeEnabled, forKey: "terminal.lineMode")
            if !lineModeEnabled { transmit(lineEditor.flush(terminalView)) }
        }
    }
    /// Set when the server rejected us (bad token / no access) — never auto-retry.
    @ObservationIgnored private var authFailed = false

    /// True while the shell emulator has keyboard focus. The iPad panel uses this
    /// to give the shell the full height above the keyboard while typing.
    var isKeyboardFocused = false

    /// True while the panel is on screen — reconnects only happen when visible.
    @ObservationIgnored private(set) var isVisible = false
    /// True once the user has opened the shell at least once in this chat.
    @ObservationIgnored private(set) var hasStarted = false

    private static let maxReconnectAttempts = 6
    private static let pendingLimit = 512 * 1024

    // MARK: - Setup

    func configure(apiClient: APIClient, serverId: String, chatId: String?) {
        let changed = self.serverId != serverId || self.chatId != chatId
        self.apiClient = apiClient
        if changed {
            disconnect(clearSession: true)
            self.serverId = serverId
            self.chatId = chatId
            state = .idle
            hasStarted = false
        }
    }

    func reset() {
        disconnect(clearSession: true)
        state = .idle
        title = ""
        hasStarted = false
        isVisible = false
        pendingOutput.removeAll()
        outbox.removeAll()
        queuedCount = 0
        lineEditor.discard()
        terminalView = nil
    }

    // MARK: - Lifecycle

    /// Starts (or resumes) the shell. Safe to call repeatedly — a failed or
    /// ended session waits for an explicit `restart()` instead of looping.
    func start() {
        hasStarted = true
        isVisible = true
        guard state == .idle else { return }
        reconnectAttempt = 0
        connect(fresh: ptyId == nil)
    }

    /// Kills the current session and opens a new one.
    func restart() {
        let oldId = ptyId
        disconnect(clearSession: true)
        if let oldId, let apiClient {
            let server = serverId, chat = chatId
            Task { await apiClient.terminalDeleteSession(serverId: server, terminalId: oldId, sessionId: chat) }
        }
        terminalView?.getTerminal().resetToInitialState()
        pendingOutput.removeAll()
        outbox.removeAll()
        queuedCount = 0
        lineEditor.discard()
        hasStarted = true
        isVisible = true
        reconnectAttempt = 0
        connect(fresh: true)
    }

    func panelDidAppear() {
        isVisible = true
        if hasStarted, !state.isLive, !state.isBusy, state != .ended, !isAuthFailure {
            reconnectAttempt = 0
            connect(fresh: ptyId == nil)
        }
    }

    /// Closes the socket but keeps the PTY id so the session can be resumed.
    func panelDidDisappear() {
        isVisible = false
        guard socket != nil || state.isBusy else { return }
        disconnect(clearSession: false)
        if state != .ended, !isAuthFailure { state = .idle }
    }

    func appDidEnterBackground() {
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func appWillEnterForeground() {
        guard isVisible, hasStarted else { return }
        if state == .connected, let socket, socket.state == .running {
            startPing()
        } else if state != .ended, !isAuthFailure {
            disconnect(clearSession: false)
            reconnectAttempt = 0
            connect(fresh: ptyId == nil)
        }
    }

    private var isAuthFailure: Bool { authFailed }

    // MARK: - Connect

    private func connect(fresh: Bool) {
        guard let apiClient, !serverId.isEmpty else { return }
        generation += 1
        let gen = generation
        tearDownSocket()
        authFailed = false
        state = reconnectAttempt > 0 ? .reconnecting(attempt: reconnectAttempt) : .connecting
        if fresh { ptyId = nil }

        Task { [weak self] in
            guard let self else { return }
            do {
                var id = self.ptyId
                if id == nil {
                    id = try await apiClient.terminalCreateSession(serverId: self.serverId, sessionId: self.chatId)
                }
                guard gen == self.generation, let id else { return }
                self.ptyId = id
                guard let url = apiClient.terminalWebSocketURL(serverId: self.serverId, terminalId: id) else {
                    throw URLError(.badURL)
                }
                self.openSocket(url: url, token: apiClient.network.authToken ?? "", generation: gen)
            } catch {
                guard gen == self.generation else { return }
                self.logger.error("Shell start failed: \(error.localizedDescription, privacy: .public)")
                if case APIError.httpError(let status, let message, _) = error, [401, 403, 404, 409].contains(status) {
                    self.fail(message ?? error.localizedDescription, permanent: true)
                } else if case APIError.tokenExpired = error {
                    self.fail("Your session expired. Sign in again to use the terminal.", permanent: true)
                } else {
                    self.scheduleReconnect(after: error.localizedDescription)
                }
            }
        }
    }

    private func openSocket(url: URL, token: String, generation gen: Int) {
        guard let apiClient else { return }
        let delegate = TerminalSocketDelegate(trustDelegate: apiClient.network.session.delegate)
        let owner = WeakShellBox(self)
        delegate.onOpen = {
            Task { @MainActor in owner.value?.socketDidOpen(generation: gen) }
        }
        delegate.onClose = { code, reason in
            Task { @MainActor in owner.value?.socketDidClose(generation: gen, code: code, reason: reason) }
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = .infinity
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpAdditionalHeaders = apiClient.network.session.configuration.httpAdditionalHeaders
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: URLRequest(url: url))
        task.maximumMessageSize = 16 * 1024 * 1024
        socket = task
        receivedData = false
        task.resume()

        // First-message auth (with the chat id so chat-scoped terminals attach
        // to the right workspace), then the initial size. Both are buffered
        // until the socket opens.
        sendJSON(["type": "auth", "token": token, "chat_id": chatId ?? ""])
        sendJSON(["type": "resize", "cols": cols, "rows": rows])

        receiveTask = Task { [weak self] in await self?.receiveLoop(generation: gen) }
    }

    private func socketDidOpen(generation gen: Int) {
        guard gen == generation else { return }
        // The server may still reject the auth frame and close with 4001/4003.
        // Treat the session as live after the first output, or a short grace
        // period (some shells print nothing until a key is pressed).
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled, gen == self.generation, self.socket != nil else { return }
            self.markConnected()
        }
    }

    private func markConnected() {
        guard state != .connected else { return }
        state = .connected
        reconnectAttempt = 0
        graceTask?.cancel()
        startPing()
        // Re-send the size — the server applies it once the PTY is attached.
        sendJSON(["type": "resize", "cols": cols, "rows": rows])
        // Deliver anything typed while offline / reconnecting.
        scheduleFlush()
    }

    private func socketDidClose(generation gen: Int, code: Int, reason: String?) {
        guard gen == generation else { return }
        handleClosed(code: code, reason: reason)
    }

    private func receiveLoop(generation gen: Int) async {
        while !Task.isCancelled, gen == generation, let socket {
            do {
                let message = try await socket.receive()
                guard gen == generation else { return }
                if !receivedData {
                    receivedData = true
                    markConnected()
                }
                switch message {
                case .data(let data): write(ArraySlice(data))
                case .string(let text):
                    // Control frames are JSON (e.g. pong); anything else is output.
                    if text.hasPrefix("{\"type\"") { continue }
                    write(ArraySlice(Array(text.utf8)))
                @unknown default: break
                }
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                let code = socket.closeCode.rawValue
                handleClosed(code: code == 0 ? nil : code,
                             reason: socket.closeReason.flatMap { String(data: $0, encoding: .utf8) })
                return
            }
        }
    }

    private func handleClosed(code: Int?, reason: String?) {
        guard socket != nil else { return }
        let hadData = receivedData
        tearDownSocket()
        generation += 1

        switch code {
        case 4001:
            fail("The terminal rejected your sign-in. Sign in again and retry.", permanent: true)
        case 4003:
            fail((reason?.isEmpty == false ? reason : nil) ?? "You don't have access to this terminal.", permanent: true)
        case 4004:
            fail("This terminal server no longer exists.", permanent: true)
        case 1000 where hadData:
            // Clean close after output → the shell exited.
            state = .ended
            ptyId = nil
            write(Self.dim("\r\n[Process completed — tap Restart for a new shell]\r\n"))
        default:
            if !hadData { ptyId = nil } // Dropped before any output — the PTY is likely gone.
            guard isVisible else { state = .idle; return }
            if hadData { write(Self.dim("\r\n[Connection lost — reconnecting…]\r\n")) }
            scheduleReconnect(after: reason)
        }
    }

    private func scheduleReconnect(after reason: String?) {
        reconnectTask?.cancel()
        guard isVisible else { state = .idle; return }
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            fail(reason ?? "Couldn't reach the terminal.", permanent: false)
            return
        }
        reconnectAttempt += 1
        state = .reconnecting(attempt: reconnectAttempt)
        let delay = min(15.0, pow(2.0, Double(reconnectAttempt - 1)))
        // After half the attempts, give up on the old PTY and start fresh.
        let fresh = ptyId == nil || reconnectAttempt > Self.maxReconnectAttempts / 2
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isVisible else { return }
            self.connect(fresh: fresh)
        }
    }

    private func fail(_ message: String, permanent: Bool) {
        tearDownSocket()
        reconnectTask?.cancel()
        authFailed = permanent
        if permanent { ptyId = nil }
        state = .failed(message)
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, !Task.isCancelled, self.state == .connected else { return }
                self.sendJSON(["type": "ping"])
            }
        }
    }

    private func tearDownSocket() {
        receiveTask?.cancel(); receiveTask = nil
        pingTask?.cancel(); pingTask = nil
        graceTask?.cancel(); graceTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func disconnect(clearSession: Bool) {
        generation += 1
        reconnectTask?.cancel(); reconnectTask = nil
        tearDownSocket()
        if clearSession { ptyId = nil }
    }

    // MARK: - IO

    /// Keystrokes from the emulator. In line mode printable keys stay local
    /// until Return; in live mode (or for keys the shell needs now) they are
    /// sent immediately.
    func handleKeyboard(_ bytes: ArraySlice<UInt8>) {
        guard let view = terminalView else { return }
        if isLineModeActive {
            let out = lineEditor.handle(bytes, view: view)
            if !out.isEmpty { transmit(out) }
        } else {
            transmit(Array(bytes))
        }
    }

    /// Raw send that bypasses line editing (key bar keys use `handleKeyboard`).
    func send(_ bytes: ArraySlice<UInt8>) { transmit(Array(bytes)) }

    func send(text: String) { transmit(Array(text.utf8)) }

    /// Pastes text, honouring bracketed-paste mode when the shell requested it.
    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        if isLineModeActive, let view = terminalView, lineEditor.paste(text, view: view) { return }
        let pending = lineEditor.flush(terminalView)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        let body = terminalView?.getTerminal().bracketedPasteMode == true
            ? "\u{1B}[200~" + normalized + "\u{1B}[201~" : normalized
        transmit(pending + Array(body.utf8))
    }

    /// Updates the Line/Live indicator after output (e.g. vim opened or a
    /// password prompt appeared) without needing a keypress.
    private func refreshInputMode() {
        guard lineModeEnabled, let terminal = terminalView?.getTerminal() else {
            if liveModeDetected { liveModeDetected = false }
            return
        }
        let live = TerminalLineEditor.needsLiveMode(terminal)
        if liveModeDetected != live { liveModeDetected = live }
    }

    /// Whether keys are currently edited locally.
    var isLineModeActive: Bool {
        guard lineModeEnabled, let terminal = terminalView?.getTerminal() else { return false }
        let live = TerminalLineEditor.needsLiveMode(terminal)
        if live, !lineEditor.isEmpty {
            // Switched to a full-screen app / password prompt mid-line: hand the text over.
            let pending = lineEditor.flush(terminalView)
            if !pending.isEmpty { transmit(pending) }
        }
        if liveModeDetected != live { liveModeDetected = live }
        return !live
    }

    /// Queues bytes and sends them in one frame per run-loop turn. While the
    /// socket isn't open (connecting, reconnecting, offline) bytes are held
    /// and delivered in order once connected.
    private func transmit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        outbox.append(contentsOf: bytes)
        if outbox.count > Self.outboxLimit { outbox.removeFirst(outbox.count - Self.outboxLimit) }
        queuedCount = state == .connected ? 0 : outbox.count
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard state == .connected, !flushScheduled else { return }
        flushScheduled = true
        // Coalesce keys typed within ~8 ms (fast typing, key repeat, paste).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000)
            self?.flushOutbox()
        }
    }

    private func flushOutbox() {
        flushScheduled = false
        guard state == .connected, let socket, !outbox.isEmpty else { return }
        let data = Data(outbox)
        outbox.removeAll(keepingCapacity: true)
        queuedCount = 0
        let log = logger
        socket.send(.data(data)) { error in
            if let error { log.error("send: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 1, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        if state == .connected { sendJSON(["type": "resize", "cols": cols, "rows": rows]) }
    }

    func setTitle(_ title: String) { self.title = title }

    /// Clears the local screen and scrollback (the shell keeps its state).
    func clearScreen() {
        guard let terminal = terminalView?.getTerminal() else { return }
        lineEditor.discard()
        terminal.resetToInitialState()
        // Ask the shell to redraw its prompt.
        send(text: "\u{0C}")
    }

    /// Full scrollback + screen as plain text.
    func allText() -> String {
        guard let terminal = terminalView?.getTerminal() else { return "" }
        let data = terminal.getBufferAsData(kind: .active, encoding: .utf8)
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let socket, socket.state != .canceling, socket.state != .completed,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func write(_ bytes: ArraySlice<UInt8>) {
        if let terminalView {
            // Keep the unsent local line after the shell's output.
            lineEditor.hideEcho(terminalView)
            terminalView.feed(byteArray: bytes)
            lineEditor.showEcho(terminalView)
            refreshInputMode()
        } else {
            pendingOutput.append(contentsOf: bytes)
            if pendingOutput.count > Self.pendingLimit {
                pendingOutput.removeFirst(pendingOutput.count - Self.pendingLimit)
            }
        }
    }

    private func write(_ text: String) { write(ArraySlice(Array(text.utf8))) }

    private func flushPendingOutput() {
        guard !pendingOutput.isEmpty, let terminalView else { return }
        let bytes = pendingOutput
        pendingOutput.removeAll()
        terminalView.feed(byteArray: bytes[...])
    }

    private static func dim(_ text: String) -> String { "\u{1B}[2m" + text + "\u{1B}[0m" }
}

/// Sendable weak reference used by URLSession delegate callbacks.
nonisolated final class WeakShellBox: @unchecked Sendable {
    weak var value: TerminalShellViewModel?
    init(_ value: TerminalShellViewModel) { self.value = value }
}

// MARK: - Socket Delegate

/// Reports WebSocket open/close (with the close code) and forwards TLS
/// challenges to the app's certificate-trust delegate for self-signed servers.
nonisolated final class TerminalSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (@Sendable () -> Void)?
    var onClose: (@Sendable (Int, String?) -> Void)?
    private weak var trustDelegate: (any URLSessionDelegate)?

    init(trustDelegate: (any URLSessionDelegate)?) {
        self.trustDelegate = trustDelegate
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(closeCode.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) })
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let handler = trustDelegate?.urlSession(_:didReceive:completionHandler:) {
            handler(session, challenge, completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
