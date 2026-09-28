import Foundation

@main struct AskUserChecks {
    @MainActor static func main() async {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        let args: [String: Any] = ["allow_other": true, "timeout_ms": 120000, "questions": [
            ["id": "color", "question": "Which paper color?", "allow_other": false,
             "options": [["label": "Blue", "description": "A blue sky"], ["label": "Green", "description": "A green field"]]]
        ]]
        let answers: [String: AskUserAnswerDraft] = ["color": .option(index: 0, label: "Blue", description: "A blue sky")]
        let h = Harness()
        let api = h.manager!.apiClient
        var replies: [[String: Any]] = []
        let reply: (Any?) -> Void = { replies.append($0 as! [String: Any]) }
        h.receiveAskUser(args, messageId: "live-message", reply: reply)
        let live = h.liveAskUserPrompt!
        check(replies.isEmpty, "No automatic answer")
        #if BASELINE
        await h.answerAskUser(messageId: live.messageId, callId: live.callId, answers: answers)
        check(replies.count == 1 && api.requests.isEmpty, "Live answers must use the callback, not REST with an empty call ID")
        #else
        check(!live.questions[0].allowOther, "Per-question prohibition overrides global Other setting")
        check(live.timeoutMs == 120000, "Native timeout preserved")
        await h.resolveAskUser(live, answers: answers)
        check(replies.count == 1 && api.requests.isEmpty, "Live response uses callback without REST")
        check(replies[0]["status"] as? String == "answered", "Native answered status")
        let received = (replies[0]["answers"] as! [String: Any])["color"] as! [String: Any]
        check(received["option_index"] as? Int == 0 && received["label"] as? String == "Blue", "Native option answer")
        await h.resolveAskUser(live, answers: answers)
        check(replies.count == 1, "Duplicate taps cannot answer twice")
        h.receiveAskUser(args, messageId: "next-message", reply: reply)
        let next = h.liveAskUserPrompt!
        await h.resolveAskUser(live, answers: answers)
        check(h.liveAskUserPrompt?.id == next.id && replies.count == 1, "Stale card cannot answer a new prompt")
        await h.resolveAskUser(next)
        check(replies.last?["status"] as? String == "cancelled", "Cancellation uses the native callback")
        check((replies.last?["answers"] as? [String: Any])?.isEmpty == true, "Cancellation has no answers")
        h.receiveAskUser(args, messageId: "cleanup", reply: reply)
        h.cancelLiveAskUser(); h.cancelLiveAskUser()
        check(replies.count == 3 && h.liveAskUserPrompt == nil, "Cleanup cancels exactly once")
        h.receiveAskUser([:], messageId: "malformed", reply: reply)
        check(replies.count == 4 && h.liveAskUserPrompt == nil, "Malformed requests cancel instead of waiting forever")
        h.receiveAskUser(args, messageId: "missing-callback", reply: nil)
        check(h.liveAskUserPrompt == nil, "Do not show an unanswerable live card")
        h.receiveAskUser(args, messageId: "active", reply: reply)
        let activeID = h.liveAskUserPrompt!.id
        h.receiveAskUser(args, messageId: "overlap", reply: reply)
        check(h.liveAskUserPrompt?.id == activeID && replies.last?["status"] as? String == "cancelled", "Overlapping requests cannot replace unanswered questions")
        h.cancelLiveAskUser()
        let saved = PendingAskUserPrompt.fromInfo(.init(messageId: "saved-message", callId: "saved-call", arguments: args))!
        h.pendingAskUserPrompt = saved
        api.fail = true
        await h.resolveAskUser(saved, answers: answers)
        check(h.pendingAskUserPrompt?.id == saved.id && h.askUserError != nil, "Failed saved answer retains the same card for retry")
        check(!h.resolvedAskUserCallIds.contains(saved.callId), "Failed calls must remain discoverable in history")
        check(!h.isResolvingAskUser, "Retry enabled after failure")
        check(api.requests.last?["chat"] as? String == "demo-chat" && api.requests.last?["call"] as? String == "saved-call", "Saved request uses originating chat/message/call context")
        api.fail = false
        await h.resolveAskUser(saved, answers: answers)
        check(h.pendingAskUserPrompt == nil && h.askUserError == nil, "Successful saved retry removes prompt")
        check(h.resolvedAskUserCallIds.contains(saved.callId), "Stale history cannot restore a successfully answered prompt")
        check(api.requests.count == 2 && api.requests.last?["action"] as? String == "answer", "Manual retry sends the same answer route")
        h.pendingAskUserPrompt = saved
        api.fail = true
        await h.resolveAskUser(saved)
        check(h.pendingAskUserPrompt?.id == saved.id && api.requests.last?["action"] as? String == "reject", "Failed saved cancellation also remains retryable")
        api.fail = false; api.suspend = true
        let task = Task { await h.resolveAskUser(saved, answers: answers) }
        while api.gate == nil { await Task.yield() }
        let before = api.requests.count
        await h.resolveAskUser(saved, answers: answers)
        check(api.requests.count == before, "Only one saved response in flight")
        let replacement = PendingAskUserPrompt.fromArguments(args, messageId: "replacement", callId: "other-call")!
        h.pendingAskUserPrompt = replacement
        api.gate?.resume(); await task.value
        check(h.pendingAskUserPrompt?.id == replacement.id, "Late REST success cannot dismiss another prompt")
        var bad = args
        bad["questions"] = [["id": "bad", "question": "Invalid choices", "options": [["label": "No description"]]]]
        check(PendingAskUserPrompt.fromArguments(bad, messageId: "invalid") == nil, "Reject malformed options without changing option indices")
        print("\(count) ask_user checks passed")
        #endif
    }
}
