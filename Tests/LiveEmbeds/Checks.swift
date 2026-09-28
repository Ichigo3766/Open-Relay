import Foundation

@main struct Checks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        let html = "<html><body><h1>Paper stars</h1></body></html>"
        let original = ChatMessage(id: "answer", role: .assistant, content: "A craft preview.")
        var updated = original
        updated.embeds = [html]
        check(original != updated, "Embed-only updates must invalidate message equality")
        let data = try JSONEncoder().encode(updated)
        check(try JSONDecoder().decode(ChatMessage.self, from: data).embeds == [html], "Embeds survive local cache")
        let oldData = try JSONEncoder().encode(original)
        var oldJSON = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        oldJSON.removeValue(forKey: "embeds")
        check(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: oldJSON)).embeds.isEmpty, "Old caches remain readable")
        let node = HistoryNode(id: "answer", role: .assistant, content: original.content, embeds: [html])
        check(node.toServerDict()["embeds"] as? [String] == [html], "Server save preserves embeds")
        var cleared = node; cleared.embeds = []
        check(cleared.toServerDict()["embeds"] as? [String] == [], "Server save preserves explicit clearing")
        #if !BASELINE
        let vm = Harness()
        vm.conversation!.messages = [original]
        vm.conversation!.history.nodes = ["answer": HistoryNode(id: "answer", role: .assistant), "branch": HistoryNode(id: "branch", role: .assistant)]
        vm.applyMessageEmbeds(["embeds": [html]], messageId: "answer", chatId: "demo-chat")
        check(vm.conversation!.messages[0].embeds == [html], "Visible message updates")
        check(vm.conversation!.history.nodes["answer"]!.embeds == [html], "History updates")
        vm.applyMessageEmbeds(["embeds": [html]], messageId: "answer", chatId: "demo-chat")
        check(vm.conversation!.messages[0].embeds.count == 1, "Duplicate listeners replace, not append")
        vm.applyMessageEmbeds(["embeds": []], messageId: "answer", chatId: "different-chat")
        check(vm.conversation!.messages[0].embeds == [html], "Stale chat event ignored")
        for payload in [nil, [:], ["embeds": "invalid"], ["embeds": [1]]] as [[String: Any]?] {
            vm.applyMessageEmbeds(payload, messageId: "answer", chatId: "demo-chat")
            check(vm.conversation!.messages[0].embeds == [html], "Malformed event preserves state")
        }
        vm.applyMessageEmbeds(["embeds": ["replacement"]], messageId: "missing", chatId: "demo-chat")
        check(vm.conversation!.history.nodes.count == 2 && vm.conversation!.messages.count == 1, "Unknown ID cannot create a message")
        vm.applyMessageEmbeds(["embeds": [html]], messageId: "branch", chatId: "demo-chat")
        check(vm.conversation!.history.nodes["branch"]!.embeds == [html], "Inactive branch retained")
        vm.applyMessageEmbeds(["embeds": []], messageId: "answer", chatId: "demo-chat")
        check(vm.conversation!.messages[0].embeds.isEmpty && vm.conversation!.history.nodes["answer"]!.embeds.isEmpty, "Explicit clear updates both copies")
        vm.applyMessageEmbeds(["embeds": [html]], messageId: nil, chatId: "demo-chat")
        check(vm.conversation!.messages[0].embeds.isEmpty, "Missing message ID is not routed to a random response")
        #endif
        print("\(count) live-embed checks passed")
    }
}
