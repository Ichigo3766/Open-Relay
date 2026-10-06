import SwiftUI

/// Admin → Documents → Danger Zone. Mirrors the web (`Documents.svelte`):
///  • Reindex knowledge + memory vectors: three calls in order, stopping at the first failure.
///  • Reset Upload Directory: `DELETE /files/all` (not `/retrieval/reset/uploads`).
///  • Reset Vector Storage / Knowledge: `POST /retrieval/reset/db`.
struct AdminDocumentsDangerZone: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    private enum Action: String, Identifiable {
        case reindex, uploads, vectors
        var id: String { rawValue }
        var title: String {
            switch self {
            case .reindex: return "Reindex Knowledge and Memory Vectors"
            case .uploads: return "Reset Upload Directory"
            case .vectors: return "Reset Vector Storage/Knowledge"
            }
        }
        var detail: String {
            switch self {
            case .reindex: return "Rebuild vectors for existing knowledge files, knowledge search, and memories."
            case .uploads: return "Delete uploaded files from the upload directory."
            case .vectors: return "Clear vector storage and knowledge indexing data."
            }
        }
        var confirm: String {
            switch self {
            case .reindex: return "Rebuild knowledge file, knowledge search, and memory vectors using the current embedding model."
            case .uploads: return "This will permanently delete every uploaded file. This cannot be undone."
            case .vectors: return "This will clear the vector database and knowledge indexing data. This cannot be undone."
            }
        }
        var button: String { self == .reindex ? "Reindex" : "Reset" }
    }

    @State private var pending: Action?
    @State private var running: Action?
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle").scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.error)
                Text("DANGER ZONE").scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary).tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, Spacing.screenPadding)

            VStack(spacing: 0) {
                row(.reindex)
                Divider().padding(.leading, Spacing.md)
                row(.uploads)
                Divider().padding(.leading, Spacing.md)
                row(.vectors)
            }
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5))
            .padding(.horizontal, Spacing.screenPadding)

            if let message {
                Text(message).scaledFont(size: 12)
                    .foregroundStyle(failed ? theme.error : theme.textSecondary)
                    .padding(.horizontal, Spacing.screenPadding)
            }
        }
        .confirmationDialog(pending?.title ?? "", isPresented: .init(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button(pending?.button ?? "", role: .destructive) {
                if let a = pending { pending = nil; Task { await run(a) } }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text(pending?.confirm ?? "") }
    }

    private func row(_ a: Action) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).scaledFont(size: 15).foregroundStyle(theme.textPrimary)
                Text(a.detail).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
            }
            Spacer()
            if running == a {
                ProgressView()
            } else {
                Button(a.button) { pending = a }
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(a == .reindex ? theme.brandPrimary : theme.error)
                    .disabled(running != nil)
            }
        }
        .padding(.horizontal, Spacing.md).padding(.vertical, 12)
    }

    private func run(_ a: Action) async {
        guard let api = dependencies.apiClient else { return }
        running = a; message = nil; failed = false
        do {
            switch a {
            case .reindex:
                try await api.reindexKnowledgeFiles()
                try await api.reindexKnowledgeMetadata()
                try await api.reindexMemoryVectors()
            case .uploads: try await api.deleteAllFiles()
            case .vectors: try await api.resetVectorDatabase()
            }
            message = "Success"
            Haptics.notify(.success)
        } catch {
            message = error.localizedDescription
            failed = true
            Haptics.notify(.error)
        }
        running = nil
    }
}
