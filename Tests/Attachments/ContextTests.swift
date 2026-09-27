import Foundation

enum InlineImageStore { static func extractAndReplace(content: String) -> String { content } }

@main enum ContextTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        precondition(condition, "\(message) at \(line)")
    }
    static func main() throws {
        let references: [[String: Any]] = [
            ["type": "file", "id": "sample", "url": "/api/v1/files/sample/content",
             "name": "Sample.txt", "context": "full", "content_type": "text/plain",
             "collection_name": "file-sample", "size": 42,
             "file": ["id": "sample", "meta": ["name": "Sample.txt", "size": 42]],
             "data": ["content": "Freshly invented sample text.", "status": "completed"]],
            ["type": "collection", "id": "collection", "context": "full", "name": "Sample collection"],
            ["type": "folder", "id": "folder", "name": "Sample folder"],
            ["type": "note", "id": "note", "name": "Sample note"],
            ["type": "chat", "id": "chat", "name": "Sample chat", "status": "processed"],
            ["type": "file", "id": "image", "content_type": "image/png"],
            ["type": "image", "url": "https://example.test/image.png"],
            ["type": "file", "id": "audio", "content_type": "audio/mp4"]
        ]
        let files = references.map(ChatMessageFile.init(serverDictionary:))
        for (source, file) in zip(references, files) {
            let cached = try JSONDecoder().decode(ChatMessageFile.self, from: JSONEncoder().encode(file))
            check(cached == file, "Disk cache round trip")
            let saved = cached.serverDictionary
            for key in source.keys {
                check(NSDictionary(dictionary: [key: saved[key]!]) == NSDictionary(dictionary: [key: source[key]!]), "Preserve \(key)")
            }
        }
        let legacy = try JSONDecoder().decode(ChatMessageFile.self,
            from: Data(#"{"type":"file","url":"legacy","name":"Legacy.txt","contentType":"text/plain"}"#.utf8))
        check(legacy.referenceID == "legacy" && legacy.context == nil, "Old local caches decode")
        let parent = ChatMessage(role: .user, content: "Summarize the sample.", files: files)
        let followUp = ChatMessage(role: .user, content: "Summarize it more briefly.")
        let active = [parent, followUp]
        let saved = AttachmentContext.adding(files, to: [])
        check(saved.count == 6, "Raster images do not become persistent retrieval sources")
        check(ChatMessageFile(type: "file", url: "svg", contentType: "image/svg+xml; charset=utf-8").isContext, "SVG is document context")
        check(!ChatMessageFile(type: "file", url: "png", contentType: " IMAGE/PNG; charset=utf-8").isContext, "Raster MIME normalization")
        check(AttachmentContext.active(saved, in: active) == saved, "Follow-up preserves sources")
        check(AttachmentContext.active([], in: active).isEmpty, "Empty saved list never resurrects history")
        let removed = saved.filter { $0.referenceID != "sample" }
        check(!AttachmentContext.active(removed, in: active).contains { $0.referenceID == "sample" }, "Removal survives reopen")
        let edited = ChatMessage(role: .user, content: "Edited sample.", files: [files[1]])
        check(AttachmentContext.active(saved, in: [edited]) == [files[1]], "Edited and inactive branches do not leak context")
        let assistant = ChatMessage(role: .assistant, content: "Generated file", files: [files[0]])
        check(AttachmentContext.active(saved, in: [assistant]).isEmpty, "Generated files are not user context")
        var focused = files[0]
        focused.context = nil
        let reattached = AttachmentContext.adding([focused, focused], to: saved)
        check(reattached.count == saved.count, "Reattachment deduplicates")
        check(reattached[0].context == nil && reattached[0].serverDictionary["context"] == nil, "Latest explicit mode wins")
        let sameIDFolder = ChatMessageFile(type: "folder", url: "sample", name: "Different type")
        check(AttachmentContext.adding([sameIDFolder], to: saved).count == saved.count + 1, "Type is part of identity")
        for kind in [KnowledgeItem.KnowledgeType.folder, .collection, .file] {
            let item = KnowledgeItem(id: "sample", name: "Sample", description: nil, type: kind, fileCount: nil,
                                     context: "full", fileReference: files[0])
            let reference = item.toChatFileRef()
            check(reference["type"] as? String == kind.rawValue, "Native Knowledge type")
            check(reference["context"] as? String == "full", "Knowledge mode")
            check(reference["file"] != nil, "Knowledge document metadata")
        }
        var history = MessageHistory()
        let first = HistoryNode(id: "first", childrenIds: ["answer"], role: .user,
                                content: "Sample question", files: files)
        let answer = HistoryNode(id: "answer", parentId: "first", role: .assistant, content: "Sample answer")
        history.nodes = [first.id: first, answer.id: answer]
        history.currentId = answer.id
        let serialized = history.toServerDict()["messages"] as! [String: [String: Any]]
        let reopened = MessageHistory.parseNode(id: "first", from: serialized["first"]!)
        check(reopened.files.map(\.serverDictionary) as NSArray == files.map(\.serverDictionary) as NSArray, "Message history metadata round trip")
        check(reopened.files[0].context == "full", "Regeneration input preserves Entire Document")
        print("PASS: \(checks) attachment context checks")
    }
}
