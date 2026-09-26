import SwiftUI

struct LibrarySearchView: View {
    let api: APIClient
    let onSelectChat: (String) -> Void
    let onSelectFolder: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var scope: LibrarySearchScope = .all
    @State private var model: LibrarySearchModel
    @State private var previewFile: KnowledgeFileEntry?
    @FocusState private var searchFocused: Bool
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(api: APIClient, onSelectChat: @escaping (String) -> Void, onSelectFolder: @escaping (String) -> Void) {
        self.api = api
        self.onSelectChat = onSelectChat
        self.onSelectFolder = onSelectFolder
        _model = State(initialValue: LibrarySearchModel(fetch: api.searchLibrary))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LibrarySearchScope.allCases) { filter in
                            Button {
                                scope = filter
                            } label: {
                                Text(LocalizedStringKey(filter.rawValue))
                                    .scaledFont(size: 15, weight: .medium)
                                    .padding(.horizontal, 17).padding(.vertical, 11)
                                    .background(scope == filter ? theme.surfaceContainer : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("search-filter-\(filter.id.rawValue)")
                            .accessibilityAddTraits(scope == filter ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, Spacing.md).padding(.vertical, 8)
                }
                results
            }
            .foregroundStyle(theme.textPrimary)
            .background(theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { searchBar }
            .task(id: "\(scope.rawValue):\(searchTerm)") { await model.search(searchTerm, scope: scope) }
            .onAppear { searchFocused = true }
            .onDisappear { model.cancel() }
            .sheet(item: $previewFile) { file in
                KnowledgeFilePreviewSheet(file: file, apiClient: api)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if searchTerm.isEmpty {
            ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                   description: Text("Find chats, folders, and text in Knowledge documents."))
        } else if !model.sections.isEmpty && model.sections.allSatisfy({ !$0.isLoading && !$0.failed && $0.items.isEmpty }) {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.sections) { section in
                        if !section.items.isEmpty || section.isLoading || section.failed {
                            Text(LocalizedStringKey(section.id.title))
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundStyle(theme.textSecondary)
                                .padding(.top, 8)
                            ForEach(section.items) { item in
                                resultLink(item)
                            }
                            if section.isLoading {
                                ProgressView().frame(maxWidth: .infinity)
                            } else if section.failed {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Couldn’t search \(section.id.title.lowercased()). Other results are still available.")
                                        .scaledFont(size: 14).foregroundStyle(theme.textSecondary)
                                    Button("Retry") { model.requestMore(section.id) }
                                }
                            } else if section.hasMore {
                                Button("Show more \(section.id.title.lowercased())") {
                                    model.requestMore(section.id)
                                }
                                .accessibilityIdentifier("search-more-\(section.id.rawValue)")
                            }
                        }
                    }
                }
                .padding(Spacing.md)
                .id(searchTerm)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("library-search-results")
        }
    }

    @ViewBuilder
    private func resultLink(_ item: LibrarySearchResult) -> some View {
        if item.source == .knowledge {
            NavigationLink {
                SearchKnowledgeFilesView(item: item, api: api)
            } label: {
                LibrarySearchRow(item: item, query: searchTerm, api: api)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                searchFocused = false
                switch item.source {
                case .chats:
                    onSelectChat(item.resourceID)
                    dismiss()
                case .folders:
                    onSelectFolder(item.resourceID)
                    dismiss()
                case .documents:
                    previewFile = KnowledgeFileEntry(id: item.resourceID, name: item.title)
                case .knowledge: break
                }
            } label: {
                LibrarySearchRow(item: item, query: searchTerm, api: api)
            }
            .buttonStyle(.plain)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textSecondary)
                TextField("Search", text: $query)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("library-search-field")
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFocused = true
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(.regularMaterial, in: Capsule())
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Close search")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.md).padding(.vertical, 8)
        .background(theme.background)
    }
}

private struct LibrarySearchRow: View {
    let item: LibrarySearchResult
    let query: String
    let api: APIClient
    @Environment(\.theme) private var theme
    @State private var excerpt = ""
    @State private var previewFailed = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.source.icon)
                .scaledFont(size: 21)
                .frame(width: 42, height: 44)
                .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(highlight(item.title)).scaledFont(size: 16, weight: .medium).lineLimit(2)
                let snippet = excerpt.isEmpty ? item.snippet : excerpt
                if !snippet.isEmpty {
                    Text(highlight(snippet)).scaledFont(size: 14)
                        .foregroundStyle(theme.textSecondary).lineLimit(3)
                } else if item.source == .documents && !query.isEmpty {
                    Text(previewFailed ? "Preview unavailable. Open document to read." : "Loading matching text…")
                        .scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                }
                if !item.context.isEmpty {
                    Text(verbatim: item.context).scaledFont(size: 12).foregroundStyle(theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .task(id: query) {
            guard item.source == .documents, !query.isEmpty else { return }
            do {
                let text = try await api.searchDocumentExcerpt(id: item.resourceID, query: query)
                try Task.checkCancellation()
                excerpt = text
                previewFailed = text.isEmpty
            } catch {
                if !Task.isCancelled { previewFailed = true }
            }
        }
    }

    private func highlight(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        var remaining = text.startIndex..<text.endIndex
        while let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
            if let start = AttributedString.Index(range.lowerBound, within: result),
               let end = AttributedString.Index(range.upperBound, within: result) {
                result[start..<end].foregroundColor = theme.brandPrimary
                result[start..<end].inlinePresentationIntent = .stronglyEmphasized
            }
            remaining = range.upperBound..<text.endIndex
        }
        return result
    }
}

/// Read-only browsing: searching a shared knowledge base never opens editing controls.
private struct SearchKnowledgeFilesView: View {
    let item: LibrarySearchResult
    let api: APIClient
    @Environment(\.theme) private var theme
    @State private var files: [LibrarySearchResult] = []
    @State private var page = 1
    @State private var request = 0
    @State private var hasMore = false
    @State private var loading = true
    @State private var failed = false
    @State private var previewFile: KnowledgeFileEntry?

    var body: some View {
        List {
            if !item.snippet.isEmpty { Text(verbatim: item.snippet).foregroundStyle(theme.textSecondary) }
            ForEach(files) { file in
                Button {
                    previewFile = KnowledgeFileEntry(id: file.resourceID, name: file.title)
                } label: { Label(file.title, systemImage: "doc.text") }
            }
            if loading { ProgressView() }
            else if failed { Button("Couldn’t load files. Retry") { request += 1 } }
            else if hasMore { Button("Show more documents") { page += 1; request += 1 } }
            else if files.isEmpty { Text("No documents in this knowledge base.") }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: request) { await load() }
        .sheet(item: $previewFile) { file in KnowledgeFilePreviewSheet(file: file, apiClient: api) }
    }

    private func load() async {
        loading = true
        failed = false
        do {
            let result = try await api.searchKnowledgeFiles(id: item.resourceID, page: page)
            try Task.checkCancellation()
            var ids = Set(files.map(\.id))
            files += result.items.filter { ids.insert($0.id).inserted }
            hasMore = result.hasMore
        } catch { if !Task.isCancelled { failed = true } }
        loading = false
    }
}
