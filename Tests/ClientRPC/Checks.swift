import Foundation

// Only transport, cache, and diagnostics are replaced; routing/dispatch are production.
struct Log {
    enum Privacy { case `public` }
    struct Message: ExpressibleByStringInterpolation {
        init(stringLiteral value: String) {}
        init(stringInterpolation: StringInterpolation) {}
        struct StringInterpolation: StringInterpolationProtocol {
            init(literalCapacity: Int, interpolationCount: Int) {}
            mutating func appendLiteral(_ value: String) {}
            mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) {}
        }
    }
    func info(_ value: Message) {}
    func warning(_ value: Message) {}
}
struct ConversationCache {
    static func scope(server: String, token: String?, headers: [String: String]) -> String? { nil }
    static let shared = ConversationCache()
    func invalidate(scope: String, id: String) async {}
}
struct Registration {
    var conversationId: String?
    var sessionId: String?
    var handler: ([String: Any], ((Any?) -> Void)?) -> Void
}
final class Socket {
    let serverConfig = (url: "https://example.test", customHeaders: [String: String]())
    let authToken: String? = "synthetic-token"
    let logger = Log()
    let handlerLock = NSLock()
    var chatHandlers: [String: Registration] = [:]
    let sid: String? = "this-session"
    var replies: [(Int, Any?)] = []
    func emitAck(_ id: Int, data: Any?) { replies.append((id, data)) }
    // PRODUCTION
}
// HELPER

var checks = 0
var failures = 0
func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(label)") }
}
func event(_ type: String, session: String? = "this-session") -> [String: Any] {
    var data: [String: Any] = ["code": "throw new Error('synthetic')", "channel": "demo-channel"]
    data["session_id"] = session
    return ["chat_id": "background-chat", "data": ["type": type, "data": data]]
}
for type in ["execute", "execute:python", "execute:tool", "request:chat:completion"] {
    let socket = Socket()
    socket.dispatchChatEvent(event(type), ackId: 7)
    check(socket.replies.count == 1, "\(type) replies without an open chat")
    let reply = socket.replies.first?.1 as? [String: Any]
    check(reply?["error"] as? String != nil, "\(type) reports unsupported execution")
    check(reply?["status"] as? Bool == false, "\(type) never fakes success")
    if type == "execute:python" {
        check(reply?["stderr"] as? String != nil && reply?["result"] is NSNull, "Python returns native error fields")
    }
    var deliveries = 0
    socket.chatHandlers = ["one": Registration(conversationId: nil, sessionId: nil, handler: { _, ack in deliveries += 1; ack?(true) }),
                           "two": Registration(conversationId: nil, sessionId: nil, handler: { _, ack in deliveries += 1; ack?(true) })]
    socket.dispatchChatEvent(event(type), ackId: 8)
    check(socket.replies.count == 2 && deliveries == 0, "\(type) is acknowledged once, before fan-out")
    socket.dispatchChatEvent(event(type, session: "other-session"), ackId: 9)
    check(socket.replies.count == 2 && deliveries == 0, "\(type) ignores another session")
    socket.dispatchChatEvent(event(type), ackId: nil)
    check(socket.replies.count == 2 && deliveries == 0, "\(type) without callback is not falsely handled by a view")
    socket.dispatchChatEvent(event(type, session: nil), ackId: 10)
    check(socket.replies.count == 3, "\(type) supports server-targeted legacy calls without embedded session")
}
let socket = Socket()
var received = 0
socket.chatHandlers["active"] = Registration(conversationId: "background-chat", sessionId: nil, handler: { _, ack in received += 1; ack?(false) })
socket.dispatchChatEvent(event("confirmation"), ackId: 11)
check(received == 1 && socket.replies.first?.1 as? Bool == false, "confirmation remains with the user-facing handler")
socket.dispatchChatEvent(event("chat:completion"))
check(received == 2, "ordinary completion dispatch is unchanged")
print("\(checks - failures)/\(checks) client RPC checks passed")
if failures != 0 { exit(1) }
