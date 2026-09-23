import Foundation

@main
@MainActor
struct CacheChecks {
    static var checks = 0
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func tool(_ suffix: String) -> String {
        // No ID attribute: a real reparse creates a fresh tool UUID, making
        // unnecessary reparsing observable without instrumenting production code.
        "<details type=\"tool_calls\" name=\"synthetic_lookup\" done=\"true\" result=\"\(suffix)\"><summary>Fixture</summary></details>"
    }

    static func main() async {
        print("Runtime: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let cache = MessageParseCache()
        let inputs = (0..<10).map { tool("invented result \($0)") }
        expect(Set(inputs.map { String($0.prefix(64)) }).count == 1, "fixture prefixes match")
        expect(Set(inputs.map { $0.utf8.count }).count == 1, "fixture byte counts match")
        expect(cache.lookupSync(inputs[0]) == nil, "new cache starts empty")

        var originalIDs: [String] = []
        for input in inputs {
            let parsed = await cache.parseAndStore(content: input)
            expect(parsed.allToolCalls.count == 1, "fixture produces one tool call")
            originalIDs.append(parsed.allToolCalls.first?.id ?? "missing")
        }
        for (index, input) in inputs.enumerated() {
            expect(cache.lookupSync(input)?.allToolCalls.first?.id == originalIDs[index], "sync lookup retains entry \(index)")
            let hit = await cache.lookup(content: input)
            expect(hit?.allToolCalls.first?.id == originalIDs[index], "actor lookup retains entry \(index)")
            let reused = await cache.parseAndStore(content: input)
            expect(reused.allToolCalls.first?.id == originalIDs[index], "repeat lookup does not reparse entry \(index)")
            expect(reused.allToolCalls.first?.result == "invented result \(index)", "lookup returns its own content")
        }

        await cache.warmBatch(inputs)
        for (index, input) in inputs.enumerated() {
            expect(cache.lookupSync(input)?.allToolCalls.first?.id == originalIDs[index], "warming keeps cached entry \(index)")
        }

        let coldWarmCache = MessageParseCache()
        await coldWarmCache.warmBatch(inputs)
        for input in inputs {
            expect(coldWarmCache.lookupSync(input) != nil, "cold batch retains each entry")
        }

        let unicode = [tool("星 🌙 e\u{301}"), tool("海 🌞 e\u{301}")]
        expect(unicode[0].utf8.count == unicode[1].utf8.count, "Unicode fixtures have equal byte counts")
        await cache.warmBatch(unicode)
        for input in unicode {
            expect(cache.lookupSync(input) != nil, "Unicode tail remains distinct")
        }

        let edited = tool("invented result X")
        expect(cache.lookupSync(edited) == nil, "same-size content edit is a miss")
        let editResult = await cache.parseAndStore(content: edited)
        expect(editResult.allToolCalls.first?.result == "invented result X", "edit returns new content")
        expect(cache.lookupSync(inputs[0])?.allToolCalls.first?.id == originalIDs[0], "edit does not evict another content revision")

        await withTaskGroup(of: Void.self) { group in
            for input in inputs {
                group.addTask { _ = await cache.parseAndStore(content: input) }
            }
        }
        for (index, input) in inputs.enumerated() {
            expect(cache.lookupSync(input)?.allToolCalls.first?.id == originalIDs[index], "concurrent requests reuse entry \(index)")
        }

        print("MessageParseCache: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
