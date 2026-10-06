import SwiftUI

extension APIClient {
    /// POST /knowledge/external/connections/{id}/test → `{ok, provider, checked_at}` (admin).
    func testExternalKnowledgeConnection(id: String) async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/knowledge/external/connections/\(id)/test", method: .post, body: [:])
    }

    /// POST /knowledge/external/connections/{id}/retrieve-test → `{documents, metadatas, distances}`.
    func retrieveTestExternalKnowledge(id: String, query: String, count: Int = 5) async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/knowledge/external/connections/\(id)/retrieve-test",
                                      method: .post, body: ["query": query, "count": count])
    }
}

/// Runs a test query against an external knowledge connection and lists what comes back.
struct ExternalRetrievalTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencyContainer.self) private var dependencies
    let connectionId: String
    let connectionName: String

    @State private var query = ""
    @State private var count = 5
    @State private var results: [(text: String, distance: Double?)] = []
    @State private var running = false
    @State private var error: String?
    @State private var ran = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Test query", text: $query)
                    Stepper("Results: \(count)", value: $count, in: 1...20)
                    Button { Task { await run() } } label: {
                        if running { ProgressView() } else { Label("Run", systemImage: "play.fill") }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || running)
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                if ran {
                    Section("Results") {
                        if results.isEmpty { Text("No documents returned").foregroundStyle(.secondary) }
                        ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.text).font(.footnote).lineLimit(6)
                                if let d = r.distance { Text(String(format: "Score %.3f", d)).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(connectionName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func run() async {
        guard let api = dependencies.apiClient else { return }
        running = true; error = nil
        do {
            let r = try await api.retrieveTestExternalKnowledge(id: connectionId, query: query, count: count)
            let docs = r["documents"] as? [Any] ?? []
            let dists = r["distances"] as? [Any] ?? []
            results = docs.enumerated().map { i, d in
                (String(describing: d), i < dists.count ? (dists[i] as? Double ?? (dists[i] as? Int).map(Double.init)) : nil)
            }
            ran = true
        } catch {
            self.error = error.localizedDescription
        }
        running = false
    }
}
