import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Custom UTType

extension UTType {
    /// Custom UTType for dragging a chat conversation row.
    static let chatItem = UTType(exportedAs: "com.openui.chat-item")
}

// MARK: - DraggableChat

/// A lightweight Transferable token that carries a conversation ID
/// across drag-and-drop operations within the app.
///
/// Used to drag chat rows into/out of folder rows in `ChatListView`.
struct DraggableChat: Transferable, Codable, Sendable {
    /// The conversation ID being dragged.
    let conversationId: String
    /// The folder ID the chat currently belongs to (nil = no folder).
    let currentFolderId: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .chatItem)
    }
}
