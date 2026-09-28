import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        let node = MessageHistory.parseNode(id: "answer", from: ["role": "assistant", "content": "Five paper stars.", "contextSummary": "The synthetic craft uses five sheets."])
        precondition(node.toServerDict()["contextSummary"] as? String == "The synthetic craft uses five sheets.", "Native compaction checkpoint must survive history round trip")
        let legacy = MessageHistory.parseNode(id: "legacy", from: ["role": "user", "context_summary": "Earlier folds."])
        precondition(legacy.toServerDict()["contextSummary"] as? String == "Earlier folds.")
        let empty = MessageHistory.parseNode(id: "empty", from: ["role": "assistant", "contextSummary": ""])
        precondition(empty.toServerDict()["contextSummary"] as? String == "")
        let malformed = MessageHistory.parseNode(id: "invalid", from: ["role": "assistant", "contextSummary": ["invalid": true]])
        precondition(malformed.toServerDict()["contextSummary"] == nil)
        let absent = MessageHistory.parseNode(id: "absent", from: ["role": "assistant"])
        precondition(absent.toServerDict()["contextSummary"] == nil)
        let both = MessageHistory.parseNode(id: "both", from: ["role": "assistant", "contextSummary": "Current", "context_summary": "Legacy"])
        precondition(both.toServerDict()["contextSummary"] as? String == "Current")
        let restored = MessageHistory.parseNode(id: node.id, from: node.toServerDict())
        precondition(restored.toServerDict()["contextSummary"] as? String == "The synthetic craft uses five sheets.")
        precondition(restored.content == node.content)
        print("8 context checkpoint checks passed")
        #if !BASELINE
        var checks = 0
        func check(_ condition: Bool) { precondition(condition); checks += 1 }
        check(ChatContextUsage.parse(nil) == nil)
        check(ChatContextUsage.parse(NSNull()) == nil)
        check(ChatContextUsage.parse(["tokens": -1, "threshold": 8000]) == nil)
        check(ChatContextUsage.parse(["tokens": 20, "threshold": 0]) == nil)
        check(ChatContextUsage.parse(["tokens": "20", "threshold": 8000]) == nil)
        check(ChatContextUsage.parse(["estimated_tokens": 2000, "threshold": 8000])?.fraction == 0.25)
        check(ChatContextUsage.parse(["tokens": 12000, "threshold": 8000])?.fraction == 1.5)
        let vm = Harness()
        vm.conversation?.history.nodes["answer"] = node
        let network = vm.manager!.apiClient.network
        await vm.compactContext()
        check(network.requests.count == 1)
        check(network.requests[0].0 == "/api/v1/chats/demo/compact")
        check(network.requests[0].1 == ["model": "demo-model"])
        check(network.requests[0].2 == 300)
        check(!vm.isCompactingContext && !vm.contextNeedsRefresh)
        check(vm.contextCompactionNotice?.contains("Context compacted") == true)
        check(vm.conversation?.history.nodes["answer"]?.contextSummary == "Five sheets were used.")
        check(vm.conversation?.contextUsage?.tokens == 2000)
        network.fail = true
        await vm.compactContext()
        check(network.requests.count == 2)
        check(vm.contextNeedsRefresh && vm.contextCompactionError != nil)
        check(!vm.isCompactingContext)
        await vm.compactContext()
        check(network.requests.count == 2)
        await vm.compactContext(refreshOnly: true)
        check(network.requests.count == 2 && !vm.contextNeedsRefresh)
        network.fail = false
        vm.manager!.failFetch = true
        await vm.compactContext()
        check(vm.contextNeedsRefresh && vm.contextCompactionError != nil)
        vm.manager!.failFetch = false
        await vm.compactContext(refreshOnly: true)
        check(!vm.contextNeedsRefresh && vm.contextCompactionError == nil)
        check(network.requests.count == 3)
        vm.isStreaming = true
        await vm.compactContext()
        check(network.requests.count == 3)
        vm.isStreaming = false
        vm.conversationId = "local:temporary"
        await vm.compactContext()
        check(network.requests.count == 3)
        vm.conversationId = "demo"
        network.suspend = true
        let pending = Task { await vm.compactContext() }
        while network.continuation == nil { await Task.yield() }
        await vm.compactContext()
        check(network.requests.count == 4)
        vm.conversationId = "other-chat"
        vm.conversation = Chat(id: "other-chat")
        network.continuation!.resume(); network.continuation = nil
        await pending.value
        check(vm.conversation?.contextUsage == nil && vm.contextCompactionNotice == nil)
        await vm.compactContext(refreshOnly: true)
        vm.conversationId = "demo"
        vm.conversation = Chat()
        let accountPending = Task { await vm.compactContext() }
        while network.continuation == nil { await Task.yield() }
        let newManager = Manager()
        newManager.apiClient.network.conversationCacheScope = "other-synthetic-account"
        vm.manager = newManager
        network.continuation!.resume(); network.continuation = nil
        await accountPending.value
        check(vm.conversation?.contextUsage == nil && vm.contextCompactionNotice == nil)
        check(newManager.fetches == 0)
        await vm.compactContext(refreshOnly: true)
        for reason in ["disabled", "empty", "too_short", "other"] {
            newManager.apiClient.network.response = "{\"ok\":true,\"compacted\":false,\"reason\":\"\(reason)\"}"
            await vm.compactContext()
            check(!vm.contextNeedsRefresh && vm.contextCompactionNotice != nil)
        }
        for malformed in ["{}", "{\"ok\":false,\"compacted\":false}", "not-json"] {
            await vm.compactContext(refreshOnly: true)
            newManager.apiClient.network.response = malformed
            await vm.compactContext()
            check(vm.contextNeedsRefresh && vm.contextCompactionError != nil)
        }
        print("\(checks) context usage/API/action checks passed")
        #endif
    }
}
