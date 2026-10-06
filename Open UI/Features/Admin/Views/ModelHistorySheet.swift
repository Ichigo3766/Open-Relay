import SwiftUI
import Charts

/// Per-model win/loss history (`GET /evaluations/leaderboard/{model}/history`).
struct ModelHistorySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencyContainer.self) private var dependencies
    let entry: LeaderboardEntryItem

    @State private var days = 30
    @State private var points: [ModelHistoryPoint] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Picker("Range", selection: $days) {
                    Text("7d").tag(7); Text("30d").tag(30); Text("90d").tag(90)
                }
                .pickerStyle(.segmented)
                HStack(spacing: Spacing.lg) {
                    stat("Rating", "\(entry.rating)"); stat("Won", "\(entry.won)"); stat("Lost", "\(entry.lost)")
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if points.isEmpty {
                    Text("No activity in this period.").foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    Chart {
                        ForEach(points) { p in
                            BarMark(x: .value("Date", p.date), y: .value("Won", p.won)).foregroundStyle(.green)
                            BarMark(x: .value("Date", p.date), y: .value("Lost", -p.lost)).foregroundStyle(.red)
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 200)
                }
                Spacer()
            }
            .padding(Spacing.md)
            .navigationTitle(entry.modelId)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task(id: days) {
                guard let api = dependencies.apiClient else { return }
                isLoading = true
                points = (try? await api.getModelHistory(modelId: entry.modelId, days: days)) ?? []
                isLoading = false
            }
        }
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack {
            Text(v).scaledFont(size: 20, weight: .bold)
            Text(t).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
