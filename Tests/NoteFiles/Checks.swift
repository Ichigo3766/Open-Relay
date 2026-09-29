import Foundation

enum Method { case post }
@MainActor final class NetworkManager {
    var authToken: String? = "synthetic-token"
    var writes = [[String: Any]]()
    var failure = false
    var dropAddition = false
    var wrongId = false
    var afterWrite: (() -> Void)?
    var files: [[String: Any]] = [["id": "guide", "type": "file", "name": "guide.txt",
        "file": ["meta": ["content_type": "text/plain", "size": 80]], "extra": ["nested": [true, 42, NSNull()] as [Any]]]]
    var writable = true
    var malformed = false
    var readDelay = false
    var emptyData = false
    var nullFiles = false
    var reads = 0
    func snapshot() -> [String: Any] {
        if emptyData { return ["id": "paper", "data": NSNull(), "write_access": writable] }
        if nullFiles { return ["id": "paper", "data": ["files": NSNull()], "write_access": writable] }
        return ["id": wrongId ? "other" : "paper", "write_access": writable,
         "data": ["content": ["json": ["rich": true], "html": "<p>Keep me</p>"],
                  "versions": [["revision": 2]], "files": malformed ? "invalid" : files as Any]]
    }
    func requestRaw(path: String, method: Method, body: Data, contentType: String) async throws -> (Data, Int) {
        precondition(path == "/api/v1/notes/paper/update" && contentType == "application/json")
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        precondition(Set(json.keys) == ["data"])
        let data = json["data"] as! [String: Any]
        precondition(Set(data.keys) == ["files"])
        writes.append(json)
        if failure { throw URLError(.timedOut) }
        if !dropAddition { files = data["files"] as! [[String: Any]] }
        afterWrite?()
        return (try JSONSerialization.data(withJSONObject: snapshot()), 200)
    }
}
@MainActor final class APIClient {
    let network = NetworkManager()
    var uploads = [Data]()
    var uploadFails = false
    var duringUpload: (() async -> Void)?
    func getNoteById(_ id: String) async throws -> [String: Any] {
        network.reads += 1
        if network.readDelay { try await Task.sleep(for: .seconds(5)) }
        return network.snapshot()
    }
    func uploadFile(data: Data, fileName: String) async throws -> (fileId: String, fileObject: [String: Any]) {
        uploads.append(data)
        await duringUpload?()
        if uploadFails { throw URLError(.cannotConnectToHost) }
        return ("new-file", ["id": "new-file", "meta": ["collection_name": "file-new-file", "content_type": "text/plain"]])
    }
}

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1; print("PASS \(name)") }
        let bytes = Data("Fold a square into a lantern.".utf8)
        let api = APIClient()
        var current = true
        let model = NoteFilesModel(noteId: "paper", api: api) { current }
        let loaded = await model.load()
        check(loaded?["id"] as? String == "paper" && api.network.reads == 1, "editor can share the attachment snapshot without a second request")
        check(model.files.count == 1 && model.canEdit, "native files loaded with write access")
        check(api.uploads.isEmpty && api.network.writes.isEmpty, "load is read-only")
        check(model.files[0].size == 80 && model.files[0].contentType == "text/plain", "nested metadata decoded")
        let unknown = model.files[0].raw
        api.network.failure = true
        await model.attach(data: bytes, name: "folds.txt")
        check(model.error != nil && model.pending?.fileId == "new-file", "failed save retains uploaded reference")
        check(model.files.count == 1 && api.network.writes.count == 1, "failed save keeps confirmed list, no auto retry")
        await model.attach(data: bytes, name: "another.txt")
        check(api.uploads.count == 1, "pending reference cannot be silently overwritten")
        await model.retryAttachment()
        check(api.uploads.count == 1 && api.network.writes.count == 2, "retry never reuploads bytes")
        api.network.failure = false
        api.network.files.append(["id": "concurrent", "type": "file", "name": "other.txt"])
        await model.retryAttachment()
        check(model.pending == nil && model.files.count == 3, "retry saves and preserves other client additions")
        check(NSDictionary(dictionary: model.files[0].raw).isEqual(to: unknown), "unknown metadata round trips intact")
        check(model.files.last?.raw["collection_name"] as? String == "file-new-file", "native collection metadata retained")
        check((model.files.last?.raw["file"] as? [String: Any])?["id"] as? String == "new-file", "full uploaded file reference retained")
        let reopened = NoteFilesModel(noteId: "paper", api: api) { current }
        await reopened.load()
        check(reopened.files.count == 3, "reopen restores attachments")
        await reopened.remove(reopened.files.last!)
        check(reopened.files.count == 2, "remove confirmed by server")
        check(api.network.files.count == 2, "remove survives future reload")
        check(api.uploads.count == 1, "remove does not upload or delete underlying file")
        api.network.failure = true
        await reopened.remove(reopened.files[0])
        check(reopened.error != nil && reopened.files.count == 2, "failed removal keeps attachment visible")
        api.network.failure = false
        api.network.writable = false
        let oldWrites = api.network.writes.count
        await reopened.remove(reopened.files[0])
        check(api.network.writes.count == oldWrites && !reopened.canEdit, "fresh permission check prevents stale writes")
        await reopened.attach(data: bytes, name: "blocked.txt")
        check(api.uploads.count == 1, "read-only blocks upload")
        api.network.writable = true
        await reopened.load()
        api.duringUpload = { await reopened.attach(data: bytes, name: "duplicate.txt") }
        await reopened.attach(data: bytes, name: "one.txt")
        check(api.uploads.count == 2 && reopened.files.count == 3, "single-flight upload and save")
        api.duringUpload = nil
        await reopened.attach(data: bytes, name: "same.txt")
        check(reopened.files.count == 3, "same uploaded file is not attached twice")
        await reopened.attach(data: Data(), name: "empty.txt")
        check(reopened.error != nil && api.uploads.count == 3, "empty import rejected before upload")
        api.uploadFails = true
        await reopened.attach(data: bytes, name: "failed.txt")
        check(reopened.error != nil && reopened.pending == nil && reopened.files.count == 3, "upload failure never appears saved")
        api.uploadFails = false
        api.network.malformed = true
        await reopened.load()
        check(reopened.error != nil && reopened.files.count == 3, "malformed list cannot replace known references")
        let writesBeforeMalformed = api.network.writes.count
        await reopened.remove(reopened.files[0])
        check(api.network.writes.count == writesBeforeMalformed, "malformed fresh list blocks destructive rewrite")
        api.network.malformed = false
        current = false
        await reopened.remove(reopened.files[0])
        check(api.network.writes.count == writesBeforeMalformed, "account switch blocks new writes")
        current = true
        api.network.authToken = "changed"
        await reopened.load()
        check(reopened.files.count == 3, "token change ignores old model")
        api.network.authToken = "synthetic-token"
        api.network.readDelay = true
        let cancelled = Task { await reopened.remove(reopened.files[0]) }
        await Task.yield(); cancelled.cancel(); await cancelled.value
        check(api.network.writes.count == writesBeforeMalformed && !reopened.isBusy, "cancel before save is safe")
        api.network.readDelay = false
        api.network.afterWrite = { current = false }
        await reopened.remove(reopened.files[0])
        check(reopened.files.count == 3, "late reply after account change ignored")
        current = true
        api.network.afterWrite = nil
        api.network.wrongId = true
        await reopened.load()
        check(reopened.error != nil && reopened.files.count == 3, "wrong note rejected")
        let image = NoteFileReference(["id": "image", "type": "image", "url": "data:image/png;base64,AA=="])
        check(image.isImage && image.name == "Image" && image.icon == "photo", "native inline image represented")
        let unknownType = NoteFileReference(["id": "future", "type": "future", "opaque": ["v": 1]])
        check(!unknownType.matches(image), "unsupported references remain distinct")
        check(!NoteFileReference(["id": "guide", "type": "collection"]).matches(model.files[0]), "same ID in another resource type remains distinct")
        api.network.wrongId = false
        api.network.emptyData = true
        await reopened.load()
        check(reopened.error == nil && reopened.files.isEmpty, "null note data is a valid empty note")
        api.network.emptyData = false
        api.network.nullFiles = true
        await reopened.load()
        check(reopened.error == nil && reopened.files.isEmpty, "null files is a valid empty list")
        let unconfirmedAPI = APIClient()
        let unconfirmed = NoteFilesModel(noteId: "paper", api: unconfirmedAPI) { true }
        await unconfirmed.load()
        unconfirmedAPI.network.dropAddition = true
        await unconfirmed.attach(data: bytes, name: "unconfirmed.txt")
        check(unconfirmed.error != nil && unconfirmed.pending != nil && unconfirmed.files.count == 1,
              "success status without the attachment is not treated as a saved reference")
        unconfirmedAPI.network.dropAddition = false
        await unconfirmed.retryAttachment()
        check(unconfirmed.pending == nil && unconfirmed.files.count == 2 && unconfirmedAPI.uploads.count == 1,
              "unconfirmed attachment retry reuses the original upload")
        unconfirmedAPI.network.afterWrite = { unconfirmedAPI.network.wrongId = true }
        await unconfirmed.remove(unconfirmed.files[0])
        check(unconfirmed.error != nil && unconfirmed.files.count == 2,
              "wrong-note update response cannot replace the visible list")
        let changedAPI = APIClient()
        var uploadAccountIsCurrent = true
        let changed = NoteFilesModel(noteId: "paper", api: changedAPI) { uploadAccountIsCurrent }
        await changed.load()
        changedAPI.duringUpload = { uploadAccountIsCurrent = false }
        await changed.attach(data: bytes, name: "late.txt")
        check(changedAPI.network.writes.isEmpty && changed.pending == nil,
              "account change during upload prevents attaching its late result")
        print("\(count) focused checks passed")
    }
}
