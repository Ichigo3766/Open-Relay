import Foundation
import UniformTypeIdentifiers

/// Metadata only. Constructing or displaying a reference never accesses the file.
nonisolated struct TerminalFileAttachment: Hashable, Sendable, Identifiable {
    let serverId: String
    let path: String
    var sessionId: String?
    let name: String
    let contentType: String
    let size: Int64?
    let inline: Bool

    var id: String { [serverId, sessionId ?? "", path].joined(separator: "\0") }
    var isMedia: Bool {
        [UTType(mimeType: contentType), UTType(filenameExtension: (name as NSString).pathExtension)]
            .compactMap { $0 }.contains { $0.conforms(to: .movie) || $0.conforms(to: .audio) }
    }

    init?(result: String?, arguments: String? = nil) {
        guard let file = Self.object(result), file["source"] as? String == "open_terminal",
              file["type"] as? String == "file", file["exists"] as? Bool != false else { return nil }
        self.init(file: file, inline: Self.object(arguments)?["inline"] as? Bool ?? file["displayed"] as? Bool ?? false)
    }

    /// Current live events may contain only a path. Only the originating request
    /// may supply the missing terminal; never guess a terminal from another chat.
    init?(event: [String: Any], serverId: String?, sessionId: String) {
        var file = event
        if file["terminal_id"] == nil && file["terminal_selector"] == nil { file["terminal_id"] = serverId }
        file["session_id"] = file["session_id"] ?? sessionId
        self.init(file: file, inline: event["inline"] as? Bool ?? false)
    }

    private init?(file: [String: Any], inline: Bool) {
        guard let server = (file["terminal_id"] as? String ?? file["terminal_selector"] as? String),
              !server.isEmpty, server != ".", server != "..",
              server.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0) }),
              let path = file["full_path"] as? String ?? file["path"] as? String,
              !path.isEmpty, !path.contains("\0"), file["exists"] as? Bool != false else { return nil }
        self.serverId = server
        self.path = path
        sessionId = (file["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let filename = ((file["name"] as? String ?? path) as NSString).lastPathComponent
        name = filename.isEmpty || filename == "." || filename == ".." ? "file" : filename
        contentType = file["content_type"] as? String ?? file["mime_type"] as? String ?? "application/octet-stream"
        size = (file["size"] as? NSNumber)?.int64Value
        self.inline = inline
    }

    static func merged(_ files: [Self], sessionId: String?) -> [Self] {
        var seen = Set<String>()
        return files.compactMap { file in
            var resolved = file
            resolved.sessionId = file.sessionId ?? sessionId
            return seen.insert(resolved.id).inserted ? resolved : nil
        }
    }

    private static func object(_ text: String?) -> [String: Any]? {
        guard let text else { return nil }
        var value: Any = text
        // Some providers JSON-encode the result string twice.
        for _ in 0..<3 {
            guard let string = value as? String, let data = string.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { break }
            value = decoded
        }
        return value as? [String: Any]
    }
}
