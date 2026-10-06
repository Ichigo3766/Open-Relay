import SwiftUI

/// Leaderboard tab: Elo ratings with optional topic filter; tap a row for its history.
struct AdminLeaderboardView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var entries: [LeaderboardEntryItem] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var error: String?
    @State private var selected: LeaderboardEntryItem?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField("Filter by topic (e.g. coding)", text: $query)
                    .scaledFont(size: 14).autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            .padding(10)
            .background(theme.surfaceContainer.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .listRowSeparator(.hidden).listRowBackground(Color.clear)

            if let error {
                Text(error).scaledFont(size: 13).foregroundStyle(.red).listRowBackground(Color.clear)
            }
            if isLoading && entries.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            } else if entries.isEmpty {
                Text("No evaluations yet. Rate model responses to build the leaderboard.")
                    .scaledFont(size: 14).foregroundStyle(theme.textTertiary).listRowBackground(Color.clear)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, e in
                Button { selected = e } label: { row(rank: idx + 1, e) }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.surfaceContainer.opacity(0.4))
            }
        }
        .listStyle(.plain)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await load()
            }
        }
        .sheet(item: $selected) { e in
            ModelHistorySheet(entry: e).presentationDetents([.medium, .large])
        }
    }

    private func row(rank: Int, _ e: LeaderboardEntryItem) -> some View {
        HStack(spacing: Spacing.sm) {
            Text("\(rank)").scaledFont(size: 15, weight: .bold)
                .foregroundStyle(rank <= 3 ? theme.brandPrimary : theme.textTertiary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.modelId).scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary).lineLimit(1)
                if !e.topTags.isEmpty {
                    Text(e.topTags.prefix(3).map(\.tag).joined(separator: " · "))
                        .scaledFont(size: 11).foregroundStyle(theme.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(e.rating)").scaledFont(size: 15, weight: .semibold).foregroundStyle(theme.textPrimary)
                Text("\(e.won)W · \(e.lost)L").scaledFont(size: 11).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let api = dependencies.apiClient else { return }
        isLoading = true
        do { entries = try await api.getLeaderboard(query: query); error = nil }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }
}
