import Foundation

enum APIError: Error { case cancelled }
final class Network {
    enum Method: Equatable { case get, post, delete }
    var conversationCacheScope: String? = "synthetic-scope"
    var response = Data()
    var calls: [(String, Method, Data?)] = []
    var fail = false
    var onRequest: (() -> Void)?
    var suspended: CheckedContinuation<Void, Never>?
    var suspend = false
    func requestRaw(path: String, method: Method = .get, body: Data? = nil) async throws -> (Data, Int) {
        calls.append((path, method, body))
        if suspend { await withCheckedContinuation { suspended = $0 } }
        onRequest?()
        if fail { throw APIError.cancelled }
        return (response, 200)
    }
}
