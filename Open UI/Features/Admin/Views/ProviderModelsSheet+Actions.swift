import SwiftUI

extension ProviderModelsSheet {
    func refresh() async {
        guard let api = dependencies.apiClient else { return }
        isLoading = models.isEmpty
        do { models = try await api.getProviderModels(urlIdx: urlIdx, provider: provider); error = nil }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }

    /// Runs one action, then refreshes the catalog and the app's model list (like the web).
    func act(_ model: String, _ body: (APIClient) async throws -> Void) async {
        guard let api = dependencies.apiClient else { return }
        busyModel = model; error = nil
        do {
            try await body(api)
            Haptics.notify(.success)
            await refresh()
            NotificationCenter.default.post(name: .functionsConfigChanged, object: nil)
        } catch {
            self.error = error.localizedDescription
            Haptics.notify(.error)
        }
        busyModel = nil
    }

    /// llama.cpp returns when done; LM Studio returns a `job_id` to poll every 1.5 s.
    func download() async {
        guard let api = dependencies.apiClient else { return }
        let ref = modelRef.trimmingCharacters(in: .whitespaces)
        busyModel = ref; error = nil
        downloadProgress = nil; downloadStatus = "Starting download…"
        do {
            let res = try await api.downloadProviderModel(urlIdx: urlIdx, model: ref)
            if let jobId = res["job_id"] as? String {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    let s = try await api.providerDownloadStatus(urlIdx: urlIdx, jobId: jobId)
                    let total = (s["total_size_bytes"] as? Double) ?? Double(s["total_size_bytes"] as? Int ?? 0)
                    let done = (s["downloaded_bytes"] as? Double) ?? Double(s["downloaded_bytes"] as? Int ?? 0)
                    if total > 0 { downloadProgress = (done / total * 1000).rounded() / 10 }
                    let status = s["status"] as? String ?? ""
                    downloadStatus = status.isEmpty ? "Downloading…" : status.capitalized
                    if status == "completed" { downloadProgress = 100; break }
                    if status == "failed" {
                        throw NSError(domain: "ProviderModels", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: (s["error"] as? String) ?? "Download failed"])
                    }
                }
            }
            downloadStatus = "Download complete"
            modelRef = ""
            Haptics.notify(.success)
            await refresh()
            NotificationCenter.default.post(name: .functionsConfigChanged, object: nil)
        } catch {
            downloadStatus = nil
            self.error = error.localizedDescription
            Haptics.notify(.error)
        }
        busyModel = nil
    }
}
