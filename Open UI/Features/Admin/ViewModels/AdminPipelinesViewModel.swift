import Foundation
import SwiftUI
import os.log

// MARK: - Pipeline Models

struct PipelineServer: Identifiable {
    let id: String  // string form of idx
    let idx: Int
    let url: String
}

struct Pipeline: Identifiable {
    let id: String
    let name: String
    let type: String
    let hasValves: Bool
}

// MARK: - AdminPipelinesViewModel

@Observable
final class AdminPipelinesViewModel {

    // MARK: - State

    var isLoading = false
    var error: String?

    var pipelineServers: [PipelineServer] = []
    var selectedServerIdx: Int = 0
    var pipelines: [Pipeline] = []
    var isLoadingPipelines = false

    var selectedPipelineId: String? = nil
    var valves: [String: Any] = [:]
    var valvesSpec: [String: Any] = [:]
    var valveKeyOrder: [String] = []
    var isLoadingValves = false
    var isSavingValves = false
    var valvesSaved = false

    // Add pipeline
    var githubURL = ""
    var isDownloading = false
    var downloadSuccess = false

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "AdminPipelines")

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load

    func load() async {
        guard let api = apiClient else { return }
        isLoading = true
        error = nil
        do {
            let raw = try await api.getPipelinesList()
            pipelineServers = raw.compactMap { item -> PipelineServer? in
                guard let idx = item["idx"] as? Int,
                      let url = item["url"] as? String else { return nil }
                return PipelineServer(id: "\(idx)", idx: idx, url: url)
            }
            if !pipelineServers.isEmpty {
                await loadPipelines(urlIdx: pipelineServers[0].idx)
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadPipelines(urlIdx: Int) async {
        guard let api = apiClient else { return }
        isLoadingPipelines = true
        pipelines = []
        selectedPipelineId = nil
        valves = [:]
        valvesSpec = [:]
        do {
            let raw = try await api.getPipelines(urlIdx: urlIdx)
            pipelines = raw.compactMap { item -> Pipeline? in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String else { return nil }
                let type = item["type"] as? String ?? "pipe"
                let hasValves = item["valves"] != nil
                return Pipeline(id: id, name: name, type: type, hasValves: hasValves)
            }
            if let first = pipelines.first {
                await loadValves(pipelineId: first.id, urlIdx: urlIdx)
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingPipelines = false
    }

    func loadValves(pipelineId: String, urlIdx: Int) async {
        guard let api = apiClient else { return }
        isLoadingValves = true
        selectedPipelineId = pipelineId
        do {
            async let specTask = api.getPipelineValvesSpec(id: pipelineId, urlIdx: urlIdx)
            async let valvesTask = api.getPipelineValves(id: pipelineId, urlIdx: urlIdx)
            let (spec, vals) = try await (specTask, valvesTask)
            valvesSpec = spec
            valves = vals
            // Extract property key order
            if let props = spec["properties"] as? [String: Any] {
                valveKeyOrder = Array(props.keys).sorted()
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingValves = false
    }

    func saveValves(urlIdx: Int) async {
        guard let api = apiClient, let pipelineId = selectedPipelineId else { return }
        isSavingValves = true
        valvesSaved = false
        do {
            try await api.updatePipelineValves(id: pipelineId, urlIdx: urlIdx, valves: valves)
            valvesSaved = true
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                valvesSaved = false
            }
        } catch {
            self.error = error.localizedDescription
        }
        isSavingValves = false
    }

    func downloadPipeline(urlIdx: Int) async {
        guard let api = apiClient, !githubURL.isEmpty else { return }
        isDownloading = true
        downloadSuccess = false
        error = nil
        do {
            try await api.downloadPipeline(url: githubURL, urlIdx: urlIdx)
            githubURL = ""
            downloadSuccess = true
            await loadPipelines(urlIdx: urlIdx)
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                downloadSuccess = false
            }
        } catch {
            self.error = error.localizedDescription
        }
        isDownloading = false
    }

    func deletePipeline(id: String, urlIdx: Int) async {
        guard let api = apiClient else { return }
        do {
            try await api.deletePipeline(id: id, urlIdx: urlIdx)
            await loadPipelines(urlIdx: urlIdx)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Valve Helpers

    var valveProperties: [(key: String, spec: [String: Any])] {
        guard let props = valvesSpec["properties"] as? [String: Any] else { return [] }
        let keys = valveKeyOrder.isEmpty ? props.keys.sorted() : valveKeyOrder
        return keys.compactMap { key -> (String, [String: Any])? in
            guard let spec = props[key] as? [String: Any] else { return nil }
            return (key, spec)
        }
    }

    func valveTitle(key: String, spec: [String: Any]) -> String {
        (spec["title"] as? String) ?? key
    }

    func valveDescription(spec: [String: Any]) -> String? {
        spec["description"] as? String
    }

    func valveType(spec: [String: Any]) -> String {
        spec["type"] as? String ?? "string"
    }

    func valveEnumOptions(spec: [String: Any]) -> [String]? {
        spec["enum"] as? [String]
    }

    func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: { self.valves[key] as? String ?? "" },
            set: { self.valves[key] = $0 }
        )
    }

    func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { self.valves[key] as? Bool ?? false },
            set: { self.valves[key] = $0 }
        )
    }
}
