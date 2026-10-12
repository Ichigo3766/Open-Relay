import SwiftUI

/// Version history sheet for a model, tool, function or skill:
/// page through every saved version, make one live again, delete old ones, or
/// compare any two.
struct ResourceVersionHistorySheet: View {
    let resource: VersionedResource
    let title: String
    /// The live version id (`version_id` on the resource), when known.
    let liveVersionId: String?
    /// Called after a version was made live so the editor can reload.
    var onRestored: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) var theme
    @Environment(AppDependencyContainer.self) var dependencies

    @State var versions: [ResourceVersion] = []
    @State var isLoading = true
    @State var error: String?
    @State var liveId: String?
    @State var busyId: String?
    @State var deleteCandidate: ResourceVersion?
    @State private var showCompare = false

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if versions.isEmpty {
                    ContentUnavailableView(
                        "No History",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("A version is kept each time you save.")
                    )
                } else {
                    Section {
                        ForEach(versions) { version in
                            row(version)
                                .swipeActions(edge: .trailing) {
                                    if version.id != liveId {
                                        Button(role: .destructive) { deleteCandidate = version } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    } footer: {
                        Text("Swipe left to delete a version. The live version can't be deleted.")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(theme.error).font(.footnote) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                if versions.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Compare") { showCompare = true }
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showCompare) {
                ResourceVersionCompareView(resource: resource, versions: versions)
            }
            .confirmationDialog(
                "Delete this version?",
                isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let candidate = deleteCandidate { Task { await delete(candidate) } }
                }
            }
        }
    }

    private func row(_ version: ResourceVersion) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(version.title)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    if version.id == liveId {
                        Text("Live")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(theme.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.successBackground, in: Capsule())
                    }
                }
                Text([version.authorName, version.createdAt.formatted(date: .abbreviated, time: .shortened), version.shortId]
                    .compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            if busyId == version.id {
                ProgressView().controlSize(.small)
            } else if version.id != liveId {
                Button("Make Live") { Task { await makeLive(version) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busyId != nil)
            }
        }
        .padding(.vertical, 2)
    }
}
