import Foundation
import os.log

final class Network {
    var calls: [[URLQueryItem]] = []
    var handler: ([URLQueryItem]) async throws -> Data = { _ in Data() }
    func requestRaw(path: String, queryItems: [URLQueryItem]) async throws -> (Data, Int) {
        precondition(path == "/api/v1/notes/search")
        calls.append(queryItems)
        return (try await handler(queryItems), 200)
    }
}
final class APIClient { let network = Network() }
final class NotesManager {
    var apiClient: APIClient?
    var isServerEnabled = true
    let logger = Logger(subsystem: "org.example", category: "fixture")
    var local: [Note] = []
    init(_ api: APIClient? = nil) { apiClient = api }
    func fetchLocalNotes() -> [Note] { local }
    func fetchNotes() async -> [Note] { local }
    func createNote(title: String) async -> Note { Note(title: title) }
    func deleteNote(id: String) async {}
    func togglePin(id: String) {}
}

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        func page(_ id: String?, total: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["items": id.map { [["id": $0, "title": $0]] } ?? [], "total": total])
        }
        let api = APIClient()
        api.network.handler = { _ in try page("remote", total: 2) }
        #if BASELINE
        let result = try await api.searchNotes(query: "paper")
        check(result.count == 1, "Native search envelope must not decode as empty")
        #else
        let result = try await api.searchNotes(query: "paper & stars", page: 2)
        check(result.items.count == 1 && result.total == 2, "Decode items and total")
        check(api.network.calls.last?.contains(URLQueryItem(name: "query", value: "paper & stars")) == true, "Keep query unescaped for URLQueryItem")
        check(api.network.calls.last?.contains(URLQueryItem(name: "page", value: "2")) == true, "Send requested page")
        api.network.handler = { _ in Data("{\"unexpected\":[]}".utf8) }
        do { _ = try await api.searchNotes(query: "paper"); preconditionFailure("Malformed response accepted") }
        catch { count += 1 }
        api.network.handler = { _ in Data("[]".utf8) }
        let legacy = try await api.searchNotes(query: "paper")
        check(legacy.items.isEmpty && legacy.total == 0, "Legacy array supported")
        let manager = NotesManager(api)
        manager.local = [Note(id: "cached", title: "paper")]
        api.network.handler = { _ in try page(nil, total: 0) }
        let empty = try await manager.searchNotes(query: "paper")
        check(empty.notes.isEmpty, "Successful empty server search must not resurrect cache")
        api.network.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await manager.searchNotes(query: "paper"); preconditionFailure("Server error hidden") }
        catch { count += 1 }
        manager.apiClient = nil
        let offline = try await manager.searchNotes(query: "paper")
        check(offline.notes.count == 1 && offline.total == 1, "Local-only search remains available")
        let offlineNext = try await manager.searchNotes(query: "paper", page: 2)
        check(offlineNext.notes.isEmpty, "Local-only results are not repeated")
        manager.apiClient = api
        let vm = NotesListViewModel()
        vm.configure(with: manager)
        api.network.handler = { query in
            let number = query.first { $0.name == "page" }?.value ?? "1"
            return try page("page-\(number)", total: 2)
        }
        vm.searchText = "paper"
        vm.triggerSearch()
        check(vm.isSearching && vm.filteredNotes.isEmpty, "Clear old results while debouncing")
        try await Task.sleep(for: .milliseconds(400))
        check(vm.filteredNotes.map(\.id) == ["page-1"] && vm.hasMoreSearchResults, "First search page")
        await vm.loadMoreSearchResults()
        check(vm.filteredNotes.map(\.id) == ["page-1", "page-2"] && !vm.hasMoreSearchResults, "Append second page")
        let requests = api.network.calls.count
        await vm.loadMoreSearchResults()
        check(api.network.calls.count == requests, "No request after final page")
        vm.triggerSearch()
        try await Task.sleep(for: .milliseconds(400))
        api.network.handler = { _ in throw URLError(.timedOut) }
        await vm.loadMoreSearchResults()
        check(vm.filteredNotes.map(\.id) == ["page-1"] && vm.errorMessage != nil, "Failed next page preserves earlier results")
        api.network.handler = { query in
            check(query.contains(URLQueryItem(name: "page", value: "2")), "Retry repeats failed page")
            try await Task.sleep(for: .milliseconds(100))
            return try page("page-2", total: 2)
        }
        let start = api.network.calls.count
        async let retry: Void = vm.retrySearch()
        async let duplicate: Void = vm.retrySearch()
        _ = await (retry, duplicate)
        check(api.network.calls.count == start + 1, "Duplicate retry cannot overlap")
        api.network.handler = { _ in throw URLError(.timedOut) }
        vm.searchText = "cloud"; vm.triggerSearch()
        try await Task.sleep(for: .milliseconds(400))
        check(vm.errorMessage != nil && !vm.isSearching, "Visible retryable error")
        api.network.handler = { _ in try page("retried", total: 1) }
        await vm.retrySearch()
        check(vm.filteredNotes.first?.id == "retried" && vm.errorMessage == nil, "Retry failed first page")
        api.network.handler = { query in
            if query.first(where: { $0.name == "query" })?.value == "slow" {
                // Intentionally ignore task cancellation to exercise stale-response protection.
                try? await Task.sleep(for: .milliseconds(300))
                return try page("stale", total: 1)
            }
            return try page("new", total: 1)
        }
        vm.searchText = "slow"; vm.triggerSearch()
        try await Task.sleep(for: .milliseconds(350))
        vm.searchText = "new"; vm.triggerSearch()
        try await Task.sleep(for: .milliseconds(400))
        check(vm.filteredNotes.map(\.id) == ["new"], "Stale response cannot replace new query")
        vm.searchText = "x"; vm.triggerSearch()
        try await Task.sleep(for: .milliseconds(400))
        check(vm.filteredNotes.map(\.id) == ["new"], "Single-character queries use server search")
        vm.clearSearch()
        await vm.loadNotes()
        try await Task.sleep(for: .milliseconds(400))
        check(vm.filteredNotes.map(\.id) == ["new"], "Returning from the editor reloads active search")
        vm.searchText = ""; vm.triggerSearch()
        check(!vm.isSearching && !vm.hasMoreSearchResults && vm.errorMessage == nil, "Clearing resets search state")
        #endif
        print("\(count) notes search checks passed")
    }
}
