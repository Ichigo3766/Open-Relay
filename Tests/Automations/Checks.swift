import Foundation

@MainActor final class NetworkManager {
    enum Method { case get, post }
    var snapshot: Data
    var failure: Error?
    var updateFailure: Error?
    var requests: [(String, Method, Data?)] = []

    init(_ snapshot: Data) { self.snapshot = snapshot }

    func requestRaw(path: String, method: Method = .get, body: Data? = nil) async throws -> (Data, Int) {
        requests.append((path, method, body))
        if let failure { throw failure }
        if method == .get { return (snapshot, 200) }
        if let updateFailure { throw updateFailure }
        // Return a valid response independently of the payload under test.
        return (Data(#"{"id":"demo","user_id":"synthetic","name":"Updated","data":{"prompt":"New prompt","model_id":"demo-model","rrule":"FREQ=DAILY"},"is_active":false}"#.utf8), 200)
    }
}

@MainActor final class APIClient {
    let network: NetworkManager
    init(_ network: NetworkManager) { self.network = network }
}

@MainActor final class AutomationsViewModel {
    let apiClient: APIClient
    var automations: [Automation] = []
    var selectedAutomation: Automation?
    var toastMessage: String?
    var errorMessage: String?
    init(_ apiClient: APIClient) { self.apiClient = apiClient }
}

enum Haptics {
    enum Style { case light }
    static func play(_ style: Style) {}
}

@main struct Checks {
    @MainActor static func main() async throws {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(name)") }
        }
        let snapshot = Data(#"{"id":"demo","user_id":"synthetic","name":"Original","folder_id":"demo-folder","data":{"prompt":"Original prompt","model_id":"old-model","rrule":"FREQ=WEEKLY","terminal":{"server_id":"demo-terminal","cwd":"/workspace"},"target":{"type":"channel","channel_id":"demo-channel"}},"meta":{"nested":{"enabled":true,"count":3,"tags":["sample",null]}},"is_active":false}"#.utf8)
        let page = Data("{\"total\":1,\"items\":[\(String(decoding: snapshot, as: UTF8.self))]}".utf8)
        let decoded = try? JSONDecoder().decode(AutomationListResponse.self, from: page)
        check(decoded?.items.count == 1, "terminal-enabled automation page decodes")
        if let automation = decoded?.items.first {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(automation)) as! [String: Any]
            let terminal = (encoded["data"] as? [String: Any])?["terminal"] as? [String: Any]
            check(terminal?["server_id"] as? String == "demo-terminal", "terminal server ID round trips")
            check(terminal?["cwd"] as? String == "/workspace", "terminal cwd round trips")
        }
        for terminal in ["null", "{\"server_id\":\"demo-terminal\"}"] {
            let data = Data("{\"prompt\":\"Demo\",\"model_id\":\"demo-model\",\"rrule\":\"FREQ=DAILY\",\"terminal\":\(terminal)}".utf8)
            check((try? JSONDecoder().decode(AutomationData.self, from: data)) != nil, "optional terminal fields decode")
        }

        let network = NetworkManager(snapshot)
        let api = APIClient(network)
        let saved = try await api.updateAutomation(id: "demo", name: "Updated", prompt: "New prompt", modelId: "demo-model", rrule: "FREQ=DAILY")
        check(saved.name == "Updated", "server update response is returned")
        check(network.requests.count == 2 && network.requests.first?.1 == .get, "fetch latest snapshot before saving")
        check(network.requests.first?.0 == "/api/v1/automations/demo", "fetch correct automation")
        check(network.requests.last?.0 == "/api/v1/automations/demo/update", "use native update route")
        let body = try JSONSerialization.jsonObject(with: network.requests.last!.2!) as! [String: Any]
        let source = try JSONSerialization.jsonObject(with: snapshot) as! [String: Any]
        check(body["is_active"] as? Bool == false, "editing does not reactivate paused automation")
        check(body["folder_id"] as? String == "demo-folder", "folder preserved")
        check((body["meta"] as? NSDictionary) == (source["meta"] as? NSDictionary), "nested metadata preserves JSON types")
        let data = body["data"] as! [String: Any]
        let original = source["data"] as! [String: Any]
        check((data["target"] as? NSDictionary) == (original["target"] as? NSDictionary), "channel target preserved")
        check((data["terminal"] as? NSDictionary) == (original["terminal"] as? NSDictionary), "terminal configuration preserved")
        check(body["name"] as? String == "Updated", "name edit applied")
        check(data["prompt"] as? String == "New prompt", "prompt edit applied")
        check(data["model_id"] as? String == "demo-model", "model edit applied")
        check(data["rrule"] as? String == "FREQ=DAILY", "schedule edit applied")

        for invalid in [Data("[]".utf8), Data("{}".utf8), Data("not-json".utf8)] {
            let bad = NetworkManager(invalid)
            do {
                _ = try await APIClient(bad).updateAutomation(id: "demo", name: "Edit", prompt: "Edit", modelId: "demo", rrule: "FREQ=DAILY")
                check(false, "malformed snapshot prevents update")
            } catch {
                check(bad.requests.count == 1 && bad.requests[0].1 == .get, "malformed snapshot prevents update")
            }
        }
        let offline = NetworkManager(snapshot)
        offline.failure = URLError(.notConnectedToInternet)
        do {
            _ = try await APIClient(offline).updateAutomation(id: "demo", name: "Edit", prompt: "Edit", modelId: "demo", rrule: "FREQ=DAILY")
            check(false, "fetch failure prevents update")
        } catch {
            check(offline.requests.count == 1 && offline.requests[0].1 == .get, "fetch failure prevents update")
        }

        let vm = AutomationsViewModel(api)
        vm.automations = decoded?.items ?? []
        let succeeded = await vm.updateAutomation(id: "demo", name: "Updated", prompt: "New prompt", modelId: "demo-model", rrule: "FREQ=DAILY")
        check(succeeded && vm.selectedAutomation?.name == "Updated", "successful save updates selection and reports success")
        network.updateFailure = APIError.httpError(statusCode: 503, message: nil, data: nil)
        let failed = await vm.updateAutomation(id: "demo", name: "Unsaved", prompt: "Retry me", modelId: "demo-model", rrule: "FREQ=DAILY")
        check(!failed && vm.errorMessage != nil && vm.selectedAutomation?.name == "Updated", "failed save leaves existing data and reports failure to editor")

        let cancelledNetwork = NetworkManager(snapshot)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await APIClient(cancelledNetwork).updateAutomation(id: "demo", name: "Edit", prompt: "Edit", modelId: "demo", rrule: "FREQ=DAILY")
        }
        do {
            try await cancelled.value
            check(false, "cancellation prevents post")
        } catch {
            check(cancelledNetwork.requests.allSatisfy { $0.1 == .get }, "cancellation prevents post")
        }
        print("\(checks - failures)/\(checks) automation checks passed")
        if failures > 0 { exit(1) }
    }
}
