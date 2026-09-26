import Foundation
import Observation

nonisolated enum LibrarySearchSource: String, CaseIterable, Identifiable, Sendable {
    case chats, folders, knowledge, documents

    var id: Self { self }
    var title: String {
        switch self {
        case .chats: return "Chats"
        case .folders: return "Folders"
        case .knowledge: return "Knowledge bases"
        case .documents: return "Documents"
        }
    }
    var icon: String {
        switch self {
        case .chats: return "bubble.left"
        case .folders: return "folder"
        case .knowledge: return "books.vertical"
        case .documents: return "doc.text"
        }
    }
}

nonisolated enum LibrarySearchScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All", chats = "Chats", folders = "Folders", knowledge = "Knowledge"
    var id: Self { self }
    var sources: [LibrarySearchSource] {
        switch self {
        case .all: return LibrarySearchSource.allCases
        case .chats: return [.chats]
        case .folders: return [.folders]
        case .knowledge: return [.knowledge, .documents]
        }
    }
}

nonisolated struct LibrarySearchResult: Identifiable, Hashable, Sendable {
    let resourceID: String
    let source: LibrarySearchSource
    let title: String
    var snippet: String = ""
    var context: String = ""
    var id: String { "\(source.rawValue):\(resourceID)" }
}

nonisolated struct LibrarySearchPage: Sendable {
    var items: [LibrarySearchResult]
    var hasMore: Bool

    static func decode(_ data: Data, source: LibrarySearchSource, query: String, page: Int) throws -> Self {
        let json = try JSONSerialization.jsonObject(with: data)
        let envelope = json as? [String: Any]
        guard let rows = (envelope?["items"] ?? json) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        let items = rows.compactMap { row -> LibrarySearchResult? in
            guard let id = row["id"] as? String else { return nil }
            let meta = row["meta"] as? [String: Any]
            let title = row["title"] as? String ?? row["name"] as? String
                ?? meta?["name"] as? String ?? row["filename"] as? String ?? "Untitled"
            if source == .folders && !title.localizedCaseInsensitiveContains(query) { return nil }
            let text = row["snippet"] as? String ?? row["description"] as? String ?? ""
            let collection = row["collection"] as? [String: Any]
            return LibrarySearchResult(resourceID: id, source: source, title: title,
                                       snippet: LibrarySearchText.excerpt(text, query: query),
                                       context: collection?["name"] as? String ?? "")
        }
        let hasMore: Bool
        if source == .folders {
            hasMore = false // The folders endpoint is not paginated.
        } else if let total = envelope?["total"] as? Int {
            hasMore = !rows.isEmpty && page * 30 < total
        } else {
            hasMore = source == .chats && rows.count == 60
        }
        return Self(items: items, hasMore: hasMore)
    }
}

nonisolated enum LibrarySearchText {
    /// A small, plain-text window around the match; never keep full documents in search state.
    static func excerpt(_ text: String, query: String, limit: Int = 240) -> String {
        let terms = [query] + query.split(whereSeparator: \.isWhitespace).map(String.init)
        let match = terms.lazy.filter { !$0.isEmpty }.compactMap {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }.first
        let start = match.map { text.index($0.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex }
            ?? text.startIndex
        let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        let window = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + window + (end < text.endIndex ? "…" : "")
    }

    static func content(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["content"] as? String ?? (json?["content"] as? [String: Any])?["text"] as? String ?? ""
    }
}

@MainActor @Observable
final class LibrarySearchModel {
    struct Section: Identifiable {
        let id: LibrarySearchSource
        var items: [LibrarySearchResult] = []
        var page = 0
        var hasMore = false
        var isLoading = true
        var failed = false
    }

    typealias Fetch = @MainActor (LibrarySearchSource, String, Int) async throws -> LibrarySearchPage
    private let fetch: Fetch
    private var pageTasks: [LibrarySearchSource: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var query = ""
    private(set) var sections: [Section] = []

    init(fetch: @escaping Fetch) { self.fetch = fetch }

    func cancel() {
        generation = UUID()
        pageTasks.values.forEach { $0.cancel() }
        pageTasks.removeAll()
    }

    func requestMore(_ source: LibrarySearchSource) {
        guard pageTasks[source] == nil else { return }
        let token = generation
        pageTasks[source] = Task {
            await loadMore(source)
            if generation == token { pageTasks[source] = nil }
        }
    }

    func search(_ text: String, scope: LibrarySearchScope, debounce: Duration = .milliseconds(300)) async {
        cancel()
        let token = generation
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sections = query.isEmpty ? [] : scope.sources.map { Section(id: $0) }
        guard !query.isEmpty else { return }
        do { try await Task.sleep(for: debounce) } catch { return }
        guard generation == token, !Task.isCancelled else { return }
        await withTaskGroup(of: Void.self) { group in
            for source in scope.sources {
                group.addTask { await self.load(source, generation: token) }
            }
        }
    }

    func loadMore(_ source: LibrarySearchSource) async {
        guard let section = sections.first(where: { $0.id == source }), !section.isLoading else { return }
        await load(source, generation: generation)
    }

    private func load(_ source: LibrarySearchSource, generation token: UUID) async {
        guard !Task.isCancelled, generation == token,
              let index = sections.firstIndex(where: { $0.id == source }) else { return }
        sections[index].isLoading = true
        sections[index].failed = false
        let page = sections[index].page + 1
        do {
            let result = try await fetch(source, query, page)
            guard generation == token, !Task.isCancelled else { return }
            var ids = Set(sections[index].items.map(\.id))
            sections[index].items += result.items.filter { ids.insert($0.id).inserted }
            sections[index].page = page
            sections[index].hasMore = result.hasMore
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            sections[index].failed = true
        }
        sections[index].isLoading = false
    }
}
