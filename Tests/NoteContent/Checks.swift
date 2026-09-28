import Foundation

@main struct Checks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        let manager = NotesManager(), api = manager.apiClient!
        let initial = api.network.data as NSDictionary
        let json: [String: Any] = ["id": "demo-note", "title": "Paper stars", "data": api.network.data]
        var note = Note.fromServerJSON(json)!
        note.title = "Paper star instructions"
        #if BASELINE
        await manager.updateNote(note)
        check(initial == api.network.data as NSDictionary, "Renaming must preserve rich content")
        #else
        check(await manager.updateNote(note), "Rename succeeds")
        check(initial == api.network.data as NSDictionary, "Rename preserves JSON, HTML, files, and versions")
        check(api.network.writes.last?["data"] == nil, "Metadata-only save omits content entirely")
        check(api.network.writes.last?["title"] as? String == note.title, "New title still sent")
        note.fileAttachments = [.init(fileName: "demo.txt", fileId: "synthetic-file")]
        _ = await manager.updateNote(note)
        check(initial == api.network.data as NSDictionary, "Local attachment bookkeeping cannot replace rich body")
        note.content = "Updated paper stars"
        check(await manager.updateNote(note, contentChanged: true), "Explicit body edit succeeds")
        let edited = api.network.data["content"] as! [String: Any]
        check(edited["md"] as? String == note.content, "Explicit Markdown change is submitted")
        check(edited["html"] as? String == "" && edited["HTML"] == nil, "Native lowercase HTML key")
        check(edited["json"] is NSNull, "Old rich JSON is deliberately cleared on a Markdown edit")
        check((api.network.data["files"] as! NSArray) == initial["files"] as! NSArray, "Body edits preserve outer attachments")
        check((api.network.data["versions"] as! NSArray) == initial["versions"] as! NSArray, "Body edits preserve outer versions")
        api.network.fail = true
        note.content = "Unsaved paper stars"
        check(await manager.updateNote(note, contentChanged: true) == false, "Failed saves are not reported successful")
        check(manager.cached?.content == note.content, "Failed body edit remains in local cache")
        api.network.fail = false
        check(await manager.updateNote(note, contentChanged: true), "Explicit retry saves the same body")
        let htmlOnly: [String: Any] = ["id": "html-note", "data": ["content": ["html": "<p>Blue paper</p>"]]]
        check(Note.fromServerJSON(htmlOnly)?.content == "<p>Blue paper</p>", "Native HTML-only fallback is not blank")
        let legacy: [String: Any] = ["id": "old-note", "data": ["content": ["HTML": "<p>Green paper</p>"]]]
        check(Note.fromServerJSON(legacy)?.content == "<p>Green paper</p>", "Legacy uppercase fallback remains readable")
        let fresh = try await api.createNote(title: "Fresh note", markdownContent: "Fresh paper", htmlContent: "<p>Fresh paper</p>")
        let created = (fresh["data"] as! [String: Any])["content"] as! [String: Any]
        check(created["html"] as? String == "<p>Fresh paper</p>" && created["HTML"] == nil, "Creation also uses the native key")
        manager.apiClient = nil
        check(await manager.updateNote(note, contentChanged: true), "Local-only storage remains usable")
        print("\(count) note-content checks passed")
        #endif
    }
}
