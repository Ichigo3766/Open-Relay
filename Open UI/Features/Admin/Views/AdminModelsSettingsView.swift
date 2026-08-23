import SwiftUI
import UniformTypeIdentifiers

// MARK: - AdminModelsSettingsView

struct AdminModelsSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminModelsSettingsViewModel()
    @State private var showManageSheet = false
    @State private var showSettingsSheet = false
    @State private var showImportPicker = false
    @State private var exportData: Data? = nil
    @State private var importError: String? = nil
    @State private var editingModelDetail: ModelDetail? = nil
    @State private var isLoadingEditId: String? = nil
    @State private var ollamaManagerURLIdx: Int? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if viewModel.isLoading {
                    loadingState
                } else {
                    toolbarRow
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.md)
                        .padding(.bottom, Spacing.sm)

                    if let err = viewModel.errorMessage {
                        errorBanner(err)
                            .padding(.horizontal, Spacing.screenPadding)
                            .padding(.bottom, Spacing.sm)
                    }

                    if let err = importError {
                        errorBanner(err)
                            .padding(.horizontal, Spacing.screenPadding)
                            .padding(.bottom, Spacing.sm)
                    }

                    modelsList
                }
                Spacer(minLength: 80)
            }
        }
        .background(theme.background)
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.loadAll()
        }
        // Manage Sheet
        .sheet(isPresented: $showManageSheet) {
            AdminModelsManageSheet(viewModel: viewModel) { idx in
                // Dismiss manage sheet first, then present Ollama manager
                showManageSheet = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    ollamaManagerURLIdx = idx
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
        // Ollama Model Manager Sheet (presented from top level to avoid nested-sheet issue)
        .sheet(item: Binding(
            get: { ollamaManagerURLIdx.map { OllamaURLIdxWrapper(idx: $0) } },
            set: { ollamaManagerURLIdx = $0?.idx }
        )) { wrapper in
            OllamaModelManagerSheet(urlIdx: wrapper.idx, apiClient: dependencies.apiClient)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        // Settings Sheet
        .sheet(isPresented: $showSettingsSheet) {
            AdminModelsGlobalSettingsSheet(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
        }
        // Model editor sheet
        .sheet(item: $editingModelDetail) { detail in
            NavigationStack {
                ModelEditorView(
                    existingModel: detail,
                    onSave: { _ in
                        Task { await viewModel.loadAll() }
                    }
                )
            }
        }
        // Import file picker
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    do {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        try await viewModel.importModels(from: data)
                        importError = nil
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
        // Export share sheet
        .sheet(isPresented: Binding(get: { exportData != nil }, set: { if !$0 { exportData = nil } })) {
            if let data = exportData {
                ShareSheetWrapper(items: [data])
            }
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView().controlSize(.large)
            Text("Loading models…")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    // MARK: - Toolbar Row

    private var toolbarRow: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                showImportPicker = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    if let data = try? await viewModel.exportModels() {
                        exportData = data
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showManageSheet = true
            } label: {
                Text("Manage")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            Button {
                showSettingsSheet = true
            } label: {
                Text("Settings")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(theme.brandPrimary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                            .strokeBorder(theme.brandPrimary.opacity(0.3), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Models List

    private var modelsList: some View {
        LazyVStack(spacing: 0) {
            ForEach(viewModel.models, id: \.id) { model in
                modelRow(model)
                Divider()
                    .background(theme.inputBorder.opacity(0.3))
                    .padding(.leading, 60)
            }
        }
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
    }

    @ViewBuilder
    private func modelRow(_ model: ModelItem) -> some View {
        HStack(spacing: Spacing.sm) {
            // Avatar — real image from server, letter fallback
            // Hidden models get an eye.slash badge overlaid on the avatar
            ZStack(alignment: .bottomTrailing) {
                ModelAvatar(
                    size: 36,
                    imageURL: model.resolveAvatarURL(baseURL: dependencies.apiClient?.baseURL ?? ""),
                    label: model.name,
                    authToken: dependencies.apiClient?.network.authToken
                )
                .opacity(model.isHidden ? 0.5 : 1.0)

                if model.isHidden {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Color.blue)
                        .clipShape(Circle())
                        .offset(x: 3, y: 3)
                }
            }

            // Name + badge + ID
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    Text(model.isPublic ? "PUBLIC" : "PRIVATE")
                        .scaledFont(size: 9, weight: .bold)
                        .foregroundStyle(model.isPublic ? Color.green : theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            (model.isPublic ? Color.green : theme.textTertiary).opacity(0.12)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                Text(model.id)
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Enable/Disable toggle (green = active)
            Toggle("", isOn: Binding(
                get: { model.isActive },
                set: { _ in Task { await viewModel.toggleModelEnabled(id: model.id) } }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .scaleEffect(0.8)
            .frame(width: 44)

            // ✏️ Edit button — always enabled for admins (Admin Console is admin-only)
            Button {
                Task { await openEditor(for: model) }
            } label: {
                if isLoadingEditId == model.id {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "pencil")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoadingEditId != nil)

            // ⋯ 3-dot menu
            Menu {
                Button {
                    Task { await viewModel.toggleModelVisibility(id: model.id) }
                } label: {
                    Label(
                        model.isHidden ? "Show Model" : "Hide Model",
                        systemImage: model.isHidden ? "eye" : "eye.slash"
                    )
                }

                Button {
                    // Copy a shareable link to the model
                    if let base = dependencies.apiClient?.baseURL {
                        let link = "\(base)/?models=\(model.id)"
                        UIPasteboard.general.string = link
                    }
                } label: {
                    Label("Copy Link", systemImage: "link")
                }

                Button {
                    Task { await exportSingleModel(id: model.id) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }

    // MARK: - Open Editor

    private func openEditor(for model: ModelItem) async {
        guard let api = dependencies.apiClient else { return }
        isLoadingEditId = model.id
        defer { isLoadingEditId = nil }
        do {
            let detail = try await api.getWorkspaceModelDetail(id: model.id)
            editingModelDetail = detail
        } catch {
            // If not found as workspace model, create a default detail for it
            editingModelDetail = ModelDetail(
                id: model.id,
                name: model.name,
                baseModelId: model.baseModelId ?? model.id,
                description: model.description
            )
        }
    }

    // MARK: - Export Single Model

    private func exportSingleModel(id: String) async {
        guard let api = dependencies.apiClient else { return }
        do {
            let detail = try await api.getWorkspaceModelDetail(id: id)
            let payload = detail.toUpdatePayload()
            let data = try JSONSerialization.data(withJSONObject: [payload], options: .prettyPrinted)
            exportData = data
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Resolve Avatar URL

    /// Resolves a profileImageURL string (data URI, absolute URL, or relative path) into a URL?.
    /// Data URIs are returned as nil — ModelAvatar handles them via its own data-URI path.
    private func resolvedAvatarURL(_ profileImageURL: String?) -> URL? {
        guard let prof = profileImageURL, !prof.isEmpty, !prof.hasPrefix("data:") else { return nil }
        if prof.hasPrefix("http://") || prof.hasPrefix("https://") {
            return URL(string: prof)
        }
        // Relative path — prefix with baseURL
        if let base = dependencies.apiClient?.baseURL {
            let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
            return URL(string: cleanBase + (prof.hasPrefix("/") ? prof : "/\(prof)"))
        }
        return nil
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .scaledFont(size: 13)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .padding(Spacing.sm)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
    }
}

// MARK: - Manage Sheet

// MARK: - Ollama URL Index Wrapper (Identifiable for sheet(item:))

private struct OllamaURLIdxWrapper: Identifiable {
    let idx: Int
    var id: Int { idx }
}

// MARK: - AdminModelsManageSheet

struct AdminModelsManageSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencyContainer.self) private var dependencies
    let viewModel: AdminModelsSettingsViewModel
    var onManageOllama: (Int) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    ollamaSection
                    Spacer(minLength: 40)
                }
                .padding(Spacing.screenPadding)
            }
            .background(theme.background)
            .navigationTitle("Manage Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var ollamaSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Ollama")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .textCase(.uppercase)

            if viewModel.ollamaConfig.ollamaBaseURLs.isEmpty {
                HStack {
                    Image(systemName: "info.circle")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                    Text("No Ollama URLs configured. Add one in Admin → Connections.")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Spacing.md)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
            } else {
                // One row per Ollama URL with a "Manage" button
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.ollamaConfig.ollamaBaseURLs.enumerated()), id: \.offset) { idx, url in
                        HStack {
                            Text(url.isEmpty ? "(no URL)" : url)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Manage") {
                                onManageOllama(idx)
                            }
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                            .buttonStyle(.plain)
                        }
                        .padding(Spacing.md)

                        if idx < viewModel.ollamaConfig.ollamaBaseURLs.count - 1 {
                            Divider().padding(.horizontal, Spacing.md)
                        }
                    }
                }
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
            }

            if let err = viewModel.ollamaTagsError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .scaledFont(size: 13)
                    Text(err)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Global Settings Sheet

struct AdminModelsGlobalSettingsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: AdminModelsSettingsViewModel

    @State private var selectedTab: SettingsTab = .defaults
    @State private var showSuggestionsImporter = false

    enum SettingsTab: String, CaseIterable {
        case defaults = "Defaults"
        case display = "Display"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab Picker
                Picker("Tab", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)

                Divider().background(theme.inputBorder.opacity(0.2))

                ScrollView {
                    if selectedTab == .defaults {
                        defaultsTabContent
                    } else {
                        displayTabContent
                    }
                }
            }
            .background(theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task {
                                await viewModel.save()
                                if viewModel.errorMessage == nil {
                                    dismiss()
                                }
                            }
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
        // Suggestions JSON importer
        .fileImporter(
            isPresented: $showSuggestionsImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importSuggestionsFromURL(url)
            case .failure:
                break
            }
        }
    }

    // MARK: - Import Suggestions Helper

    private func importSuggestionsFromURL(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }

        // Accept either [[String:Any]] directly or {"suggestions": [...]}
        var rawArray: [[String: Any]] = []
        if let arr = json as? [[String: Any]] {
            rawArray = arr
        } else if let dict = json as? [String: Any],
                  let arr = dict["suggestions"] as? [[String: Any]] {
            rawArray = arr
        }

        let imported = rawArray.compactMap { SuggestionPrompt(json: $0) }
        if !imported.isEmpty {
            viewModel.suggestions = imported
        }
    }

    // MARK: - Defaults Tab

    private var defaultsTabContent: some View {
        VStack(spacing: Spacing.lg) {
            if let err = viewModel.errorMessage {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).scaledFont(size: 13).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .padding(Spacing.sm)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
            }

            selectedModelsSection
            promptSuggestionsSection
            modelCapabilitiesSection
            modelParamsSection

            Button("Reset") {
                resetAll()
            }
            .scaledFont(size: 14)
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screenPadding)

            Spacer(minLength: 40)
        }
        .padding(.top, Spacing.md)
    }

    private func resetAll() {
        viewModel.defaultModelId = ""
        viewModel.defaultPinnedModelIds = []
        viewModel.suggestions = []
        viewModel.capVision = true; viewModel.capFileUpload = true
        viewModel.capFileContext = true; viewModel.capWebSearch = true
        viewModel.capImageGeneration = true; viewModel.capCodeInterpreter = true
        viewModel.capTerminal = false; viewModel.capUsage = false
        viewModel.capCitations = true; viewModel.capStatusUpdates = true
        viewModel.capBuiltinTools = true
        viewModel.defWebSearch = true; viewModel.defImageGeneration = true
        viewModel.defCodeInterpreter = false
        viewModel.btTime = true; viewModel.btMemory = true; viewModel.btChats = true
        viewModel.btNotes = true; viewModel.btKnowledge = true; viewModel.btChannels = true
        viewModel.btWebSearch = true; viewModel.btImageGeneration = true
        viewModel.btCodeInterpreter = true; viewModel.btTaskManagement = true
        viewModel.btAutomations = true; viewModel.btCalendar = true
        viewModel.streamChat = nil; viewModel.streamDeltaChunkSize = nil
        viewModel.functionCalling = nil; viewModel.reasoningTags = nil
        viewModel.paramTemperature = nil; viewModel.paramSeed = nil
        viewModel.paramMaxTokens = nil; viewModel.paramTopK = nil
        viewModel.paramTopP = nil; viewModel.paramMinP = nil
        viewModel.paramFrequencyPenalty = nil; viewModel.paramPresencePenalty = nil
        viewModel.paramMirostat = nil; viewModel.paramMirostatEta = nil
        viewModel.paramMirostatTau = nil; viewModel.paramRepeatLastN = nil
        viewModel.paramTfsZ = nil; viewModel.paramRepeatPenalty = nil
        viewModel.paramNumKeep = nil; viewModel.paramNumCtx = nil
        viewModel.paramNumBatch = nil; viewModel.paramReasoningEffort = nil
        viewModel.paramFormat = nil; viewModel.paramThinkMode = .default
    }

    // MARK: - Selected Models

    private var selectedModelsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Selected Models")

            AdminSettingsRow(title: "Default Model") {
                Picker("", selection: $viewModel.defaultModelId) {
                    Text("Select a model").tag("")
                    ForEach(viewModel.models, id: \.id) { m in
                        Text(m.name).tag(m.id)
                    }
                }
                .labelsHidden()
                .scaledFont(size: 13)
            }

            // Pinned models
            VStack(alignment: .leading, spacing: 4) {
                Text("Pinned Models")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, 2)

                if viewModel.models.isEmpty {
                    Text("No models selected")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.bottom, 4)
                } else {
                    ForEach(viewModel.models, id: \.id) { model in
                        let isPinned = viewModel.defaultPinnedModelIds.contains(model.id)
                        Button {
                            if isPinned {
                                viewModel.defaultPinnedModelIds.removeAll { $0 == model.id }
                            } else {
                                viewModel.defaultPinnedModelIds.append(model.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: isPinned ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isPinned ? theme.brandPrimary : theme.textTertiary)
                                    .scaledFont(size: 16)
                                Text(model.name)
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, Spacing.screenPadding)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Prompt Suggestions

    @State private var showSuggestions = false

    private var promptSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation { showSuggestions.toggle() }
            } label: {
                HStack {
                    sectionHeader("Prompt Suggestions")
                    Spacer()
                    Image(systemName: showSuggestions ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.trailing, Spacing.screenPadding)
                }
            }
            .buttonStyle(.plain)

            AnimatedPresence(visible: showSuggestions) {
                VStack(spacing: Spacing.md) {
                    // Use ID-based iteration to avoid index-out-of-bounds crash on delete
                    ForEach(viewModel.suggestions) { suggestion in
                        if let idx = viewModel.suggestions.firstIndex(where: { $0.id == suggestion.id }) {
                            suggestionCard(index: idx)
                        }
                    }

                    HStack(spacing: Spacing.sm) {
                        Button {
                            viewModel.suggestions.append(SuggestionPrompt(content: "", title: "", subtitle: ""))
                        } label: {
                            Label("Add Suggestion", systemImage: "plus.circle")
                                .scaledFont(size: 13)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            showSuggestionsImporter = true
                        } label: {
                            Label("Import JSON", systemImage: "square.and.arrow.down")
                                .scaledFont(size: 13)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                .padding(.horizontal, Spacing.screenPadding)
            }
        }
    }

    @ViewBuilder
    private func suggestionCard(index i: Int) -> some View {
        // Guard against stale index after deletion
        if i < viewModel.suggestions.count {
            VStack(spacing: 0) {
                // Title
                HStack {
                    Text("Title")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 56, alignment: .leading)
                    TextField("e.g. Help me study…", text: Binding(
                        get: { i < viewModel.suggestions.count ? viewModel.suggestions[i].title : "" },
                        set: { if i < viewModel.suggestions.count { viewModel.suggestions[i].title = $0 } }
                    ))
                    .scaledFont(size: 13)
                    .textFieldStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 8)

                Divider().background(theme.inputBorder.opacity(0.3))

                // Subtitle
                HStack {
                    Text("Subtitle")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 56, alignment: .leading)
                    TextField("e.g. for a vocabulary quiz", text: Binding(
                        get: { i < viewModel.suggestions.count ? viewModel.suggestions[i].subtitle : "" },
                        set: { if i < viewModel.suggestions.count { viewModel.suggestions[i].subtitle = $0 } }
                    ))
                    .scaledFont(size: 13)
                    .textFieldStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 8)

                Divider().background(theme.inputBorder.opacity(0.3))

                // Content (the actual prompt)
                HStack(alignment: .top) {
                    Text("Prompt")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 56, alignment: .leading)
                        .padding(.top, 2)
                    TextField("Enter the prompt content…", text: Binding(
                        get: { i < viewModel.suggestions.count ? viewModel.suggestions[i].content : "" },
                        set: { if i < viewModel.suggestions.count { viewModel.suggestions[i].content = $0 } }
                    ), axis: .vertical)
                    .scaledFont(size: 13)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 8)
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    // Safe delete — only remove if index is still valid
                    if i < viewModel.suggestions.count {
                        viewModel.suggestions.remove(at: i)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red.opacity(0.7))
                        .scaledFont(size: 18)
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
    }

    // MARK: - Model Capabilities

    @State private var showCapabilities = true

    private var modelCapabilitiesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation { showCapabilities.toggle() }
            } label: {
                HStack {
                    sectionHeader("Model Capabilities")
                    Spacer()
                    Image(systemName: showCapabilities ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.trailing, Spacing.screenPadding)
                }
            }
            .buttonStyle(.plain)

            AnimatedPresence(visible: showCapabilities) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Capabilities")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .padding(.horizontal, Spacing.screenPadding)

                    capabilityGrid

                    Text("Default Features")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.xs)

                    defaultFeaturesRow

                    Text("Builtin Tools")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.xs)

                    builtinToolsGrid
                }
            }
        }
    }

    private var capabilityGrid: some View {
        let items: [(String, Binding<Bool>)] = [
            ("Vision", $viewModel.capVision),
            ("File Upload", $viewModel.capFileUpload),
            ("File Context", $viewModel.capFileContext),
            ("Web Search", $viewModel.capWebSearch),
            ("Image Generation", $viewModel.capImageGeneration),
            ("Code Interpreter", $viewModel.capCodeInterpreter),
            ("Terminal", $viewModel.capTerminal),
            ("Usage", $viewModel.capUsage),
            ("Citations", $viewModel.capCitations),
            ("Status Updates", $viewModel.capStatusUpdates),
            ("Builtin Tools", $viewModel.capBuiltinTools)
        ]
        return capCheckboxGrid(items: items)
    }

    private var defaultFeaturesRow: some View {
        let items: [(String, Binding<Bool>)] = [
            ("Web Search", $viewModel.defWebSearch),
            ("Image Generation", $viewModel.defImageGeneration),
            ("Code Interpreter", $viewModel.defCodeInterpreter)
        ]
        return capCheckboxGrid(items: items)
    }

    private var builtinToolsGrid: some View {
        let items: [(String, Binding<Bool>)] = [
            ("Time & Calculation", $viewModel.btTime),
            ("Memory", $viewModel.btMemory),
            ("Chat History", $viewModel.btChats),
            ("Notes", $viewModel.btNotes),
            ("Knowledge Base", $viewModel.btKnowledge),
            ("Files", $viewModel.btFiles),
            ("Channels", $viewModel.btChannels),
            ("Notifications", $viewModel.btNotifications),
            ("Web Search", $viewModel.btWebSearch),
            ("Image Generation", $viewModel.btImageGeneration),
            ("Code Interpreter", $viewModel.btCodeInterpreter),
            ("Task Management", $viewModel.btTaskManagement),
            ("Automations", $viewModel.btAutomations),
            ("Calendar", $viewModel.btCalendar),
            ("Sub-agents", $viewModel.btSubagents)
        ]
        return capCheckboxGrid(items: items)
    }

    private func capCheckboxGrid(items: [(String, Binding<Bool>)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.xs) {
            ForEach(items, id: \.0) { label, binding in
                Button {
                    binding.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: binding.wrappedValue ? "checkmark.square.fill" : "square")
                            .foregroundStyle(binding.wrappedValue ? theme.brandPrimary : theme.textTertiary)
                            .scaledFont(size: 15)
                        Text(label)
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Model Params

    @State private var showParams = true

    private var modelParamsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation { showParams.toggle() }
            } label: {
                HStack {
                    sectionHeader("Model Parameters")
                    Spacer()
                    Image(systemName: showParams ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.trailing, Spacing.screenPadding)
                }
            }
            .buttonStyle(.plain)

            AnimatedPresence(visible: showParams) {
                VStack(spacing: 0) {
                    // Streaming & Function Calling
                    paramGroupHeader("Streaming & Function Calling")
                    adminCyclingBoolPillRow(label: "Stream Chat Response", value: $viewModel.streamChat)
                    paramDivider
                    adminIntPillRow(label: "Stream Delta Chunk Size", value: $viewModel.streamDeltaChunkSize,
                                    range: 1...65536, step: 1, defaultHint: "1")
                    paramDivider
                    adminCyclingPillRow(
                        label: "Function Calling",
                        value: $viewModel.functionCalling,
                        states: [("Native", "native")]
                    )
                    paramDivider
                    reasoningTagsRow

                    // Basic
                    paramGroupHeader("Basic")
                    adminDoubleParamRow(label: "Temperature", value: $viewModel.paramTemperature,
                                       range: 0...2, step: 0.05, defaultHint: "0.8")
                    paramDivider
                    adminIntParamRow(label: "Max Tokens", value: $viewModel.paramMaxTokens,
                                     range: -1...131072, step: 1, defaultHint: "-1")
                    paramDivider
                    adminIntParamRow(label: "Seed", value: $viewModel.paramSeed,
                                     range: 0...9_999_999, step: 1, defaultHint: "Random")

                    // Sampling
                    paramGroupHeader("Sampling")
                    adminIntParamRow(label: "top_k", value: $viewModel.paramTopK,
                                     range: 0...1000, step: 1, defaultHint: "40")
                    paramDivider
                    adminDoubleParamRow(label: "top_p", value: $viewModel.paramTopP,
                                        range: 0...1, step: 0.05, defaultHint: "0.9")
                    paramDivider
                    adminDoubleParamRow(label: "min_p", value: $viewModel.paramMinP,
                                        range: 0...1, step: 0.05, defaultHint: "0.0")
                    paramDivider
                    adminDoubleParamRow(label: "frequency_penalty", value: $viewModel.paramFrequencyPenalty,
                                        range: -2...2, step: 0.05, defaultHint: "1.1")
                    paramDivider
                    adminDoubleParamRow(label: "presence_penalty", value: $viewModel.paramPresencePenalty,
                                        range: -2...2, step: 0.05, defaultHint: "0.0")

                    // Mirostat
                    paramGroupHeader("Mirostat")
                    adminIntParamRow(label: "mirostat", value: $viewModel.paramMirostat,
                                     range: 0...2, step: 1, defaultHint: "0")
                    paramDivider
                    adminDoubleParamRow(label: "mirostat_eta", value: $viewModel.paramMirostatEta,
                                        range: 0...1, step: 0.01, defaultHint: "0.1")
                    paramDivider
                    adminDoubleParamRow(label: "mirostat_tau", value: $viewModel.paramMirostatTau,
                                        range: 0...10, step: 0.1, defaultHint: "5.0")

                    // Repeat / Tail-Free
                    paramGroupHeader("Repeat / Tail-Free")
                    adminIntParamRow(label: "repeat_last_n", value: $viewModel.paramRepeatLastN,
                                     range: -1...128, step: 1, defaultHint: "64")
                    paramDivider
                    adminDoubleParamRow(label: "tfs_z", value: $viewModel.paramTfsZ,
                                        range: 0...2, step: 0.05, defaultHint: "1.0")
                    paramDivider
                    adminDoubleParamRow(label: "repeat_penalty", value: $viewModel.paramRepeatPenalty,
                                        range: -2...2, step: 0.05, defaultHint: "1.1")

                    // Ollama
                    paramGroupHeader("Ollama")
                    adminIntParamRow(label: "num_keep", value: $viewModel.paramNumKeep,
                                     range: -1...10_240_000, step: 1, defaultHint: "24")
                    paramDivider
                    adminIntParamRow(label: "num_ctx", value: $viewModel.paramNumCtx,
                                     range: -1...10_240_000, step: 1, defaultHint: "2048")
                    paramDivider
                    adminIntParamRow(label: "num_batch", value: $viewModel.paramNumBatch,
                                     range: 256...8192, step: 256, defaultHint: "512")
                    paramDivider
                    adminThinkRow
                    paramDivider
                    adminTextParamRow(label: "format", value: $viewModel.paramFormat, placeholder: "e.g. json")

                    // Reasoning
                    paramGroupHeader("Reasoning")
                    adminReasoningEffortRow
                }
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
                .padding(.horizontal, Spacing.screenPadding)
            }
        }
    }

    // MARK: - Param Helpers

    private var paramDivider: some View {
        Divider()
            .background(theme.inputBorder.opacity(0.2))
            .padding(.leading, Spacing.screenPadding)
    }

    private func paramGroupHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.top, Spacing.sm)
            .padding(.bottom, 2)
    }

    // Cycling pill for String? (nil = Default)
    @ViewBuilder
    private func adminCyclingPillRow(
        label: String,
        value: Binding<String?>,
        states: [(label: String, value: String?)]
    ) -> some View {
        let current = value.wrappedValue
        let allStates: [(label: String, value: String?)] = [("Default", nil)] + states
        let currentLabel = allStates.first(where: { $0.value == current })?.label ?? "Default"
        let currentIdx = allStates.firstIndex(where: { $0.value == current }) ?? 0

        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                let nextIdx = (currentIdx + 1) % allStates.count
                value.wrappedValue = allStates[nextIdx].value
            } label: {
                Text(currentLabel)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.brandPrimary.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(theme.brandPrimary.opacity(0.35), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.sm)
    }

    // Cycling pill for Bool? (nil = Default)
    @ViewBuilder
    private func adminCyclingBoolPillRow(
        label: String,
        value: Binding<Bool?>,
        onLabel: String = "Enabled",
        offLabel: String = "Disabled"
    ) -> some View {
        let current = value.wrappedValue
        let currentLabel: String = {
            switch current {
            case .some(true): return onLabel
            case .some(false): return offLabel
            case .none: return "Default"
            }
        }()

        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                switch current {
                case .none:        value.wrappedValue = true
                case .some(true):  value.wrappedValue = false
                case .some(false): value.wrappedValue = nil
                }
            } label: {
                Text(currentLabel)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.brandPrimary.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(theme.brandPrimary.opacity(0.35), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.sm)
    }

    // Double slider row (nil = Default)
    @ViewBuilder
    private func adminDoubleParamRow(
        label: String,
        value: Binding<Double?>,
        range: ClosedRange<Double>,
        step: Double,
        defaultHint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if let v = value.wrappedValue {
                    Text(String(format: step < 0.01 ? "%.3f" : "%.2f", v))
                        .scaledFont(size: 12)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                    Button {
                        value.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textTertiary)
                            .scaledFont(size: 15)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Default (\(defaultHint))")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                    Button {
                        value.wrappedValue = Double(defaultHint) ?? range.lowerBound
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(theme.brandPrimary)
                            .scaledFont(size: 15)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let v = value.wrappedValue {
                Slider(
                    value: Binding(get: { v }, set: { value.wrappedValue = ($0 / step).rounded() * step }),
                    in: range,
                    step: step
                )
                .tint(theme.brandPrimary)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
        .padding(.bottom, value.wrappedValue != nil ? 0 : Spacing.sm)
    }

    // Int slider row (nil = Default)
    @ViewBuilder
    private func adminIntParamRow(
        label: String,
        value: Binding<Int?>,
        range: ClosedRange<Double>,
        step: Double,
        defaultHint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if let v = value.wrappedValue {
                    Text("\(v)")
                        .scaledFont(size: 12)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                    Button {
                        value.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textTertiary)
                            .scaledFont(size: 15)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Default (\(defaultHint))")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                    Button {
                        value.wrappedValue = Int(Double(defaultHint) ?? range.lowerBound)
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(theme.brandPrimary)
                            .scaledFont(size: 15)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let v = value.wrappedValue {
                Slider(
                    value: Binding(
                        get: { Double(v) },
                        set: { value.wrappedValue = Int(($0 / step).rounded() * step) }
                    ),
                    in: range,
                    step: step
                )
                .tint(theme.brandPrimary)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
        .padding(.bottom, value.wrappedValue != nil ? 0 : Spacing.sm)
    }

    // Int pill row for small values (stream delta chunk size)
    @ViewBuilder
    private func adminIntPillRow(
        label: String,
        value: Binding<Int?>,
        range: ClosedRange<Double>,
        step: Double,
        defaultHint: String
    ) -> some View {
        adminIntParamRow(label: label, value: value, range: range, step: step, defaultHint: defaultHint)
    }

    // Text field row
    @ViewBuilder
    private func adminTextParamRow(label: String, value: Binding<String?>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            TextField(placeholder, text: Binding(
                get: { value.wrappedValue ?? "" },
                set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
            ))
            .multilineTextAlignment(.trailing)
            .scaledFont(size: 13)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: 160)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.sm)
    }

    // Think (Ollama) row
    @ViewBuilder
    private var adminThinkRow: some View {
        let current = viewModel.paramThinkMode
        let isCustom: Bool = { if case .custom = current { return true }; return false }()
        let currentLabel: String = {
            switch current {
            case .default:       return "Default"
            case .on:            return "On"
            case .off:           return "Off"
            case .custom(let s): return s.isEmpty ? "Custom" : s
            }
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("think (Ollama)")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button {
                    switch viewModel.paramThinkMode {
                    case .default: viewModel.paramThinkMode = .on
                    case .on:      viewModel.paramThinkMode = .off
                    case .off:     viewModel.paramThinkMode = .custom(viewModel.paramThinkCustom ?? "")
                    case .custom:  viewModel.paramThinkMode = .default
                    }
                } label: {
                    Text(currentLabel)
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.brandPrimary.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(theme.brandPrimary.opacity(0.35), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
            if isCustom {
                TextField("budget string, e.g. medium", text: Binding(
                    get: { viewModel.paramThinkCustom ?? "" },
                    set: {
                        viewModel.paramThinkCustom = $0
                        viewModel.paramThinkMode = .custom($0)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .scaledFont(size: 13)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.sm)
    }

    // reasoning_effort row: Default → low → medium → high → xhigh → Custom (free-text)
    // Emits one or two rows: the pill cycling row, plus (when in Custom mode) a plain text field row.
    @ViewBuilder
    private var adminReasoningEffortRow: some View {
        let presets: [String] = ["low", "medium", "high", "xhigh"]
        let current = viewModel.paramReasoningEffort
        let isCustom = current != nil && !presets.contains(current!)

        let currentLabel: String = {
            if current == nil { return "Default" }
            if presets.contains(current!) { return current! }
            return "Custom"
        }()

        // Row 1: pill cycling button
        HStack {
            Text("reasoning_effort")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                let next: String?
                if current == nil {
                    next = "low"
                } else if current == "low" {
                    next = "medium"
                } else if current == "medium" {
                    next = "high"
                } else if current == "high" {
                    next = "xhigh"
                } else if current == "xhigh" {
                    next = ""
                } else {
                    next = nil
                }
                viewModel.paramReasoningEffort = next
            } label: {
                Text(currentLabel)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.brandPrimary.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(theme.brandPrimary.opacity(0.35), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.sm)

        // Row 2: plain text field, only shown in Custom mode
        if isCustom || current == "" {
            Divider()
                .background(theme.inputBorder.opacity(0.2))
                .padding(.leading, Spacing.screenPadding)
            HStack {
                Text("Custom value")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                TextField("e.g. auto, xhigh…", text: Binding(
                    get: { viewModel.paramReasoningEffort ?? "" },
                    set: { viewModel.paramReasoningEffort = $0 }
                ))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .scaledFont(size: 13)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: 200)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, Spacing.sm)
        }
    }

    // Reasoning tags row (shows comma-separated tags)
    @ViewBuilder
    private var reasoningTagsRow: some View {
        HStack {
            Text("Reasoning Tags")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            TextField("e.g. think,thinking", text: Binding(
                get: { viewModel.reasoningTags?.joined(separator: ",") ?? "" },
                set: { raw in
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        viewModel.reasoningTags = nil
                    } else {
                        viewModel.reasoningTags = trimmed.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
            ))
            .multilineTextAlignment(.trailing)
            .scaledFont(size: 13)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: 200)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Display Tab

    private var displayTabContent: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Reorder Models")
                .padding(.top, Spacing.md)

            reorderList

            Spacer(minLength: 40)
        }
    }

    private var reorderList: some View {
        let orderedModels = viewModel.modelOrderList.compactMap { id in
            viewModel.models.first { $0.id == id }
        }

        return List {
            ForEach(orderedModels, id: \.id) { model in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(theme.textTertiary)
                        .scaledFont(size: 16)
                    Text(model.name)
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                }
                .padding(.vertical, 4)
                .listRowBackground(theme.surfaceContainer)
                .listRowSeparatorTint(theme.inputBorder.opacity(0.3))
            }
            .onMove { source, destination in
                viewModel.modelOrderList.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
        .frame(minHeight: CGFloat(viewModel.modelOrderList.count) * 52)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .textCase(.uppercase)
            .padding(.horizontal, Spacing.screenPadding)
    }
}

// MARK: - Admin Settings Row

private struct AdminSettingsRow<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack {
            Text(title)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            content()
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
    }
}

// MARK: - ShareSheet Wrapper

private struct ShareSheetWrapper: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
