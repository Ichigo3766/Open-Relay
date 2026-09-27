import SwiftUI

/// A shared, paginated result list for sheet and composer attachment pickers.
struct AttachmentPickerResults: View {
    let apiClient: APIClient?
    let query: String
    let sources: [AttachmentSearchSource]
    var selectedIDs: Set<String>? = nil
    let onSelect: (KnowledgeItem) -> Void
    var onBrowse: ((KnowledgeItem) -> Void)? = nil
    @State private var search: AttachmentSearchModel?

    var body: some View {
        List {
            if let search {
                ForEach(search.sections.filter { !$0.items.isEmpty || $0.isLoading || $0.failed || $0.hasMore }) { section in
                    Section {
                        ForEach(section.items) { item in
                            HStack {
                                Button { onSelect(item) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.iconName).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.name).foregroundStyle(.primary).lineLimit(2)
                                            if let description = item.description, !description.isEmpty {
                                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: selectedIDs.map { $0.contains(item.id) ? "checkmark.circle.fill" : "circle" } ?? "plus.circle")
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selectedIDs?.contains(item.id) == true ? .isSelected : [])
                                if item.type == .collection, let onBrowse {
                                    Button { onBrowse(item) } label: {
                                        Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Browse \(item.name)")
                                }
                            }
                        }
                        if section.isLoading {
                            ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Loading \(section.id.title)")
                        } else if section.failed {
                            Button("Couldn’t load \(section.id.title.lowercased()). Retry", systemImage: "arrow.clockwise") {
                                search.requestMore(section.id)
                            }
                        } else if section.hasMore {
                            Button("Load more \(section.id.title.lowercased())") { search.requestMore(section.id) }
                        }
                    } header: {
                        if sources.count > 1 { Text(section.id.title) }
                    }
                }
                if search.sections.allSatisfy({ $0.items.isEmpty && !$0.isLoading && !$0.failed && !$0.hasMore }) {
                    Text("No results").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
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

struct InlineFilesPickerView: View {
    var apiClient: APIClient?
    var onFilesSelected: ([ChatAttachment]) -> Void
    @State private var query = ""
    @State private var selected: [KnowledgeItem] = []

    var body: some View {
        AttachmentPickerResults(apiClient: apiClient, query: query, sources: [.uploads],
                                selectedIDs: Set(selected.map(\.id))) { item in
            if selected.contains(where: { $0.id == item.id }) {
                selected.removeAll { $0.id == item.id }
            } else { selected.append(item) }
        }
        .navigationTitle("Attach Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $query, prompt: "Search files")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Attach \(selected.count) files", systemImage: "checkmark") {
                    onFilesSelected(selected.map { item in
                        var attachment = ChatAttachment(type: .file, name: item.name)
                        attachment.uploadStatus = .completed
                        attachment.uploadedFileId = item.id
                        attachment.uploadedFileObject = item.fileReference?.serverDictionary["file"] as? [String: Any]
                        return attachment
                    })
                }
                .labelStyle(.iconOnly)
                .disabled(selected.isEmpty)
            }
        }
    }
}

struct InlineKnowledgePickerView: View {
    var apiClient: APIClient?
    var collection: KnowledgeItem? = nil
    var onItemSelected: (KnowledgeItem) -> Void
    @State private var query = ""
    @State private var browsing: KnowledgeItem?

    var body: some View {
        AttachmentPickerResults(apiClient: apiClient, query: query,
                                sources: collection.map { [.documents(collectionID: $0.id)] } ?? [.collections, .documents(collectionID: nil)],
                                onSelect: onItemSelected, onBrowse: { browsing = $0 })
            .navigationTitle(collection?.name ?? "Attach Knowledge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar(.visible, for: .navigationBar)
            .searchable(text: $query, prompt: collection == nil ? "Search knowledge" : "Search documents")
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .navigationDestination(item: $browsing) { item in
                InlineKnowledgePickerView(apiClient: apiClient, collection: item, onItemSelected: onItemSelected)
            }
    }
}
