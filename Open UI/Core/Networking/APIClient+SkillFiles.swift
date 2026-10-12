import Foundation

/// Skill files, import and clone.
extension APIClient {

    struct SkillFileSummary: Identifiable, Hashable, Sendable {
        let path: String
        let size: Int
        let encoding: String?
        var id: String { path }
        var isBinary: Bool { encoding != nil }
    }

    /// GET `/skills/id/{id}/files` — the file tree (SKILL.md, scripts, references…).
    func getSkillFiles(skillId: String) async throws -> (versionId: String?, files: [SkillFileSummary]) {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/skills/id/\(skillId.encodedPathSegment)/files",
            deduplicate: false,
            pathIsEncoded: true
        )
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let files = (json["files"] as? [[String: Any]] ?? []).compactMap { f -> SkillFileSummary? in
            guard let path = f["path"] as? String else { return nil }
            return SkillFileSummary(path: path, size: f["size"] as? Int ?? 0, encoding: f["encoding"] as? String)
        }
        return (json["version_id"] as? String, files)
    }

    /// GET `/skills/id/{id}/files/content?path=&version_id=` — raw bytes of one file.
    func getSkillFileContent(skillId: String, path: String, versionId: String) async throws -> Data {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/skills/id/\(skillId.encodedPathSegment)/files/content",
            queryItems: [URLQueryItem(name: "path", value: path), URLQueryItem(name: "version_id", value: versionId)],
            deduplicate: false,
            pathIsEncoded: true
        )
        return data
    }

    /// POST `/skills/id/{id}/clone` — copies a skill with all its files.
    func cloneSkillOnServer(skillId: String, newId: String, newName: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["id": newId, "name": newName])
        _ = try await network.requestRaw(
            path: "/api/v1/skills/id/\(skillId.encodedPathSegment)/clone",
            method: .post,
            body: body,
            pathIsEncoded: true
        )
    }

    /// POST `/skills/import/preview` (multipart) — parses a ZIP, JSON or SKILL.md file.
    func previewSkillImport(fileData: Data, fileName: String) async throws -> [[String: Any]] {
        let data = try await skillMultipart(path: "/api/v1/skills/import/preview", fileData: fileData, fileName: fileName, decisions: nil)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// POST `/skills/import` (multipart) — one decision per previewed skill:
    /// `{"action": "create"|"copy"|"replace"|"skip", "id", "name", "expected_version_id"}`.
    func importSkills(fileData: Data, fileName: String, decisions: [[String: Any]]) async throws -> [[String: Any]] {
        let json = String(data: try JSONSerialization.data(withJSONObject: decisions), encoding: .utf8) ?? "[]"
        let data = try await skillMultipart(path: "/api/v1/skills/import", fileData: fileData, fileName: fileName, decisions: json)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private func skillMultipart(path: String, fileData: Data, fileName: String, decisions: String?) async throws -> Data {
        let boundary = "OpenUI-\(UUID().uuidString)"
        var body = Data()
        if let decisions {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"decisions\"\r\n\r\n\(decisions)\r\n".utf8))
        }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (data, _) = try await network.requestRaw(
            path: path,
            method: .post,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            timeout: 120
        )
        return data
    }
}
