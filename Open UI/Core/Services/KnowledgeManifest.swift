import Foundation
import CryptoKit

/// Folder import for a knowledge base — mirrors the web client (`KnowledgeBase.svelte`).
///
///  • **Upload directory**: adds every file under the current folder; never deletes.
///  • **Sync directory**: mirrors the picked folder onto the WHOLE knowledge base (paths are
///    not prefixed): unchanged files are skipped, changed ones replaced, files/folders that
///    are missing locally are removed. Always confirm with the user first.
///
/// Like the web (`webkitRelativePath` = "Folder/sub/file.txt"), the picked folder's own name
/// is the first path segment, so it becomes a top-level folder in the knowledge base.
struct KnowledgeSyncResult: Sendable {
    var added = 0, modified = 0, deleted = 0, unmodified = 0, failed = 0
    var failures: [String] = []
    var summary: String {
        var s = "\(added) added, \(modified) modified, \(deleted) deleted, \(unmodified) unchanged"
        if failed > 0 { s += ", \(failed) failed" }
        return s
    }
}

nonisolated struct KnowledgeLocalFile: Sendable {
    let entry: KnowledgeSyncEntry
    let url: URL
}

nonisolated enum KnowledgeManifest {
    /// Anything in or under a dot-folder, and dot-files, is skipped (same as the web).
    private static func isHidden(_ components: [String]) -> Bool {
        components.contains { $0.hasPrefix(".") }
    }

    /// Walks `root` and builds manifest entries (SHA-256 per file).
    /// - Parameter pathPrefix: leading path (the current knowledge folder) for "upload" mode.
    static func build(root: URL, pathPrefix: String) throws -> [KnowledgeLocalFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants]) else { return [] }
        let rootName = root.lastPathComponent
        let rootPath = root.standardizedFileURL.path
        var out: [KnowledgeLocalFile] = []
        for case let url as URL in en.allObjects {
            guard (try? url.resourceValues(forKeys: keys))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            var comps = String(full.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
            guard let filename = comps.popLast(), !isHidden(comps + [filename]) else { continue }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let rel = ([rootName] + comps).joined(separator: "/")
            let path = [pathPrefix, rel].filter { !$0.isEmpty }.joined(separator: "/")
            out.append(KnowledgeLocalFile(
                entry: KnowledgeSyncEntry(path: path, filename: filename, checksum: checksum, size: data.count),
                url: url))
        }
        return out
    }

    /// Files a sync/upload would consider (for the confirmation message).
    static func count(root: URL) -> Int {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants]) else { return 0 }
        let rootPath = root.standardizedFileURL.path
        return en.allObjects.compactMap { $0 as? URL }.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
            let rel = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            return !rel.split(separator: "/").contains { $0.hasPrefix(".") }
        }.count
    }
}
