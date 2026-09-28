import CryptoKit
import Darwin
import Foundation

let testDirectory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("cache")
let testDefaultsName = "org.example.relay.decoding.\(UUID())"
let testDefaults = UserDefaults(suiteName: testDefaultsName)!
struct ConversationIndex: Codable { let marker: String }
struct Conversation { let id: String }

final class DecodeProbe: @unchecked Sendable {
    static let lock = NSLock()
    private static var count = 0
    static func jsonObject(with data: Data) throws -> Any {
        lock.lock(); count += 1; lock.unlock()
        return try JSONSerialization.jsonObject(with: data)
    }
    static func takeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let result = count; count = 0; return result
    }
}

func payload(_ id: String, count: Int = 1, done: Bool = true) throws -> Data {
    let paragraph = String(repeating: "An invented silver robot counts paper leaves. ", count: 44)
    let messages = (0..<count).map { ["id": "message-\($0)", "content": "Entry \($0). " + paragraph, "done": done] as [String: Any] }
    return try JSONSerialization.data(withJSONObject: ["id": id, "chat": ["messages": messages]])
}

actor Gate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class Network: @unchecked Sendable {
    // Tests mutate configuration between requests or while parked at the gate.
    var conversationCacheScope: String? = "synthetic-a"
    var data = try! payload("one")
    var status = 200
    var headers = ["ETag": "synthetic-etag"]
    var error: APIError?
    var requests = 0
    var validator: String?
    var gate: Gate?
    func requestRaw(path: String, ifNoneMatch: String?, deduplicate: Bool) async throws -> (Data, HTTPURLResponse) {
        requests += 1; validator = ifNoneMatch
        if let gate { await gate.wait() }
        if let error { throw error }
        return (data, HTTPURLResponse(url: URL(string: "https://fixture.invalid" + path)!,
                                     statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

final class APIClient: @unchecked Sendable {
    let network = Network()
    func parseFullConversation(_ json: [String: Any]) -> Conversation {
        Conversation(id: json["id"] as! String)
    }
}

actor Counter {
    var value = 0
    func next() -> Int { value += 1; return value }
}

@main struct Checks {
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); print("PASS \(message)")
    }
    static func decodeCount(_ candidate: Int, _ baseline: Int, _ message: String) {
        let count = DecodeProbe.takeCount()
        #if BASELINE
        check(count == baseline, message + " baseline decodes=\(count)")
        #else
        check(count == candidate, message + " candidate decodes=\(count)")
        #endif
    }
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    static func started(_ gate: Gate) async {
        let deadline = Date().addingTimeInterval(5)
        while !(await gate.started), Date() < deadline { await Task.yield() }
        check(await gate.started, "controlled request started")
    }
    static func main() async throws {
        defer { testDefaults.removePersistentDomain(forName: testDefaultsName) }
        testDefaults.set(50, forKey: ConversationCache.limitKey)
        let api = APIClient(), cache = ConversationCache.shared
        check(try await api.getConversation(id: "one").id == "one", "cold response validates and constructs the intended chat")
        decodeCount(1, 2, "cold response")
        check(try await api.getConversation(id: "one", preferRecent: true).id == "one", "recent response is reused")
        check(api.network.requests == 1, "recent navigation sends no second request")
        decodeCount(1, 2, "recent response")
        check(await api.cachedConversation(id: "one")?.conversation.id == "one", "offline cached conversation validates")
        decodeCount(1, 2, "cached conversation")
        api.network.status = 304
        check(try await api.getConversation(id: "one").id == "one", "304 retains the matching chat")
        check(api.network.validator == "synthetic-etag", "conditional request retains its validator")
        decodeCount(1, 3, "304 response")

        api.network.conversationCacheScope = "synthetic-b"
        check(await api.cachedConversation(id: "one") == nil, "account scope remains isolated")
        api.network.status = 200
        _ = try await api.getConversation(id: "one")
        check(api.network.validator == nil, "new account does not reuse another validator")
        api.network.error = .httpError(statusCode: 403, message: nil, data: nil)
        do { _ = try await api.getConversation(id: "one"); preconditionFailure("403 must throw") }
        catch { check(await api.cachedConversation(id: "one") == nil, "forbidden response invalidates that account's copy") }
        api.network.error = nil

        for bytes in [Data("invalid JSON".utf8), try payload("another-chat"), Data("{\"id\":\"one\"}".utf8)] {
            api.network.data = bytes
            do { _ = try await api.getConversation(id: "one"); preconditionFailure("invalid response must throw") }
            catch { check(await api.cachedConversation(id: "one") == nil, "invalid or mismatched response is not cached") }
        }
        api.network.data = try payload("one", done: false)
        _ = try await api.getConversation(id: "one")
        check(await api.cachedConversation(id: "one") == nil, "unfinished response is usable but not cached")
        api.network.data = try payload("one")
        api.network.headers = ["Cache-Control": "no-store"]
        _ = try await api.getConversation(id: "one")
        check(await api.cachedConversation(id: "one") == nil, "no-store is honored")

        // Corrupt but otherwise fresh disk records must fall through to the network.
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data("one".utf8)).map { String(format: "%02x", $0) }.joined()
        let entry = ConversationCache.Entry(data: try payload("wrong-id"), etag: "bad", validatedAt: .now, freshFor: 30)
        try PropertyListEncoder().encode(entry).write(to: testDirectory.appendingPathComponent("synthetic-b-\(key).plist"))
        api.network.headers = ["ETag": "replacement"]
        let before = api.network.requests
        check(try await api.getConversation(id: "one", preferRecent: true).id == "one", "corrupt recent record refetches")
        check(api.network.requests == before + 1 && api.network.validator == nil, "corrupt record does not supply a validator")

        let requests = Counter()
        _ = try await cache.load(scope: "synthetic-b", id: "one") { _ in
            let count = await requests.next()
            if count == 1 { await cache.clear() }
            return (try payload("one"), HTTPURLResponse(url: URL(string: "https://fixture.invalid/one")!,
                statusCode: count == 1 ? 304 : 200, httpVersion: nil, headerFields: nil)!)
        }
        check(await requests.value == 2, "clear during revalidation forces an unconditional fetch")
        check(await api.cachedConversation(id: "one") == nil, "in-flight response cannot repopulate a cleared cache")

        api.network.data = try payload("coalesced")
        let gate = Gate()
        api.network.gate = gate
        _ = DecodeProbe.takeCount()
        let requestCount = api.network.requests
        let first = Task { try await api.getConversation(id: "coalesced") }
        await started(gate)
        let second = Task { try await api.getConversation(id: "coalesced") }
        for _ in 0..<100 { await Task.yield() }
        check(api.network.requests == requestCount + 1, "overlapping callers share one fetch")
        first.cancel()
        await gate.release()
        let firstValue = try await first.value, secondValue = try await second.value
        check(firstValue.id == "coalesced" && secondValue.id == "coalesced",
              "a cancelled waiter does not cancel shared response processing")
        decodeCount(1, 3, "coalesced callers")

        let switching = Gate()
        api.network.gate = switching
        api.network.data = try payload("switching")
        let pending = Task { try await api.getConversation(id: "switching") }
        await started(switching)
        api.network.conversationCacheScope = "synthetic-c"
        await switching.release()
        do { _ = try await pending.value; preconditionFailure("switched account must reject the response") }
        catch { check(await cache.cached(scope: "synthetic-b", id: "switching") == nil,
                      "account switch rejects and does not cache the response") }
        api.network.gate = nil
        for id in ["one", "two"] {
            api.network.data = try payload(id)
            _ = try await api.getConversation(id: id)
        }
        api.network.error = .httpError(statusCode: 401, message: nil, data: nil)
        do { _ = try await api.getConversation(id: "one"); preconditionFailure("401 must throw") }
        catch {
            check(await api.cachedConversation(id: "one") == nil, "401 removes the requested cached chat")
            check(await api.cachedConversation(id: "two") == nil, "401 invalidates the account scope")
        }
        api.network.error = nil

        if CommandLine.arguments.contains("--benchmark") {
            for count in [64, 512, 4096] {
                api.network.data = try payload("one", count: count)
                _ = try await api.getConversation(id: "one")
                _ = DecodeProbe.takeCount()
                var samples: [Double] = []
                for _ in 0..<15 {
                    let start = cpu()
                    let value = await api.cachedConversation(id: "one")
                    precondition(value?.conversation.id == "one")
                    samples.append((cpu() - start) * 1000)
                }
                samples.sort()
                print("DECODE_BENCH messages=\(count) bytes=\(api.network.data.count) median_cpu_ms=\(samples[7]) p95_cpu_ms=\(samples[14]) decodes=\(DecodeProbe.takeCount())")
            }
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("DECODE_PROCESS peak_resident_bytes=\(usage.ru_maxrss)")
        }
        await cache.clear()
    }
}
