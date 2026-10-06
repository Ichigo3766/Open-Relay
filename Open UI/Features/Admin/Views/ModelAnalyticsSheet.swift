import SwiftUI
import Charts

extension APIClient {
    /// Web: `encodeURIComponent(modelId)`. The route is `{model_id:path}`, which decodes `%2F`.
    private func analyticsModelPath(_ id: String, _ tail: String) -> String {
        "/api/v1/analytics/models/\(id.encodedPathSegment)/\(tail)"
    }

    /// GET /analytics/models/{id}/overview?days= → feedback history + chat tags.
    func getModelAnalyticsOverview(modelId: String, days: Int) async throws
        -> (history: [ModelHistoryPoint], tags: [(tag: String, count: Int)]) {
        let (data, _) = try await network.requestRaw(
            path: analyticsModelPath(modelId, "overview"),
            queryItems: [URLQueryItem(name: "days", value: "\(days)")],
            pathIsEncoded: true)
        let d = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let history = (d["history"] as? [[String: Any]] ?? []).compactMap { h -> ModelHistoryPoint? in
            guard let date = h["date"] as? String else { return nil }
            return ModelHistoryPoint(date: date, won: h["won"] as? Int ?? 0, lost: h["lost"] as? Int ?? 0)
        }
        let tags = (d["tags"] as? [[String: Any]] ?? []).compactMap { t -> (String, Int)? in
            guard let tag = t["tag"] as? String else { return nil }
            return (tag, t["count"] as? Int ?? 0)
        }
        return (history, tags)
    }

    /// GET /analytics/models/{id}/chats — chats that used this model (admin).
    func getModelAnalyticsChats(modelId: String, skip: Int = 0, limit: Int = 50) async throws
        -> (chats: [[String: Any]], total: Int) {
        let (data, _) = try await network.requestRaw(
            path: analyticsModelPath(modelId, "chats"),
            queryItems: [URLQueryItem(name: "skip", value: "\(skip)"), URLQueryItem(name: "limit", value: "\(limit)")],
            pathIsEncoded: true)
        let d = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (d["chats"] as? [[String: Any]] ?? [], d["total"] as? Int ?? 0)
    }
}

/// Model drill-down for Admin → Analytics.
struct ModelAnalyticsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencyContainer.self) private var dependencies
    let modelId: String

    @State private var days = 30
    @State private var history: [ModelHistoryPoint] = []
    @State private var tags: [(tag: String, count: Int)] = []
    @State private var chats: [[String: Any]] = []
    @State private var total = 0
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Picker("Range", selection: $days) {
                    Text("7d").tag(7); Text("30d").tag(30); Text("90d").tag(90); Text("All").tag(0)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if isLoading { HStack { Spacer(); ProgressView(); Spacer() } }

                if !history.isEmpty {
                    Section("Feedback") {
                        Chart {
                            ForEach(history) { p in
                                BarMark(x: .value("Date", p.date), y: .value("Won", p.won)).foregroundStyle(.green)
                                BarMark(x: .value("Date", p.date), y: .value("Lost", -p.lost)).foregroundStyle(.red)
                            }
                        }
                        .chartXAxis(.hidden)
                        .frame(height: 160)
                    }
                }
                if !tags.isEmpty {
                    Section("Top topics") {
                        ForEach(tags, id: \.tag) { t in
                            HStack { Text(t.tag); Spacer(); Text("\(t.count)").foregroundStyle(theme.textTertiary) }
                        }
                    }
                }
                Section("Chats (\(total))") {
                    if chats.isEmpty && !isLoading {
                        Text("No chats").foregroundStyle(theme.textTertiary)
                    }
                    ForEach(Array(chats.enumerated()), id: \.offset) { _, c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c["first_message"] as? String ?? "(no message)").lineLimit(2)
                            Text(c["user_name"] as? String ?? "").scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            }
            .navigationTitle(modelId)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task(id: days) { await load() }
        }
    }

    private func load() async {
        guard let api = dependencies.apiClient else { return }
        isLoading = true
        if let o = try? await api.getModelAnalyticsOverview(modelId: modelId, days: days) {
            history = o.history; tags = o.tags
        }
        if let c = try? await api.getModelAnalyticsChats(modelId: modelId) {
            chats = c.chats; total = c.total
        }
        isLoading = false
    }
}
