import CryptoKit
import Foundation

struct ConversationIndex: Codable { let marker: String }

@main struct CacheChecks {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS \(message)")
    }
    static func payload(_ id: String, text: String = "Invented station data.") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "chat": ["messages": [["content": text, "done": true]]]])
    }
    static func seed(_ id: String, in dir: URL, validatedAt: Date = .now) throws {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let entry = ConversationCache.Entry(data: try payload(id), etag: nil, validatedAt: validatedAt, freshFor: 30)
        try encoder.encode(entry).write(to: dir.appendingPathComponent("scope-\(hash).plist"))
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cache-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "org.example.relay.cache-checks")!
        defaults.set(1, forKey: ConversationCache.limitKey)
        let cache = ConversationCache(directory: root, defaults: defaults)
        try seed("valid", in: root)
        check(await cache.cached(scope: "scope", id: "valid") != nil, "valid completed record is readable")
        check(await cache.cached(scope: "another-account", id: "valid") == nil, "account scope remains isolated")
        check(await cache.cached(scope: nil, id: "valid") == nil, "unauthenticated reads return no cache")
        try seed("expired", in: root, validatedAt: .now.addingTimeInterval(-ConversationCache.retention - 1))
        check(await cache.cached(scope: "scope", id: "expired") == nil, "expired requested record rejected between pruning passes")
        let backwards = Date.now.addingTimeInterval(-3600)
        check(await cache.cached(scope: "scope", id: "valid", now: backwards) != nil, "clock rollback does not lose valid records")
        for index in 0..<3 {
            let id = "write-\(index)"
            let bytes = try payload(id, text: String(repeating: "Synthetic. ", count: 35_000))
            _ = try await cache.load(scope: "scope", id: id) { _ in
                (bytes, HTTPURLResponse(url: URL(string: "https://example.test/chat")!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
            check(await cache.size() <= 1024 * 1024, "write \(index) enforces byte budget immediately")
        }
        defaults.set(0, forKey: ConversationCache.limitKey)
        check(await cache.cached(scope: "scope", id: "valid") == nil, "disabled cache returns no record")
        check(await cache.size() == 0, "disabled cache clears stored data")
        defaults.set(1, forKey: ConversationCache.limitKey)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try seed("restored", in: root)
        check(await cache.cached(scope: "scope", id: "restored") != nil, "cache can be re-enabled")
        await cache.clear()
        check(await cache.size() == 0, "explicit clear removes all cached data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let start = Date.now
        try seed("current", in: root, validatedAt: start)
        _ = await cache.cached(scope: "scope", id: "current", now: start)
        try seed("unused", in: root, validatedAt: start)
        let hash = SHA256.hash(data: Data("unused".utf8)).map { String(format: "%02x", $0) }.joined()
        let unused = root.appendingPathComponent("scope-\(hash).plist")
        try FileManager.default.setAttributes([.creationDate: start.addingTimeInterval(-ConversationCache.retention - 1)], ofItemAtPath: unused.path)
        _ = await cache.cached(scope: "scope", id: "current", now: start.addingTimeInterval(599))
        check(FileManager.default.fileExists(atPath: unused.path), "unrelated read does not repeat maintenance before ten minutes")
        _ = await cache.cached(scope: "scope", id: "current", now: start.addingTimeInterval(600))
        check(!FileManager.default.fileExists(atPath: unused.path), "next read performs overdue maintenance at ten minutes")
        defaults.set(0, forKey: ConversationCache.limitKey)
        await cache.prune()
        check(await cache.size() == 0, "settings-triggered maintenance applies a reduced budget immediately")
        await cache.clear()
        defaults.removePersistentDomain(forName: "org.example.relay.cache-checks")
    }
}
