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
        let allowsStale: Bool?

        init(data: Data, etag: String?, validatedAt: Date, freshFor: TimeInterval, allowsStale: Bool? = nil) {
            self.data = data
            self.etag = etag
            self.validatedAt = validatedAt
            self.freshFor = freshFor
            self.allowsStale = allowsStale
        }

        func isRecent(at date: Date = .now) -> Bool {
            let age = date.timeIntervalSince(validatedAt)
            return age >= 0 && age < freshFor
        }
    }

    /// JSONSerialization creates immutable Foundation values (no mutable options).
    /// Carry that validated tree to model construction instead of decoding again.
    nonisolated struct Response: @unchecked Sendable {
        let json: [String: Any]
        let chat: [String: Any]

        init(data: Data, id: String) throws {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["id"] as? String == id, let chat = json["chat"] as? [String: Any] else {
                throw APIError.responseDecoding(underlying: CocoaError(.coderReadCorrupt), data: nil)
            }
            self.json = json
            self.chat = chat
        }
    }

    nonisolated struct CachedResponse: Sendable {
        let entry: Entry
        let response: Response
    }

    private let directory: URL
    private let defaults: UserDefaults
    private var generation = UUID()
    private var inFlight: [String: Task<Response, Error>] = [:]
    private var staged: [String: (token: UUID, response: CachedResponse)] = [:]
    private var pendingStores: [String: Task<Void, Never>] = [:]
    private var lastPrunedAt = Date.distantPast

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

    private func file(scope: String, id: String, details: Bool = false) -> URL {
        directory.appendingPathComponent(scope + "-" + Self.digest(Data(id.utf8)) + (details ? ".full" : ".plist"))
    }

    func cached(scope: String?, id: String, now: Date = .now) -> CachedResponse? {
        if limit > 0, let scope, let pending = staged[scope + ":" + id],
           now.timeIntervalSince(pending.response.entry.validatedAt) <= Self.retention {
            return pending.response
        }
        guard let entry = read(scope: scope, id: id, details: true, now: now) ?? read(scope: scope, id: id, now: now),
              let response = try? Response(data: entry.data, id: id) else { return nil }
        if let scope { try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file(scope: scope, id: id).path) }
        return CachedResponse(entry: entry, response: response)
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

    private func read(scope: String?, id: String, details: Bool = false, now: Date = .now) -> Entry? {
        // Writes still enforce the budget immediately; reads need only periodic cleanup.
        if now.timeIntervalSince(lastPrunedAt) >= 600 || now < lastPrunedAt || limit == 0 {
            prune(now: now)
        }
        guard let scope, !id.hasPrefix("local:"), limit > 0 else { return nil }
        let url = file(scope: scope, id: id, details: details)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= limit, let data = try? Data(contentsOf: url),
              let entry = Self.decodeEntry(data),
              now.timeIntervalSince(entry.validatedAt) <= Self.retention else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return entry
    }

    /// Only navigation may opt into the short freshness window. Recovery and actions validate every time.
    func load(scope: String?, id: String, preferRecent: Bool = false,
              fetch: @escaping @Sendable (String?) async throws -> (Data, HTTPURLResponse)) async throws -> Response {
        guard let scope, !id.hasPrefix("local:") else { return try await Response(data: fetch(nil).0, id: id) }
        let cached = cached(scope: scope, id: id)
        let entry = cached?.entry
        let compact = cached?.response.chat[CachedConversationSnapshot.marker] as? Bool == true
        if preferRecent, let cached, cached.entry.isRecent() { return cached.response }
        let revision = generation
        let key = scope + ":" + id + ":" + revision.uuidString + (compact && preferRecent ? ":snapshot" : ":full")
        if let pending = inFlight[key] { return try await pending.value }
        let task = Task<Response, Error> {
            defer { self.inFlight[key] = nil }
            do {
                var (data, response) = try await fetch(compact && !preferRecent ? nil : entry?.etag)
                // A mutation/clear while validating makes the old representation unusable for a 304.
                if response.statusCode == 304 && (revision != self.generation || (compact && !preferRecent)) {
                    (data, response) = try await fetch(nil)
                }
                if [200, 304].contains(response.statusCode), compact, preferRecent, revision == self.generation,
                   let latest = self.cached(scope: scope, id: id), latest.entry.validatedAt > (entry?.validatedAt ?? .distantPast),
                   latest.response.chat[CachedConversationSnapshot.marker] as? Bool != true {
                    let control = (response.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
                    if control.contains("no-store") || control.contains("no-cache") || control.contains("must-revalidate")
                        || response.value(forHTTPHeaderField: "Vary") == "*" { self.invalidate(scope: scope, id: id) }
                    return latest.response
                }
                if response.statusCode == 304, revision == self.generation, let entry {
                    data = entry.data
                } else if response.statusCode != 200 {
                    throw APIError.httpError(statusCode: response.statusCode, message: nil, data: nil)
                }
                let decoded = response.statusCode == 304 ? cached?.response : try? Response(data: data, id: id)
                guard let decoded else {
                    self.invalidate(scope: scope, id: id)
                    throw APIError.responseDecoding(underlying: CocoaError(.coderReadCorrupt), data: nil)
                }
                if revision == self.generation {
                    let control = (response.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
                    if control.contains("no-store") || response.value(forHTTPHeaderField: "Vary") == "*"
                        || Self.hasUnfinishedMessages(decoded.chat) {
                        self.invalidate(scope: scope, id: id)
                    } else {
                        var freshFor = control.contains("no-cache") ? 0
                            : (response.statusCode == 304 ? (entry?.freshFor ?? 0) : Self.recentInterval)
                        for part in control.split(separator: ",") {
                            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                            if pair.count == 2, pair[0] == "max-age", let seconds = Double(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))) {
                                freshFor = min(freshFor, max(0, seconds))
                            }
                        }
                        freshFor = max(0, freshFor - max(0, Double(response.value(forHTTPHeaderField: "Age") ?? "0") ?? 0))
                        self.storeLater(Entry(data: data,
                            etag: response.value(forHTTPHeaderField: "ETag") ?? (response.statusCode == 304 ? entry?.etag : nil),
                            validatedAt: .now, freshFor: freshFor, allowsStale: response.statusCode == 304 && control.isEmpty ? entry?.allowsStale : !control.contains("no-cache") && !control.contains("must-revalidate")), response: decoded, scope: scope, id: id)
                    }
                }
                return decoded
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

    nonisolated private static func hasUnfinishedMessages(_ chat: [String: Any]) -> Bool {
        let history = chat["history"] as? [String: Any]
        let messages = history?["messages"] as? [String: Any]
        return messages?.values.contains { ($0 as? NSDictionary)?["done"] as? Bool == false } == true
            || (chat["messages"] as? [Any])?.contains { ($0 as? NSDictionary)?["done"] as? Bool == false } == true
    }

    // Versioned lossless envelope; legacy uncompressed property lists remain readable.
    private nonisolated static let magic = Data("ORC2".utf8)

    private nonisolated static func decodeEntry(_ data: Data) -> Entry? {
        let payload: Data
        if data.starts(with: magic) {
            guard let decoded = try? (Data(data.dropFirst(magic.count)) as NSData).decompressed(using: .lzfse) else { return nil }
            payload = decoded as Data
        } else { payload = data }
        return try? PropertyListDecoder().decode(Entry.self, from: payload)
    }

    nonisolated private struct Prepared: Sendable {
        let base: Data
        let full: Data?
    }

    // One utility encoder keeps expensive parsing/compression away from cache reads and first paint.
    private actor Encoder {
        func prepare(_ entry: Entry, id: String, limit: Int) throws -> Prepared {
            try Task.checkCancellation()
            return try ConversationCache.prepare(entry, id: id, limit: limit)
        }
    }
    private static let encoder = Encoder()

    nonisolated private static func prepare(_ entry: Entry, id: String, limit: Int) throws -> Prepared {
        func encode(_ entry: Entry) throws -> Data {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(entry)
            return magic + ((try (data as NSData).compressed(using: .lzfse)) as Data)
        }
        let compact = id == "index:sidebar" ? nil : CachedConversationSnapshot.compact(entry.data)
        let base = compact.map { Entry(data: $0, etag: entry.etag, validatedAt: entry.validatedAt, freshFor: entry.freshFor, allowsStale: entry.allowsStale) } ?? entry
        let full = compact == nil ? nil : try encode(entry)
        return try Prepared(base: encode(base), full: full.flatMap { $0.count <= limit / 2 ? $0 : nil })
    }

    private func storeLater(_ entry: Entry, response: Response, scope: String, id: String) {
        guard limit > 0 else { return }
        let key = scope + ":" + id, token = UUID(), budget = limit
        pendingStores[key]?.cancel()
        staged[key] = (token, CachedResponse(entry: entry, response: response))
        pendingStores[key] = Task(priority: .utility) {
            let prepared = try? await Self.encoder.prepare(entry, id: id, limit: budget)
            guard !Task.isCancelled, staged[key]?.token == token else { return }
            defer { staged[key] = nil; pendingStores[key] = nil }
            if let prepared { store(entry, scope: scope, id: id, prepared: prepared) }
            else { invalidate(scope: scope, id: id) }
        }
    }

    private func store(_ entry: Entry, scope: String, id: String, prepared: Prepared? = nil) {
        guard limit > 0, !id.hasPrefix("local:") else { return }
        do {
            let prepared = try prepared ?? Self.prepare(entry, id: id, limit: limit)
            guard prepared.base.count <= limit else { invalidate(scope: scope, id: id); return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var root = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            var options: Data.WritingOptions = .atomic
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            // Never pair a new compact snapshot with an older full representation.
            try? FileManager.default.removeItem(at: file(scope: scope, id: id, details: true))
            try prepared.base.write(to: file(scope: scope, id: id), options: options)
            if let full = prepared.full, full.count <= limit / 2 {
                try full.write(to: file(scope: scope, id: id, details: true), options: options)
            }
            prune()
        } catch {
            invalidate(scope: scope, id: id)
        }
    }

    private func cancelPendingStores(scope: String? = nil, id: String? = nil) {
        for key in Array(pendingStores.keys) {
            if let scope {
                let prefix = scope + ":"
                if let id { guard key == prefix + id else { continue } }
                else { guard key.hasPrefix(prefix) else { continue } }
            }
            pendingStores.removeValue(forKey: key)?.cancel()
            staged[key] = nil
        }
    }

    func invalidate(scope: String, id: String? = nil) {
        generation = UUID()
        cancelPendingStores(scope: scope, id: id)
        if let id {
            try? FileManager.default.removeItem(at: file(scope: scope, id: id))
            try? FileManager.default.removeItem(at: file(scope: scope, id: id, details: true))
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
        cancelPendingStores()
        lastPrunedAt = .distantPast
        try? FileManager.default.removeItem(at: directory)
    }

    func size() -> Int { files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }

    /// Oldest-accessed files go first. The budget applies across all server/session scopes.
    func prune(now: Date = .now) {
        if limit == 0 { clear(); return }
        lastPrunedAt = now
        let entries = files().compactMap { url -> (URL, Int, Date, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast, values.creationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        var detailsTotal = entries.filter { $0.0.pathExtension == "full" }.reduce(0) { $0 + $1.1 }
        // Demote oldest full chats first; keep answers and expandable headers.
        for (url, size, _, created) in entries where url.pathExtension == "full" {
            if detailsTotal > limit / 2 || total > limit || now.timeIntervalSince(created) > Self.retention {
                try? FileManager.default.removeItem(at: url)
                total -= size
                detailsTotal -= size
            }
        }
        for (url, size, _, created) in entries where url.pathExtension == "plist" {
            if total > limit || now.timeIntervalSince(created) > Self.retention {
                try? FileManager.default.removeItem(at: url)
                total -= size
                let full = url.deletingPathExtension().appendingPathExtension("full")
                if let fullSize = try? full.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    try? FileManager.default.removeItem(at: full)
                    total -= fullSize
                }
            }
        }
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { ["plist", "full"].contains($0.pathExtension) }
    }
}
