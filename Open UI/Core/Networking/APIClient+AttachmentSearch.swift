import Foundation

extension APIClient {
    func searchAttachments(source: AttachmentSearchSource, query: String, page: Int, offset: Int) async throws -> AttachmentSearchPage {
        let path: String
        var parameters = [URLQueryItem(name: "query", value: query),
                          URLQueryItem(name: "page", value: String(page))]
        switch source {
        case .uploads:
            path = "/api/v1/files/search"
            parameters = [
                URLQueryItem(name: "filename", value: query.isEmpty ? "*" : "*\(query)*"),
                URLQueryItem(name: "skip", value: String(offset)),
                URLQueryItem(name: "limit", value: "30"),
                URLQueryItem(name: "content", value: "false")
            ]
        case .folders:
            path = "/api/v1/folders/"
            parameters = []
        case .collections:
            path = "/api/v1/knowledge/search"
        case .documents(let id):
            if let id {
                let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
                path = "/api/v1/knowledge/\(encoded)/files"
            } else {
                path = "/api/v1/knowledge/search/files"
            }
        }
        do {
            let (data, _) = try await network.requestRaw(path: path, queryItems: parameters, deduplicate: false)
            return try AttachmentSearchPage.decode(data, source: source, query: query)
        } catch APIError.httpError(statusCode: 404, message: _, data: _) where source == .uploads {
            // This endpoint returns 404 for an empty search or the final page.
            return AttachmentSearchPage(items: [], count: 0, total: 0)
        }
    }
}
