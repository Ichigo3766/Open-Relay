struct Chat {
    var id = "demo-chat"
    var history = MessageHistory()
    var messages: [ChatMessage] = []
}
final class Store {
    var streamingMessageId: String?
    var isFinishing = false
    var isActive = false
    var aborts = 0
    func abortStreaming() { aborts += 1; isFinishing = false; isActive = false; streamingMessageId = nil }
}
