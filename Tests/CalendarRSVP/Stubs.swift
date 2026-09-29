enum APIError: Error { case cancelled, unknown(underlying: Error?) }
@MainActor final class Network {
    enum Method: Equatable { case post }
    var conversationCacheScope: String? = "synthetic-account"
    var response: [String: Any] = ["status": true, "rsvp": "accepted"]
    var calls: [(String, Method, [String: Any])] = []
    var fail = false
    var suspend = false
    var suspended: CheckedContinuation<Void, Never>?
    func requestRaw(path: String, method: Method, body: Data) async throws -> (Data, Int) {
        calls.append((path, method, try JSONSerialization.jsonObject(with: body) as! [String: Any]))
        if suspend { await withCheckedContinuation { suspended = $0 } }
        if fail { throw APIError.unknown(underlying: nil) }
        return (try JSONSerialization.data(withJSONObject: response), 200)
    }
}
