import Foundation

extension StreamingTests {
    @MainActor static func responseTests() async {
        #if !BASELINE
        func item(_ id: String, _ kind: String, _ text: String, done: Bool = false) -> [String: Any] {
            ["id": id, "type": kind, "status": done ? "completed" : "in_progress",
             "content": [["type": "output_text", "text": text]]]
        }
        func delta(_ id: String, _ kind: String, _ text: String, index: Int, part: Int = 0) -> [String: Any] {
            ["type": "response.\(kind).delta", "item_id": id,
             "output_index": index, "content_index": part, "delta": text]
        }
        let acc = ContentAccumulator()
        var deliveries: [String] = []
        acc.onUpdate = { deliveries.append($0) }
        acc.receiveResponse(delta("r", "reasoning_text", "Compare paper", index: 0))
        await waitUntil { !deliveries.isEmpty }
        check(deliveries.last?.contains("Compare paper") == true, "thinking visible before answer or final snapshot")
        check(acc.content.contains("done=\"false\""), "thinking remains active")
        acc.receiveResponse(delta("r", "reasoning_text", " stars.", index: 0))
        acc.receiveResponse(delta("a", "output_text", "Seven stars.", index: 1))
        let expected = MessageHistory.reconstructContentFromOutput([
            item("r", "reasoning", "Compare paper stars.", done: true),
            item("a", "message", "Seven stars.")])!
        check(acc.content == expected, "reasoning-to-answer keeps ordered exact text and completes thinking")

        // A snapshot and subsequent deltas can arrive before the queued UI task.
        // Apply both in socket order, not snapshot-after-delta on the main actor.
        acc.replaceOutput([item("r", "reasoning", "Corrected note.", done: true),
                           item("a", "message", "Seven")])
        acc.receiveResponse(delta("a", "output_text", " stars.", index: 1))
        let corrected = acc.content
        await waitUntil { deliveries.last == corrected }
        check(corrected.contains("Corrected note.") && corrected.hasSuffix("Seven stars."), "snapshot then delta preserved")
        check(!corrected.contains("Compare paper"), "snapshot replaces old reasoning")
        check(corrected.components(separatedBy: "Seven stars.").count == 2, "no duplicate snapshot text")

        acc.replaceOutput([item("a", "message", "Answer")])
        acc.receiveResponse(delta("r", "reasoning_text", "Earlier thought", index: 0))
        acc.receiveResponse(delta("a", "output_text", " continues", index: 1))
        check(acc.content == MessageHistory.reconstructContentFromOutput([
            item("r", "reasoning", "Earlier thought", done: true),
            item("a", "message", "Answer continues")]), "late inserted reasoning uses item identity after index shifts")
        acc.receiveResponse(delta("a", "output_text", " second part", index: 1, part: 1))
        check(acc.content.hasSuffix("Answer continues second part"), "multiple content parts")

        let tool: [String: Any] = ["type": "function_call", "id": "tool", "call_id": "call",
                                   "name": "synthetic_lookup", "status": "in_progress", "arguments": "{}"]
        acc.receiveResponse(["type": "response.output_item.added", "output_index": 2, "item": tool])
        acc.receiveResponse(delta("r2", "reasoning_text", "Second note", index: 3))
        acc.receiveResponse(["type": "response.output_item.done", "output_index": 3,
                             "item": item("r2", "reasoning", "Second note corrected", done: true)])
        acc.receiveResponse(delta("a2", "output_text", "Final answer", index: 4))
        check(acc.content.contains("synthetic_lookup") && acc.content.contains("Second note corrected"), "tool-separated reasoning retained")
        check(acc.content.hasSuffix("Final answer"), "second answer retained")
        let beforeIgnored = acc.content
        acc.receiveResponse(["type": "response.function_call_arguments.delta", "delta": "ignored"])
        acc.receiveResponse(delta("a2", "output_text", "invalid", index: 4, part: -1))
        acc.receiveResponse(delta("a2", "output_text", "invalid", index: 4, part: Int.max))
        check(acc.content == beforeIgnored, "unknown and invalid parts do not alter content")

        acc.replace("Existing continuation. ")
        acc.receiveResponse(delta("a3", "output_text", "New text", index: 0))
        check(acc.content == "Existing continuation. New text", "continuation prefix retained")
        acc.append(" legacy")
        check(acc.content == "Existing continuation. New text legacy", "legacy delta following structured content")
        acc.replaceOutput([])
        acc.replaceOutput([item("pending", "message", "")])
        check(acc.content == "Existing continuation. New text legacy", "non-renderable snapshots retain existing continuation")
        acc.receiveResponse(delta("a4", "output_text", " continues", index: 0))
        check(acc.content == "Existing continuation. New text legacy continues", "delta after empty snapshot keeps continuation")
        acc.replace("")

        // Bursts still produce one pending main-actor delivery, not one task per token.
        deliveries.removeAll()
        for _ in 0..<10_000 {
            acc.receiveResponse(delta("burst", "reasoning_text", "x", index: 0))
        }
        let burst = acc.content
        await waitUntil { deliveries.last == burst }
        check(deliveries.count == 1, "structured burst coalesces delivery")
        check(burst.filter { $0 == "x" }.count == 10_000, "structured burst retains every character")
        acc.replaceOutput([item("burst", "reasoning", "Authoritative final", done: true)])
        let final = acc.content
        await waitUntil { deliveries.last == final }
        check(deliveries.last == final && !final.contains("xxx"), "final snapshot supersedes queued deltas")

        let unindexed = ContentAccumulator()
        unindexed.receiveResponse(delta("invalid", "reasoning_text", "invalid", index: 0, part: Int.max))
        unindexed.receiveResponse(["type": "response.reasoning_text.delta", "delta": "Invented thought"])
        unindexed.receiveResponse(["type": "response.output_text.delta", "delta": "Invented answer"])
        check(unindexed.content == MessageHistory.reconstructContentFromOutput([
            item("r", "reasoning", "Invented thought", done: true), item("a", "message", "Invented answer")]),
              "events without optional indices preserve arrival order")

        let concurrent = ContentAccumulator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1000 {
                        concurrent.receiveResponse(["type": "response.reasoning_text.delta", "item_id": "r",
                                                    "delta": "x", "output_index": 0, "content_index": 0])
                    }
                }
            }
        }
        check(concurrent.content.filter { $0 == "x" }.count == 8000, "concurrent structured producers retain every token")
        #endif
    }
}
