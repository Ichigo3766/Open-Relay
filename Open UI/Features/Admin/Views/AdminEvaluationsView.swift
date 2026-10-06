import SwiftUI

/// Admin → Evaluations: Leaderboard, Feedback and Arena models.
struct AdminEvaluationsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    enum Section: String, CaseIterable, Identifiable {
        case leaderboard = "Leaderboard", feedback = "Feedback", arena = "Arena"
        var id: String { rawValue }
    }

    @State private var section: Section = .leaderboard
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var showDeleteAll = false
    @State private var isExporting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if section == .feedback {
                    Menu {
                        Button("Export as JSON", systemImage: "square.and.arrow.up") { Task { await export() } }
                        Button("Delete All Feedback", systemImage: "trash", role: .destructive) { showDeleteAll = true }
                    } label: {
                        if isExporting { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, Spacing.sm)

            Group {
                switch section {
                case .leaderboard: AdminLeaderboardView()
                case .feedback: AdminFeedbackView()
                case .arena: AdminArenaView()
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let exportURL { ActivityShareSheet(items: [exportURL]) }
        }
        .confirmationDialog("Delete all feedback?", isPresented: $showDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                Task {
                    do { try await dependencies.apiClient?.deleteAllFeedbacks(); Haptics.notify(.success) }
                    catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every feedback record and resets the leaderboard.")
        }
        .alert("Error", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func export() async {
        guard let api = dependencies.apiClient else { return }
        isExporting = true
        do {
            let data = try await api.exportAllFeedbacks()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-history-export.json")
            try data.write(to: url, options: .atomic)
            exportURL = url
            showShare = true
        } catch { self.error = error.localizedDescription }
        isExporting = false
    }
}
