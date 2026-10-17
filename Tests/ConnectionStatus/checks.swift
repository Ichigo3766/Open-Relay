import Foundation
import Observation

struct ServerConfig: Sendable {}
actor ConversationCache {
    static let shared = ConversationCache()
    func cachedIndex(scope: String?) -> Bool? { nil }
}
final class FixtureNetwork: @unchecked Sendable { var conversationCacheScope: String? = "invented-scope" }
final class APIClient: @unchecked Sendable {
    let network = FixtureNetwork()
    var healthy = true
    var checks = 0
    var delay: Duration = .zero
    @MainActor func checkHealthFast(timeout: TimeInterval) async -> Bool {
        checks += 1
        try? await Task.sleep(for: delay)
        return healthy
    }
}
final class SocketIOService {
    var isConnected = false
    var reconnects = 0
    func resetBackoffAndReconnect() { reconnects += 1 }
}
struct NetworkPath: Sendable {
    enum Status { case satisfied }
    enum Kind { case wifi, wiredEthernet, cellular }
    struct Interface { var type: Kind }
    var status = Status.satisfied
    var availableInterfaces = [Interface]()
}
final class NWPathMonitor {
    var pathUpdateHandler: (@Sendable (NetworkPath) -> Void)?
    func start(queue: DispatchQueue) {}
    func cancel() {}
}
final class ExternalProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
enum ExternalFixture {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExternalProtocol.self]
        return URLSession(configuration: config)
    }()
}
// INSERT_MONITOR

@main struct Checks {
    @MainActor static func main() async {
        var checks = 0, failures = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: " + label) }
        }
        let monitor = ServerConnectionMonitor(), client = APIClient(), socket = SocketIOService()
        expect(monitor.connectionState == .checking, "startup does not claim verified connectivity")
        expect(monitor.disconnectTitle == "Connecting…", "initial status explains uncertainty")
        monitor.start(apiClient: client, socketService: socket)
        expect(monitor.connectionState == .checking, "starting a server does not turn the dot green")
        await monitor.checkServerHealth()
        expect(monitor.connectionState == .connected, "server success confirms connectivity")
        expect(socket.reconnects == 0, "initial verification does not restart an in-flight socket connection")
        expect(monitor.disconnectTitle == "Connected", "connected sidebar has an accessible label")
        expect(monitor.disconnectIcon == "circle.fill", "connected sidebar uses a dot")
        monitor.transitionTo(.internetDown)
        expect(monitor.disconnectTitle == "Offline" && monitor.disconnectIcon == "wifi.slash", "offline state agrees across controls")
        monitor.markAppBackground()
        monitor.markAppForeground()
        expect(monitor.connectionState != .connected, "foreground does not hide a known outage with false success")
        expect(monitor.disconnectTitle == "Reconnecting…", "recovery is distinguished from first connection")
        monitor.foregroundTask?.cancel()
        await monitor.checkServerHealth()
        expect(monitor.connectionState == .connected && monitor.disconnectedSince == nil, "verified recovery clears outage state")
        client.healthy = false
        monitor.isNetworkAvailable = false
        await monitor.checkServerHealth()
        expect(monitor.connectionState == .connected, "one transient probe failure preserves known connectivity")
        await monitor.checkServerHealth()
        expect(monitor.connectionState == .internetDown, "existing two-failure threshold is retained")
        client.delay = .milliseconds(40)
        let before = client.checks
        for _ in 0..<10 { monitor.triggerImmediateCheck() }
        expect(monitor.disconnectTitle == "Reconnecting…", "explicit retry shows recovery")
        try? await Task.sleep(for: .milliseconds(15))
        expect(client.checks == before + 1, "repeated retry actions coalesce")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while monitor.immediateCheckInFlight && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(monitor.connectionState == .internetDown, "failed retry retains offline diagnosis")
        monitor.transitionTo(.serverDown)
        expect(monitor.disconnectTitle == "Server unreachable" && monitor.disconnectIcon == "server.rack", "server reachability has distinct wording")
        monitor.markAppBackground()
        let state = monitor.connectionState
        await monitor.checkServerHealth()
        expect(monitor.connectionState == state, "background probe does not replace an existing diagnosis")
        let count = client.checks
        monitor.triggerImmediateCheck()
        try? await Task.sleep(for: .milliseconds(10))
        expect(client.checks == count, "background retry does not make a request")
        monitor.stop()
        expect(monitor.connectionState == .checking && monitor.disconnectedSince == nil, "switching servers resets verified status")
        expect(!monitor.canSwitchServer, "switch action requires another saved server")
        monitor.otherAvailableServers = [ServerConfig()]
        expect(monitor.canSwitchServer, "saved alternatives remain accessible")
        expect(socket.reconnects > 0, "verified recovery retains socket reconnection")
        print("\(checks) connection status checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
