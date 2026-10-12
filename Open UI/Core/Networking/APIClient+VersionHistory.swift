import Foundation

/// Version history routes for models, tools, functions and skills.
extension APIClient {

    /// GET `.../history?page=N` — 20 per page, newest first, pages from 1.
    func getResourceHistory(_ resource: VersionedResource) async throws -> [ResourceVersion] {
        let (path, query) = resource.base
        var all: [ResourceVersion] = []
        var page = 1
        while page < 50 {
            let (data, _) = try await network.requestRaw(
                path: "\(path)/history",
                queryItems: query + [URLQueryItem(name: "page", value: "\(page)")],
                deduplicate: false,
                pathIsEncoded: true
            )
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            all.append(contentsOf: rows.compactMap(ResourceVersion.init(json:)))
            if rows.count < 20 { break }
            page += 1
        }
        return all
    }

    /// GET `.../history/diff?from_id=&to_id=`.
    func getResourceDiff(_ resource: VersionedResource, from: String, to: String) async throws -> ResourceVersionDiff {
        let (path, query) = resource.base
        let (data, _) = try await network.requestRaw(
            path: "\(path)/history/diff",
            queryItems: query + [URLQueryItem(name: "from_id", value: from), URLQueryItem(name: "to_id", value: to)],
            deduplicate: false,
            pathIsEncoded: true
        )
        return ResourceVersionDiff(json: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    /// GET skills `.../history/diff/file?from_id=&to_id=&path=` — one file's patch.
    func getSkillFileDiff(skillId: String, from: String, to: String, path filePath: String) async throws -> (lines: [String], binary: Bool) {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/skills/id/\(skillId.encodedPathSegment)/history/diff/file",
            queryItems: [
                URLQueryItem(name: "from_id", value: from),
                URLQueryItem(name: "to_id", value: to),
                URLQueryItem(name: "path", value: filePath),
            ],
            deduplicate: false,
            pathIsEncoded: true
        )
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let diff = json["diff"] as? String ?? ""
        return (diff.isEmpty ? [] : diff.components(separatedBy: "\n"), json["binary"] as? Bool ?? false)
    }

    /// DELETE `.../history/{history_id}` — the live version can't be deleted.
    func deleteResourceVersion(_ resource: VersionedResource, versionId: String) async throws {
        let (path, query) = resource.base
        _ = try await network.requestRaw(
            path: "\(path)/history/\(versionId.encodedPathSegment)",
            method: .delete,
            queryItems: query,
            pathIsEncoded: true
        )
    }

    /// POST `.../update/version` — makes a saved version the live one.
    /// Skills also send the currently-live version id (optimistic concurrency).
    func setResourceVersion(_ resource: VersionedResource, versionId: String, expectedVersionId: String? = nil) async throws {
        let (path, query) = resource.base
        var body: [String: Any] = ["version_id": versionId]
        if resource.isSkill { body["expected_version_id"] = expectedVersionId.map { $0 as Any } ?? NSNull() }
        _ = try await network.requestRaw(
            path: "\(path)/update/version",
            method: .post,
            queryItems: query,
            body: try JSONSerialization.data(withJSONObject: body),
            pathIsEncoded: true
        )
    }
}
