import SwiftUI
import UniformTypeIdentifiers

// MARK: - Function Type Filter

enum FunctionTypeFilter: String, CaseIterable {
    case all = "All"
    case filter = "Filter"
    case pipe = "Pipe"
    case action = "Action"
}

// MARK: - Function Editor Mode

enum FunctionEditorMode: Identifiable {
    case new
    case edit(FunctionDetail)

    var id: String {
        switch self {
        case .new: return "__new__"
        case .edit(let detail): return detail.id
        }
    }

    var existingFunction: FunctionDetail? {
        switch self {
        case .new: return nil
        case .edit(let detail): return detail
        }
    }
}

// MARK: - AdminFunctionsView

/// Lists all server functions (filters, pipes, actions) with search, type filter,
/// toggle, valves, import/export, and context menu actions.
struct AdminFunctionsView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    @State private var searchQuery = ""
    @State private var typeFilter: FunctionTypeFilter = .all
    @State private var isTogglingIds: Set<String> = []

    // Sheets
    @State private var editorMode: FunctionEditorMode?
    @State private var valvesSheetItem: FunctionValvesSheetItem?
    @State private var showImportPicker = false
    @State private var showExportShare = false
    @State private var exportData: Data?

    // Alerts
    @State private var deleteTarget: FunctionItem?
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    private var manager: FunctionsManager? { dependencies.functionsManager }

    private var filteredFunctions: [FunctionItem] {
        guard let manager else { return [] }
        var items = manager.functions
        // Type filter
        if typeFilter != .all {
            items = items.filter { $0.type.lowercased() == typeFilter.rawValue.lowercased() }
        }
        // Search
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            items = items.filter {
                $0.name.lowercased().contains(query) ||
                $0.id.lowercased().contains(query) ||
                $0.description.lowercased().contains(query)
            }
        }
        return items
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Search bar
                searchBar

                // Type filter chips
                typeFilterBar

                // Error banner
                if let error = errorMessage {
                    errorBanner(error)
                }
                if let error = manager?.error {
                    errorBanner(error)
                }

                // Count header
                if let manager, !manager.isLoading && !manager.functions.isEmpty {
                    HStack {
                        Text("Functions \(filteredFunctions.count)")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xs)
                }

                // Content
                if manager?.isLoading == true && manager?.functions.isEmpty == true {
                    loadingState
                } else if filteredFunctions.isEmpty {
                    emptyState
                } else {
                    functionsList
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImportPicker = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        Task { await exportFunctions() }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }

                Button {
                    editorMode = .new
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
            }
        }
        .refreshable {
            // Use a detached task to prevent SwiftUI's refresh action from cancelling the request
            await withCheckedContinuation { continuation in
                Task.detached { [manager] in
                    await manager?.fetchAll()
                    continuation.resume()
                }
            }
        }
        .sheet(item: $editorMode) { mode in
            FunctionEditorView(
                existingFunction: mode.existingFunction,
                onSave: { _ in
                    Task { await manager?.fetchAll() }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
        .sheet(item: $valvesSheetItem) { item in
            FunctionValvesSheet(functionId: item.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        .sheet(isPresented: $showExportShare) {
            if let data = exportData {
                ShareSheet(items: [data])
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImport(result) }
        }
        .confirmationDialog(
            "Delete function?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            if let target = deleteTarget {
                Button("Delete \(target.name)", role: .destructive) {
                    Task { await deleteFunction(target) }
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if let target = deleteTarget {
                Text("Are you sure you want to delete \"\(target.name)\"? This action cannot be undone.")
            }
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await manager?.fetchAll()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textTertiary)

            TextField("Search Functions", text: $searchQuery)
                .scaledFont(size: 16)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
    }

    // MARK: - Type Filter Bar

    private var typeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(FunctionTypeFilter.allCases, id: \.rawValue) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            typeFilter = filter
                        }
                        Haptics.play(.light)
                    } label: {
                        Text(filter.rawValue)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(
                                typeFilter == filter ? theme.brandPrimary : theme.textTertiary
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                (typeFilter == filter ? theme.brandPrimary : theme.textTertiary)
                                    .opacity(0.1)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.top, Spacing.sm)
        }
    }

    // MARK: - Functions List

    private var functionsList: some View {
        VStack(spacing: 0) {
            ForEach(filteredFunctions) { fn in
                functionRow(fn)

                if fn.id != filteredFunctions.last?.id {
                    Divider()
                        .padding(.leading, Spacing.screenPadding + 8)
                        .padding(.trailing, Spacing.screenPadding)
                }
            }
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: - Function Row

    private func functionRow(_ fn: FunctionItem) -> some View {
        HStack(spacing: Spacing.md) {
            // Type badge + info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    functionTypeBadge(fn.type)

                    Text(fn.name)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if let version = fn.version, !version.isEmpty {
                        Text("v\(version)")
                            .scaledFont(size: 11)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                if let author = fn.authorName, !author.isEmpty {
                    Text("By \(author)")
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }

                if !fn.description.isEmpty {
                    Text(fn.description)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Valves gear
            Button {
                valvesSheetItem = FunctionValvesSheetItem(id: fn.id)
            } label: {
                Image(systemName: "gearshape")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Toggle switch
            if isTogglingIds.contains(fn.id) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 44)
            } else {
                Toggle("", isOn: Binding(
                    get: { fn.isActive },
                    set: { _ in
                        Task { await toggleFunction(fn) }
                    }
                ))
                .tint(theme.brandPrimary)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await openEditor(for: fn) }
        }
        .contextMenu {
            // Global toggle — instant API call
            Button {
                Task { await toggleGlobal(fn) }
            } label: {
                Label(
                    fn.isGlobal ? "Disable Global" : "Enable Global",
                    systemImage: fn.isGlobal ? "globe.badge.chevron.backward" : "globe"
                )
            }

            Button {
                Task { await openEditor(for: fn) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button {
                Task { await cloneFunction(fn) }
            } label: {
                Label("Clone", systemImage: "doc.on.doc")
            }

            Button {
                Task { await exportSingleFunction(fn) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            Button {
                valvesSheetItem = FunctionValvesSheetItem(id: fn.id)
            } label: {
                Label("Valves", systemImage: "gearshape")
            }

            Divider()

            Button(role: .destructive) {
                deleteTarget = fn
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Type Badge

    private func functionTypeBadge(_ type: String) -> some View {
        Text(type.uppercased())
            .scaledFont(size: 9, weight: .heavy)
            .foregroundStyle(badgeColor(for: type))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badgeColor(for: type).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func badgeColor(for type: String) -> Color {
        switch type.lowercased() {
        case "filter": return .orange
        case "pipe":   return .purple
        case "action": return .blue
        default:       return .gray
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Loading functions…")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "function")
                .scaledFont(size: 40)
                .foregroundStyle(theme.textTertiary)
            Text(searchQuery.isEmpty && typeFilter == .all
                 ? "No functions found"
                 : "No matching functions")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 14)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.error)
            Spacer()
            Button("Retry") {
                Task { await manager?.fetchAll() }
            }
            .scaledFont(size: 12, weight: .medium)
            .fontWeight(.semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .padding(Spacing.md)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
    }

    // MARK: - Actions

    private func toggleFunction(_ fn: FunctionItem) async {
        guard let manager else { return }
        isTogglingIds.insert(fn.id)
        do {
            try await manager.toggleActive(id: fn.id)
            Haptics.play(.light)
            NotificationCenter.default.post(name: .functionsConfigChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
            Haptics.notify(.error)
        }
        isTogglingIds.remove(fn.id)
    }

    private func openEditor(for fn: FunctionItem) async {
        guard let manager else { return }
        do {
            let detail = try await manager.getDetail(id: fn.id)
            editorMode = .edit(detail)
        } catch {
            errorMessage = "Failed to load function: \(error.localizedDescription)"
        }
    }

    private func toggleGlobal(_ fn: FunctionItem) async {
        guard let manager else { return }
        do {
            try await manager.toggleGlobal(id: fn.id)
            Haptics.play(.light)
            NotificationCenter.default.post(name: .functionsConfigChanged, object: nil)
        } catch {
            errorMessage = "Toggle global failed: \(error.localizedDescription)"
            Haptics.notify(.error)
        }
    }

    private func exportSingleFunction(_ fn: FunctionItem) async {
        guard let manager else { return }
        do {
            let rawData = try await manager.getDetailRaw(id: fn.id)
            // Parse the raw JSON, wrap in an array for export format consistency
            let jsonObject = try JSONSerialization.jsonObject(with: rawData)
            let arrayData = try JSONSerialization.data(withJSONObject: [jsonObject], options: [.prettyPrinted, .sortedKeys])
            exportData = arrayData
            showExportShare = true
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            Haptics.notify(.error)
        }
    }

    private func cloneFunction(_ fn: FunctionItem) async {
        guard let manager else { return }
        do {
            try await manager.cloneFunction(id: fn.id)
            Haptics.notify(.success)
        } catch {
            errorMessage = "Clone failed: \(error.localizedDescription)"
            Haptics.notify(.error)
        }
    }

    private func deleteFunction(_ fn: FunctionItem) async {
        guard let manager else { return }
        do {
            try await manager.deleteFunction(id: fn.id)
            Haptics.notify(.success)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            Haptics.notify(.error)
        }
        deleteTarget = nil
    }

    private func exportFunctions() async {
        guard let manager else { return }
        do {
            exportData = try await manager.exportAll()
            showExportShare = true
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                // Try parsing as array of functions
                guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    errorMessage = "Invalid format — expected a JSON array of functions."
                    return
                }
                var importCount = 0
                for json in jsonArray {
                    if let detail = FunctionDetail(json: json) {
                        try await manager?.createFunction(from: detail)
                        importCount += 1
                    }
                }
                await manager?.fetchAll()
                Haptics.notify(.success)
                if importCount == 0 {
                    errorMessage = "No valid functions found in file."
                }
            } catch {
                errorMessage = "Import failed: \(error.localizedDescription)"
                Haptics.notify(.error)
            }

        case .failure(let error):
            errorMessage = "File selection failed: \(error.localizedDescription)"
        }
    }
}

