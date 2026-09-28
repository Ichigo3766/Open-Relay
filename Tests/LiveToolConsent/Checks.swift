import Foundation

@main struct Checks {
    @MainActor static func main() {
        var count = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
        let prompts = ChatEventPrompts()
        var replies: [Any] = []
        let ack: (Any?) -> Void = { replies.append($0 ?? NSNull()) }
        prompts.receive(type: "confirmation", payload: ["title": "Use the demo tool?"], active: true, reply: ack)
        check(replies.isEmpty, "No automatic approval")
        let first = prompts.requests[0].id
        prompts.receive(type: "input", payload: ["value": "demo", "placeholder": "Label"], active: true, reply: ack)
        check(prompts.requests.count == 2, "Concurrent prompts remain queued")
        let second = prompts.requests[1].id
        prompts.respond(id: second, value: "out of order")
        check(replies.isEmpty, "Cannot answer a hidden prompt")
        prompts.respond(id: first, value: true)
        prompts.respond(id: first, value: true)
        check(replies.count == 1 && replies[0] as? Bool == true, "Explicit approval sent once")
        check(prompts.requests.first?.value == "demo", "Input default preserved")
        check(prompts.requests.first?.placeholder == "Label", "Input placeholder preserved")
        prompts.respond(id: second, value: "new label")
        check(replies.last as? String == "new label", "User input sent without coercion")
        check(prompts.requests.isEmpty, "Completed prompts removed")
        for type in ["confirmation", "input"] {
            prompts.receive(type: type, payload: [:], active: true, reply: ack)
        }
        let stale = prompts.requests[0].id
        prompts.cancelAll()
        check(replies.suffix(2).allSatisfy { $0 as? Bool == false }, "Cleanup denies all pending calls")
        let before = replies.count
        prompts.cancelAll()
        prompts.respond(id: stale, value: true)
        check(replies.count == before, "Cleanup and late taps are idempotent")
        prompts.receive(type: "confirmation", payload: [:], active: false, reply: ack)
        check(prompts.requests.isEmpty && replies.last as? Bool == false, "Late event cannot approve a finished stream")
        prompts.receive(type: "input", payload: nil, active: true, reply: ack)
        check(prompts.requests.isEmpty && replies.last as? Bool == false, "Malformed call denied")
        prompts.receive(type: "input", payload: [:], active: true, reply: nil)
        check(prompts.requests.isEmpty, "No unanswerable dialog without callback")
        prompts.receive(type: "notification", payload: ["content": "Demo completed"], active: false, reply: nil)
        check(prompts.notice?.message == "Demo completed", "Notifications visible after completion")
        prompts.receive(type: "input", payload: ["input": ["type": "select", "options": ["blue", ["label": "Green", "value": "green"]]]], active: true, reply: ack)
        let request = prompts.requests[0]
        check(request.inputType == "select", "Nested input type supported")
        check(request.options.map(\.label) == ["blue", "Green"], "String and labelled options parsed")
        check(request.options.map(\.value) == ["blue", "green"], "Option values preserved")
        prompts.cancelAll()
        prompts.receive(type: "input", payload: ["type": "password"], active: true, reply: ack)
        check(prompts.requests[0].inputType == "password", "Legacy password input parsed")
        prompts.cancelAll()
        let transport = Transport()
        transport.emitAck(7, data: true, sessionId: "first")
        check(transport.sent == ["437[true]"], "Native Socket.IO boolean response")
        transport.emitAck(8, data: "paper", sessionId: "first")
        check(transport.sent.last == "438[\"paper\"]", "Native Socket.IO input response")
        transport.isConnected = false
        transport.emitAck(9, data: true, sessionId: "first")
        check(transport.sent.count == 2, "Disconnected session cannot receive a reply")
        transport.isConnected = true
        transport.sid = "second"
        transport.emitAck(9, data: true, sessionId: "first")
        transport.emitAck(9, data: true, sessionId: nil)
        check(transport.sent.count == 2, "Old or absent session cannot reply after reconnect")
        print("\(count) consent checks passed")
    }
}
