import Foundation

// MARK: - Knowledge Item

/// Represents a knowledge source that can be attached to a chat message.
///
/// Knowledge items come in three flavors matching the OpenWebUI web client:
/// - **Folder**: A chat folder (shown at the top of the `#` picker)
/// - **Collection**: A knowledge base (group of documents with embeddings)
/// - **File**: A knowledge-associated file (not raw uploads — only files in knowledge bases)
///
/// When the user types `#` in the chat input, these items appear in a
/// filterable picker. Selected items are sent in the `files` array of the
/// chat completion request so the server performs RAG retrieval against them.
struct KnowledgeItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
    let type: KnowledgeType
    /// Number of files in a collection (only meaningful for `.collection`).
    let fileCount: Int?

    enum KnowledgeType: String, Sendable, Equatable, Hashable {
        case folder
        case collection
        case file
    }

    /// The SF Symbol icon name for this item type.
    var iconName: String {
        switch type {
        case .folder: return "folder"
        case .collection: return "cylinder.split.1x2"
        case .file: return "doc.text"
        }
    }

    /// The badge label shown next to selected items.
    var typeBadge: String {
        switch type {
        case .folder: return "Folder"
        case .collection: return "Collection"
        case .file: return "File"
        }
    }

    /// Converts this item to the `files` array entry format expected by
    /// the `/api/chat/completions` endpoint.
    ///
    /// Knowledge bases → `{"type": "collection", "id": "...", "name": "..."}`
    /// Folders → `{"type": "collection", "id": "...", "name": "..."}`
    /// Individual files → `{"type": "file", "id": "...", "name": "..."}`
    func toChatFileRef() -> [String: Any] {
        let apiType: String
        switch type {
        case .folder: apiType = "collection"
        case .collection: apiType = "collection"
        case .file: apiType = "file"
        }
        return [
            "type": apiType,
            "id": id,
            "name": name
        ]
    }
}
