import CryptoKit
import Darwin
import Foundation

// Only the unused sidebar-index data type is stubbed; the cache is compiled
// directly from the selected Open Relay checkout, with no extraction or edits.
struct ConversationIndex: Codable { let marker: String }

@main struct CacheBench {
    static func cpu() -> Double {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    static func digest(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func report(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        print("METRIC \(name) n=\(sorted.count) median_ms=\(sorted[sorted.count / 2] * 1000) p95_ms=\(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000)")
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let defaults = UserDefaults(suiteName: "org.example.relay.cache-benchmark")!
        defaults.set(250, forKey: ConversationCache.limitKey)
        for count in [10, 100, 1000, 5000] {
            let dir = root.appendingPathComponent("cache-\(count)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            for index in 0..<count {
                let id = "synthetic-\(index)"
                let data = try JSONSerialization.data(withJSONObject: ["id": id, "chat": ["messages": [["content": "A synthetic test record.", "done": true]]]])
                let entry = ConversationCache.Entry(data: data, etag: nil, validatedAt: .now, freshFor: 30)
                try encoder.encode(entry).write(to: dir.appendingPathComponent("scope-" + digest(id) + ".plist"))
            }
            let cache = ConversationCache(directory: dir, defaults: defaults)
            var wall: [Double] = [], usedCPU: [Double] = []
            for trial in 0..<26 {
                let start = ContinuousClock.now, c = cpu()
                let entry = await cache.cached(scope: "scope", id: "synthetic-0")
                guard entry != nil else { fatalError("Seeded cache record must be readable") }
                let elapsed = start.duration(to: .now).components
                if trial > 0 {
                    wall.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                    usedCPU.append(cpu() - c)
                }
            }
            report("cache_read_\(count)_wall", wall)
            report("cache_read_\(count)_cpu", usedCPU)
            await cache.clear()
        }
        defaults.removePersistentDomain(forName: "org.example.relay.cache-benchmark")
    }
}
