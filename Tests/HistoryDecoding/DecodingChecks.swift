@main struct DecodingChecks {
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(0, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    static func main() throws {
        let subject = Subject()
        if CommandLine.arguments.contains("--benchmark") {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let start = cpu(), wall = ProcessInfo.processInfo.systemUptime
            let conversation = subject.parseFullConversation(json)
            let cpuMS = (cpu() - start) * 1000
            let wallMS = (ProcessInfo.processInfo.systemUptime - wall) * 1000
            var usage = rusage()
            getrusage(0, &usage)
            let count = Int(CommandLine.arguments[3])!
            precondition(conversation.history.nodes.count == count && conversation.messages.count == count)
            precondition(conversation.messages.last?.content.hasPrefix("Invented violet telescope \(count - 1).") == true)
            print(String(data: try JSONSerialization.data(withJSONObject: [
                "rows": count, "cpu_ms": cpuMS, "wall_ms": wallMS,
                "peak_rss_mib": Double(usage.ru_maxrss) / 1048576
            ], options: .sortedKeys), encoding: .utf8)!)
            withExtendedLifetime((json, conversation)) {}
            return
        }
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            precondition(condition, name)
        }
        func decode(_ map: [String: Any], current: Any = "answer", flat: [[String: Any]] = []) throws -> Conversation {
            // Round-trip through Foundation, matching wire JSON rather than native-only dictionaries.
            let wire: [String: Any] = ["id": "fixture-chat", "created_at": 1700000000,
                "chat": ["title": "Invented telescope", "models": ["fixture-model"],
                    "history": ["messages": map, "currentId": current], "messages": flat]]
            return subject.parseFullConversation(try JSONSerialization.jsonObject(
                with: JSONSerialization.data(withJSONObject: wire)) as! [String: Any])
        }
        let user: [String: Any] = ["role": "user", "content": "Invent a violet comet.",
            "timestamp": 1700000000, "parentId": NSNull(), "childrenIds": ["answer", "sibling"]]
        let answer: [String: Any] = ["role": "assistant", "content": "A violet paper comet.",
            "timestamp": 1700000001, "parentId": "user", "childrenIds": [], "done": true,
            "model": "fixture-model", "usage": ["total_tokens": 17],
            "files": [["type": "file", "name": "invented.txt", "url": "https://example.test/invented.txt"]],
            "sources": [["id": "invented-source", "name": "Invented observatory", "url": "https://example.test/comet"]],
            "followUps": ["Invent a paper orbit."], "embeds": ["<p>Invented telescope</p>"],
            "statusHistory": [["action": "invented_lookup", "description": "Invented sample", "done": true]],
            "user": ["id": "invented-author", "name": "Invented astronomer"]]
        var sibling = answer
        sibling["content"] = "Another invented orbit."
        sibling["timestamp"] = 1700000002
        let map: [String: Any] = ["user": user, "answer": answer, "sibling": sibling]
        let conversation = try decode(map)
        check(conversation.history.nodes.count == 3, "inactive branch preserved")
        check(conversation.messages.map(\.id) == ["user", "answer"], "active branch order")
        let message = conversation.messages.last!
        check(message.versions.count == 1 && message.versions[0].id == "sibling", "sibling navigation")
        check(message.content == "A violet paper comet.", "content")
        check(message.usage?["total_tokens"] as? Int == 17, "usage")
        check(message.files.count == 1 && message.sources.count == 1, "files and sources")
        check(message.followUps == ["Invent a paper orbit."], "follow-ups")
        check(message.embeds == ["<p>Invented telescope</p>"], "embeds")
        check(message.statusHistory.first?.description == "Invented sample", "status")
        check(!message.isStreaming && conversation.model == "fixture-model", "model and completion")
        let raw = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: map)) as! [String: [String: Any]]
        var reference = MessageHistory()
        reference.currentId = "answer"
        for (id, value) in raw { reference.nodes[id] = MessageHistory.parseNode(id: id, from: value) }
        check(NSDictionary(dictionary: conversation.history.toServerDict()).isEqual(to: reference.toServerDict()), "all node fields match eager reference")
        check(conversation.messages == reference.createMessagesList(), "all flat fields match eager reference")
        let fallback: [[String: Any]] = [["id": "legacy", "role": "assistant", "content": "Invented legacy reply.", "timestamp": 1700000000]]
        for invalid: Any in [NSNull(), "invented", 7, [], ["invented"]] {
            let broken = try decode(["user": user, "answer": answer, "invalid": invalid], flat: fallback)
            check(broken.messages.map(\.id) == ["legacy"], "malformed map uses legacy fallback")
        }
        check(try decode(map, current: NSNull(), flat: fallback).messages.map(\.id) == ["legacy"], "missing current ID fallback")
        check(try decode([:], current: "missing").messages.isEmpty, "empty history")
        check(try decode(map, current: "missing").messages.isEmpty, "dangling current ID")
        var cyclic = answer
        cyclic["parentId"] = "answer"
        check(try decode(["answer": cyclic]).messages.count == 1, "cycle terminates")
        for text in ["🔭 é العربية 日本語", "<details type=\"reasoning\" done=\"true\"><summary>Thought</summary>Invented thought.</details>\n\nA paper comet."] {
            var variant = answer
            variant["content"] = text
            variant["done"] = false
            variant["error"] = ["content": "Invented error."]
            let result = try decode(["user": user, "answer": variant])
            check(result.messages.last?.content == text, "Unicode and details retained")
            check(result.messages.last?.isStreaming == true, "unfinished node retained")
            check(result.messages.last?.error?.content == "Invented error.", "error retained")
        }
        var output = answer
        output["output"] = [["type": "message", "content": [["type": "output_text", "text": "Invented structured answer."]]]]
        check(try decode(["user": user, "answer": output]).messages.last?.content == "Invented structured answer.", "structured output reconstructed")
        output["originalContent"] = "Original invented answer."
        output["content"] = "Invented outlet replacement."
        check(try decode(["user": user, "answer": output]).messages.last?.content == "Invented outlet replacement.", "outlet replacement retained")
        for count in [2, 17, 128, 1024] {
            var chain: [String: Any] = [:]
            for index in 0..<count {
                var node = index % 2 == 0 ? user : answer
                node["content"] = "Invented violet telescope \(index)."
                node["timestamp"] = 1700000000 + index
                node["parentId"] = index == 0 ? NSNull() : "chain-\(index - 1)" as Any
                node["childrenIds"] = index + 1 < count ? ["chain-\(index + 1)"] : []
                chain["chain-\(index)"] = node
            }
            let result = try decode(chain, current: "chain-\(count - 1)")
            let eager = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: chain)) as! [String: [String: Any]]
            var expected = MessageHistory()
            expected.currentId = "chain-\(count - 1)"
            for (id, value) in eager { expected.nodes[id] = MessageHistory.parseNode(id: id, from: value) }
            check(result.messages == expected.createMessagesList(), "long mixed-role chain matches eager reference")
            check(NSDictionary(dictionary: result.history.toServerDict()).isEqual(to: expected.toServerDict()), "long mixed-role metadata retained")
        }
        print("PASS \(checks) history decoding checks")
    }
}
