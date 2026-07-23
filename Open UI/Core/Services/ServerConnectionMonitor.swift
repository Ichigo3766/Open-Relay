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
///
/// Key reliability behaviours:
/// - **2 consecutive failures** required before declaring `.serverDown`
///   (eliminates false positives from a single slow/timed-out request).
/// - **Background suppression**: while the app is backgrounded, transient
///   network failures are ignored. Only NWPathMonitor internet loss
///   (which is reliable in the background) can flip the state.
/// - **Fast foreground recovery**: immediately health-checks + socket-reconnects
///   on app foreground without waiting for the next poll cycle.
/// - **8 s health timeout**: prevents a 30 s stalled request from blocking
///   `immediateCheckInFlight` and missing real failures.
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
    /// Uses a debounce so transient blips don't flash the overlay.
    var isShowingOverlay: Bool = false

    /// Other saved servers the user could switch to.
    /// Set by `AppDependencyContainer.startServerConnectionMonitor()`.
    /// Used by `ConnectionOverlayView` to offer a "Switch Server" escape hatch.
    var otherAvailableServers: [ServerConfig] = []

    /// `true` when at least one other saved server has a cached token,
    /// meaning a switch would succeed even without internet.
    var canSwitchServer: Bool {
        !otherAvailableServers.isEmpty
    }

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.openui", category: "ConnectionMonitor")

    /// Apple Network.framework path monitor — event-driven internet detection.
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let monitorQueue = DispatchQueue(label: "com.openui.connection.monitor")

    /// Whether the device network path is satisfied (has internet or a local interface).
    @ObservationIgnored private var isNetworkAvailable: Bool = true

    /// Whether the app is currently in the background.
    /// While true, transient HTTP failures are suppressed — only NWPathMonitor
    /// internet loss (reliable in the background) can change the state.
    @ObservationIgnored private var isAppInBackground: Bool = false

    /// The polling task that periodically checks /health.
    @ObservationIgnored private var healthPollTask: Task<Void, Never>?

    /// The debounce task for showing/hiding the overlay.
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Pending foreground-return work: health check + socket reconnect.
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?

    /// Weak reference to the API client for health checks.
    @ObservationIgnored private weak var apiClient: APIClient?

    /// Weak reference to the socket service for reconnection.
    @ObservationIgnored private weak var socketService: SocketIOService?

    /// Whether the monitor is currently running.
    @ObservationIgnored private var isRunning = false

    /// Flag to coalesce rapid immediate-check requests.
    @ObservationIgnored private var immediateCheckInFlight = false

    /// Consecutive health check failure counter.
    /// We require `failureThreshold` consecutive failures before declaring
    /// the server down. A single slow or dropped request is not a failure.
    @ObservationIgnored private var consecutiveFailures: Int = 0

    // MARK: - Configuration

    /// How often to poll /health when connected (seconds).
    /// The WebSocket is the real-time signal; this is just a sanity check.
    private let connectedPollInterval: TimeInterval = 30

    /// Base delay for exponential backoff when disconnected (seconds).
    private let disconnectedBaseDelay: TimeInterval = 2

    /// Maximum backoff delay when disconnected (seconds).
    private let disconnectedMaxDelay: TimeInterval = 15

    /// How long to wait before showing the overlay (debounce, seconds).
    /// 3 s covers brief network hiccups and background→foreground transitions
    /// without flashing the overlay to the user.
    private let overlayDebounce: TimeInterval = 3.0

    /// Timeout for a single /health request (seconds).
    /// Fast enough to detect real failures; long enough for slow networks.
    private let healthCheckTimeout: TimeInterval = 8

    /// Timeout for the external ping (seconds).
    private let externalPingTimeout: TimeInterval = 5

    /// Number of consecutive /health failures required before declaring
    /// the server down. Eliminates false positives from a single slow request.
    private let failureThreshold: Int = 2

    // MARK: - Lifecycle

    /// Starts the connection monitor with the given API client and socket service.
    ///
    /// Safe to call multiple times — stops any previous monitor first.
    func start(apiClient: APIClient, socketService: SocketIOService?) {
        stop()

        self.apiClient = apiClient
        self.socketService = socketService
        isRunning = true
        isAppInBackground = false
        consecutiveFailures = 0

        startPathMonitor()
        startHealthPoll()

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
        foregroundTask?.cancel()
        foregroundTask = nil
        immediateCheckInFlight = false
        consecutiveFailures = 0

        // Reset state
        connectionState = .connected
        disconnectedSince = nil
        reconnectAttempt = 0
        isShowingOverlay = false

        logger.info("Connection monitor stopped")
    }

    // MARK: - App Lifecycle

    /// Called when the app moves to the background (.inactive / .background).
    ///
    /// Suppresses transient HTTP failures to prevent false "server down"
    /// overlays caused by the OS suspending network activity.
    func markAppBackground() {
        guard !isAppInBackground else { return }
        isAppInBackground = true
        // Cancel any pending foreground work
        foregroundTask?.cancel()
        foregroundTask = nil
        // Reset the failure counter so background-era failures don't carry over
        consecutiveFailures = 0
        logger.debug("App backgrounded — suppressing transient HTTP failures")
    }

    /// Called when the app returns to the foreground (.active).
    ///
    /// Immediately triggers a health check and socket reconnect so the app
    /// feels instantaneous on return, without waiting for the next poll cycle.
    func markAppForeground() {
        guard isAppInBackground else { return }
        isAppInBackground = false
        consecutiveFailures = 0
        logger.debug("App foregrounded — triggering immediate health check + socket reconnect")

        // Optimistically assume we're connected on foreground return.
        //
        // When the app is backgrounded for a long time the OS may drop the
        // network path, causing NWPathMonitor to fire transitionTo(.internetDown)
        // which sets isShowingOverlay = true.  If we don't clear that overlay
        // here, the full-screen black "Connection lost" view blocks all tap-based
        // interactions while we wait for the first post-resume health check to
        // complete (which can take several seconds while the iOS network stack wakes
        // back up). Gesture recognizers still work, which is why swiping the drawer
        // would "unblock" things.
        //
        // By optimistically marking the connection as restored here we immediately
        // hide the overlay, restoring touch interactivity. If the health check that
        // follows actually fails (real server down), the overlay will reappear after
        // the normal 3-second debounce — which is the correct behaviour.
        if connectionState != .connected {
            connectionState = .connected
            disconnectedSince = nil
            reconnectAttempt = 0
            isShowingOverlay = false
            debounceTask?.cancel()
            debounceTask = nil
            logger.info("Foreground: optimistically cleared disconnect overlay — health check will follow")
        }

        foregroundTask?.cancel()
        foregroundTask = Task { [weak self] in
            // Give the iOS network stack more time to fully wake up after a long
            // suspension before we fire the health check. 300 ms was often not
            // enough — the first request would fail, causing two rapid failures
            // that re-triggered the overlay immediately on foreground.
            // 1.5 s is still fast enough to feel instant but avoids false positives.
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }

            // Reconnect socket proactively (cancels any pending backoff timer)
            await MainActor.run { [weak self] in
                guard let self, let socket = self.socketService else { return }
                if !socket.isConnected {
                    socket.resetBackoffAndReconnect()
                    self.logger.info("Foreground: triggered immediate socket reconnect")
                }
            }

            // Then health check
            await self?.checkServerHealth()
        }
    }

    /// Triggers an immediate health check, e.g. on explicit user action.
    func triggerImmediateCheck() {
        // Suppress while backgrounded — the OS may have suspended our network
        // activity, so a failure here would be a false positive.
        guard isRunning, !immediateCheckInFlight, !isAppInBackground else { return }
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

            // On local-only LANs (no internet gateway), iOS NWPathMonitor reports
            // path.status == .unsatisfied even though WiFi is fully functional.
            // This is because iOS defines "satisfied" as "can reach the internet",
            // not "has a network interface". For local/LAN-only servers we must not
            // use .satisfied as the sole indicator — instead check whether any
            // relevant interface (WiFi, Ethernet, cellular) is present at all.
            let hasLocalInterface = path.availableInterfaces.contains(where: {
                $0.type == .wifi || $0.type == .wiredEthernet || $0.type == .cellular
            })
            let isLocal = self.isLocalServerURL()
            let nowAvailable = (path.status == .satisfied) || (hasLocalInterface && isLocal)

            self.isNetworkAvailable = nowAvailable

            if !nowAvailable {
                // Device truly lost network — transition immediately even in background
                // (NWPathMonitor is reliable; this is a real loss)
                Task { @MainActor [weak self] in
                    self?.consecutiveFailures = self?.failureThreshold ?? 2 // mark as failed
                    self?.transitionTo(isLocal ? .serverDown : .internetDown)
                }
            } else if !wasAvailable && nowAvailable {
                // Network just came back
                self.logger.info("NWPathMonitor: network restored (local=\(isLocal))")
                // Only run an immediate check if we're in the foreground
                if !self.isAppInBackground {
                    self.triggerImmediateCheck()
                }
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

                // Skip health polls while backgrounded — they'd fail spuriously
                // and we have NWPathMonitor for background internet loss
                if !self.isAppInBackground {
                    await self.checkServerHealth()
                }

                guard !Task.isCancelled else { break }

                let interval = self.currentPollInterval()
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

        let healthy = await apiClient.checkHealthFast(timeout: healthCheckTimeout)

        await MainActor.run { [weak self] in
            guard let self else { return }

            if healthy {
                // Reset failure counter on any success
                self.consecutiveFailures = 0
                self.transitionTo(.connected)
            } else {
                // Don't count background failures
                if !self.isAppInBackground {
                    self.consecutiveFailures += 1
                    self.logger.debug("Health check failure \(self.consecutiveFailures)/\(self.failureThreshold)")
                }

                // Only declare a problem after threshold consecutive failures
                guard self.consecutiveFailures >= self.failureThreshold else {
                    self.logger.debug("Health check failed but below threshold — ignoring")
                    return
                }

                if !self.isNetworkAvailable {
                    self.transitionTo(self.isLocalServerURL() ? .serverDown : .internetDown)
                } else if self.isLocalServerURL() {
                    // Local/LAN-only server — internet reachability is irrelevant.
                    // If /health fails on a LAN server, the server itself is down
                    // (or temporarily unreachable on the LAN), not the internet.
                    // Skip the external ping entirely to avoid a false .internetDown.
                    self.transitionTo(.serverDown)
                } else {
                    // NWPath says we're online — check if internet actually works
                    // (distinguishes captive portals from real server-down conditions)
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
    }

    /// Returns `true` when the currently configured server URL resolves to a
    /// local/private network address where internet reachability is irrelevant.
    ///
    /// Covers:
    /// - RFC 1918 private IPv4 ranges: 10.x.x.x, 172.16-31.x.x, 192.168.x.x
    /// - Loopback: 127.x.x.x, localhost
    /// - mDNS / Bonjour: *.local hostnames
    private func isLocalServerURL() -> Bool {
        guard let urlString = apiClient?.baseURL,
              let url = URL(string: urlString),
              let host = url.host else { return false }

        // mDNS / .local and loopback names
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".local") { return true }

        // Parse as dotted-decimal IPv4
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }

        switch octets[0] {
        case 10:                                      return true  // 10.0.0.0/8
        case 172 where (16...31).contains(octets[1]): return true  // 172.16.0.0/12
        case 192 where octets[1] == 168:              return true  // 192.168.0.0/16
        case 127:                                     return true  // 127.0.0.0/8 loopback
        default:                                      return false
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
            consecutiveFailures = 0
            disconnectedSince = nil
            connectionState = .connected
            updateOverlayVisibility(disconnected: false)
        } else {
            // Entering a disconnected state

            // While backgrounded, only show internet-down states (NWPathMonitor-driven)
            // Suppress server-down overlays from HTTP timeouts in the background
            if isAppInBackground && newState == .serverDown {
                logger.debug("Suppressing serverDown transition while app is backgrounded")
                return
            }

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
        // Reconnect socket if it's not already connected
        if let socket = socketService, !socket.isConnected {
            socket.resetBackoffAndReconnect()
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
            // Show overlay after debounce delay — prevents flickering on transient blips
            debounceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.overlayDebounce))
                guard !Task.isCancelled else { return }
                // Double-check we're still disconnected and in the foreground
                guard self.connectionState != .connected, !self.isAppInBackground else { return }
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
