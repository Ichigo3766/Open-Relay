import Foundation

/// Represents a note with markdown content and optional audio attachments.
///
/// Supports both local-only mode and server-backed mode. When fetched from the
/// OpenWebUI server, notes use the `/api/v1/notes/` endpoints. The server stores
/// content in a nested structure: `data.content.md` for markdown, `data.content.html`
/// for HTML. This model flattens that to a single `content` string (markdown).
struct Note: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
    var audioAttachments: [AudioAttachment]
    var fileAttachments: [FileAttachmentRef]
    var isPinned: Bool
    var folderId: String?

    init(
        id: String = UUID().uuidString,
        title: String = "",
        content: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        tags: [String] = [],
        audioAttachments: [AudioAttachment] = [],
        fileAttachments: [FileAttachmentRef] = [],
        isPinned: Bool = false,
        folderId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
        self.audioAttachments = audioAttachments
        self.fileAttachments = fileAttachments
        self.isPinned = isPinned
        self.folderId = folderId
    }

    // MARK: - Server JSON Parsing

    /// Creates a `Note` from the OpenWebUI server JSON format.
    ///
    /// The server sends timestamps as nanoseconds since epoch. Content is nested
    /// under `data.content.md` (markdown) and `data.content.html`. This matches
    /// the Flutter `Note.fromJson()` which uses `createdAt ~/ 1000` for microseconds.
    static func fromServerJSON(_ json: [String: Any]) -> Note? {
        guard let id = json["id"] as? String else { return nil }
        let title = json["title"] as? String ?? ""

        // Parse nested content: data.content.md
        var markdownContent = ""
        if let data = json["data"] as? [String: Any],
           let content = data["content"] as? [String: Any] {
            markdownContent = content["md"] as? String ?? content["HTML"] as? String ?? ""
        }

        // Parse timestamps (nanoseconds → Date)
        let createdAt = Self.parseTimestamp(json["created_at"])
        let updatedAt = Self.parseTimestamp(json["updated_at"])

        return Note(
            id: id,
            title: title,
            content: markdownContent,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Parses an OpenWebUI timestamp which may be nanoseconds, microseconds,
    /// milliseconds, or seconds since epoch.
    private static func parseTimestamp(_ value: Any?) -> Date {
        guard let value else { return .now }
        let ts: Double
        if let intVal = value as? Int { ts = Double(intVal) }
        else if let dblVal = value as? Double { ts = dblVal }
        else { return .now }

        // Nanoseconds (> 1e18)
        if ts > 1_000_000_000_000_000_000 {
            return Date(timeIntervalSince1970: ts / 1_000_000_000)
        }
        // Microseconds (> 1e15)
        if ts > 1_000_000_000_000_000 {
            return Date(timeIntervalSince1970: ts / 1_000_000)
        }
        // Milliseconds (> 1e12)
        if ts > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: ts / 1_000)
        }
        // Seconds
        return Date(timeIntervalSince1970: ts)
    }

    /// Word count of the note content.
    var wordCount: Int {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    /// A preview of the content, stripped of markdown.
    var contentPreview: String {
        let stripped = content
            .replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[*_]{1,3}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(150))
    }

    // Include mutable fields so SwiftUI detects content changes.
    static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.content == rhs.content
            && lhs.updatedAt == rhs.updatedAt
            && lhs.isPinned == rhs.isPinned
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(updatedAt)
    }
}

/// Reference to an audio recording attached to a note.
struct AudioAttachment: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var fileName: String
    var duration: TimeInterval
    var fileId: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        fileName: String,
        duration: TimeInterval,
        fileId: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.fileName = fileName
        self.duration = duration
        self.fileId = fileId
        self.createdAt = createdAt
    }
}

/// Reference to a file attached to a note.
struct FileAttachmentRef: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var fileName: String
    var fileSize: Int64
    var mimeType: String
    var fileId: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        fileName: String,
        fileSize: Int64 = 0,
        mimeType: String = "application/octet-stream",
        fileId: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.fileId = fileId
        self.createdAt = createdAt
    }
}
