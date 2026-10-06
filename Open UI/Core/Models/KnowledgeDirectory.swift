import Foundation

// MARK: - Knowledge directories
//
// Server: `GET /api/v1/knowledge/{id}/files?directory_id=` returns
// `{ items, directories, breadcrumbs, total }`. `directory_id` omitted = everything,
// `""` = root only, `<id>` = that folder.

struct KnowledgeDirectory: Identifiable, Hashable, Sendable {
    let id: String
    let knowledgeId: String
    let parentId: String?
    var name: String
    let createdAt: Date?
    let updatedAt: Date?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.knowledgeId = json["knowledge_id"] as? String ?? ""
        self.parentId = json["parent_id"] as? String
        func date(_ v: Any?) -> Date? {
            if let i = v as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
            if let d = v as? Double { return Date(timeIntervalSince1970: d) }
            return nil
        }
        self.createdAt = date(json["created_at"])
        self.updatedAt = date(json["updated_at"])
    }
}

/// One page of a knowledge base folder listing.
struct KnowledgeFolderPage: Sendable {
    var files: [KnowledgeFileEntry]
    var directories: [KnowledgeDirectory]
    var breadcrumbs: [KnowledgeDirectory]
    var total: Int
}

/// Server-side file list sort (`order_by` / `direction`).
enum KnowledgeFileSort: String, CaseIterable, Identifiable {
    case nameAsc, nameDesc, updatedDesc, createdDesc
    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAsc: return "Name (A–Z)"
        case .nameDesc: return "Name (Z–A)"
        case .updatedDesc: return "Recently updated"
        case .createdDesc: return "Recently created"
        }
    }

    var query: (orderBy: String, direction: String) {
        switch self {
        case .nameAsc: return ("name", "asc")
        case .nameDesc: return ("name", "desc")
        case .updatedDesc: return ("updated_at", "desc")
        case .createdDesc: return ("created_at", "desc")
        }
    }
}

/// Entry of the local manifest sent to `/sync/diff`.
nonisolated struct KnowledgeSyncEntry: Sendable {
    let path: String      // folder path relative to the synced root, "" for root
    let filename: String
    let checksum: String  // SHA-256 of the file bytes
    let size: Int         // byte count
}

struct KnowledgeSyncDiff: @unchecked Sendable {
    var added: [[String: Any]] = []        // {filename, path}
    var modified: [[String: Any]] = []     // {filename, path, stale_file_id}
    var deleted: [[String: Any]] = []      // {file_id, filename}
    var mkdir: [String] = []               // directory paths to create (shallowest first)
    var rmdir: [String] = []               // directory IDs to remove
    var unmodifiedCount = 0
    var directoryMap: [String: String] = [:]  // existing path → directory ID
}

