import Foundation

struct User {
    enum Role { case admin, user }
    var id = "owner"
    var role = Role.user
    struct Permissions {
        struct Sharing { var notes = true; var publicNotes = true }
        struct Grants { var allowUsers = true; var allowGroups = true }
        var sharing = Sharing(); var accessGrants = Grants()
    }
    var permissions: Permissions? = Permissions()
}
enum APIError: Error { case responseDecoding(underlying: Error, data: Data?) }
final class APIClient { let network = Network() }
final class Network {
    enum Method { case get, post }
    var authToken: String? = "synthetic"
    var snapshot: [String: Any] = ["id": "note", "user_id": "owner", "write_access": true,
                                  "access_grants": [["principal_type": "future", "principal_id": "opaque", "permission": "custom"]]]
    var writes: [[String: Any]] = []
    var fail = false
    var malformed = false
    var wrongID = false
    var filterPublic = false
    var delay: UInt64 = 0
    func requestRaw(path: String, method: Method = .get, body: Data? = nil, contentType: String? = nil) async throws -> (Data, Int) {
        precondition(path == "/api/v1/notes/note" || path == "/api/v1/notes/note/access/update")
        if let body {
            precondition(method == .post && contentType == "application/json")
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            precondition(Set(object.keys) == ["access_grants"], "Never submit content/title/files")
            writes.append(object)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) } // Deliberately uncooperative transport.
        if fail { throw URLError(.cannotConnectToHost) }
        if malformed { return (Data("{}".utf8), 200) }
        if let body {
            var grants = (try JSONSerialization.jsonObject(with: body) as! [String: Any])["access_grants"] as! [[String: Any]]
            if filterPublic { grants.removeAll { $0["principal_id"] as? String == "*" } }
            snapshot["access_grants"] = grants
        }
        var result = snapshot
        if wrongID { result["id"] = "different" }
        if body != nil { result.removeValue(forKey: "write_access") }
        return (try JSONSerialization.data(withJSONObject: result), 200)
    }
}

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), name); count += 1
        }
        let api = APIClient()
        var current = true
        let model = NoteSharingModel(noteId: "note", api: api, user: User()) { current }
        await model.load()
        check(model.canManage, "Owner manages")
        check(model.entries.count == 1, "Unknown grant retained")
        await model.setAccess(type: "user", id: "reader", permission: "read")
        check(model.entries.count == 2, "User added")
        check(model.grants.contains { $0.principalType == "future" }, "Unrelated grants preserved")
        await model.setAccess(type: "group", id: "team", permission: "write")
        check(model.entries.last?.permission == "write", "Group write")
        check(model.grants.contains { $0.principalId == "team" && $0.permission == "read" }, "Native write also needs explicit read")
        await model.setAccess(type: "user", id: "*", permission: "read")
        check(model.publicPermission == "read", "Public read")
        check(model.entries.count == 3, "Public grant not duplicated as person")
        await model.setAccess(type: "user", id: "*", permission: "write")
        check(model.publicPermission == "write", "Public write")
        check(model.grants.contains { $0.principalId == "*" && $0.permission == "read" }, "Public write retains native read grant")
        await model.setAccess(type: "user", id: "*", permission: nil)
        check(model.publicPermission == "private", "Private removes wildcard only")
        check(model.entries.count == 3, "Private retains people and groups")
        let saved = model.grants
        api.network.fail = true
        await model.setAccess(type: "user", id: "reader", permission: nil)
        check(model.grants == saved && model.error != nil && !model.isBusy, "Failure retains confirmed grants")
        api.network.fail = false
        await model.setAccess(type: "user", id: "reader", permission: nil)
        check(model.entries.count == 2 && model.error == nil, "Retry removes access")
        api.network.malformed = true
        let previous = model.grants
        await model.setAccess(type: "group", id: "team", permission: nil)
        check(model.grants == previous && model.error != nil, "Malformed response does not commit")
        api.network.malformed = false
        api.network.wrongID = true
        await model.setAccess(type: "group", id: "team", permission: nil)
        check(model.grants == previous && model.error != nil, "Wrong note response rejected")
        api.network.wrongID = false
        api.network.filterPublic = true
        await model.setAccess(type: "user", id: "*", permission: "read")
        check(model.publicPermission == "private", "Server filtered response authoritative")
        api.network.delay = 80_000_000
        let before = api.network.writes.count
        let first = Task { await model.setAccess(type: "user", id: "one", permission: "read") }
        try await Task.sleep(nanoseconds: 10_000_000)
        await model.setAccess(type: "user", id: "two", permission: "read")
        await first.value
        check(api.network.writes.count == before + 1, "Double taps single flight")
        let beforeSwitch = model.grants
        let late = Task { await model.setAccess(type: "user", id: "late", permission: "read") }
        try await Task.sleep(nanoseconds: 10_000_000)
        current = false
        await late.value
        check(model.grants == beforeSwitch && !model.canManage, "Late account response ignored")
        let countBefore = api.network.writes.count
        await model.setAccess(type: "user", id: "new", permission: "read")
        check(api.network.writes.count == countBefore, "Old account cannot submit")
        current = true
        api.network.authToken = "different"
        check(!model.canManage, "Changed token rejected")

        for mode in ["reader", "writer", "restricted", "admin", "readonly-owner"] {
            let client = APIClient()
            var user = User()
            if mode == "reader" || mode == "writer" { user.id = "other" }
            if mode == "reader" || mode == "readonly-owner" { client.network.snapshot["write_access"] = false }
            if mode == "restricted" { user.permissions?.sharing.notes = false; user.permissions?.sharing.publicNotes = false }
            if mode == "admin" { user.role = .admin; user.id = "admin"; user.permissions = nil }
            let subject = NoteSharingModel(noteId: "note", api: client, user: user) { true }
            await subject.load()
            await subject.setAccess(type: "user", id: "target", permission: "read")
            check(client.network.writes.count == (mode == "admin" ? 1 : 0), "Permission gate \(mode)")
        }
        for type in ["user", "group"] {
            let client = APIClient(); var user = User()
            if type == "user" { user.permissions?.accessGrants.allowUsers = false }
            else { user.permissions?.accessGrants.allowGroups = false }
            let subject = NoteSharingModel(noteId: "note", api: client, user: user) { true }
            await subject.load(); await subject.setAccess(type: type, id: "target", permission: "read")
            check(client.network.writes.isEmpty, "Blocked principal type \(type)")
        }
        let client = APIClient()
        let subject = NoteSharingModel(noteId: "note", api: client, user: User()) { true }
        await subject.load()
        await subject.setAccess(type: "user", id: "", permission: "read")
        await subject.setAccess(type: "future", id: "opaque", permission: "read")
        await subject.setAccess(type: "user", id: "target", permission: "admin")
        check(client.network.writes.isEmpty, "Invalid edits rejected")
        client.network.snapshot["access_grants"] = [
            ["principal_type": "user", "principal_id": "reader", "permission": "read"],
            ["principal_type": "user", "principal_id": "reader", "permission": "write"]]
        await subject.load()
        check(subject.entries.count == 1 && subject.entries[0].permission == "write", "Collapse native read/write rows")
        await subject.setAccess(type: "user", id: "reader", permission: "read")
        check(subject.grants.count == 1 && subject.grants[0].permission == "read", "Downgrade removes both old grants")
        client.network.delay = 80_000_000
        let savedCancellation = subject.grants
        let cancelled = Task { await subject.setAccess(type: "group", id: "late", permission: "read") }
        try await Task.sleep(nanoseconds: 10_000_000)
        cancelled.cancel(); await cancelled.value
        check(subject.grants == savedCancellation, "Cancelled response not committed")
        await subject.load()
        check(subject.grants.contains { $0.principalId == "late" }, "Reload reflects server outcome after ambiguous cancellation")
        let invalid = APIClient()
        invalid.network.snapshot.removeValue(forKey: "access_grants")
        let unavailable = NoteSharingModel(noteId: "note", api: invalid, user: User()) { true }
        await unavailable.load()
        check(unavailable.note == nil && unavailable.error != nil && !unavailable.canManage, "Missing grants never interpreted as private")
        invalid.network.snapshot["access_grants"] = [["principal_type": "anyone", "principal_id": "*", "permission": "read"]]
        await unavailable.load()
        check(unavailable.entries.count == 1 && !unavailable.canChange(type: "anyone", id: "*"), "Unknown wildcard remains visible and unchanged")
        invalid.network.wrongID = true
        let unmatched = NoteSharingModel(noteId: "note", api: invalid, user: User()) { true }
        await unmatched.load()
        check(unmatched.note == nil && unmatched.error != nil, "Initial wrong note load rejected")
        print("PASS \(count) synthetic sharing checks")
    }
}
