import CryptoKit
import Foundation

/// Disposable server responses, never an offline write queue. All disk work is actor-isolated.
actor ConversationCache {
    static let shared = ConversationCache()
    nonisolated static let directoryName = "ConversationCache-v1"
    nonisolated static let limitKey = "storage.conversationCacheLimitMB"
    nonisolated static let defaultLimitMB = 50
    nonisolated static let recentInterval: TimeInterval = 30
    nonisolated static let retention: TimeInterval = 7 * 24 * 60 * 60

    nonisolated struct Entry: Codable, Sendable {
        let data: Data
        let etag: String?
        let validatedAt: Date
        let freshFor: TimeInterval

        func isRecent(at date: Date = .now) -> Bool {
            let age = date.timeIntervalSince(validatedAt)
            return age >= 0 && age < freshFor
        }
    }

    private let directory: URL
    private let defaults: UserDefaults
    private var generation = UUID()
    private var inFlight: [String: Task<Data, Error>] = [:]

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(ConversationCache.directoryName), defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    /// Hash the complete server/session identity; credentials never appear in filenames or records.
    nonisolated static func scope(server: String, token: String?, headers: [String: String] = [:]) -> String? {
        guard let token, !token.isEmpty else { return nil }
        let parts = [server, token] + headers.sorted { $0.key < $1.key }.flatMap { [$0.key, $0.value] }
        return digest((try? JSONEncoder().encode(parts)) ?? Data())
    }

    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var limit: Int {
        let mb = defaults.object(forKey: Self.limitKey) == nil
            ? Self.defaultLimitMB : defaults.integer(forKey: Self.limitKey)
        return min(250, max(0, mb)) * 1024 * 1024
    }

    private func file(scope: String, id: String) -> URL {
        directory.appendingPathComponent(scope + "-" + Self.digest(Data(id.utf8)) + ".plist")
    }

    func cached(scope: String?, id: String, now: Date = .now) -> Entry? {
        guard let entry = read(scope: scope, id: id, now: now),
              Self.conversation(entry.data, id: id) != nil else { return nil }
        return entry
    }

    func cachedIndex(scope: String?) -> ConversationIndex? {
        guard let entry = read(scope: scope, id: "index:sidebar") else { return nil }
        return try? PropertyListDecoder().decode(ConversationIndex.self, from: entry.data)
    }

    func currentRevision() -> UUID { generation }

    func saveIndex(_ index: ConversationIndex, scope: String?, revision: UUID) {
        guard let scope, revision == generation,
              let data = try? PropertyListEncoder().encode(index) else { return }
        store(Entry(data: data, etag: nil, validatedAt: .now, freshFor: 0), scope: scope, id: "index:sidebar")
    }

    private func read(scope: String?, id: String, now: Date = .now) -> Entry? {
        prune(now: now)
        guard let scope, !id.hasPrefix("local:"), limit > 0 else { return nil }
        let url = file(scope: scope, id: id)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= limit, let data = try? Data(contentsOf: url),
              let entry = try? PropertyListDecoder().decode(Entry.self, from: data),
              now.timeIntervalSince(entry.validatedAt) <= Self.retention else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return entry
    }

    /// Only navigation may opt into the short freshness window. Recovery and actions validate every time.
    func load(scope: String?, id: String, preferRecent: Bool = false,
              fetch: @escaping @Sendable (String?) async throws -> (Data, HTTPURLResponse)) async throws -> Data {
        guard let scope, !id.hasPrefix("local:") else { return try await fetch(nil).0 }
        let entry = cached(scope: scope, id: id)
        if preferRecent, let entry, entry.isRecent() { return entry.data }
        let revision = generation
        let key = scope + ":" + id + ":" + revision.uuidString
        if let pending = inFlight[key] { return try await pending.value }
        let task = Task<Data, Error> {
            defer { self.inFlight[key] = nil }
            do {
                var (data, response) = try await fetch(entry?.etag)
                // A mutation/clear while validating makes the old representation unusable for a 304.
                if response.statusCode == 304 && revision != self.generation {
                    (data, response) = try await fetch(nil)
                }
                if response.statusCode == 304, revision == self.generation, let entry {
                    data = entry.data
                } else if response.statusCode != 200 {
                    throw APIError.httpError(statusCode: response.statusCode, message: nil, data: nil)
                }
                guard let chat = Self.conversation(data, id: id) else {
                    self.invalidate(scope: scope, id: id)
                    throw APIError.responseDecoding(underlying: CocoaError(.coderReadCorrupt), data: nil)
                }
                if revision == self.generation {
                    let control = (response.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
                    if control.contains("no-store") || response.value(forHTTPHeaderField: "Vary") == "*"
                        || Self.hasUnfinishedMessages(chat) {
                        self.invalidate(scope: scope, id: id)
                    } else {
                        var freshFor = control.contains("no-cache") ? 0
                            : (response.statusCode == 304 ? (entry?.freshFor ?? 0) : Self.recentInterval)
                        for part in control.split(separator: ",") {
                            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                            if pair.count == 2, pair[0] == "max-age", let seconds = Double(pair[1]) {
                                freshFor = min(freshFor, max(0, seconds))
                            }
                        }
                        freshFor = max(0, freshFor - (Double(response.value(forHTTPHeaderField: "Age") ?? "0") ?? 0))
                        self.store(Entry(data: data,
                            etag: response.value(forHTTPHeaderField: "ETag") ?? (response.statusCode == 304 ? entry?.etag : nil),
                            validatedAt: .now, freshFor: freshFor), scope: scope, id: id)
                    }
                }
                return data
            } catch {
                if case APIError.httpError(let code, _, _) = error,
                   [403, 404, 410].contains(code) { self.invalidate(scope: scope, id: id) }
                if APIError.from(error).requiresReauth { self.invalidate(scope: scope) }
                throw error
            }
        }
        inFlight[key] = task
        return try await task.value
    }

    nonisolated private static func conversation(_ data: Data, id: String) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["id"] as? String == id else { return nil }
        return json["chat"] as? [String: Any]
    }

    nonisolated private static func hasUnfinishedMessages(_ chat: [String: Any]) -> Bool {
        let history = chat["history"] as? [String: Any]
        let messages = history?["messages"] as? [String: [String: Any]]
        return messages?.values.contains { $0["done"] as? Bool == false } == true
            || (chat["messages"] as? [[String: Any]])?.contains { $0["done"] as? Bool == false } == true
    }

    private func store(_ entry: Entry, scope: String, id: String) {
        guard limit > 0, !id.hasPrefix("local:") else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(entry), data.count <= limit else {
            invalidate(scope: scope, id: id)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var root = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            var options: Data.WritingOptions = .atomic
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: file(scope: scope, id: id), options: options)
            prune()
        } catch {
            // Do not leave an older copy marked fresh after a replacement fails.
            try? FileManager.default.removeItem(at: file(scope: scope, id: id))
        }
    }

    func invalidate(scope: String, id: String? = nil) {
        generation = UUID()
        if let id {
            try? FileManager.default.removeItem(at: file(scope: scope, id: id))
        } else {
            for url in files() where url.lastPathComponent.hasPrefix(scope + "-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Metadata changes invalidate body copies without allowing a concurrent clear to be undone.
    func invalidate(scope: String?, ids: [String], since revision: UUID) -> UUID {
        let wasCurrent = revision == generation
        if let scope {
            for id in ids { invalidate(scope: scope, id: id) }
        }
        return wasCurrent ? generation : revision
    }

    /// Route mutations through the same invalidation path, including direct APIClient writes.
    func invalidateMutation(_ request: URLRequest, scope: String?) {
        guard let scope, let method = request.httpMethod, method != "GET", method != "HEAD",
              let path = request.url?.path else { return }
        if let range = path.range(of: "/api/v1/chats/") {
            let component = path[range.upperBound...].split(separator: "/").first.map(String.init)
            if ["new", "config", "read", "tags"].contains(component) { return }
            let bulk = component == nil || ["archive", "unarchive", "share", "shared", "import"].contains(component)
            invalidate(scope: scope, id: bulk ? nil : component)
            try? FileManager.default.removeItem(at: file(scope: scope, id: "index:sidebar"))
        } else if path.contains("/api/chat/"), let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = json["chat_id"] as? String {
            invalidate(scope: scope, id: id)
        }
    }

    func clear() {
        generation = UUID() // Requests already in flight cannot repopulate a cleared cache.
        try? FileManager.default.removeItem(at: directory)
    }

    func size() -> Int { files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }

    /// Oldest-accessed files go first. The budget applies across all server/session scopes.
    func prune(now: Date = .now) {
        if limit == 0 { clear(); return }
        let entries = files().compactMap { url -> (URL, Int, Date, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast, values.creationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _, created) in entries where total > limit || now.timeIntervalSince(created) > Self.retention {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "plist" }
    }
}
