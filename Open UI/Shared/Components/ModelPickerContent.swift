import SwiftUI

// MARK: - Model Picker Content

/// The model list shared by the glass drop-down card (`ModelPickerCard`, used in the
/// chat) and the bottom sheet (`ModelSelectorSheet`, used by Automations).
///
/// Sections: Currently Selected, Pinned, All Models. Search matches name, id, tags and
/// description. Pinning glides a row between sections. A long-press menu offers
/// Pin/Unpin, Copy Model ID and (admins) Edit.
///
/// Split across `+Chrome` (header, search, filter pills) and `+Rows` (list, rows).
struct ModelPickerContent: View {
    let models: [AIModel]
    let selectedModelId: String?
    let serverBaseURL: String
    let authToken: String?
    let isAdmin: Bool
    let pinnedModelIds: [String]
    let onEdit: ((AIModel) -> Void)?
    let onTogglePin: ((String) -> Void)?
    /// Called when a model row is tapped. The host is responsible for closing itself.
    let onSelect: (AIModel) -> Void
    /// Called when the search field gains or loses focus (the card grows to make room).
    var onSearchFocusChange: ((Bool) -> Void)? = nil
    /// When false, rows wait just below their spot, faded out; flipping it to true
    /// deals them in one after another (used while the card is still growing).
    var contentRevealed: Bool = true
    /// Shows the "Models  N" title row (the sheet uses it; the card has its own).
    var showsHeader: Bool = true

    @Environment(\.theme) var theme

    @State var searchText = ""
    @State var selectedTag: String? = nil
    @State var selectedConnection: String? = nil
    @State var filteredModels: [AIModel] = []
    @State var filterTask: Task<Void, Never>? = nil
    @FocusState var searchFocused: Bool

    // MARK: Filter data

    var allTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for model in models {
            for tag in model.tags {
                let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, seen.insert(t).inserted { result.append(t) }
            }
        }
        return result.sorted()
    }

    var allConnections: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for model in models {
            if let ct = model.connectionType?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ct.isEmpty, seen.insert(ct).inserted {
                result.append(ct)
            }
        }
        return result.sorted()
    }

    var hasFilters: Bool { !allTags.isEmpty || !allConnections.isEmpty }

    func applyFilters() {
        var result = models
        if let tag = selectedTag { result = result.filter { $0.tags.contains(tag) } }
        if let conn = selectedConnection { result = result.filter { $0.connectionType == conn } }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                || $0.shortName.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
                || ($0.description?.localizedCaseInsensitiveContains(q) ?? false)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) }
            }
        }
        filteredModels = result
    }

    func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            applyFilters()
        }
    }

    /// The filtered list, or every model until the first filter pass has run — so the
    /// list is already full on the card's very first frame instead of filling in later.
    var visibleModels: [AIModel] {
        let unfiltered = searchText.isEmpty && selectedTag == nil && selectedConnection == nil
        return (filteredModels.isEmpty && unfiltered) ? models : filteredModels
    }

    // MARK: Sections

    var currentModel: AIModel? {
        guard let id = selectedModelId else { return nil }
        return visibleModels.first { $0.id == id }
    }

    var pinnedModels: [AIModel] {
        let pinnedSet = Set(pinnedModelIds)
        return visibleModels.filter { pinnedSet.contains($0.id) && $0.id != selectedModelId }
    }

    var remainingModels: [AIModel] {
        let pinnedSet = Set(pinnedModelIds)
        return visibleModels.filter { $0.id != selectedModelId && !pinnedSet.contains($0.id) }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, showsHeader ? 4 : 0)
                .padding(.bottom, hasFilters ? 0 : 8)
                .modifier(MorphRowReveal(isRevealed: contentRevealed, index: 0))
            if hasFilters {
                filterPillsRow
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .modifier(MorphRowReveal(isRevealed: contentRevealed, index: 1))
            }
            Divider().background(theme.divider.opacity(0.4))
            modelList
        }
        .onAppear { filteredModels = models }
        .onChange(of: searchText) { scheduleFilter() }
        .onChange(of: selectedTag) { withAnimation(MicroAnimation.snappy) { applyFilters() } }
        .onChange(of: selectedConnection) { withAnimation(MicroAnimation.snappy) { applyFilters() } }
        .onChange(of: models) { applyFilters() }
        .onChange(of: searchFocused) { _, focused in onSearchFocusChange?(focused) }
    }
}
