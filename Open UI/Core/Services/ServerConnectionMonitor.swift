import Foundation
import Network
import os.log

/// The current state of the server connection.
enum ServerConnectionState: Equatable, Sendable {
    /// Connected and healthy.
    case connected
    /// Actively checking whether the server/internet is reachable.
    case checking
    /// The server is unreachable but the device has internet.
    case serverDown
    /// The device has no internet connectivity at all.
    case internetDown
}

/// Centralized service that continuously monitors server reachability
/// and provides an observable connection state to the entire app.
///
/// Combines three signals:
/// 1. **NWPathMonitor** — instant, event-driven detection of device-level
///    internet loss (WiFi off, airplane mode, no cellular).
/// 2. **`GET /health` polling** — periodic lightweight ping to the OpenWebUI
///    server to detect server-down conditions.
/// 3. **External ping** — HEAD request to Apple's captive portal URL to
///    distinguish "internet is down" from "server is down" when NWPath
///    reports satisfied but /health fails (e.g. captive portals).
///
/// Exposes an `@Observable` `connectionState` that the UI overlay reads,
/// and auto-reconnects the Socket.IO service when the server comes back.
@Observable
final class ServerConnectionMonitor: @unchecked Sendable {
    // MARK: - Observable State

    /// The current connection state. SwiftUI views observe this.
    var connectionState: ServerConnectionState = .connected

    /// When the connection was first lost (nil when connected).
    var disconnectedSince: Date?

    /// Number of reconnect attempts since the last disconnect.
    var reconnectAttempt: Int = 0

    /// Whether the disconnect overlay should be visible.
    /// Uses a debounce so transient blips (<1.5s) don't flash the overlay.
    var isShowingOverlay: Bool = false

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.openui", category: "ConnectionMonitor")

    /// Apple Network.framework path monitor — event-driven internet detection.
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let monitorQueue = DispatchQueue(label: "com.openui.connection.monitor")

    /// Whether the device network path is satisfied (has internet).
    @ObservationIgnored private var isNetworkAvailable: Bool = true

    /// The polling task that periodically checks /health.
    @ObservationIgnored private var healthPollTask: Task<Void, Never>?

    /// The debounce task for showing/hiding the overlay.
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Weak reference to the API client for health checks.
    @ObservationIgnored private weak var apiClient: APIClient?

    /// Weak reference to the socket service for reconnection.
    @ObservationIgnored private weak var socketService: SocketIOService?

    /// Whether the monitor is currently running.
    @ObservationIgnored private var isRunning = false

    /// Flag to coalesce rapid immediate-check requests.
    @ObservationIgnored private var immediateCheckInFlight = false

    // MARK: - Configuration

    /// How often to poll /health when connected (seconds).
    private let connectedPollInterval: TimeInterval = 15

    /// Base delay for exponential backoff when disconnected (seconds).
    private let disconnectedBaseDelay: TimeInterval = 2

    /// Maximum backoff delay when disconnected (seconds).
    private let disconnectedMaxDelay: TimeInterval = 15

    /// How long to wait before showing the overlay (debounce, seconds).
    private let overlayDebounce: TimeInterval = 1.5

    /// Timeout for the external ping (seconds).
    private let externalPingTimeout: TimeInterval = 5

    // MARK: - Lifecycle

    /// Starts the connection monitor with the given API client and socket service.
    ///
    /// Safe to call multiple times — stops any previous monitor first.
    func start(apiClient: APIClient, socketService: SocketIOService?) {
        stop()

        self.apiClient = apiClient
        self.socketService = socketService
        isRunning = true

        startPathMonitor()
        startHealthPoll()

        // Wire socket disconnect to trigger immediate health check
        socketService?.onDisconnect = { [weak self] _ in
            self?.triggerImmediateCheck()
        }

        logger.info("Connection monitor started")
    }

    /// Stops all monitoring. Call on server switch or logout.
    func stop() {
        isRunning = false
        pathMonitor?.cancel()
        pathMonitor = nil
        healthPollTask?.cancel()
        healthPollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        immediateCheckInFlight = false

        // Reset state
        connectionState = .connected
        disconnectedSince = nil
        reconnectAttempt = 0
        isShowingOverlay = false

        logger.info("Connection monitor stopped")
    }

    /// Triggers an immediate health check, e.g. on foreground return.
    func triggerImmediateCheck() {
        guard isRunning, !immediateCheckInFlight else { return }
        immediateCheckInFlight = true

        Task { [weak self] in
            await self?.checkServerHealth()
            self?.immediateCheckInFlight = false
        }
    }

    // MARK: - NWPathMonitor

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wasAvailable = self.isNetworkAvailable
            let nowAvailable = path.status == .satisfied

            self.isNetworkAvailable = nowAvailable

            if !nowAvailable {
                // Device lost internet — transition immediately
                Task { @MainActor [weak self] in
                    self?.transitionTo(.internetDown)
                }
            } else if !wasAvailable && nowAvailable {
                // Internet just came back — immediate health check
                self.logger.info("NWPathMonitor: network restored, triggering health check")
                self.triggerImmediateCheck()
            }
        }

        monitor.start(queue: monitorQueue)
    }

    // MARK: - Health Polling

    private func startHealthPoll() {
        healthPollTask = Task { [weak self] in
            // Initial small delay to let the app finish launching
            try? await Task.sleep(for: .seconds(2))

            while !Task.isCancelled {
                guard let self, self.isRunning else { break }

                await self.checkServerHealth()

                guard !Task.isCancelled else { break }

                // Sleep duration depends on current state
                let interval = await self.currentPollInterval()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    @MainActor
    private func currentPollInterval() -> TimeInterval {
        if connectionState == .connected {
            return connectedPollInterval
        } else {
            return backoffInterval()
        }
    }

    // MARK: - Health Check

    private func checkServerHealth() async {
        guard let apiClient else { return }

        let healthy = await apiClient.checkHealth()

        await MainActor.run { [weak self] in
            guard let self else { return }

            if healthy {
                self.transitionTo(.connected)
            } else if !self.isNetworkAvailable {
                self.transitionTo(.internetDown)
            } else {
                // NWPath says we're online — check if internet actually works
                Task { [weak self] in
                    guard let self else { return }
                    let externalReachable = await self.pingExternalEndpoint()
                    await MainActor.run {
                        self.transitionTo(externalReachable ? .serverDown : .internetDown)
                    }
                }
            }
        }
    }

    /// Pings Apple's captive portal URL to determine if the device actually
    /// has working internet (as opposed to a captive portal or blocked network).
    private func pingExternalEndpoint() async -> Bool {
        guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = externalPingTimeout

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - State Machine

    @MainActor
    private func transitionTo(_ newState: ServerConnectionState) {
        let oldState = connectionState

        // Avoid redundant transitions
        if newState == oldState && newState != .checking { return }

        if newState == .connected {
            // Reconnected!
            if oldState != .connected {
                logger.info("Connection restored after \(self.reconnectAttempt) attempts")
                onReconnected()
            }
            reconnectAttempt = 0
            disconnectedSince = nil
            connectionState = .connected
            updateOverlayVisibility(disconnected: false)
        } else {
            // Entering a disconnected state
            if oldState == .connected {
                disconnectedSince = Date()
                logger.warning("Connection lost: \(String(describing: newState))")
            }

            if newState != .checking {
                reconnectAttempt += 1
            }

            connectionState = newState
            updateOverlayVisibility(disconnected: true)
        }
    }

    /// Called when the server becomes reachable again.
    @MainActor
    private func onReconnected() {
        // Reconnect socket if it's not connected
        if let socket = socketService, !socket.isConnected {
            socket.connect(force: true)
            logger.info("Triggered socket reconnection after server recovery")
        }
    }

    // MARK: - Overlay Debounce

    /// Updates the overlay visibility with a debounce to prevent flickering.
    @MainActor
    private func updateOverlayVisibility(disconnected: Bool) {
        debounceTask?.cancel()

        if !disconnected {
            // Hide overlay immediately on reconnection
            isShowingOverlay = false
        } else if !isShowingOverlay {
            // Show overlay after debounce delay
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.overlayDebounce ?? 1.5))
                guard !Task.isCancelled else { return }
                guard let self, self.connectionState != .connected else { return }
                self.isShowingOverlay = true
            }
        }
    }

    // MARK: - Backoff

    private func backoffInterval() -> TimeInterval {
        let attempt = max(reconnectAttempt - 1, 0)
        let exponent = min(attempt, 3) // caps at 2^3 = 8 → 2*8 = 16, clamped to 15
        let delay = min(
            disconnectedBaseDelay * pow(2.0, Double(exponent)),
            disconnectedMaxDelay
        )
        let jitter = Double.random(in: 0...0.5)
        return delay + jitter
    }

    // MARK: - User-Facing Message

    /// A contextual disconnect message for the overlay.
    var disconnectMessage: String {
        switch connectionState {
        case .connected:
            return ""
        case .checking:
            return String(localized: "Checking connection…")
        case .serverDown:
            return String(localized: "Your server appears to be offline. Reconnecting…")
        case .internetDown:
            return String(localized: "Check your WiFi or cellular connection.")
        }
    }

    /// A contextual title for the overlay.
    var disconnectTitle: String {
        switch connectionState {
        case .connected, .checking:
            return ""
        case .serverDown:
            return String(localized: "Server Unreachable")
        case .internetDown:
            return String(localized: "No Internet Connection")
        }
    }

    /// The SF Symbol name for the overlay icon.
    var disconnectIcon: String {
        switch connectionState {
        case .connected, .checking:
            return "arrow.triangle.2.circlepath"
        case .serverDown:
            return "server.rack"
        case .internetDown:
            return "wifi.slash"
        }
    }
}
