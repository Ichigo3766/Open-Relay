import Foundation

enum InlineImageStore { static func extractAndReplace(content: String) -> String { content } }

@main enum SearchTests {
    @MainActor static func main() async throws {
        var calls: [(String, Int, Int)] = []
        var fail = false
        let model = AttachmentSearchModel { source, query, page, offset in
            calls.append((query, page, offset))
            if fail { throw URLError(.notConnectedToInternet) }
            // Intentionally ignore cancellation: stale responses still must be rejected.
            if query == "slow" { try? await Task.sleep(for: .milliseconds(100)) }
            let items = (offset..<min(offset + 5, 12)).map {
                KnowledgeItem(id: "\($0)", name: query + " Sample \($0)", description: nil, type: source.kind, fileCount: nil)
            }
            return AttachmentSearchPage(items: items, count: items.count, total: 12)
        }
        await model.search("", sources: [.collections], debounce: .zero)
        precondition(model.sections[0].items.count == 5 && model.sections[0].hasMore)
        await model.loadMore(.collections)
        precondition(calls.last?.1 == 2 && calls.last?.2 == 5)
        precondition(model.sections[0].items.count == 10)
        fail = true
        await model.loadMore(.collections)
        precondition(model.sections[0].failed && model.sections[0].items.count == 10)
        fail = false
        await model.loadMore(.collections)
        precondition(model.sections[0].items.count == 12 && !model.sections[0].hasMore)
        let callCount = calls.count
        await model.loadMore(.collections)
        precondition(calls.count == callCount)
        let slow = Task { await model.search("slow", sources: [.collections], debounce: .zero) }
        try await Task.sleep(for: .milliseconds(10))
        await model.search("fresh", sources: [.documents(collectionID: "sample")], debounce: .zero)
        await slow.value
        precondition(model.sections.count == 1 && model.sections[0].items[0].name.hasPrefix("fresh"))
        let canceled = Task { await model.search("slow", sources: [.uploads], debounce: .zero) }
        try await Task.sleep(for: .milliseconds(10))
        model.cancel()
        await canceled.value
        precondition(model.sections[0].items.isEmpty)
        let data = Data(#"{"items":[{"id":"sample","filename":"Sample.txt","meta":{"name":"Display name","content_type":"text/plain"},"data":{"status":"completed"}}],"total":1}"#.utf8)
        let decoded = try AttachmentSearchPage.decode(data, source: .documents(collectionID: "sample"), query: "")
        precondition(decoded.items[0].name == "Display name")
        precondition(decoded.items[0].toChatFileRef()["file"] != nil)
        precondition(decoded.items[0].fileReference?.contentType == "text/plain")
        let folders = try AttachmentSearchPage.decode(Data(#"[{"id":"a","name":"Orchard"},{"id":"b","name":"Ocean"}]"#.utf8), source: .folders, query: "orch")
        precondition(folders.items.count == 1 && folders.items[0].toChatFileRef()["type"] as? String == "folder")
        precondition(AttachmentUsage().title(fullContext: true) == "Entire Document")
        precondition(AttachmentUsage().title(fullContext: false) == "Focused Retrieval")
        precondition(AttachmentUsage(capabilities: ["file_context": "false"]).title(fullContext: true) == "Tools Only")
        precondition(AttachmentUsage(capabilities: ["file_context": "false"], functionCalling: "legacy").title(fullContext: true) == "File Context Disabled")
        precondition(AttachmentUsage(capabilities: ["file_context": "0", "builtin_tools": "0"]).title(fullContext: false) == "File Context Disabled")
        precondition(AttachmentUsage(capabilities: ["file_context": "false"], builtinTools: ["knowledge": false]).title(fullContext: false) == "File Context Disabled")
        print("PASS: search pagination, failed-page retry, stale-response isolation, cancellation, native metadata, and effective context labels")
    }
}
