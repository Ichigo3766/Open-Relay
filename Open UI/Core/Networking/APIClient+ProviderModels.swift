import Foundation

// MARK: - Provider model management (llama.cpp / LM Studio connections)
//
// Server: routers/openai.py `/openai/models/{url_idx}/…` proxies to the provider's own model API.
// The catalog is the provider's raw response, normalised like the web's ManageProviderModels.

struct ProviderModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let status: String          // loaded | sleeping | loading | unloaded | available | downloading
    let unloadId: String        // LM Studio: loaded instance id, else the model id

    var isLoaded: Bool { status == "loaded" || status == "sleeping" }
    var isBusy: Bool { status == "loading" || status == "downloading" }

    /// Web `normalizeModels` + `getModelId/getDisplayName/getStatus/getUnloadId`.
    static func parse(_ json: Any, provider: String) -> [ProviderModel] {
        let entries: [Any]
        if let arr = json as? [Any] { entries = arr }
        else if let d = json as? [String: Any] {
            entries = (d["models"] as? [Any]) ?? (d["data"] as? [Any]) ?? (d["items"] as? [Any]) ?? []
        } else { entries = [] }

        return entries.compactMap { raw -> ProviderModel? in
            if let s = raw as? String { return ProviderModel(id: s, displayName: s, status: "available", unloadId: s) }
            guard let m = raw as? [String: Any] else { return nil }
            let id = (m["key"] as? String) ?? (m["id"] as? String) ?? (m["name"] as? String) ?? (m["model"] as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let instances = m["loaded_instances"] as? [[String: Any]] ?? []
            let status: String
            if !instances.isEmpty { status = "loaded" }
            else if provider == "lmstudio" { status = "unloaded" }
            else if let s = m["status"] as? String { status = s }
            else { status = ((m["status"] as? [String: Any])?["value"] as? String) ?? "available" }
            return ProviderModel(id: id, displayName: (m["display_name"] as? String) ?? id, status: status,
                                 unloadId: (instances.first?["id"] as? String) ?? id)
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }
}

extension APIClient {
    /// GET /openai/models/{idx}/catalog (admin)
    func getProviderModels(urlIdx: Int, provider: String) async throws -> [ProviderModel] {
        let (data, _) = try await network.requestRaw(path: "/openai/models/\(urlIdx)/catalog")
        let json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return ProviderModel.parse(json, provider: provider)
    }

    /// POST /openai/models/{idx}/download → provider response (LM Studio returns a job id).
    @discardableResult
    func downloadProviderModel(urlIdx: Int, model: String) async throws -> [String: Any] {
        try await network.requestJSON(path: "/openai/models/\(urlIdx)/download", method: .post,
                                      body: ["model": model], timeout: 600)
    }

    /// GET /openai/models/{idx}/download/status/{job} (LM Studio only).
    func providerDownloadStatus(urlIdx: Int, jobId: String) async throws -> [String: Any] {
        let (data, _) = try await network.requestRaw(
            path: "/openai/models/\(urlIdx)/download/status/\(jobId.encodedPathSegment)",
            pathIsEncoded: true)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// POST /openai/models/{idx}/load
    func loadProviderModel(urlIdx: Int, model: String) async throws {
        _ = try await network.requestJSON(path: "/openai/models/\(urlIdx)/load", method: .post,
                                          body: ["model": model], timeout: 600)
    }

    /// POST /openai/models/{idx}/unload — LM Studio needs the loaded instance id.
    func unloadProviderModel(urlIdx: Int, model: String, instanceId: String) async throws {
        _ = try await network.requestJSON(path: "/openai/models/\(urlIdx)/unload", method: .post,
                                          body: ["model": model, "instance_id": instanceId])
    }

    /// DELETE /openai/models/{idx}?model= (llama.cpp only).
    func deleteProviderModel(urlIdx: Int, model: String) async throws {
        _ = try await network.requestRaw(path: "/openai/models/\(urlIdx)", method: .delete,
                                         queryItems: [URLQueryItem(name: "model", value: model)])
    }
}
