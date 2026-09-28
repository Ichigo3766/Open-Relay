import Foundation

@MainActor final class APIClient { let network = Transport() }
@MainActor final class Transport {
    var calls: [(String, [URLQueryItem], Bool)] = []
    var response = Data("[]".utf8)
    var error: Error?
    func requestRaw(path: String, queryItems: [URLQueryItem]? = nil, deduplicate: Bool = true) async throws -> (Data, Int) {
        calls.append((path, queryItems ?? [], deduplicate))
        if let error { throw error }
        return (response, 200)
    }
}

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        check(LibrarySearchScope.files.sources == [.files], "Files does not trigger Knowledge content search")
        check(LibrarySearchScope.documents.sources == [.documents], "Documents directly searches Knowledge document contents")
        check(LibrarySearchScope.allCases.contains(.documents), "Documents is a top-level filter")
        check(LibrarySearchScope.knowledge.sources == [.knowledge, .documents], "Knowledge unchanged")
        check(LibrarySearchScope.all.sources.contains(.files), "All includes Files")
        let file: [String: Any] = ["id": "paper-1", "filename": "stored.pdf", "meta": ["name": "Paper guide.pdf", "content_type": "application/pdf", "size": 8_000_000_000 as Int64]]
        for count in [0, 1, 29, 30] {
            let page = try LibrarySearchPage.decode(data(Array(repeating: file, count: count)), source: .files, query: "paper", page: 1)
            check(page.items.count == count, "Decode bare array")
            check(page.hasMore == (count == 30), "Use file page size, not chat page size")
        }
        let page = try LibrarySearchPage.decode(data([file]), source: .files, query: "paper", page: 1)
        check(page.items[0].title == "Paper guide.pdf", "Display metadata name")
        check(page.items[0].size == 8_000_000_000, "64-bit file size")
        check(page.items[0].contentType == "application/pdf", "MIME metadata")
        let sparse = try LibrarySearchPage.decode(data([["id": "s", "filename": "plain.txt"]]), source: .files, query: "plain", page: 1)
        check(sparse.items[0].size == nil && sparse.items[0].contentType.isEmpty, "Optional metadata")
        let api = APIClient()
        for (query, page) in [("paper", 1), ("a & b + café.pdf", 2), ("*.pdf", 3)] {
            _ = try await api.searchLibrary(source: .files, query: query, page: page)
            let call = api.network.calls.last!
            check(call.0 == "/api/v1/files/search", "Native endpoint")
            check(call.1.contains(.init(name: "filename", value: "*\(query)*")), "Substring/wildcard pattern")
            check(call.1.contains(.init(name: "skip", value: String((page - 1) * 30))), "Offset pagination")
            check(call.1.contains(.init(name: "limit", value: "30")), "Bounded page")
            check(call.1.contains(.init(name: "content", value: "false")), "Exclude extracted file contents")
            check(!call.2 && !call.1.contains(where: { $0.name == "page" }), "Cancellable view-owned request")
        }
        api.network.error = APIError.httpError(statusCode: 404, message: "No files found matching the pattern.", data: nil)
        let empty = try await api.searchLibrary(source: .files, query: "missing", page: 2)
        check(empty.items.isEmpty && !empty.hasMore, "Native no-match 404 ends pagination")
        for error: APIError in [.httpError(statusCode: 404, message: "Not Found", data: nil), .httpError(statusCode: 503, message: nil, data: nil), .tokenExpired, .cancelled] {
            api.network.error = error
            do { _ = try await api.searchLibrary(source: .files, query: "paper", page: 1); preconditionFailure("Failure must remain visible") }
            catch { checks += 1 }
        }
        api.network.error = nil
        _ = try await api.searchLibrary(source: .documents, query: "paper", page: 1)
        check(api.network.calls.last!.0 == "/api/v1/knowledge/search/files", "Document route unchanged")

        var requests: [(LibrarySearchSource, Int)] = []
        let model = LibrarySearchModel { source, _, page in
            requests.append((source, page))
            let items = source == .files
                ? [LibrarySearchResult(resourceID: "shared", source: source, title: "Guide"), LibrarySearchResult(resourceID: "upload-\(page)", source: source, title: "Paper \(page)")]
                : source == .documents ? [LibrarySearchResult(resourceID: "shared", source: source, title: "Guide")] : []
            return LibrarySearchPage(items: items, hasMore: source == .files && page == 1)
        }
        await model.search("paper", scope: .all, debounce: .zero)
        check(model.visibleSections.flatMap(\.items).filter { $0.resourceID == "shared" }.count == 1, "All deduplicates by file ID")
        check(model.sections.first { $0.id == .files }!.items.count == 2, "Keep raw page state")
        await model.loadMore(.files)
        check(model.visibleSections.first { $0.id == .files }!.items.count == 2, "Additional uploads remain visible")
        check(!model.sections.first { $0.id == .files }!.hasMore, "Pagination completes")
        await model.search("paper", scope: .files, debounce: .zero)
        check(model.visibleSections.flatMap(\.items).contains { $0.resourceID == "shared" }, "Files includes Knowledge-linked uploads")
        check(model.sections.count == 1, "Files-only scope")

        var release: CheckedContinuation<LibrarySearchPage, Error>?
        let race = LibrarySearchModel { source, query, _ in
            if query == "slow" { return try await withCheckedThrowingContinuation { release = $0 } }
            return LibrarySearchPage(items: [LibrarySearchResult(resourceID: query, source: source, title: query)], hasMore: false)
        }
        let old = Task { await race.search("slow", scope: .files, debounce: .zero) }
        while release == nil { await Task.yield() }
        await race.search("new", scope: .files, debounce: .zero)
        release!.resume(returning: page)
        await old.value
        check(race.sections[0].items[0].title == "new", "Late old query cannot replace new results")
        let cancelled = Task { await model.search("cancel", scope: .files, debounce: .seconds(1)) }
        await Task.yield()
        let count = requests.count
        cancelled.cancel(); await cancelled.value
        check(requests.count == count, "Cancelled debounce sends no request")
        print("PASS: \(checks) Files search API, metadata, pagination, deduplication, errors and cancellation checks")
    }
}
