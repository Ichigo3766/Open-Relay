import Foundation

// Synthetic stand-in for the app model; these tests only need sidebar fields.
nonisolated struct Conversation: Sendable {
    var id: String
    var title: String
    var createdAt: Date = Date(timeIntervalSince1970: 1)
    var updatedAt: Date = Date(timeIntervalSince1970: 1)
    var model: String? = nil
    var pinned = false
    var archived = false
    var folderId: String? = nil
    var tags: [String] = []
    var messages: [Message] = []
    var history = History()
    var tasks: [String] = []
    var files: [String] = []
    mutating func rederiveMessages() { messages = history.createMessagesList() }
}

nonisolated struct Message: Sendable {
    enum Role { case assistant }
    var role = Role.assistant
    var model: String? = nil
}
nonisolated struct History: Sendable {
    var isPopulated = false
    func createMessagesList() -> [Message] { isPopulated ? [Message()] : [] }
}
