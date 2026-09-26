import Foundation

// Minimal transport double: compile the production search API and model unchanged.
@MainActor final class APIClient {
    let network = Network()
}
@MainActor final class Network {
    var requests: [(String, [URLQueryItem], Bool)] = []
    var response = Data("[]".utf8)
    func requestRaw(path: String, queryItems: [URLQueryItem]? = nil, deduplicate: Bool = true) async throws -> (Data, Int) {
        requests.append((path, queryItems ?? [], deduplicate))
        return (response, 200)
    }
}

@main struct ModelTests {
    static func check(_ value: Bool, _ message: String = "Assertion failed") { precondition(value, message) }
    @MainActor static func main() async throws {
        func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let bodyMatch: [String: Any] = ["id": "chat-1", "title": "Paper gallery", "snippet": "A yellow lantern lights the display."]
        let chat = try LibrarySearchPage.decode(data([bodyMatch]), source: .chats, query: "lantern", page: 1)
        check(chat.items.count == 1 && chat.items[0].snippet.contains("lantern"), "Body-only results must survive")
        check(!chat.hasMore)
        let fullPage = try LibrarySearchPage.decode(data(Array(repeating: bodyMatch, count: 60)), source: .chats, query: "lantern", page: 1)
        check(fullPage.hasMore)
        let legacy = try LibrarySearchPage.decode(data([["id": "old", "title": "Old server"]]), source: .chats, query: "text", page: 1)
        check(legacy.items[0].snippet.isEmpty)
        let folders = try LibrarySearchPage.decode(data([["id": "a", "name": "Lantern workshop"], ["id": "b", "name": "Other"]]), source: .folders, query: "lantern", page: 1)
        check(folders.items.count == 1 && !folders.hasMore)
        let doc: [String: Any] = ["id": "doc-1", "filename": "guide.txt", "collection": ["name": "Paper crafts"]]
        let docs = try LibrarySearchPage.decode(data(["items": [doc], "total": 31]), source: .documents, query: "lantern", page: 1)
        check(docs.hasMore && docs.items[0].context == "Paper crafts")
        check(try LibrarySearchPage.decode(data(["items": [doc], "total": 31]), source: .documents, query: "lantern", page: 2).hasMore == false)
        check(try LibrarySearchPage.decode(data(["items": [], "total": 300]), source: .documents, query: "x", page: 1).hasMore == false)
        do {
            _ = try LibrarySearchPage.decode(Data("{}".utf8), source: .chats, query: "x", page: 1)
            fatalError("Malformed responses must not look like empty results")
        } catch {}

        let text = String(repeating: "🪁 café display. ", count: 100) + "YELLOW LANTERN" + String(repeating: " tail", count: 100)
        let excerpt = LibrarySearchText.excerpt(text, query: "yellow lantern")
        check(excerpt.contains("YELLOW LANTERN") && excerpt.count <= 242 && excerpt.hasPrefix("…"))
        check(LibrarySearchText.excerpt("line one\nline two", query: "two") == "line one line two")
        check(LibrarySearchText.excerpt("", query: "") == "")
        check(try LibrarySearchText.content(from: data(["content": "plain"])) == "plain")
        check(try LibrarySearchText.content(from: data(["content": ["text": "nested"]])) == "nested")
        check(LibrarySearchText.excerpt("café", query: "cafe") == "café")
        print("PASS: response parsing, pagination, body matches, legacy responses, Unicode excerpts")

        let api = APIClient()
        _ = try await api.searchLibrary(source: .documents, query: "a & b", page: 2)
        check(api.network.requests[0].0 == "/api/v1/knowledge/search/files")
        check(api.network.requests[0].1.contains(URLQueryItem(name: "include_content", value: "true")))
        check(api.network.requests[0].1.contains(URLQueryItem(name: "query", value: "a & b")))
        check(api.network.requests[0].1.contains(URLQueryItem(name: "page", value: "2")))
        _ = try await api.searchLibrary(source: .chats, query: "lantern", page: 3)
        check(api.network.requests[1].1.contains(URLQueryItem(name: "text", value: "lantern")))
        _ = try await api.searchLibrary(source: .folders, query: "lantern", page: 1)
        check(api.network.requests[2].1.isEmpty)
        api.network.response = try data(["content": text])
        check(try await api.searchDocumentExcerpt(id: "doc-1", query: "lantern").contains("LANTERN"))
        check(api.network.requests.last!.0 == "/api/v1/files/doc-1/data/content")
        check(api.network.requests.allSatisfy { !$0.2 }, "Queries must be cancellable rather than shared")
        print("PASS: API routes, page/query encoding, content search, cancellable transport")

        var calls: [(LibrarySearchSource, String, Int)] = []
        var failDocuments = true
        let model = LibrarySearchModel { source, query, page in
            calls.append((source, query, page))
            if source == .documents && failDocuments { throw URLError(.notConnectedToInternet) }
            let item = LibrarySearchResult(resourceID: "\(source)-\(query)", source: source, title: query)
            return LibrarySearchPage(items: [item, item], hasMore: page == 1)
        }
        await model.search("  ", scope: .all, debounce: .zero)
        check(calls.isEmpty && model.sections.isEmpty)
        await model.search(" lantern ", scope: .all, debounce: .zero)
        check(calls.count == 4 && calls.allSatisfy { $0.1 == "lantern" })
        check(model.sections.first { $0.id == .chats }!.items.count == 1)
        check(model.sections.first { $0.id == .documents }!.failed)
        failDocuments = false
        await model.loadMore(.documents)
        check(model.sections.first { $0.id == .documents }!.page == 1)
        await model.loadMore(.chats)
        check(model.sections.first { $0.id == .chats }!.items.count == 1)
        check(model.sections.first { $0.id == .chats }!.page == 2)
        check(!model.sections.first { $0.id == .chats }!.hasMore)
        await model.search("other", scope: .knowledge, debounce: .zero)
        check(model.sections.map(\.id) == [.knowledge, .documents])
        print("PASS: independent results, partial failure, retry, deduplication, filter and pagination reset")

        var releaseOld: CheckedContinuation<LibrarySearchPage, Error>?
        let race = LibrarySearchModel { source, query, _ in
            if query == "old" { return try await withCheckedThrowingContinuation { releaseOld = $0 } }
            return LibrarySearchPage(items: [LibrarySearchResult(resourceID: query, source: source, title: query)], hasMore: false)
        }
        let old = Task { await race.search("old", scope: .chats, debounce: .zero) }
        while releaseOld == nil { await Task.yield() }
        await race.search("new", scope: .chats, debounce: .zero)
        releaseOld!.resume(returning: chat)
        await old.value
        check(race.sections[0].items[0].title == "new", "Stale responses must not overwrite the current query")
        let pending = Task { await model.search("cancelled", scope: .all, debounce: .seconds(1)) }
        await Task.yield()
        let count = calls.count
        pending.cancel()
        await pending.value
        check(calls.count == count)
        print("PASS: out-of-order replies and cancelled debounce; all search model checks passed")
    }
}
