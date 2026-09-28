import Foundation

extension APIClient {
    func searchLibrary(source: LibrarySearchSource, query: String, page: Int) async throws -> LibrarySearchPage {
        let path: String
        var parameters = [URLQueryItem(name: "page", value: String(page))]
        switch source {
        case .chats:
            path = "/api/v1/chats/search"
            parameters.append(URLQueryItem(name: "text", value: query))
        case .folders:
            path = "/api/v1/folders/"
            parameters = []
        case .files:
            path = "/api/v1/files/search"
            parameters = [
                URLQueryItem(name: "filename", value: "*\(query)*"),
                URLQueryItem(name: "skip", value: String((page - 1) * LibrarySearchPage.filePageSize)),
                URLQueryItem(name: "limit", value: String(LibrarySearchPage.filePageSize)),
                URLQueryItem(name: "content", value: "false")
            ]
        case .knowledge, .documents:
            path = source == .knowledge ? "/api/v1/knowledge/search" : "/api/v1/knowledge/search/files"
            parameters.append(URLQueryItem(name: "query", value: query))
            if source == .documents {
                parameters.append(URLQueryItem(name: "include_content", value: "true"))
            }
        }
        // Search requests belong to the view task, not the shared GET deduplicator,
        // so changing the query or closing search cancels the underlying request.
        do {
            let (data, _) = try await network.requestRaw(path: path, queryItems: parameters, deduplicate: false)
            return try LibrarySearchPage.decode(data, source: source, query: query, page: page)
        } catch APIError.httpError(let code, let message, _) where source == .files && code == 404
            && message == "No files found matching the pattern." {
            return LibrarySearchPage(items: [], hasMore: false)
        }
    }

    func searchDocumentExcerpt(id: String, query: String) async throws -> String {
        let (data, _) = try await network.requestRaw(path: "/api/v1/files/\(id)/data/content", deduplicate: false)
        return try await Task.detached(priority: .userInitiated) {
            try LibrarySearchText.excerpt(LibrarySearchText.content(from: data), query: query)
        }.value
    }

    func searchKnowledgeFiles(id: String, page: Int) async throws -> LibrarySearchPage {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/knowledge/\(id)/files",
            queryItems: [URLQueryItem(name: "page", value: String(page))], deduplicate: false)
        return try LibrarySearchPage.decode(data, source: .documents, query: "", page: page)
    }
}
