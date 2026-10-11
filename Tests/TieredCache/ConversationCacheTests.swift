import CryptoKit
import Foundation

actor Fetches {
    var count = 0
    var validators: [String?] = []
    func record(_ etag: String?) { count += 1; validators.append(etag) }
}

@main struct ConversationCacheTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ name: String) {
        if !condition { FileHandle.standardError.write(Data(("FAILED: " + name + "\n").utf8)) }
        precondition(condition, name)
        checks += 1
    }
    static func response(_ status: Int = 200, control: String = "max-age=30") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.test/chat")!, statusCode: status,
                        httpVersion: nil, headerFields: ["ETag": "\"synthetic-revision\"", "Cache-Control": control])!
    }
    static func noise(_ count: Int) -> String {
        var seed: UInt64 = 47
        let bytes = (0..<count).map { _ -> UInt8 in
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed)
        }
        return Data(bytes).base64EncodedString()
    }
    static func payload(_ id: String, content: String, output: [[String: Any]] = [], unfinished: Bool = false) -> Data {
        let user: [String: Any] = ["id": "u", "role": "user", "content": "Describe an invented observatory.", "parentId": NSNull(), "childrenIds": ["a"], "done": true]
        let answer: [String: Any] = ["id": "a", "role": "assistant", "content": content, "parentId": "u", "childrenIds": [], "done": !unfinished, "output": output]
        return try! JSONSerialization.data(withJSONObject: ["id": id, "chat": ["history": ["currentId": "a", "messages": ["u": user, "a": answer]], "messages": [user, answer]]], options: .sortedKeys)
    }
    static func details(_ body: String) -> String {
        "<details type=\"reasoning\" done=\"true\" duration=\"2\"><summary>Thought for 2 seconds</summary>\(body)</details>\nFinal answer: a copper telescope."
    }
    static func message(_ response: ConversationCache.Response) -> String {
        let history = response.chat["history"] as! [String: Any]
        return (history["messages"] as! [String: [String: Any]])["a"]!["content"] as! String
    }
    static func visible(_ text: String) -> [String] {
        ToolCallParser.parseOrdered(text).segments.compactMap { if case .text(let text) = $0 { return text }; return nil }
    }
    @MainActor static func suite(_ root: URL, _ name: String, mb: Int = 1) -> (ConversationCache, URL) {
        let directory = root.appendingPathComponent(name)
        let defaults = UserDefaults()
        defaults.setVolatileDomain([ConversationCache.limitKey: mb], forName: UserDefaults.argumentDomain)
        return (ConversationCache(directory: directory, defaults: defaults), directory)
    }
    static func save(_ cache: ConversationCache, _ id: String, _ data: Data, control: String = "max-age=30") async throws {
        _ = try await cache.load(scope: "synthetic", id: id) { _ in (data, response(control: control)) }
        await cache.flushForTesting()
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = details(String(repeating: "Invented violet moons & lenses 👩🏽‍🚀. ", count: 500))
        let data = payload("projection", content: original)
        let compact = CachedConversationSnapshot.compact(data)!
        let decoded = try ConversationCache.Response(data: compact, id: "projection")
        expect(compact.count < data.count / 10, "projection materially shrinks a detail-heavy chat")
        expect(visible(message(decoded)) == visible(original), "final answers are unchanged")
        expect(decoded.chat[CachedConversationSnapshot.marker] as? Bool == true, "compact conversation is marked read-only")
        let parsed = ToolCallParser.parseOrdered(message(decoded))
        expect(parsed.segments.contains { if case .reasoning(let r) = $0 { return r.isDeferred && r.duration == "2" && r.content.count <= 80 }; return false }, "reasoning header, duration and identity anchor survive")
        let spill = "<details type=\"reasoning\" done=\"true\"><summary>Thought</summary>\(noise(2000))</think>Visible final reply.</details>"
        let spillCompact = CachedConversationSnapshot.compact(payload("spill", content: spill))!
        expect(visible(message(try ConversationCache.Response(data: spillCompact, id: "spill"))) == visible(spill), "reasoning spillover remains visible")
        let tool = "<details type=\"tool_calls\" name=\"count_moons\" id=\"call-1\" done=\"true\" result=\"{&quot;error&quot;:&quot;\(noise(5000))&quot;}\"><summary>Tool Executed</summary></details>\nAn invented answer."
        let fullTool = ToolCallParser.parseOrdered(tool).allToolCalls.first!
        expect(fullTool.cachedError == true, "completed tool status is computed once per parsed response")
        let toolCompact = CachedConversationSnapshot.compact(payload("tool", content: tool))!
        let toolParsed = ToolCallParser.parseOrdered(message(try ConversationCache.Response(data: toolCompact, id: "tool")))
        expect(toolParsed.allToolCalls.first?.isError == true && toolParsed.allToolCalls.first?.isDeferred == true, "tool identity and error status survive eviction")
        for extra in ["embeds=\"[]\"", "files=\"[]\"", "name=\"display_file\""] {
            let body = "<details type=\"tool_calls\" done=\"true\" \(extra)>\(noise(3000))</details>"
            expect(CachedConversationSnapshot.compact(payload("visible", content: body)) == nil, "inline tool media/file blocks are retained")
        }
        let literal = "```html\n<details><summary>Example</summary>\(noise(1000))</details>\n```"
        expect(CachedConversationSnapshot.compact(payload("code", content: literal)) == nil, "literal details in code are preserved")
        expect(CachedConversationSnapshot.compact(payload("live", content: original, unfinished: true)) == nil, "active reasoning is not projected")
        let output: [[String: Any]] = [["type": "reasoning", "status": "completed", "content": [["type": "reasoning_text", "text": noise(3000)]]], ["type": "message", "content": [["type": "output_text", "text": "Visible output answer."]]]]
        let outputCompact = CachedConversationSnapshot.compact(payload("output", content: "", output: output))!
        expect(visible(message(try ConversationCache.Response(data: outputCompact, id: "output"))) == ["Visible output answer."], "output-only messages retain their final text")

        let pendingTool = "<details type=\"tool_calls\" name=\"count_moons\">\(noise(3000))</details>"
        expect(CachedConversationSnapshot.compact(payload("pending-tool", content: pendingTool)) == nil, "tool calls without a completion flag are retained")
        expect(CachedConversationSnapshot.hasDeferredContent(message(decoded)), "deferred assistant history is recognizable at API write boundaries")
        expect(!CachedConversationSnapshot.hasDeferredContent("```html\n<details cache-missing=\"true\">Example</details>\n```"), "literal marker examples are safe to send")

        let (cache, directory) = suite(root, "tiers")
        let body = details(noise(220_000))
        for id in ["one", "two", "three"] { try await save(cache, id, payload(id, content: body)); try await Task.sleep(for: .milliseconds(15)) }
        let one = await cache.cached(scope: "synthetic", id: "one")
        expect(one != nil && one?.response.chat[CachedConversationSnapshot.marker] as? Bool == true, "oldest chat keeps answers after details eviction")
        let three = await cache.cached(scope: "synthetic", id: "three")
        expect(three?.response.chat[CachedConversationSnapshot.marker] == nil, "most recent chat retains full details")
        let navigated = try await cache.load(scope: "synthetic", id: "one", preferRecent: true) { _ in preconditionFailure("fresh compact navigation must not fetch details") }
        expect(navigated.chat[CachedConversationSnapshot.marker] as? Bool == true, "navigation retains a fresh compact snapshot until expansion")
        let count = Fetches()
        let restored = try await cache.load(scope: "synthetic", id: "one") { etag in
            await count.record(etag)
            return (payload("one", content: body), response())
        }
        expect(message(restored) == body, "one expansion restores the entire original conversation")
        await cache.flushForTesting()
        let validators = await count.validators
        expect(await count.count == 1 && validators.first! == nil, "compact cache cannot satisfy a conditional 304")
        let again = try await cache.load(scope: "synthetic", id: "one", preferRecent: true) { _ in preconditionFailure("full recent cache must not refetch") }
        expect(message(again) == body, "subsequent expansions use the full local copy")
        let two = await cache.cached(scope: "synthetic", id: "two")
        expect(two?.response.chat[CachedConversationSnapshot.marker] as? Bool == true, "hydration promotes the chat and demotes the next oldest")
        expect(await cache.size() <= 1024 * 1024, "total stored bytes obey the configured budget")
        let persisted = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        expect(persisted.allSatisfy { (try! Data(contentsOf: $0)).starts(with: Data("ORC2".utf8)) }, "all new disk entries use the compressed versioned envelope")

        let (oversized, _) = suite(root, "oversized")
        try await save(oversized, "large", payload("large", content: details(noise(700_000))))
        expect(await oversized.cached(scope: "synthetic", id: "large")?.response.chat[CachedConversationSnapshot.marker] as? Bool == true, "oversized details do not discard a small answer snapshot")

        let (validation, _) = suite(root, "validation")
        try await save(validation, "conditional", payload("conditional", content: details(noise(700_000))), control: "max-age=0")
        let conditional = Fetches()
        let unchanged = try await validation.load(scope: "synthetic", id: "conditional", preferRecent: true) { etag in
            await conditional.record(etag)
            return (Data(), response(304))
        }
        let conditionalValidators = await conditional.validators
        expect(conditionalValidators == ["\"synthetic-revision\""] && unchanged.chat[CachedConversationSnapshot.marker] as? Bool == true, "unchanged compact navigation validates without downloading details")
        let unexpected = Fetches()
        let hydrated = try await validation.load(scope: "synthetic", id: "conditional") { etag in
            await unexpected.record(etag)
            if await unexpected.count == 1 { return (Data(), response(304)) }
            return (payload("conditional", content: details(noise(700_000))), response())
        }
        expect(await unexpected.count == 2 && hydrated.chat[CachedConversationSnapshot.marker] == nil, "expansion retries an unexpected 304 with a full response")
        try await save(validation, "overlap", payload("overlap", content: details(noise(700_000))), control: "max-age=0")
        let passive = Task { try await validation.load(scope: "synthetic", id: "overlap", preferRecent: true) { _ in
            try await Task.sleep(for: .milliseconds(100)); return (Data(), response(304))
        } }
        try await Task.sleep(for: .milliseconds(20))
        let demanded = try await validation.load(scope: "synthetic", id: "overlap") { _ in
            (payload("overlap", content: details(noise(100_000))), response())
        }
        _ = try await passive.value
        expect(demanded.chat[CachedConversationSnapshot.marker] == nil, "an expansion cannot join a compact-only validation")
        expect(await validation.cached(scope: "synthetic", id: "overlap")?.response.chat[CachedConversationSnapshot.marker] == nil, "late compact validation cannot demote newly hydrated details")
        try await save(validation, "late-body", payload("late-body", content: details(noise(700_000))), control: "max-age=0")
        let lateBody = Task { try await validation.load(scope: "synthetic", id: "late-body", preferRecent: true) { _ in
            try await Task.sleep(for: .milliseconds(100))
            return (payload("late-body", content: details(noise(2000)) + " Older response."), response())
        } }
        try await Task.sleep(for: .milliseconds(20))
        let freshBody = details(noise(100_000)) + " Newer demanded response."
        _ = try await validation.load(scope: "synthetic", id: "late-body") { _ in (payload("late-body", content: freshBody), response()) }
        _ = try await lateBody.value
        await validation.flushForTesting()
        expect(await validation.cached(scope: "synthetic", id: "late-body").map { message($0.response) } == freshBody, "a late background 200 cannot replace a newer full-chat expansion")

        let scopeA = ConversationCache.scope(server: "https://example.test", token: "synthetic-a")!
        let scopeB = ConversationCache.scope(server: "https://example.test", token: "synthetic-b")!
        _ = try await validation.load(scope: scopeA, id: "account") { _ in (payload("account", content: original), response()) }
        await validation.flushForTesting()
        expect(scopeA != scopeB && scopeA.count == 64, "account identities are separated and filenames contain only hashes")
        expect(await validation.cached(scope: scopeB, id: "account") == nil, "one account cannot read another account's snapshot")
        let (corrupt, corruptDirectory) = suite(root, "corrupt")
        try await save(corrupt, "corrupt", payload("corrupt", content: original))
        let fullFile = try FileManager.default.contentsOfDirectory(at: corruptDirectory, includingPropertiesForKeys: nil).first { $0.pathExtension == "full" }!
        try Data("invalid envelope".utf8).write(to: fullFile)
        expect(await corrupt.cached(scope: "synthetic", id: "corrupt")?.response.chat[CachedConversationSnapshot.marker] as? Bool == true, "corrupt full details fall back to the intact answer snapshot")
        let branchData = payload("branches", content: original)
        var branchJSON = try JSONSerialization.jsonObject(with: branchData) as! [String: Any]
        var branchChat = branchJSON["chat"] as! [String: Any]
        var branchHistory = branchChat["history"] as! [String: Any]
        var branchNodes = branchHistory["messages"] as! [String: [String: Any]]
        branchNodes["inactive"] = ["id": "inactive", "role": "assistant", "content": original, "parentId": "u", "childrenIds": [], "done": true, "files": [["url": "https://example.test/fictional.png"]]]
        branchHistory["messages"] = branchNodes
        branchChat["history"] = branchHistory
        branchChat["files"] = [["id": "fictional-file"]]
        branchJSON["chat"] = branchChat
        let branched = CachedConversationSnapshot.compact(try JSONSerialization.data(withJSONObject: branchJSON))!
        let projectedBranch = try ConversationCache.Response(data: branched, id: "branches")
        let projectedHistory = projectedBranch.chat["history"] as! [String: Any]
        let projectedNodes = projectedHistory["messages"] as! [String: [String: Any]]
        expect(projectedHistory["currentId"] as? String == branchHistory["currentId"] as? String && projectedNodes.count == branchNodes.count, "all active and inactive branch nodes and selection survive projection")
        expect((projectedNodes["inactive"]?["files"] as? [[String: String]]) == [["url": "https://example.test/fictional.png"]] && projectedBranch.chat["files"] != nil, "node and chat attachments survive projection")
        let unicode = details(String(repeating: "🌙é&<>\"", count: 500))
        let unicodeCompact = CachedConversationSnapshot.compact(payload("unicode", content: unicode))!
        let unicodeReason = ToolCallParser.parseOrdered(message(try ConversationCache.Response(data: unicodeCompact, id: "unicode"))).segments.compactMap { if case .reasoning(let r) = $0 { return r }; return nil }.first!
        let fullReason = ToolCallParser.parseOrdered(unicode).segments.compactMap { if case .reasoning(let r) = $0 { return r }; return nil }.first!
        expect(unicodeReason.id == fullReason.id, "Unicode and escaped reasoning anchors keep stable view identity")

        let (legacy, legacyDir) = suite(root, "legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyData = payload("legacy", content: "An invented legacy answer.")
        let old = ConversationCache.Entry(data: legacyData, etag: nil, validatedAt: .now, freshFor: 30)
        let hash = SHA256.hash(data: Data("legacy".utf8)).map { String(format: "%02x", $0) }.joined()
        try PropertyListEncoder().encode(old).write(to: legacyDir.appendingPathComponent("synthetic-\(hash).plist"))
        let legacyEntry = await legacy.cached(scope: "synthetic", id: "legacy")?.entry
        expect(legacyEntry?.data == legacyData && legacyEntry?.allowsStale == nil, "legacy uncompressed records retain their unknown HTTP policy for offline fallback")

        let (policy, _) = suite(root, "policy")
        for control in ["no-store", "no-cache", "must-revalidate"] {
            try await save(policy, control, payload(control, content: original), control: control)
            let entry = await policy.cached(scope: "synthetic", id: control)
            if control == "no-store" { expect(entry == nil, "no-store leaves neither tier") }
            else { expect(entry?.entry.allowsStale == false, "server directives forbid immediate stale display") }
        }
        try await save(policy, "unfinished", payload("unfinished", content: original, unfinished: true))
        expect(await policy.cached(scope: "synthetic", id: "unfinished") == nil, "unfinished server conversations are not persisted")
        try await save(policy, "expired", payload("expired", content: original))
        expect(await policy.cached(scope: "synthetic", id: "expired", now: .now.addingTimeInterval(8 * 86400)) == nil, "both tiers expire together")
        try await save(policy, "denied", payload("denied", content: original))
        do { _ = try await policy.load(scope: "synthetic", id: "denied") { _ in (Data(), response(403)) }; preconditionFailure("denied request succeeded") } catch { }
        expect(await policy.cached(scope: "synthetic", id: "denied") == nil, "permission loss removes both tiers")

        let (races, _) = suite(root, "races")
        let fetched = Fetches()
        let raceData = payload("race", content: original)
        let fetch: @Sendable (String?) async throws -> (Data, HTTPURLResponse) = { etag in
            await fetched.record(etag)
            try await Task.sleep(for: .milliseconds(50))
            return (raceData, response())
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await races.load(scope: "synthetic", id: "race", fetch: fetch) } }
            try await group.waitForAll()
        }
        expect(await fetched.count == 1, "overlapping full-chat hydration shares one request")
        await races.flushForTesting()
        let gate = PreparationGateForTesting.shared
        await gate.hold()
        _ = try await races.load(scope: "synthetic", id: "retained") { _ in (payload("retained", content: original), response()) }
        await races.invalidate(scope: "synthetic", id: "unrelated")
        await gate.release()
        await races.flushForTesting()
        expect(await races.cached(scope: "synthetic", id: "retained") != nil, "unrelated chat mutations preserve already validated pending writes")

        await gate.hold()
        for id in ["targeted", "neighbor"] {
            _ = try await races.load(scope: "synthetic", id: id) { _ in (payload(id, content: original), response()) }
        }
        await races.invalidate(scope: "synthetic", id: "targeted")
        await gate.release()
        await races.flushForTesting()
        let target = await races.cached(scope: "synthetic", id: "targeted")
        let neighbor = await races.cached(scope: "synthetic", id: "neighbor")
        expect(target == nil && neighbor != nil, "targeted invalidation cancels only its pending representation")

        await gate.hold()
        for scope in ["synthetic", "other-session"] {
            _ = try await races.load(scope: scope, id: "session-write") { _ in (payload("session-write", content: original), response()) }
        }
        await races.invalidate(scope: "synthetic")
        await gate.release()
        await races.flushForTesting()
        let clearedScope = await races.cached(scope: "synthetic", id: "session-write")
        let otherScope = await races.cached(scope: "other-session", id: "session-write")
        expect(clearedScope == nil && otherScope != nil, "scope invalidation preserves pending writes from other sessions")

        let pending = Task { try await races.load(scope: "synthetic", id: "cleared") { _ in try await Task.sleep(for: .milliseconds(80)); return (payload("cleared", content: original), response()) } }
        try await Task.sleep(for: .milliseconds(20))
        await races.clear()
        _ = try await pending.value
        expect(await races.cached(scope: "synthetic", id: "cleared") == nil, "clear cannot be undone by a late response")
        _ = try await races.load(scope: "synthetic", id: "preparing") { _ in (payload("preparing", content: details(noise(400_000))), response()) }
        expect(await races.cached(scope: "synthetic", id: "preparing") != nil, "the complete response stays readable during background persistence")
        let draining = Task { await races.flushForTesting() }
        await races.clear()
        await draining.value
        let clearedSize = await races.size()
        expect(await races.cached(scope: "synthetic", id: "preparing") == nil && clearedSize == 0, "clear cannot be undone by background preparation")
        let (disabled, _) = suite(root, "disabled", mb: 0)
        try await save(disabled, "disabled", payload("disabled", content: original))
        expect(await disabled.size() == 0, "disabled cache writes no data")
        print("Passed \(checks) synthetic cache/projection checks.")
    }
}
