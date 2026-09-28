import Foundation

@main struct Checks {
    static func main() {
        var failed = 0
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1
            if !condition { failed += 1; print("FAIL: " + label) }
        }
        let output: [[String: Any]] = [["type": "message", "content": [["type": "output_text", "text": "Use red paper."]]]]
        let wire: [String: Any] = ["role": "assistant", "content": "Use tan paper.", "originalContent": "Use red paper.", "output": output]
        let node = MessageHistory.parseNode(id: "answer", from: wire)
        check(node.content == "Use tan paper.", "Saved filter correction takes precedence over unchanged structured output")
        check(node.toServerDict()["originalContent"] as? String == "Use red paper.", "Original text survives history sync")
        let old = ChatMessage(id: "answer", role: .assistant, content: "Use red paper.")
        var updated = old; updated.content = "Use tan paper."
        check(old != updated, "Equal-byte-count corrections invalidate message equality")
        #if !BASELINE
        var cleared = wire; cleared["content"] = ""
        check(MessageHistory.parseNode(id: "answer", from: cleared).content.isEmpty, "Empty correction is authoritative")
        var unfiltered = wire; unfiltered.removeValue(forKey: "originalContent")
        check(MessageHistory.parseNode(id: "answer", from: unfiltered).content == "Use red paper.", "Ordinary rich output still wins over summary content")
        var outputOnly = wire; outputOnly["content"] = "Use red paper."
        outputOnly["output"] = [["type": "message", "content": [["type": "output_text", "text": "Use blue paper."]]]]
        check(MessageHistory.parseNode(id: "answer", from: outputOnly).content == "Use blue paper.", "Output-only corrections still reconstruct")
        let reopened = MessageHistory.parseNode(id: node.id, from: node.toServerDict())
        check(reopened.content == "Use tan paper.", "Correction survives another round trip")
        let vm = Harness()
        vm.conversation!.messages = [old]
        vm.conversation!.history.nodes = ["answer": HistoryNode(id: "answer", role: .assistant, content: old.content), "branch": HistoryNode(id: "branch", role: .assistant, content: "Old branch.")]
        let patch: [String: Any] = ["messages": [["id": "answer", "content": "Use tan paper."]]]
        vm.applyOutletMessages(patch, chatId: "different-chat")
        check(vm.conversation!.messages[0].content == old.content, "Wrong chat ignored")
        vm.applyOutletMessages(patch, chatId: "demo-chat")
        check(vm.conversation!.messages[0].content == "Use tan paper.", "Visible text corrected")
        check(vm.conversation!.history.nodes["answer"]?.content == "Use tan paper.", "History corrected")
        check(vm.conversation!.history.nodes["answer"]?.originalContent == old.content, "Original text retained")
        vm.applyOutletMessages(patch, chatId: "demo-chat")
        check(vm.conversation!.history.nodes["answer"]?.originalContent == old.content, "Duplicate event is idempotent")
        for invalid in [nil, [:], ["messages": "invalid"], ["messages": [["id": "answer", "content": 42]]], ["messages": [["content": "Missing ID"]]], ["messages": [["id": "missing", "content": "Unknown ID"]]]] as [[String: Any]?] {
            vm.applyOutletMessages(invalid, chatId: "demo-chat")
            check(vm.conversation!.messages[0].content == "Use tan paper." && vm.conversation!.history.nodes.count == 2, "Malformed/unknown update ignored")
        }
        vm.applyOutletMessages(["messages": [["id": "branch", "content": "New branch."]]], chatId: nil)
        check(vm.conversation!.history.nodes["branch"]?.content == "New branch.", "Inactive branch corrected")
        check(vm.conversation!.messages.count == 1, "Inactive branch does not become visible")
        vm.streamingStore.streamingMessageId = "answer"
        vm.streamingStore.isActive = true
        vm.applyOutletMessages(["messages": [["id": "answer", "content": "Delayed old correction"]]], chatId: "demo-chat")
        check(vm.streamingStore.aborts == 0 && vm.conversation!.messages[0].content == "Use tan paper.", "New continuation not interrupted")
        vm.streamingStore.isFinishing = true
        vm.applyOutletMessages(["messages": [["id": "answer", "content": ""]]], chatId: "demo-chat")
        check(vm.conversation!.messages[0].content.isEmpty, "Live empty correction applied")
        check(vm.conversation!.history.nodes["answer"]?.content == "", "Live empty correction persists")
        check(vm.streamingStore.aborts == 1 && !vm.streamingStore.isActive, "Obsolete finishing tail removed")
        vm.applyOutletMessages(["messages": [["id": "answer", "content": ""]]], chatId: "demo-chat")
        check(vm.streamingStore.aborts == 1, "Duplicate cannot end stream twice")
        #endif
        print("\(count - failed)/\(count) outlet checks passed")
        if failed > 0 { exit(1) }
    }
}
