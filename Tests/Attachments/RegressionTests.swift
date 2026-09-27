import Foundation

enum InlineImageStore { static func extractAndReplace(content: String) -> String { content } }

@main enum RegressionTests {
    static func main() throws {
        let reference: [String: Any] = [
            "type": "file", "id": "sample-document", "url": "/api/v1/files/sample-document/content",
            "name": "Sample.txt", "content_type": "text/plain", "context": "full",
            "collection_name": "file-sample-document", "size": 42,
            "file": ["id": "sample-document", "meta": ["name": "Sample.txt", "size": 42]]
        ]
        let node = MessageHistory.parseNode(id: "sample-message", from: [
            "role": "user", "content": "Summarize the sample.", "files": [reference]
        ])
        let saved = (node.toServerDict()["files"] as! [[String: Any]])[0]
        let folder = KnowledgeItem(id: "sample-folder", name: "Sample folder", description: nil,
                                   type: .folder, fileCount: nil).toChatFileRef()
        let checks = [
            (saved["context"] as? String == "full", "Entire Document survives history save"),
            (saved["id"] as? String == "sample-document", "ID remains distinct from URL"),
            (saved["collection_name"] as? String == "file-sample-document", "Retrieval metadata survives"),
            (saved["file"] as? NSDictionary == reference["file"] as? NSDictionary, "Nested file metadata survives"),
            (folder["type"] as? String == "folder", "Folder is not a Knowledge collection")
        ]
        for (passed, label) in checks { print("\(passed ? "PASS" : "FAIL"): \(label)") }
        if checks.contains(where: { !$0.0 }) { exit(1) }
    }
}
