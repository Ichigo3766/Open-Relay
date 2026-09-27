import Foundation

enum InlineImageStore { static func extractAndReplace(content: String) -> String { content } }
enum APIError: Error { case httpError(statusCode: Int, message: String?, data: Data?) }
@MainActor final class StubNetwork {
    var lastPath = ""
    var lastQuery: [String: String] = [:]
    var failure: Int?
    func requestRaw(path: String, queryItems: [URLQueryItem], deduplicate: Bool) async throws -> (Data, Int) {
        precondition(!deduplicate, "Picker requests must belong to the cancelling view task")
        lastPath = path
        lastQuery = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        if let failure { throw APIError.httpError(statusCode: failure, message: nil, data: nil) }
        return (Data(#"{"items":[],"total":0}"#.utf8), 200)
    }
}
@MainActor final class APIClient { let network = StubNetwork() }

@main enum SearchAPITests {
    @MainActor static func main() async throws {
        let api = APIClient()
        _ = try await api.searchAttachments(source: .uploads, query: "a & b", page: 2, offset: 30)
        precondition(api.network.lastPath == "/api/v1/files/search")
        precondition(api.network.lastQuery == ["filename": "*a & b*", "skip": "30", "limit": "30", "content": "false"])
        _ = try await api.searchAttachments(source: .uploads, query: "", page: 1, offset: 0)
        precondition(api.network.lastQuery["filename"] == "*")
        _ = try await api.searchAttachments(source: .collections, query: "sample", page: 3, offset: 60)
        precondition(api.network.lastPath == "/api/v1/knowledge/search" && api.network.lastQuery["page"] == "3")
        _ = try await api.searchAttachments(source: .documents(collectionID: nil), query: "sample", page: 2, offset: 30)
        precondition(api.network.lastPath == "/api/v1/knowledge/search/files")
        precondition(api.network.lastQuery["include_content"] == nil, "Do not fetch extracted document contents to pick a file")
        _ = try await api.searchAttachments(source: .documents(collectionID: "a/b"), query: "sample", page: 2, offset: 30)
        precondition(api.network.lastPath == "/api/v1/knowledge/a%2Fb/files")
        precondition(api.network.lastQuery["query"] == "sample")
        api.network.failure = 404
        let empty = try await api.searchAttachments(source: .uploads, query: "missing", page: 1, offset: 0)
        precondition(empty.count == 0)
        do {
            _ = try await api.searchAttachments(source: .collections, query: "", page: 1, offset: 0)
            preconditionFailure("Do not hide a missing Knowledge endpoint")
        } catch APIError.httpError(statusCode: 404, message: _, data: _) {}
        api.network.failure = 401
        do {
            _ = try await api.searchAttachments(source: .uploads, query: "", page: 1, offset: 0)
            preconditionFailure("Authentication errors must be visible")
        } catch APIError.httpError(statusCode: 401, message: _, data: _) {}
        let defaults = UserDefaultParams(from: ["defaultUploadContext": "full", "params": ["temperature": 0.4]])
        precondition(defaults.defaultUploadContext == "full" && defaults.temperature == 0.4)
        precondition(defaults.toRequestParams()["defaultUploadContext"] == nil)
        precondition(UserDefaultParams(from: [:]).defaultUploadContext == "focused")
        let cached = try JSONDecoder().decode(UserDefaultParams.self, from: JSONEncoder().encode(defaults))
        precondition(cached.defaultUploadContext == "full")
        print("PASS: native search routes, cursors, metadata-only requests, error handling, and account upload defaults")
    }
}
