import Foundation
import Observation

struct ServerConfig: Sendable { var url="https://relay.example.test"; var customHeaders=[String:String](); var isCloudflareBotProtected=false }
enum TLSChallengeHandler {
    static func resolve(_ challenge: URLAuthenticationChallenge, serverConfig: ServerConfig, checkPort: Bool) -> (URLSession.AuthChallengeDisposition, URLCredential?) { (.performDefaultHandling,nil) }
}
enum CallAudioSession { nonisolated(unsafe) static var isCallActive=false }
actor ConversationCache {
    static let shared=ConversationCache()
    nonisolated static func scope(server:String,token:String?,headers:[String:String])->String? { token.map { _ in "synthetic-scope" } }
    func invalidate(scope:String,id:String) {}
    func cachedIndex(scope:String?) -> Bool? { nil }
}
final class Network: @unchecked Sendable {
    var onConnectionResult: (@Sendable (Bool)->Void)?
    var conversationCacheScope:String?="synthetic-scope"
}
final class APIClient: @unchecked Sendable {
    let network=Network(); var healthy=true; var delay:Duration = .zero; var checks=0
    @MainActor func checkHealthFast(timeout:TimeInterval) async -> Bool {
        checks+=1;let result=healthy;try? await Task.sleep(for:delay);return result
    }
}
struct NetworkPath: Sendable {
    enum Status { case satisfied }; enum Kind { case wifi,wiredEthernet,cellular }
    struct Interface { var type:Kind }; var status=Status.satisfied;var availableInterfaces=[Interface]()
}
final class NWPathMonitor {
    var pathUpdateHandler: (@Sendable (NetworkPath)->Void)?; func start(queue:DispatchQueue) {};func cancel() {}
}
final class ExternalProtocol: URLProtocol {
    nonisolated(unsafe) static var status=200
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        let response=HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
enum ExternalFixture {
    static let session:URLSession = { let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ExternalProtocol.self];return URLSession(configuration:config) }()
}
// INSERT_SOCKET
// INSERT_MONITOR

@main struct Checks {
    @MainActor static func main() async {
        var total=0;var failures=0
        func check(_ condition:Bool,_ label:String) { total+=1;if !condition { failures+=1;print("FAIL: "+label) } }
        func pump(_ seconds:Double) async {
            await MainActor.run { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
            await Task.yield()
        }
        func socket(_ polling:Bool=false) -> SocketIOService {
            let result=SocketIOService(serverConfig:ServerConfig(isCloudflareBotProtected:polling))
            result.handleEngineIOMessage("0{\"sid\":\"fixture\",\"pingInterval\":80,\"pingTimeout\":120}")
            result.handleSocketIOMessage("0{\"sid\":\"fixture\"}")
            return result
        }
        for polling in [false,true] {
            let subject=socket(polling);await pump(0.015)
            check(subject.pingTimer != nil,"negotiated heartbeat installs watchdog for \(polling ? "polling" : "websocket")")
            let start=ContinuousClock.now;await pump(0.24)
            check(!subject.isConnected,"silent transport disconnects without another request")
            check(!subject.isUserJoined,"expired connection cannot remain room-ready")
            check(subject.reconnectAttempt==1,"heartbeat timeout schedules exactly one reconnect")
            print("Synthetic missing-heartbeat detection: \(start.duration(to:.now))")
            subject.disconnect();await pump(0.005)
        }
        let subject=socket();var pings=0;subject.onServerPing={pings+=1};await pump(0.11)
        subject.handleEngineIOMessage("2");await pump(0.13)
        check(subject.isConnected,"server ping renews deadline");check(pings==1,"server ping reports reachability once")
        subject.markAppBackground();await pump(0.23)
        check(subject.isConnected,"background suspension is not a disconnect");check(subject.pingTimer==nil,"background cancels watchdog")
        subject.resetBackoffAndReconnect();await pump(0.015)
        check(subject.pingTimer != nil,"foreground rearms connected socket watchdog")
        let stale=subject.pingTimer;subject.connectionGeneration+=1;stale?.fire()
        check(subject.isConnected,"old-generation timer cannot disconnect new socket")
        let session=URLSession(configuration:.ephemeral);let oldTask=session.webSocketTask(with:URL(string:"wss://relay.example.test")!)
        subject.urlSession(session,webSocketTask:oldTask,didCloseWith:.normalClosure,reason:nil)
        check(subject.isConnected,"old transport close cannot disconnect current socket");session.invalidateAndCancel()
        subject.disconnect();await pump(0.01)
        check(subject.pingTimer==nil && subject.heartbeatTimer==nil,"intentional disconnect removes both timers")
        let voice=socket();CallAudioSession.isCallActive=true;voice.markAppBackground();await pump(0.24)
        check(!voice.isConnected,"active voice calls retain heartbeat protection in background")
        CallAudioSession.isCallActive=false;voice.disconnect();await pump(0.01)

        let monitor=ServerConnectionMonitor();let client=APIClient();let live=SocketIOService(serverConfig:ServerConfig())
        monitor.start(apiClient:client,socketService:live)
        for _ in 0..<8 { monitor.recordConnectionResult(true);try? await Task.sleep(for:.milliseconds(30)) }
        check(client.checks==0,"ongoing real activity eliminates redundant health requests")
        try? await Task.sleep(for:.milliseconds(100))
        check(client.checks>=1,"idle connection still receives fallback health check")
        monitor.stop();monitor.start(apiClient:client,socketService:live);client.checks=0;client.delay = .milliseconds(60)
        for _ in 0..<12 { monitor.triggerImmediateCheck() }
        try? await Task.sleep(for:.milliseconds(20))
        check(client.checks==1,"concurrent immediate probes coalesce")
        monitor.recordConnectionResult(true);try? await Task.sleep(for:.milliseconds(80))
        client.healthy=false;client.delay = .milliseconds(40);monitor.isNetworkAvailable=false
        let before=client.checks;monitor.recordConnectionResult(false)
        try? await Task.sleep(for:.milliseconds(55))
        check(client.checks==before+1,"request failure starts a health probe without polling delay")
        check(monitor.connectionState == .internetDown,"failed real request plus failed probe detects outage")
        monitor.recordConnectionResult(true)
        check(monitor.connectionState == .connected && monitor.consecutiveFailures==0,"real success restores reachability")
        let task=Task { @MainActor in await monitor.checkServerHealth() }
        try? await Task.sleep(for:.milliseconds(10));monitor.recordConnectionResult(true);await task.value
        check(monitor.connectionState == .connected,"later activity supersedes stale health failure")
        let staleProbe=Task { @MainActor in await monitor.checkServerHealth() }
        try? await Task.sleep(for:.milliseconds(10));monitor.stop();let replacement=APIClient();monitor.start(apiClient:replacement,socketService:nil);await staleProbe.value
        check(monitor.connectionState == .connected,"old-server probe cannot change replacement state")
        monitor.markAppBackground();let count=replacement.checks;monitor.recordConnectionResult(false);monitor.triggerImmediateCheck()
        try? await Task.sleep(for:.milliseconds(80));check(replacement.checks==count,"background suppresses health probes")
        monitor.stop();check(replacement.network.onConnectionResult==nil,"stopping disconnects request callbacks")
        for status in [200,503] {
            ExternalProtocol.status=status;let failed=APIClient();failed.healthy=false
            monitor.start(apiClient:failed,socketService:nil);monitor.isNetworkAvailable=true;monitor.recordConnectionResult(false)
            try? await Task.sleep(for:.milliseconds(30))
            check(monitor.connectionState == (status==200 ? .serverDown : .internetDown),"external probe distinguishes server outage from internet outage")
            monitor.stop()
        }
        print("Passed \(total-failures)/\(total) connection recovery checks")
        if failures>0 { exit(1) }
    }
}
