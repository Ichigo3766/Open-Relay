import Foundation

@MainActor final class NetworkManager {
    enum Method { case get, post }
    var response = Data("true".utf8)
    var failure: Error?
    var requests: [(String, Method, Data?)] = []
    func requestRaw(path: String, method: Method = .get, body: Data? = nil) async throws -> (Data, Int) {
        requests.append((path, method, body))
        if let failure { throw failure }
        return (response, 200)
    }
}
@MainActor final class APIClient {
    let network = NetworkManager()
    var configWrites = 0
    func updateImageConfig(_ value: Int) async throws -> Int { configWrites += 1; return value }
}
struct TestLogger {
    func info(_ message: String) {}
    func error(_ message: String) {}
}
@MainActor final class AdminImagesViewModel {
    let apiClient: APIClient?
    var config = 7
    var isVerifying = false
    var verifyResult: Bool?
    let logger = TestLogger()
    init(_ api: APIClient) { apiClient = api }
}

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            count += 1
            if !condition { failures += 1; print("FAIL: \(name)") }
        }
        let api = APIClient()
        let vm = AdminImagesViewModel(api)
        #if BASELINE
        await vm.verifyURL()
        #else
        await vm.verifyURL(url: "https://image-engine.example.invalid/edit", key: "synthetic-key")
        #endif
        check(api.configWrites == 0 && vm.config == 7, "verification never saves configuration")
        check(api.network.requests.count == 1, "one verification request")
        let request = api.network.requests[0]
        check(request.0 == "/api/v1/images/verify" && request.1 == .post, "native verification endpoint and HTTP method")
        let body = request.2.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        check(body == ["engine": "comfyui", "url": "https://image-engine.example.invalid/edit", "key": "synthetic-key"], "verify selected field values, including edit-engine key")
        check(vm.verifyResult == true && !vm.isVerifying, "success clears loading and shows result")

        func verify(_ key: String?) async throws -> Bool {
            #if BASELINE
            return try await api.verifyImageConfigURL()
            #else
            return try await api.verifyImageConfigURL(engine: "automatic1111", url: "https://image-engine.example.invalid", key: key)
            #endif
        }
        _ = try await verify(nil)
        let noKey = api.network.requests.last!.2.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        check(noKey == ["engine": "automatic1111", "url": "https://image-engine.example.invalid"], "optional key omitted without changing engine or URL")
        api.network.response = Data("false".utf8)
        check(try await verify(nil) == false, "false response stays false")
        api.network.response = Data(#"{"unexpected":true}"#.utf8)
        do { _ = try await verify(nil); check(false, "invalid response throws") }
        catch { check(true, "invalid response throws") }
        api.network.failure = URLError(.notConnectedToInternet)
        do { _ = try await verify(nil); check(false, "network failure propagates") }
        catch { check(true, "network failure propagates") }
        #if BASELINE
        await vm.verifyURL()
        #else
        await vm.verifyURL(url: "https://image-engine.example.invalid/edit", key: "synthetic-key")
        #endif
        check(vm.verifyResult == false && !vm.isVerifying, "failed verification clears loading and shows failure")
        check(api.configWrites == 0, "failed verification also never saves configuration")
        print("\(count - failures)/\(count) image verification checks passed")
        if failures > 0 { exit(1) }
    }
}
