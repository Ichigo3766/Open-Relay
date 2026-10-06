import SwiftUI

// MARK: - Card-style Attach results (Files & Knowledge)
//
// Same search model / API / paging as AttachmentPickerResults, styled for the
// + card: transparent background and tinted rows with the shared press effect.
// Folder sheets and other picker sheets keep using AttachmentPickerResults.

struct CardAttachmentResults: View {
    let apiClient: APIClient?
    let query: String
    let sources: [AttachmentSearchSource]
    var selectedIDs: Set<String>? = nil
    let onSelect: (KnowledgeItem) -> Void
    var onBrowse: ((KnowledgeItem) -> Void)? = nil

    @State private var search: AttachmentSearchModel?
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                if let search {
                    ForEach(search.sections.filter { !$0.items.isEmpty || $0.isLoading || $0.failed || $0.hasMore }) { section in
                        if sources.count > 1 {
                            Text(section.id.title)
                                .scaledFont(size: 11, weight: .semibold)
                                .textCase(.uppercase)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.top, Spacing.sm)
                                .padding(.leading, 4)
                        }
                        ForEach(section.items) { item in
                            CardAttachmentRow(item: item, selectedIDs: selectedIDs,
                                              onSelect: onSelect, onBrowse: onBrowse)
                        }
                        CardAttachmentSectionFooter(section: section, search: search)
                    }
                    if search.sections.allSatisfy({ $0.items.isEmpty && !$0.isLoading && !$0.failed && !$0.hasMore }) {
                        Text("No results")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Spacing.xl)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.lg)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .task(id: query) {
            if search == nil {
                search = AttachmentSearchModel { source, query, page, offset in
                    guard let apiClient else { throw URLError(.notConnectedToInternet) }
                    return try await apiClient.searchAttachments(source: source, query: query, page: page, offset: offset)
                }
            }
            await search?.search(query, sources: sources)
        }
        .onDisappear { search?.cancel() }
    }
}

struct CardAttachmentSectionFooter: View {
    let section: AttachmentSearchModel.Section
    let search: AttachmentSearchModel

    var body: some View {
        if section.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .accessibilityLabel("Loading \(section.id.title)")
        } else if section.failed {
            Button("Couldn’t load \(section.id.title.lowercased()). Retry", systemImage: "arrow.clockwise") {
                search.requestMore(section.id)
            }
            .scaledFont(size: 13, weight: .medium)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
        } else if section.hasMore {
            // Infinite scroll: load the next page when the end comes into view.
            Color.clear.frame(height: 1)
                .onAppear { search.requestMore(section.id) }
        }
    }
}
