import SwiftUI

// MARK: - Card Files Picker

struct CardFilesPickerView: View {
    var apiClient: APIClient?
    var onFilesSelected: ([ChatAttachment]) -> Void
    @State private var query = ""
    @State private var selected: [KnowledgeItem] = []

    var body: some View {
        VStack(spacing: 0) {
            PickerNavBar(
                title: "Attach Files",
                trailingLabel: selected.isEmpty ? "Attach" : "Attach (\(selected.count))",
                trailingDisabled: selected.isEmpty,
                onTrailingTap: attach
            )
            CardSearchField(prompt: "Search files", text: $query)
            CardAttachmentResults(apiClient: apiClient, query: query, sources: [.uploads],
                                  selectedIDs: Set(selected.map(\.id))) { item in
                if selected.contains(where: { $0.id == item.id }) {
                    selected.removeAll { $0.id == item.id }
                } else {
                    selected.append(item)
                }
            }
        }
    }

    private func attach() {
        onFilesSelected(selected.map { item in
            var attachment = ChatAttachment(type: .file, name: item.name)
            attachment.uploadStatus = .completed
            attachment.uploadedFileId = item.id
            attachment.uploadedFileObject = item.fileReference?.serverDictionary["file"] as? [String: Any]
            return attachment
        })
    }
}

// MARK: - Card Knowledge Picker

/// Knowledge bases + documents. Browsing into a collection slides its documents
/// in within the same card page; ‹ steps back up a level before leaving the page.
struct CardKnowledgePickerView: View {
    var apiClient: APIClient?
    var onItemSelected: (KnowledgeItem) -> Void

    @State private var query = ""
    @State private var collection: KnowledgeItem?
    @Environment(\.morphCardBack) private var morphCardBack

    var body: some View {
        VStack(spacing: 0) {
            PickerNavBar(title: collection?.name ?? "Attach Knowledge")
                // Inside a collection, ‹ goes back to the collection list first.
                .environment(\.morphCardBack, MorphCardBackAction {
                    if collection != nil {
                        withAnimation(MorphCardMetrics.spring) { collection = nil }
                        query = ""
                    } else {
                        morphCardBack?()
                    }
                })
            CardSearchField(prompt: collection == nil ? "Search knowledge" : "Search documents", text: $query)
            ZStack {
                if let collection {
                    CardAttachmentResults(apiClient: apiClient, query: query,
                                          sources: [.documents(collectionID: collection.id)],
                                          onSelect: onItemSelected)
                        .id(collection.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    CardAttachmentResults(apiClient: apiClient, query: query,
                                          sources: [.collections, .documents(collectionID: nil)],
                                          onSelect: onItemSelected,
                                          onBrowse: { item in
                                              query = ""
                                              withAnimation(MorphCardMetrics.spring) { collection = item }
                                          })
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .clipped()
        }
    }
}
