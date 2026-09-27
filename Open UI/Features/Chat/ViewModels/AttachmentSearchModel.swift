import Foundation
import Observation

nonisolated enum AttachmentSearchSource: Hashable, Sendable {
    case uploads, folders, collections, documents(collectionID: String?)

    var title: String {
        switch self {
        case .uploads: "Files"
        case .folders: "Folders"
        case .collections: "Knowledge bases"
        case .documents: "Documents"
        }
    }

    var kind: KnowledgeItem.KnowledgeType {
        switch self {
        case .folders: .folder
        case .collections: .collection
        default: .file
        }
    }
}

nonisolated struct AttachmentSearchPage: Sendable {
    let items: [KnowledgeItem]
    let count: Int
    let total: Int?

    static func decode(_ data: Data, source: AttachmentSearchSource, query: String) throws -> Self {
        let json = try JSONSerialization.jsonObject(with: data)
        let envelope = json as? [String: Any]
        guard let rows = (envelope?["items"] ?? json) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        let items = rows.compactMap { row -> KnowledgeItem? in
            guard let id = row["id"] as? String else { return nil }
            let meta = row["meta"] as? [String: Any]
            let name = row["name"] as? String ?? meta?["name"] as? String
                ?? row["filename"] as? String ?? id
            if source == .folders && !query.isEmpty && !name.localizedCaseInsensitiveContains(query) { return nil }
            var reference = row
            reference["type"] = source.kind.rawValue
            reference["name"] = name
            if source.kind == .file {
                reference["file"] = row
                reference["content_type"] = meta?["content_type"] ?? row["content_type"]
            }
            return KnowledgeItem(id: id, name: name, description: row["description"] as? String,
                                 type: source.kind, fileCount: row["file_count"] as? Int,
                                 fileReference: ChatMessageFile(serverDictionary: reference))
        }
        return Self(items: items, count: rows.count, total: envelope?["total"] as? Int)
    }
}

/// Each source has its own cursor and error state. Selection belongs to the
/// caller, not this result window, so queries never clear selected files.
@MainActor @Observable
final class AttachmentSearchModel {
    struct Section: Identifiable {
        let id: AttachmentSearchSource
        var items: [KnowledgeItem] = []
        var page = 0
        var count = 0
        var hasMore = true
        var isLoading = false
        var failed = false
    }
    typealias Fetch = @MainActor (AttachmentSearchSource, String, Int, Int) async throws -> AttachmentSearchPage
    private let fetch: Fetch
    private var generation = UUID()
    private var pageTasks: [AttachmentSearchSource: Task<Void, Never>] = [:]
    private var query = ""
    private(set) var sections: [Section] = []

    init(fetch: @escaping Fetch) { self.fetch = fetch }

    func cancel() {
        generation = UUID()
        pageTasks.values.forEach { $0.cancel() }
        pageTasks.removeAll()
    }

    func requestMore(_ source: AttachmentSearchSource) {
        guard pageTasks[source] == nil else { return }
        let token = generation
        pageTasks[source] = Task {
            await loadMore(source)
            if generation == token { pageTasks[source] = nil }
        }
    }

    func search(_ text: String, sources: [AttachmentSearchSource], debounce: Duration = .milliseconds(250)) async {
        cancel()
        let token = generation
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sections = sources.map { Section(id: $0, isLoading: true) }
        do { try await Task.sleep(for: query.isEmpty ? .zero : debounce) } catch { return }
        guard generation == token, !Task.isCancelled else { return }
        await withTaskGroup(of: Void.self) { group in
            for source in sources { group.addTask { await self.load(source, token: token) } }
        }
    }

    func loadMore(_ source: AttachmentSearchSource) async {
        guard let section = sections.first(where: { $0.id == source }),
              !section.isLoading, section.hasMore || section.failed else { return }
        await load(source, token: generation)
    }

    private func load(_ source: AttachmentSearchSource, token: UUID) async {
        guard generation == token, !Task.isCancelled,
              let index = sections.firstIndex(where: { $0.id == source }) else { return }
        sections[index].isLoading = true
        sections[index].failed = false
        do {
            let result = try await fetch(source, query, sections[index].page + 1, sections[index].count)
            guard generation == token, !Task.isCancelled else { return }
            var ids = Set(sections[index].items.map(\.id))
            sections[index].items += result.items.filter { ids.insert($0.id).inserted }
            sections[index].page += 1
            sections[index].count += result.count
            sections[index].hasMore = source != .folders && result.count > 0
                && (result.total.map { sections[index].count < $0 } ?? (result.count == 30))
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            sections[index].failed = true
        }
        sections[index].isLoading = false
    }
}
