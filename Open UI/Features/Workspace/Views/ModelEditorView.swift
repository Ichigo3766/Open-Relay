import SwiftUI
import PhotosUI
import os.log

// MARK: - ModelEditorView

/// Sheet for creating or editing a custom Model.
/// Mirrors SkillEditorView/KnowledgeEditorView in structure and access-grant UI.
struct ModelEditorView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private let logger = Logger(subsystem: "com.openui", category: "ModelEditor")

    // MARK: - Input

    var existingModel: ModelDetail?
    /// When set, pre-fills the editor with this model's data in "create new" mode (clone flow).
    var cloneSource: ModelDetail? = nil
    /// Admin → Models: `existingModel` is a connection base model with no DB record
    /// yet. Saving creates the record (POST /create) instead of updating.
    var isNewBaseRecord: Bool = false
    var onSave: ((ModelDetail) -> Void)?

    // MARK: - Basic Info

    @State private var name = ""
    @State private var modelId = ""
    @State private var baseModelId = ""
    @State private var baseModelDisplayName = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var idManuallyEdited = false
    @State private var isAutoSettingId = false

    // MARK: - Profile Image

    @State private var profileImageURL: String? = nil
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedImageData: Data? = nil
    @State private var isUploadingProfileImage = false

    // MARK: - System Prompt

    @State private var systemPrompt = ""
    @State private var isSystemPromptExpanded = false

    // MARK: - Active

    @State private var isActive = true
    @State private var initialIsActive = true
    @State private var isTogglingActive = false

    // MARK: - Capabilities

    @State private var capVision = true
    @State private var capFileUpload = true
    @State private var capFileContext = true
    @State private var capWebSearch = true
    @State private var capImageGeneration = true
    @State private var capCodeInterpreter = true
    @State private var capTerminal = true
    @State private var capUsage = false
    @State private var capCitations = true
    @State private var capStatusUpdates = true
    @State private var capMemory = true
    @State private var capBuiltinTools = true

    // MARK: - Default Terminal (meta.terminalId)

    @State private var terminalId: String = ""
    @State private var terminalServers: [TerminalServer] = []

    /// Server's original meta (preserved on save so unmanaged keys aren't wiped).
    @State private var originalMetaJSON: Data? = nil

    // MARK: - Default Features

    @State private var defaultWebSearch = true
    @State private var defaultImageGen = false
    @State private var defaultCodeInterpreter = false

    // MARK: - Builtin Tools

    @State private var builtinTime = true
    @State private var builtinUserInput = true
    @State private var builtinMemory = true
    @State private var builtinChats = true
    @State private var builtinNotes = true
    @State private var builtinKnowledge = true
    @State private var builtinFiles = true
    @State private var builtinChannels = true
    @State private var builtinNotifications = true
    @State private var builtinTaskManagement = true
    @State private var builtinAutomations = true
    @State private var builtinCalendar = true
    @State private var builtinSubagents = true
    @State private var builtinWebSearch = true
    @State private var builtinImageGen = true
    @State private var builtinCodeInterpreter = true

    // MARK: - Knowledge

    @State private var knowledgeItems: [ModelKnowledgeEntry] = []
    @State private var showKnowledgePicker = false

    // MARK: - Tools, Skills, Filters

    @State private var selectedToolIds: Set<String> = []
    @State private var selectedFilterIds: Set<String> = []
    @State private var defaultFilterIds: Set<String> = []
    @State private var selectedActionIds: Set<String> = []
    @State private var allTools: [(id: String, name: String)] = []
    @State private var allFilters: [(id: String, name: String, isGlobal: Bool, hasToggle: Bool)] = []
    @State private var allActions: [(id: String, name: String)] = []
    /// Action-type functions (type == "action") with global/active state.
    /// Used for the "Actions" section with global lock support.
    @State private var allActionFunctions: [(id: String, name: String, isGlobal: Bool)] = []
    @State private var selectedActionFunctionIds: Set<String> = []
    @State private var isFetchingToolsAndFunctions = false

    // MARK: - Suggestion Prompts

    @State private var suggestionPrompts: [SuggestionPrompt] = []
    @State private var useCustomPrompts: Bool = false

    // MARK: - TTS Voice

    @State private var ttsVoice = ""

    // MARK: - Base Model Picker

    @State private var availableModels: [AIModel] = []
    @State private var showBaseModelPicker = false
    @State private var isFetchingModels = false

    // MARK: - Advanced Params

    @State private var showAdvancedParams = false

    @State private var advStreamResponse: Bool? = nil
    @State private var advStreamDeltaChunkSize: Int? = nil
    @State private var advFunctionCalling: String? = nil
    @State private var advCompactTokenThreshold: Int? = nil
    @State private var advReasoningEffort: String? = nil
    @State private var advReasoningTagsEnabled: Bool? = nil
    @State private var advReasoningTagStart: String? = nil
    @State private var advReasoningTagEnd: String? = nil
    @State private var advSeed: Int? = nil
    @State private var advStopSequences: String? = nil
    @State private var advTemperature: Double? = nil
    @State private var advLogitBias: String? = nil
    @State private var advMaxTokens: Int? = nil
    @State private var advTopK: Int? = nil
    @State private var advTopP: Double? = nil
    @State private var advMinP: Double? = nil
    @State private var advFrequencyPenalty: Double? = nil
    @State private var advPresencePenalty: Double? = nil
    @State private var advMirostat: Int? = nil
    @State private var advMirostatEta: Double? = nil
    @State private var advMirostatTau: Double? = nil
    @State private var advRepeatLastN: Int? = nil
    @State private var advTfsZ: Double? = nil
    @State private var advRepeatPenalty: Double? = nil
    @State private var advUseMmap: Bool? = nil
    @State private var advUseMlock: Bool? = nil
    @State private var advThink: Bool? = nil
    @State private var advThinkCustom: String? = nil
    @State private var advFormat: String? = nil
    @State private var advNumKeep: Int? = nil
    @State private var advNumCtx: Int? = nil
    @State private var advNumBatch: Int? = nil
    @State private var advNumThread: Int? = nil
    @State private var advNumGpu: Int? = nil
    @State private var advKeepAlive: String? = nil
    @State private var customParams: [(key: String, value: String)] = []

    // MARK: - Access Control

    @State private var isPrivate = true
    @State private var localAccessGrants: [AccessGrant] = []
    @State private var resolvedGroups: [String: GroupResponse] = [:]
    @State private var isUpdatingAccess = false
    @State private var accessUpdateError: String?

    // MARK: - UI State

    @State private var isSaving = false
    @State private var validationError: String? = nil
    @State private var showDiscardConfirm = false
    /// Fingerprint of the editor state right after loading — used by `hasChanges`.
    @State private var baselinePayload: Data? = nil

    // MARK: - Background image (meta.background_image_url)

    @State private var pendingBackground: ModelBackgroundImage.Validated? = nil
    @State private var backgroundRemoved = false
    @State private var backgroundURL: String? = nil
    /// Set during `save()` once the picked image is uploaded; read by `buildDetail`.
    @State private var pendingUploadedPath: String? = nil

    // MARK: - Translations (meta.i18n)

    @State private var i18n: LocalizedMap = [:]

    // MARK: - Suggestions (voices, tags)

    @State private var voiceSuggestions: [(id: String, name: String)] = []
    @State private var tagSuggestions: [String] = []

    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case name, modelId, description, systemPrompt, ttsVoice, newSuggestion }

    // MARK: - Computed

    private var manager: ModelManager? { dependencies.modelManager }
    private var allUsers: [ChannelMember] { manager?.allUsers ?? [] }
    private var isEditing: Bool { existingModel != nil }
    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }


    /// Whether this is a provider model (not a custom model wrapping another).
    /// Provider models have no base_model_id. The web UI hides the base model
    /// picker for these models since they ARE the base model.
    private var isProviderModel: Bool {
        isEditing && existingModel?.baseModelId == nil
    }

    private var hasChanges: Bool {
        guard existingModel != nil else {
            return !name.isEmpty || !modelId.isEmpty || !systemPrompt.isEmpty
        }
        // Compare the payload the editor would send against the one it loaded.
        if pendingBackground != nil || backgroundRemoved { return true }
        guard let baseline = baselinePayload else { return true }
        return currentPayloadFingerprint != baseline
    }

    /// Fingerprint of everything `save()` would send (sorted-key JSON).
    private var currentPayloadFingerprint: Data? {
        var d = buildDetail(id: existingModel?.id ?? modelId.trimmingCharacters(in: .whitespaces))
        var grants = localAccessGrants
        if !isPrivate {
            grants.append(AccessGrant(id: "", userId: "*", groupId: nil, read: true, write: false))
        }
        d.accessGrants = grants
        return try? JSONSerialization.data(withJSONObject: d.toCreatePayload(), options: [.sortedKeys])
    }

    // Resolved profile image URL for displaying in the editor.
    // Returns nil for data URIs (handled via selectedImageData / dataURIImage).
    private var resolvedProfileImageURL: URL? {
        let urlString = profileImageURL ?? ""
        if urlString.hasPrefix("data:image") { return nil }
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return URL(string: urlString)
        }
        // For an existing model use the model avatar endpoint
        if let id = existingModel?.id, !id.isEmpty {
            let normalizedBase = serverBaseURL.hasSuffix("/") ? String(serverBaseURL.dropLast()) : serverBaseURL
            var comps = URLComponents(string: "\(normalizedBase)/api/v1/models/model/profile/image")
            comps?.queryItems = [URLQueryItem(name: "id", value: id)]
            return comps?.url
        }
        // New model with no user-picked image → show server default favicon
        let normalizedBase = serverBaseURL.hasSuffix("/") ? String(serverBaseURL.dropLast()) : serverBaseURL
        if !normalizedBase.isEmpty {
            return URL(string: "\(normalizedBase)/static/favicon.png")
        }
        return nil
    }

    // UIImage decoded from an existing data URI profileImageURL (edit mode, no new photo picked)
    private var dataURIImage: UIImage? {
        guard let urlString = profileImageURL, urlString.hasPrefix("data:image") else { return nil }
        guard selectedImageData == nil else { return nil } // already showing via selectedImageData
        if let commaIdx = urlString.firstIndex(of: ",") {
            let base64 = String(urlString[urlString.index(after: commaIdx)...])
            if let data = Data(base64Encoded: base64) {
                return UIImage(data: data)
            }
        }
        return nil
    }

    /// Mirrors `getBaseModelItems` in ModelEditor.svelte: hides self, presets
    /// (workspace models wrapping another model), arena and direct-connection
    /// models, and models hidden by an admin (unless admin, or already selected).
    private func baseModelAllowed(_ model: AIModel) -> Bool {
        let raw = model.rawModelItem ?? [:]
        let isCurrentBase = isEditing && model.id == baseModelId
        if model.id == modelId, !isCurrentBase { return false }
        let info = raw["info"] as? [String: Any]
        let infoBase = (info?["base_model_id"] as? String) ?? ""
        let isPreset = (raw["preset"] as? Bool ?? false) || !infoBase.isEmpty
        if isPreset && !isCurrentBase { return false }
        if raw["owned_by"] as? String == "arena" || raw["arena"] as? Bool == true { return false }
        if raw["direct"] as? Bool == true { return false }
        let hidden = ((info?["meta"] as? [String: Any])?["hidden"] as? Bool) ?? false
        let isAdmin = dependencies.authViewModel.currentUser?.role == .admin
        if hidden && !isAdmin && model.id != baseModelId { return false }
        return true
    }

    // MARK: - Suggestion helpers

    private var voiceMatches: [(id: String, name: String)] {
        let q = ttsVoice.trimmingCharacters(in: .whitespaces).lowercased()
        let list = voiceSuggestions.filter {
            q.isEmpty || $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
        // Hide the list once the field exactly matches a voice.
        if list.count == 1, list[0].id == ttsVoice { return [] }
        return Array(list.prefix(8))
    }

    private var currentTags: [String] {
        tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var tagMatches: [String] {
        let typing = (tags.components(separatedBy: ",").last ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let used = Set(currentTags.map { $0.lowercased() })
        return Array(tagSuggestions.filter {
            !used.contains($0.lowercased()) && (typing.isEmpty || $0.lowercased().contains(typing))
        }.prefix(8))
    }

    private func addTag(_ tag: String) {
        var parts = tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // Replace the fragment being typed, if any, else append.
        if let last = parts.last, !last.isEmpty, tag.lowercased().contains(last.lowercased()) { parts.removeLast() }
        parts = parts.filter { !$0.isEmpty }
        parts.append(tag)
        tags = parts.joined(separator: ", ")
        Haptics.play(.light)
    }

    @ViewBuilder
    private func suggestionChips(_ items: [(String, String)], onPick: @escaping (String) -> Void) -> some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.0) { item in
                        Button { onPick(item.0) } label: {
                            Text(item.1)
                                .scaledFont(size: 12)
                                .padding(.vertical, 4).padding(.horizontal, 10)
                                .background(Capsule().fill(theme.surfaceContainer))
                                .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func loadSuggestions() async {
        guard let api = dependencies.apiClient else { return }
        if let voices = try? await api.getVoices() {
            voiceSuggestions = voices.compactMap {
                guard let id = $0["id"] as? String else { return nil }
                return (id: id, name: ($0["name"] as? String) ?? id)
            }
        }
        // Web: preset models suggest tags from /models/tags; base-model records (admin) from /models/base/tags.
        let isBase = isNewBaseRecord || isProviderModel
        tagSuggestions = (try? await (isBase ? api.getBaseModelTags() : api.getWorkspaceModelTags())) ?? []
    }

    // MARK: - Slugify helper

    /// Converts a display name into a URL-safe slug: "Abhi AI" → "abhi-ai"
    static func slugify(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    profileImageSection
                    basicInfoSection
                    systemPromptSection
                    ModelTranslationsSection(i18n: $i18n)
                    ModelBackgroundSection(
                        currentURL: backgroundURL,
                        serverBaseURL: serverBaseURL,
                        authToken: authToken,
                        pending: $pendingBackground,
                        removed: $backgroundRemoved
                    )
                    // Advanced params extracted into a child struct to prevent stack overflow
                    ModelAdvancedParamsSection(
                        showAdvancedParams: $showAdvancedParams,
                        advStreamResponse: $advStreamResponse,
                        advStreamDeltaChunkSize: $advStreamDeltaChunkSize,
                        advFunctionCalling: $advFunctionCalling,
                        advCompactTokenThreshold: $advCompactTokenThreshold,
                        advReasoningEffort: $advReasoningEffort,
                        advReasoningTagsEnabled: $advReasoningTagsEnabled,
                        advReasoningTagStart: $advReasoningTagStart,
                        advReasoningTagEnd: $advReasoningTagEnd,
                        advSeed: $advSeed,
                        advStopSequences: $advStopSequences,
                        advTemperature: $advTemperature,
                        advLogitBias: $advLogitBias,
                        advMaxTokens: $advMaxTokens,
                        advTopK: $advTopK,
                        advTopP: $advTopP,
                        advMinP: $advMinP,
                        advFrequencyPenalty: $advFrequencyPenalty,
                        advPresencePenalty: $advPresencePenalty,
                        advMirostat: $advMirostat,
                        advMirostatEta: $advMirostatEta,
                        advMirostatTau: $advMirostatTau,
                        advRepeatLastN: $advRepeatLastN,
                        advTfsZ: $advTfsZ,
                        advRepeatPenalty: $advRepeatPenalty,
                        advUseMmap: $advUseMmap,
                        advUseMlock: $advUseMlock,
                        advThink: $advThink,
                        advThinkCustom: $advThinkCustom,
                        advFormat: $advFormat,
                        advNumKeep: $advNumKeep,
                        advNumCtx: $advNumCtx,
                        advNumBatch: $advNumBatch,
                        advNumThread: $advNumThread,
                        advNumGpu: $advNumGpu,
                        advKeepAlive: $advKeepAlive,
                        customParams: $customParams
                    )
                    suggestionPromptsSection
                    knowledgeSection
                    ModelToolsAndCapabilitiesSection(
                        selectedToolIds: $selectedToolIds,
                        allTools: $allTools,
                        isFetchingToolsAndFunctions: $isFetchingToolsAndFunctions,
                        selectedActionIds: $selectedActionIds,
                        allActions: $allActions,
                        allActionFunctions: $allActionFunctions,
                        selectedActionFunctionIds: $selectedActionFunctionIds,
                        selectedFilterIds: $selectedFilterIds,
                        defaultFilterIds: $defaultFilterIds,
                        allFilters: $allFilters,
                        capVision: $capVision, capFileUpload: $capFileUpload,
                        capFileContext: $capFileContext, capWebSearch: $capWebSearch,
                        capImageGeneration: $capImageGeneration, capCodeInterpreter: $capCodeInterpreter,
                        capTerminal: $capTerminal,
                        capUsage: $capUsage, capCitations: $capCitations,
                        capStatusUpdates: $capStatusUpdates, capMemory: $capMemory,
                        capBuiltinTools: $capBuiltinTools,
                        terminalId: $terminalId, terminalServers: terminalServers,
                        defaultWebSearch: $defaultWebSearch, defaultImageGen: $defaultImageGen,
                        defaultCodeInterpreter: $defaultCodeInterpreter,
                        builtinTime: $builtinTime, builtinUserInput: $builtinUserInput,
                        builtinMemory: $builtinMemory,
                        builtinChats: $builtinChats, builtinNotes: $builtinNotes,
                        builtinKnowledge: $builtinKnowledge, builtinFiles: $builtinFiles,
                        builtinChannels: $builtinChannels, builtinNotifications: $builtinNotifications,
                        builtinTaskManagement: $builtinTaskManagement, builtinAutomations: $builtinAutomations, builtinCalendar: $builtinCalendar,
                        builtinSubagents: $builtinSubagents,
                        builtinWebSearch: $builtinWebSearch, builtinImageGen: $builtinImageGen,
                        builtinCodeInterpreter: $builtinCodeInterpreter
                    )
                    ttsVoiceSection
                    settingsSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit Model" : "New Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $isSystemPromptExpanded) {
                FullscreenContentEditor(
                    title: "System Prompt",
                    placeholder: "Write a system prompt…",
                    content: $systemPrompt
                )
            }
            .sheet(isPresented: $showBaseModelPicker) {
                BaseModelPickerSheet(
                    availableModels: availableModels.filter { baseModelAllowed($0) },
                    selectedModelId: baseModelId,
                    serverBaseURL: serverBaseURL,
                    authToken: authToken,
                    onSelect: { model in
                        baseModelId = model.id
                        baseModelDisplayName = model.name
                        showBaseModelPicker = false
                        logger.info("[BaseModelPicker] Selected base model: id='\(model.id)' name='\(model.name)'")
                    },
                    onClear: {
                        baseModelId = ""
                        baseModelDisplayName = ""
                        showBaseModelPicker = false
                        logger.info("[BaseModelPicker] Cleared base model selection")
                    },
                    onDismiss: { showBaseModelPicker = false }
                )
                .environment(dependencies)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "Discard Changes?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your unsaved changes will be lost.")
            }
            .alert("Validation Error", isPresented: .init(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(validationError ?? "") }
            .alert("Access Error", isPresented: .init(
                get: { accessUpdateError != nil },
                set: { if !$0 { accessUpdateError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(accessUpdateError ?? "") }
        }
        .onAppear {
            populateIfEditing()
            Task {
                await applyAdminDefaultsIfNew()
                await manager?.fetchAllUsers()
                await fetchAvailableModels()
                await fetchToolsAndFunctions()
                await fetchTerminalServers()
                await resolveGroupNames()
                await loadSuggestions()
                // Loading (defaults, global filters/actions) is done — anything
                // changed from here on is a user edit.
                if baselinePayload == nil { baselinePayload = currentPayloadFingerprint }
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await handlePhotoSelection(newItem) }
        }
    }

    // MARK: - Profile Image Section

    private var profileImageSection: some View {
        VStack(alignment: .center, spacing: Spacing.sm) {
            HStack {
                Spacer()
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        // Priority: 1) newly picked photo, 2) existing data URI, 3) resolved URL, 4) fallback
                        if let imageData = selectedImageData, let uiImage = UIImage(data: imageData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else if let uiImage = dataURIImage {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else if let avatarURL = resolvedProfileImageURL {
                            CachedAsyncImage(url: avatarURL, authToken: authToken) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(theme.shimmerBase)
                                    .frame(width: 72, height: 72)
                                    .shimmer()
                            }
                        } else {
                            // Fallback avatar
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(theme.brandPrimary.opacity(0.12))
                                    .frame(width: 72, height: 72)
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 1)
                                    .frame(width: 72, height: 72)
                                if let initial = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
                                    Text(String(initial).uppercased())
                                        .scaledFont(size: 28, weight: .semibold, design: .rounded)
                                        .foregroundStyle(theme.brandPrimary)
                                } else {
                                    Image(systemName: "brain")
                                        .scaledFont(size: 28, weight: .medium)
                                        .foregroundStyle(theme.brandPrimary)
                                }
                            }
                        }

                        // Edit badge overlay
                        ZStack {
                            Circle()
                                .fill(theme.brandPrimary)
                                .frame(width: 22, height: 22)
                            Image(systemName: "pencil")
                                .scaledFont(size: 11, weight: .bold)
                                .foregroundStyle(.white)
                        }
                        .offset(x: 4, y: 4)
                    }
                }
                .buttonStyle(.plain)
                .overlay(
                    Group {
                        if isUploadingProfileImage {
                            ProgressView()
                                .tint(.white)
                                .frame(width: 72, height: 72)
                                .background(Color.black.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                )
                Spacer()
            }
            Text("Tap to change profile image")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: - Basic Info Section

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Model Info")
            fieldCard {
                VStack(spacing: 0) {
                    // Name
                    HStack {
                        Text("Name")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. AWS Chatbot", text: $name)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                            .onChange(of: name) { _, newValue in
                                // Auto-fill Model ID with slugified name unless user edited it manually.
                                // isAutoSettingId is intentionally left true here; it is cleared in the
                                // modelId onChange handler which fires in the same render pass after the
                                // binding is updated, ensuring the flag is still set when that fires.
                                if !idManuallyEdited {
                                    isAutoSettingId = true
                                    modelId = Self.slugify(newValue)
                                }
                            }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Model ID
                    HStack {
                        Text("Model ID")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. aws-chatbot", text: $modelId)
                            .scaledFont(size: 15)
                            .foregroundStyle(isEditing ? theme.textSecondary : theme.textPrimary)
                            .focused($focusedField, equals: .modelId)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .disabled(isEditing)
                            .onChange(of: modelId) { _, _ in
                                if isAutoSettingId {
                                    // This change was triggered programmatically by the name field.
                                    // Clear the flag here (correct render cycle) so future user
                                    // edits are correctly detected.
                                    isAutoSettingId = false
                                } else {
                                    idManuallyEdited = true
                                }
                            }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    if !isProviderModel {
                    // Base Model — Picker button
                    Button {
                        Haptics.play(.light)
                        showBaseModelPicker = true
                        logger.info("[BaseModelPicker] Opening base model picker (available models: \(availableModels.count))")
                    } label: {
                        HStack {
                            Text("Base Model")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 90, alignment: .leading)
                            if isFetchingModels {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(theme.brandPrimary)
                                    .padding(.leading, 4)
                            } else if baseModelId.isEmpty {
                                Text("Select a model")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textTertiary)
                            } else {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(baseModelDisplayName.isEmpty ? baseModelId : baseModelDisplayName)
                                        .scaledFont(size: 15)
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    if !baseModelDisplayName.isEmpty && baseModelDisplayName != baseModelId {
                                        Text(baseModelId)
                                            .scaledFont(size: 11)
                                            .foregroundStyle(theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))
                    } // end if !isProviderModel

                    // Description
                    HStack {
                        Text("Description")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("Optional description", text: $description)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .description)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Tags
                    HStack {
                        Text("Tags")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. aws, chat (comma-separated)", text: $tags)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    suggestionChips(tagMatches.map { ($0, $0) }) { addTag($0) }
                        .padding(.horizontal, Spacing.md)
                        .padding(.bottom, tagMatches.isEmpty ? 0 : 10)
                }
            }
        }
    }

    // MARK: - System Prompt Section

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("System Prompt")
                Spacer()
                Button {
                    Haptics.play(.light)
                    isSystemPromptExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(6)
                        .background(theme.surfaceContainer.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            fieldCard {
                TextEditor(text: $systemPrompt)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 120, maxHeight: 300)
                    .focused($focusedField, equals: .systemPrompt)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.sm)
            }
            ChatVariablesPreviewView(preview: ChatVariablesPreview.scan(systemPrompt))
        }
    }

    // MARK: - Suggestion Prompts Section

    private var suggestionPromptsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header row: "PROMPTS" label + Default/Custom toggle button
            HStack {
                sectionHeader("Prompts")
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        useCustomPrompts.toggle()
                        if !useCustomPrompts { suggestionPrompts = [] }
                    }
                    Haptics.play(.light)
                } label: {
                    Text(useCustomPrompts ? "Custom" : "Default")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(useCustomPrompts ? theme.brandPrimary : theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(useCustomPrompts ? theme.brandPrimary.opacity(0.12) : theme.surfaceContainer)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Only show the card when Custom mode is active
            AnimatedPresence(visible: useCustomPrompts) {
                fieldCard {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestionPrompts.enumerated()), id: \.offset) { idx, _ in
                            VStack(spacing: 0) {
                                // Title field
                                HStack {
                                    Text("Title")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField("Optional title", text: Binding(
                                        get: { suggestionPrompts[idx].title },
                                        set: { suggestionPrompts[idx].title = $0 }
                                    ))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                    .autocorrectionDisabled()
                                    Spacer()
                                    Button {
                                        suggestionPrompts.remove(at: idx)
                                        Haptics.play(.light)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .scaledFont(size: 16)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                                // Subtitle field
                                HStack {
                                    Text("Subtitle")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField("Optional subtitle", text: Binding(
                                        get: { suggestionPrompts[idx].subtitle },
                                        set: { suggestionPrompts[idx].subtitle = $0 }
                                    ))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                    .autocorrectionDisabled()
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.bottom, 4)

                                // Prompt content field
                                HStack {
                                    Text("Prompt")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField("Prompt text", text: Binding(
                                        get: { suggestionPrompts[idx].content },
                                        set: { suggestionPrompts[idx].content = $0 }
                                    ))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                    .autocorrectionDisabled()
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.bottom, 10)
                            }
                            Divider().background(theme.inputBorder.opacity(0.3))
                        }

                        // Add new prompt button
                        Button {
                            suggestionPrompts.append(SuggestionPrompt())
                            Haptics.play(.light)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .scaledFont(size: 13, weight: .medium)
                                    .foregroundStyle(theme.brandPrimary)
                                Text("Add Prompt")
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.brandPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: - Knowledge Section

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Knowledge")
            Text("Attach knowledge collections or files to this model.")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)

            fieldCard {
                VStack(spacing: 0) {
                    ForEach(knowledgeItems) { entry in
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: entry.icon)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.brandPrimary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .scaledFont(size: 14, weight: .medium)
                                    .foregroundStyle(theme.textPrimary)
                                Text(entry.typeLabel)
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                            Button {
                                logger.info("[Knowledge] Removing entry: id='\(entry.id)' name='\(entry.name)' type=\(entry.type.rawValue)")
                                knowledgeItems.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 10)
                        Divider().background(theme.inputBorder.opacity(0.3))
                    }

                    Button {
                        Haptics.play(.light)
                        showKnowledgePicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundStyle(theme.brandPrimary)
                            Text("Add Knowledge")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 10)
                }
            }
        }
        .sheet(isPresented: $showKnowledgePicker) {
            WorkspaceKnowledgePickerSheet(
                selectedIds: Set(knowledgeItems.map { $0.id }),
                onSelectCollection: { item in
                    if !knowledgeItems.contains(where: { $0.id == item.id }) {
                        let entry = ModelKnowledgeEntry(
                            id: item.id,
                            name: item.name,
                            description: item.description,
                            type: .collection
                        )
                        knowledgeItems.append(entry)
                        logger.info("[Knowledge] Added collection: id='\(item.id)' name='\(item.name)'")
                    }
                    showKnowledgePicker = false
                },
                onSelectFile: { item in
                    if !knowledgeItems.contains(where: { $0.id == item.id }) {
                        let entry = ModelKnowledgeEntry(
                            id: item.id,
                            name: item.name,
                            description: item.description,
                            type: .file
                        )
                        knowledgeItems.append(entry)
                        logger.info("[Knowledge] Added file: id='\(item.id)' name='\(item.name)'")
                    }
                    showKnowledgePicker = false
                },
                onDismiss: { showKnowledgePicker = false }
            )
            .environment(dependencies)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Tools Section

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Tools")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("Loading tools…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allTools.isEmpty {
                fieldCard {
                    Text("No tools available. Add tools in the Tools workspace first.")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(Spacing.md)
                }
            } else {
                fieldCard {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                            ForEach(allTools, id: \.id) { tool in
                                setCheckbox(tool.name, id: tool.id, selection: $selectedToolIds)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                }
                Text("To select toolkits here, add them to the \"Tools\" workspace first.")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: - Skills Section

    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Skills")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("Loading skills…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allActions.isEmpty {
                fieldCard {
                    Text("No skills available. Add skills in the Skills workspace first.")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allActions, id: \.id) { action in
                            setCheckbox(action.name, id: action.id, selection: $selectedActionIds)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
                Text("To select skills here, add them to the \"Skills\" workspace first.")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: - Filters Section

    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Filters")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("Loading filters…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allFilters.isEmpty {
                fieldCard {
                    Text("No filters available.")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allFilters, id: \.id) { filter in
                            setCheckbox(filter.name, id: filter.id, selection: $selectedFilterIds)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }

                // Default Filters — only shows toggleable filters that are currently selected above.
                // Non-toggle filters (no meta.toggle) are always-on once selected; there is no
                // per-message default state to configure for them.
                let checkedFilters = allFilters.filter { selectedFilterIds.contains($0.id) && $0.hasToggle }
                if !checkedFilters.isEmpty {
                    sectionHeader("Default Filters")
                    fieldCard {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                            ForEach(checkedFilters, id: \.id) { filter in
                                setCheckbox(filter.name, id: filter.id, selection: $defaultFilterIds)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    // MARK: - TTS Voice Section

    private var ttsVoiceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("TTS Voice")
            fieldCard {
                HStack {
                    TextField("e.g. alloy, echo, shimmer", text: $ttsVoice)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                        .focused($focusedField, equals: .ttsVoice)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 12)
            }
            suggestionChips(voiceMatches.map { ($0.id, $0.name) }) { ttsVoice = $0 }
        }
    }

    // MARK: - Settings Section (Active + Access Control)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Settings")
            fieldCard {
                VStack(spacing: 0) {
                    Toggle(isOn: $isActive) {
                        HStack(spacing: Spacing.sm) {
                            if isTogglingActive {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(theme.brandPrimary)
                                    .frame(width: 18, height: 18)
                            } else {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Active")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textPrimary)
                                Text("Inactive models won't appear in the model picker.")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                    .tint(theme.brandPrimary)
                    .disabled(isTogglingActive)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))
                    accessControlSection
                }
            }
        }
    }

    // MARK: - Access Control Section

    @ViewBuilder
    private var accessControlSection: some View {
        AccessControlSection(
            localAccessGrants: $localAccessGrants,
            isPrivate: $isPrivate,
            allUsers: allUsers,
            resolvedGroups: resolvedGroups,
            isUpdating: isUpdatingAccess,
            serverBaseURL: serverBaseURL,
            authToken: authToken,
            apiClient: dependencies.apiClient,
            onAccessModeChange: { newVal in
                await handleAccessModeChange(isPrivate: newVal)
            },
            onTogglePermission: { principalId, isGroup, currentlyWrite in
                await togglePermission(principalId: principalId, isGroup: isGroup, currentlyWrite: currentlyWrite)
            },
            onRemoveGrant: { principalId, isGroup in
                await removeGrant(principalId: principalId, isGroup: isGroup)
            },
            onAddGrants: { userIds, groupIds in
                await addGrants(userIds: userIds, groupIds: groupIds)
            }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel", systemImage: "xmark") {
                if hasChanges { showDiscardConfirm = true } else { dismiss() }
            }
            .labelStyle(.iconOnly)
            .tint(.secondary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSaving {
                ProgressView().tint(theme.brandPrimary)
            } else {
                Button("Save", systemImage: "checkmark") {
                    Task { await save() }
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(theme.brandPrimary)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || modelId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Set-based Checkbox (for Tools, Skills, Filters)

    @ViewBuilder
    private func setCheckbox(_ label: String, id: String, selection: Binding<Set<String>>) -> some View {
        let isSelected = selection.wrappedValue.contains(id)
        Button {
            if isSelected {
                selection.wrappedValue.remove(id)
            } else {
                selection.wrappedValue.insert(id)
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .scaledFont(size: 16)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                Text(label)
                    .scaledFont(size: 13)
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(theme.surfaceContainer.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
            )
    }

    // MARK: - Populate

    private func populateIfEditing() {
        // Support both edit mode (existingModel) and clone mode (cloneSource).
        // In clone mode the editor behaves like "new model" — id is editable, isEditing == false.
        let model: ModelDetail
        let isCloneMode: Bool
        if let existing = existingModel {
            model = existing
            isCloneMode = false
        } else if let source = cloneSource {
            model = source
            isCloneMode = true
        } else {
            return
        }

        logger.info("[Populate] Loading model: id='\(model.id)' name='\(model.name)' cloneMode=\(isCloneMode)")

        if isCloneMode {
            // Clone: append "(Clone)" to name, "-clone" to id, editable id
            name = model.name + " (Clone)"
            let cloneId = model.id + "-clone"
            modelId = cloneId
            idManuallyEdited = true // prevent auto-slug from overriding
        } else {
            name = model.name
            modelId = model.id
            idManuallyEdited = true
        }

        baseModelId = model.baseModelId ?? ""
        baseModelDisplayName = "" // will be resolved from available models after fetch
        description = model.description ?? ""
        tags = model.tags.joined(separator: ", ")
        isActive = model.isActive
        initialIsActive = model.isActive
        systemPrompt = model.systemPrompt
        ttsVoice = model.ttsVoice
        suggestionPrompts = model.suggestionPrompts
        useCustomPrompts = !model.suggestionPrompts.isEmpty
        knowledgeItems = model.knowledgeItems
        profileImageURL = model.profileImageURL // web clone copies the full model, image included

        capVision = model.capVision; capFileUpload = model.capFileUpload
        capFileContext = model.capFileContext; capWebSearch = model.capWebSearch
        capImageGeneration = model.capImageGeneration; capCodeInterpreter = model.capCodeInterpreter
        capTerminal = model.capTerminal
        capUsage = model.capUsage; capCitations = model.capCitations
        capStatusUpdates = model.capStatusUpdates; capBuiltinTools = model.capBuiltinTools
        capMemory = model.capMemory
        terminalId = model.terminalId ?? ""
        originalMetaJSON = model.originalMetaJSON
        // Cloning copies the model (web `cloneModelHandler` spreads the full model, background included).
        backgroundURL = decodeOriginalMeta(model.originalMetaJSON)["background_image_url"] as? String
        i18n = LocalizedContent.read(decodeOriginalMeta(model.originalMetaJSON))

        defaultWebSearch = model.defaultFeatureWebSearch
        defaultImageGen = model.defaultFeatureImageGen
        defaultCodeInterpreter = model.defaultFeatureCodeInterpreter

        builtinTime = model.builtinTime; builtinMemory = model.builtinMemory
        builtinUserInput = model.builtinUserInput
        builtinChats = model.builtinChats; builtinNotes = model.builtinNotes
        builtinKnowledge = model.builtinKnowledge; builtinFiles = model.builtinFiles
        builtinChannels = model.builtinChannels; builtinNotifications = model.builtinNotifications
        builtinTaskManagement = model.builtinTaskManagement
        builtinAutomations = model.builtinAutomations
        builtinCalendar = model.builtinCalendar; builtinSubagents = model.builtinSubagents
        builtinWebSearch = model.builtinWebSearch; builtinImageGen = model.builtinImageGen
        builtinCodeInterpreter = model.builtinCodeInterpreter

        advStreamResponse = model.advStreamResponse
        advStreamDeltaChunkSize = model.advStreamDeltaChunkSize
        advFunctionCalling = model.advFunctionCalling
        advCompactTokenThreshold = model.advCompactTokenThreshold
        advReasoningEffort = model.advReasoningEffort
        advReasoningTagsEnabled = model.advReasoningTagsEnabled
        advReasoningTagStart = model.advReasoningTagStart
        advReasoningTagEnd = model.advReasoningTagEnd
        advSeed = model.advSeed
        advStopSequences = model.advStopSequences?.joined(separator: ", ")
        advTemperature = model.advTemperature
        advLogitBias = model.advLogitBias
        advMaxTokens = model.advMaxTokens
        advTopK = model.advTopK
        advTopP = model.advTopP
        advMinP = model.advMinP
        advFrequencyPenalty = model.advFrequencyPenalty
        advPresencePenalty = model.advPresencePenalty
        advMirostat = model.advMirostat
        advMirostatEta = model.advMirostatEta
        advMirostatTau = model.advMirostatTau
        advRepeatLastN = model.advRepeatLastN
        advTfsZ = model.advTfsZ
        advRepeatPenalty = model.advRepeatPenalty
        advUseMmap = model.advUseMmap
        advUseMlock = model.advUseMlock
        advThink = model.advThink
        advThinkCustom = model.advThinkCustom
        advFormat = model.advFormat
        advNumKeep = model.advNumKeep
        advNumCtx = model.advNumCtx
        advNumBatch = model.advNumBatch
        advNumThread = model.advNumThread
        advNumGpu = model.advNumGpu
        advKeepAlive = model.advKeepAlive
        customParams = model.customParams

        if !isCloneMode {
            let hasWildcard = model.accessGrants.contains { $0.userId == "*" }
            localAccessGrants = model.accessGrants.filter { $0.userId != "*" }
            isPrivate = !hasWildcard
        }
        // Tools, Skills, Filters — copy for both edit and clone
        selectedToolIds = Set(model.toolIds)
        selectedFilterIds = Set(model.filterIds)
        defaultFilterIds = Set(model.defaultFilterIds)
        // Skills (meta.skillIds) and action functions (meta.actionIds) are independent.
        selectedActionIds = Set(model.skillIds)
        selectedActionFunctionIds.formUnion(model.actionIds)

        logger.info("[Populate] Done. baseModelId='\(model.baseModelId ?? "none")' knowledgeItems=\(model.knowledgeItems.count) toolIds=\(model.toolIds.count) filterIds=\(model.filterIds.count) actionIds=\(model.actionIds.count)")
    }

    // MARK: - Fetch Available Models

    private func fetchAvailableModels() async {
        guard let api = dependencies.apiClient else { return }
        isFetchingModels = true
        logger.info("[BaseModelPicker] Fetching available models (including hidden for admin base model picker)...")
        do {
            // Use getModelsIncludingHidden() so hidden models appear in the base model picker —
            // admins need to be able to select any enabled model as a base, matching the web UI
            // behaviour in ModelEditor.svelte where hidden models are visible to admins.
            let models = try await api.getModelsIncludingHidden()
            availableModels = models
            logger.info("[BaseModelPicker] Fetched \(models.count) models")
            // Resolve display name for the current baseModelId
            if !baseModelId.isEmpty {
                if let match = models.first(where: { $0.id == baseModelId }) {
                    baseModelDisplayName = match.name
                    logger.info("[BaseModelPicker] Resolved base model display name: '\(match.name)' for id='\(baseModelId)'")
                }
            }
        } catch {
            logger.error("[BaseModelPicker] Failed to fetch models: \(error.localizedDescription)")
        }
        isFetchingModels = false
    }

    // MARK: - Fetch Tools & Functions

    // MARK: - Terminal Servers

    /// Loads terminal servers for the "Terminal" default picker (mirrors web TerminalSelector).
    private func fetchTerminalServers() async {
        guard let api = dependencies.apiClient else { return }
        terminalServers = (try? await api.listTerminalServers()) ?? []
    }

    // MARK: - Admin Defaults (new models)

    /// For models that don't yet exist on the server (brand-new models, or base models
    /// opened for customisation), seed capabilities / default features / builtin tools
    /// from the admin's `DEFAULT_MODEL_METADATA` — exactly like the web ModelEditor.
    /// Falls back to OpenWebUI's DEFAULT_CAPABILITIES when the call fails.
    private func applyAdminDefaultsIfNew() async {
        guard cloneSource == nil, let api = dependencies.apiClient else { return }
        let defaults = (try? await api.getModelsDefaultMetadata()) ?? [:]
        guard !defaults.isEmpty else { return }

        // Existing model: ModelEditor.svelte layers the model's own capabilities over
        // the admin defaults (`{ ...defaults, ...model.meta.capabilities }`), so a
        // capability the model doesn't define takes the admin default, not a built-in.
        if originalMetaJSON != nil {
            let own = (decodeOriginalMeta(originalMetaJSON)["capabilities"] as? [String: Any]) ?? [:]
            let adminCaps = defaults["capabilities"] as? [String: Any] ?? [:]
            func fill(_ key: String, _ current: Bool) -> Bool {
                own[key] == nil ? (adminCaps[key] as? Bool ?? current) : current
            }
            capVision = fill("vision", capVision); capFileUpload = fill("file_upload", capFileUpload)
            capFileContext = fill("file_context", capFileContext); capWebSearch = fill("web_search", capWebSearch)
            capImageGeneration = fill("image_generation", capImageGeneration)
            capCodeInterpreter = fill("code_interpreter", capCodeInterpreter)
            capTerminal = fill("terminal", capTerminal); capUsage = fill("usage", capUsage)
            capCitations = fill("citations", capCitations); capStatusUpdates = fill("status_updates", capStatusUpdates)
            capMemory = fill("memory", capMemory); capBuiltinTools = fill("builtin_tools", capBuiltinTools)
            // `defaultFeatureIds` / `builtinTools` are whole-value overrides in the web editor.
            let ownMeta = decodeOriginalMeta(originalMetaJSON)
            if ownMeta["defaultFeatureIds"] == nil {
                let defF = defaults["defaultFeatureIds"] as? [String] ?? []
                defaultWebSearch = defF.contains("web_search")
                defaultImageGen = defF.contains("image_generation")
                defaultCodeInterpreter = defF.contains("code_interpreter")
            }
            if ownMeta["builtinTools"] == nil {
                let bt = defaults["builtinTools"] as? [String: Any] ?? [:]
                func tool(_ key: String) -> Bool { bt[key] as? Bool ?? true }
                builtinTime = tool("time"); builtinUserInput = tool("user_input"); builtinMemory = tool("memory")
                builtinChats = tool("chats"); builtinNotes = tool("notes"); builtinKnowledge = tool("knowledge")
                builtinFiles = tool("files"); builtinChannels = tool("channels")
                builtinNotifications = tool("notifications")
                builtinTaskManagement = bt["tasks"] as? Bool ?? bt["task_management"] as? Bool ?? true
                builtinAutomations = tool("automations"); builtinCalendar = tool("calendar")
                builtinSubagents = tool("subagents"); builtinWebSearch = tool("web_search")
                builtinImageGen = tool("image_generation"); builtinCodeInterpreter = tool("code_interpreter")
            }
            return
        }

        let caps = defaults["capabilities"] as? [String: Any] ?? [:]
        func cap(_ key: String, _ fallback: Bool) -> Bool { caps[key] as? Bool ?? fallback }
        capVision = cap("vision", true); capFileUpload = cap("file_upload", true)
        capFileContext = cap("file_context", true); capWebSearch = cap("web_search", true)
        capImageGeneration = cap("image_generation", true); capCodeInterpreter = cap("code_interpreter", true)
        capTerminal = cap("terminal", true); capUsage = cap("usage", false)
        capCitations = cap("citations", true); capStatusUpdates = cap("status_updates", true)
        capMemory = cap("memory", true); capBuiltinTools = cap("builtin_tools", true)

        let defF = defaults["defaultFeatureIds"] as? [String] ?? []
        defaultWebSearch = defF.contains("web_search")
        defaultImageGen = defF.contains("image_generation")
        defaultCodeInterpreter = defF.contains("code_interpreter")

        let bt = defaults["builtinTools"] as? [String: Any] ?? [:]
        func tool(_ key: String) -> Bool { bt[key] as? Bool ?? true }
        builtinTime = tool("time"); builtinUserInput = tool("user_input"); builtinMemory = tool("memory")
        builtinChats = tool("chats"); builtinNotes = tool("notes"); builtinKnowledge = tool("knowledge")
        builtinFiles = tool("files"); builtinChannels = tool("channels")
        builtinNotifications = tool("notifications")
        builtinTaskManagement = bt["tasks"] as? Bool ?? bt["task_management"] as? Bool ?? true
        builtinAutomations = tool("automations"); builtinCalendar = tool("calendar")
        builtinSubagents = tool("subagents"); builtinWebSearch = tool("web_search")
        builtinImageGen = tool("image_generation"); builtinCodeInterpreter = tool("code_interpreter")
    }

    private func fetchToolsAndFunctions() async {
        guard let api = dependencies.apiClient else { return }
        isFetchingToolsAndFunctions = true
        logger.info("[ToolsFunctions] Fetching tools, skills, and functions…")
        do {
            // Fetch tools from /api/v1/tools/ (returns [[String: Any]])
            let tools = try await api.getTools()
            allTools = tools.compactMap { dict -> (id: String, name: String)? in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { return nil }
                return (id: id, name: name)
            }
            logger.info("[ToolsFunctions] Fetched \(allTools.count) tools")

            // Fetch filters and action functions from /api/v1/functions/
            let functions = try await api.getFunctions()
            allFilters = functions
                .filter { $0.type == "filter" }
                .map { (id: $0.id, name: $0.name, isGlobal: $0.isGlobal, hasToggle: $0.hasToggle) }
            logger.info("[ToolsFunctions] Fetched \(allFilters.count) filters from functions")

            // Pre-select global filters (always enabled, non-editable)
            for fn in allFilters where fn.isGlobal {
                selectedFilterIds.insert(fn.id)
            }
            // Also select per-model filter IDs from the existing model
            if let model = existingModel {
                for filterId in model.filterIds {
                    selectedFilterIds.insert(filterId)
                }
            }

            // Extract action-type functions with global state for the Actions section
            allActionFunctions = functions
                .filter { $0.type == "action" && $0.isActive }
                .map { (id: $0.id, name: $0.name, isGlobal: $0.isGlobal) }
            logger.info("[ToolsFunctions] Fetched \(allActionFunctions.count) active action functions")

            // Pre-select action functions: global ones are always selected,
            // per-model ones come from the model's actionIds
            for fn in allActionFunctions where fn.isGlobal {
                selectedActionFunctionIds.insert(fn.id)
            }
            // Also select per-model action IDs from the existing model
            if let model = existingModel {
                for actionId in model.actionIds {
                    selectedActionFunctionIds.insert(actionId)
                }
            }

            // Fetch skills from /api/v1/skills/list (separate paginated endpoint)
            let skills = try await api.getSkills()
            allActions = skills.map { (id: $0.id, name: $0.name) }
            logger.info("[ToolsFunctions] Fetched \(allActions.count) skills")
        } catch {
            logger.error("[ToolsFunctions] Failed to fetch: \(error.localizedDescription)")
        }
        isFetchingToolsAndFunctions = false
    }

    // MARK: - Handle Photo Selection

    private func handlePhotoSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        logger.info("[ProfileImage] Photo selected, loading data...")
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                logger.error("[ProfileImage] Failed to load photo data — nil result")
                return
            }
            // Resize to reasonable size (max 512x512) before encoding
            guard let uiImage = UIImage(data: data) else {
                logger.error("[ProfileImage] Failed to create UIImage from data (size: \(data.count) bytes)")
                return
            }
            let resized = resizeImage(uiImage, maxDimension: 512)
            guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
                logger.error("[ProfileImage] Failed to encode image as JPEG")
                return
            }
            let base64 = jpegData.base64EncodedString()
            let dataURI = "data:image/jpeg;base64,\(base64)"

            selectedImageData = jpegData
            profileImageURL = dataURI
            logger.info("[ProfileImage] Photo encoded as data URI — original size: \(data.count) bytes, jpeg size: \(jpegData.count) bytes, data URI length: \(dataURI.count) chars")
        } catch {
            logger.error("[ProfileImage] Error loading photo: \(error.localizedDescription)")
        }
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxCurrent = max(size.width, size.height)
        guard maxCurrent > maxDimension else { return image }
        let scale = maxDimension / maxCurrent
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Build Detail from Form State

    private func buildDetail(id: String) -> ModelDetail {
        var detail = ModelDetail(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            baseModelId: baseModelId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : baseModelId.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces).isEmpty ? nil : description.trimmingCharacters(in: .whitespaces),
            profileImageURL: profileImageURL,
            tags: tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            isActive: isActive,
            accessGrants: localAccessGrants,
            writeAccess: existingModel?.writeAccess ?? true,
            userId: existingModel?.userId ?? "",
            createdAt: existingModel?.createdAt,
            updatedAt: existingModel?.updatedAt,
            systemPrompt: systemPrompt,
            capVision: capVision, capFileUpload: capFileUpload, capFileContext: capFileContext,
            capWebSearch: capWebSearch, capImageGeneration: capImageGeneration, capCodeInterpreter: capCodeInterpreter,
            capTerminal: capTerminal,
            capUsage: capUsage, capCitations: capCitations, capStatusUpdates: capStatusUpdates,
            capMemory: capMemory, capBuiltinTools: capBuiltinTools,
            terminalId: terminalId.isEmpty ? nil : terminalId,
            defaultFeatureWebSearch: defaultWebSearch, defaultFeatureImageGen: defaultImageGen, defaultFeatureCodeInterpreter: defaultCodeInterpreter,
            builtinTime: builtinTime, builtinUserInput: builtinUserInput,
            builtinMemory: builtinMemory, builtinChats: builtinChats,
            builtinNotes: builtinNotes, builtinKnowledge: builtinKnowledge, builtinFiles: builtinFiles,
            builtinChannels: builtinChannels, builtinNotifications: builtinNotifications,
            builtinTaskManagement: builtinTaskManagement, builtinAutomations: builtinAutomations, builtinCalendar: builtinCalendar,
            builtinSubagents: builtinSubagents,
            builtinWebSearch: builtinWebSearch, builtinImageGen: builtinImageGen, builtinCodeInterpreter: builtinCodeInterpreter,
            knowledgeItems: knowledgeItems,
            suggestionPrompts: suggestionPrompts,
            ttsVoice: ttsVoice.trimmingCharacters(in: .whitespaces)
        )
        detail.advStreamResponse = advStreamResponse
        detail.advStreamDeltaChunkSize = advStreamDeltaChunkSize
        detail.advFunctionCalling = advFunctionCalling
        detail.advCompactTokenThreshold = advCompactTokenThreshold
        detail.advReasoningEffort = advReasoningEffort
        detail.advReasoningTagsEnabled = advReasoningTagsEnabled
        detail.advReasoningTagStart = advReasoningTagStart
        detail.advReasoningTagEnd = advReasoningTagEnd
        detail.advSeed = advSeed
        detail.advStopSequences = advStopSequences.map {
            $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        detail.advTemperature = advTemperature
        detail.advLogitBias = advLogitBias
        detail.advMaxTokens = advMaxTokens
        detail.advTopK = advTopK
        detail.advTopP = advTopP
        detail.advMinP = advMinP
        detail.advFrequencyPenalty = advFrequencyPenalty
        detail.advPresencePenalty = advPresencePenalty
        detail.advMirostat = advMirostat
        detail.advMirostatEta = advMirostatEta
        detail.advMirostatTau = advMirostatTau
        detail.advRepeatLastN = advRepeatLastN
        detail.advTfsZ = advTfsZ
        detail.advRepeatPenalty = advRepeatPenalty
        detail.advUseMmap = advUseMmap
        detail.advUseMlock = advUseMlock
        detail.advThink = advThinkCustom == nil ? advThink : nil
        detail.advThinkCustom = advThinkCustom
        detail.advFormat = advFormat
        detail.advNumKeep = advNumKeep
        detail.advNumCtx = advNumCtx
        detail.advNumBatch = advNumBatch
        detail.advNumThread = advNumThread
        detail.advNumGpu = advNumGpu
        detail.advKeepAlive = advKeepAlive
        detail.customParams = customParams.filter { !$0.key.isEmpty }
        detail.originalMetaJSON = metaJSONWithBackground(originalMetaJSON, uploadedPath: pendingUploadedPath)
        // Tools, Skills, Filters
        detail.toolIds = Array(selectedToolIds)
        // Filter IDs: exclude global filters (server applies them automatically).
        // Only save per-model filter selections.
        let globalFilterIds = Set(allFilters.filter(\.isGlobal).map(\.id))
        detail.filterIds = Array(selectedFilterIds.subtracting(globalFilterIds))
        detail.defaultFilterIds = Array(defaultFilterIds)
        // Actions and Skills are separate native selections.
        // Global action functions are excluded — the server applies them automatically.
        let globalActionIds = Set(allActionFunctions.filter(\.isGlobal).map(\.id))
        detail.actionIds = selectedActionFunctionIds.subtracting(globalActionIds).sorted()
        detail.skillIds = selectedActionIds.sorted()
        return detail
    }

    // MARK: - Background image

    /// `background_image_url` for the next save: the uploaded file path when a new
    /// image was picked, `null` when removed, else the stored value untouched.
    private func metaJSONWithBackground(_ base: Data?, uploadedPath: String? = nil) -> Data? {
        var meta = decodeOriginalMeta(base)
        let pruned = LocalizedContent.prune(i18n)
        if pruned.isEmpty { meta.removeValue(forKey: "i18n") } else { meta["i18n"] = pruned }
        if let uploadedPath {
            meta["background_image_url"] = uploadedPath
        } else if backgroundRemoved {
            meta["background_image_url"] = NSNull()
        }
        return try? JSONSerialization.data(withJSONObject: meta)
    }

    /// Uploads the picked image (`process=false`, like the web) and returns its file id.
    private func uploadPendingBackground() async throws -> String? {
        guard let pending = pendingBackground, let api = dependencies.apiClient else { return nil }
        let res = try await api.uploadFileOnly(data: pending.data, fileName: pending.fileName)
        guard let id = res["id"] as? String else {
            throw NSError(domain: "ModelEditor", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to upload background image."])
        }
        return id
    }

    // MARK: - Save

    private func save() async {
        guard let manager else { return }
        isSaving = true
        validationError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedId = modelId.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationError = "Please enter a name for the model."
            isSaving = false; return
        }
        guard !trimmedId.isEmpty else {
            validationError = "Model ID is required."
            isSaving = false; return
        }
        // Server `ModelForm.id` must match ^\S+$ and is capped at 256 chars.
        guard !trimmedId.contains(where: { $0.isWhitespace }) else {
            validationError = "Model ID cannot contain whitespace."
            isSaving = false; return
        }
        guard trimmedId.count <= 256 else {
            validationError = "The model ID is too long. Please make sure your model ID is less than 256 characters long."
            isSaving = false; return
        }
        // Workspace models wrap a base model; only admin-created base records
        // (Admin → Models) have none. The server otherwise rejects with a bare 401.
        if !isNewBaseRecord, !isProviderModel,
           baseModelId.trimmingCharacters(in: .whitespaces).isEmpty {
            validationError = "Base Model is required."
            isSaving = false; return
        }

        var allGrants = localAccessGrants.filter { $0.userId != "*" }
        if !isPrivate {
            allGrants.append(AccessGrant(id: UUID().uuidString, userId: "*", groupId: nil, read: true, write: false))
        }

        var uploadedId: String? = nil
        var savedOK = false
        defer {
            // A failed save must not leave an orphaned upload behind (web deletes it too).
            if let uploadedId, !savedOK {
                Task { try? await dependencies.apiClient?.deleteFile(id: uploadedId) }
            }
        }

        do {
            uploadedId = try await uploadPendingBackground()
            let uploadedPath = uploadedId.map { ModelBackgroundImage.contentPath(forFileId: $0) }
            if uploadedPath != nil { pendingUploadedPath = uploadedPath }
            if let existing = existingModel, isNewBaseRecord {
                // Same as the web admin upsertModelHandler: create the base record
                // (base_model_id null) with the edited settings.
                var detail = buildDetail(id: existing.id)
                detail.baseModelId = nil
                detail.accessGrants = allGrants
                let created = try await manager.create(from: detail)
                onSave?(created)
                NotificationCenter.default.post(name: .functionsConfigChanged, object: nil)
            } else if let existing = existingModel {
                var detail = buildDetail(id: existing.id)
                detail.accessGrants = allGrants

                let payload = detail.toUpdatePayload()
                logger.info("[Save] Updating model id='\(existing.id)' name='\(trimmedName)'")
                if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    logger.debug("[Save] Update payload:\n\(jsonString)")
                }

                var updated = try await manager.update(detail)
                logger.info("[Save] Model updated successfully: id='\(updated.id)'")

                let updatedGrants = try await manager.updateAccessGrants(
                    modelId: existing.id,
                    modelName: trimmedName,
                    grants: localAccessGrants.filter { $0.userId != "*" },
                    isPublic: !isPrivate
                )
                updated.accessGrants = updatedGrants
                onSave?(updated)
                NotificationCenter.default.post(name: .functionsConfigChanged, object: nil)
            } else {
                var detail = buildDetail(id: trimmedId)
                detail.accessGrants = allGrants

                let payload = detail.toCreatePayload()
                logger.info("[Save] Creating model id='\(trimmedId)' name='\(trimmedName)' baseModelId='\(baseModelId)'")
                if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    logger.debug("[Save] Create payload:\n\(jsonString)")
                }

                let created = try await manager.create(from: detail)
                logger.info("[Save] Model created successfully: id='\(created.id)' name='\(created.name)'")
                onSave?(created)
            }
            savedOK = true
            dismiss()
        } catch {
            pendingUploadedPath = nil
            logger.error("[Save] Error saving model: \(error.localizedDescription)")
            validationError = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - Access Control Actions

    // Access edits stay local and are written by `save()` (update + access/update),
    // matching the web editor, which only applies sharing changes on Save.

    private func handleAccessModeChange(isPrivate: Bool) async {
        Haptics.play(.light)
    }

    private func addGrants(userIds: [String], groupIds: [String]) async {
        for userId in userIds where !localAccessGrants.contains(where: { $0.userId == userId }) {
            localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
        }
        for groupId in groupIds where !localAccessGrants.contains(where: { $0.groupId == groupId }) {
            localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: nil, groupId: groupId, read: true, write: false))
        }
        await resolveGroupNames()
        Haptics.notify(.success)
    }

    private func togglePermission(principalId: String, isGroup: Bool, currentlyWrite: Bool) async {
        let idx = isGroup
            ? localAccessGrants.firstIndex(where: { $0.groupId == principalId })
            : localAccessGrants.firstIndex(where: { $0.userId == principalId })
        guard let idx else { return }
        let old = localAccessGrants[idx]
        localAccessGrants[idx] = AccessGrant(id: old.id, userId: old.userId, groupId: old.groupId, read: true, write: !currentlyWrite)
        Haptics.play(.light)
    }

    private func removeGrant(principalId: String, isGroup: Bool) async {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isGroup { localAccessGrants.removeAll { $0.groupId == principalId } }
            else { localAccessGrants.removeAll { $0.userId == principalId } }
        }
        Haptics.play(.light)
    }

    private func resolveGroupNames() async {
        guard let api = dependencies.apiClient else { return }
        let groupIds = Set(localAccessGrants.compactMap(\.groupId))
        let unknownIds = groupIds.subtracting(resolvedGroups.keys)
        guard !unknownIds.isEmpty else { return }
        do {
            let groups = try await api.getGroups()
            for g in groups where unknownIds.contains(g.id) {
                resolvedGroups[g.id] = g
            }
        } catch {}
    }

}

// MARK: - BaseModelPickerSheet

struct BaseModelPickerSheet: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    var availableModels: [AIModel]
    var selectedModelId: String
    var serverBaseURL: String
    var authToken: String?
    var onSelect: (AIModel) -> Void
    var onClear: () -> Void
    var onDismiss: () -> Void

    @State private var searchText = ""

    private let logger = Logger(subsystem: "com.openui", category: "ModelEditor")

    private var filtered: [AIModel] {
        guard !searchText.isEmpty else { return availableModels }
        return availableModels.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if availableModels.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "cpu")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(theme.textTertiary)
                        Text("No models found")
                            .scaledFont(size: 17, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text("Could not load available models from the server.")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !selectedModelId.isEmpty {
                            Section {
                                Button {
                                    onClear()
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Color.red.opacity(0.12))
                                                .frame(width: 36, height: 36)
                                            Image(systemName: "xmark")
                                                .scaledFont(size: 14, weight: .medium)
                                                .foregroundStyle(.red)
                                        }
                                        Text("None (clear selection)")
                                            .scaledFont(size: 15)
                                            .foregroundStyle(.red)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(theme.surfaceContainer.opacity(0.4))
                            }
                        }

                        Section {
                            ForEach(filtered) { model in
                                Button {
                                    logger.info("[BaseModelPicker] User selected model: id='\(model.id)' name='\(model.name)'")
                                    onSelect(model)
                                } label: {
                                    HStack(spacing: 12) {
                                        ModelAvatar(
                                            size: 36,
                                            imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                                            label: model.name,
                                            authToken: authToken
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(model.name)
                                                .scaledFont(size: 15, weight: .medium)
                                                .foregroundStyle(theme.textPrimary)
                                                .lineLimit(1)
                                            Text(model.id)
                                                .scaledFont(size: 12)
                                                .foregroundStyle(theme.textTertiary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if model.id == selectedModelId {
                                            Image(systemName: "checkmark.circle.fill")
                                                .scaledFont(size: 18)
                                                .foregroundStyle(theme.brandPrimary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(model.id == selectedModelId
                                    ? theme.brandPrimary.opacity(0.08)
                                    : theme.surfaceContainer.opacity(0.4))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.background)
            .navigationTitle("Select Base Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search Models")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel", systemImage: "xmark") { onDismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
            }
        }
        .onAppear {
            logger.info("[BaseModelPicker] Sheet opened. Available models: \(availableModels.count). Currently selected: '\(selectedModelId)'")
        }
    }
}

// MARK: - ModelAdvancedParamsSection (extracted child struct to prevent stack overflow)

/// All 30+ advanced parameter rows are in this separate struct so the Swift
/// compiler/runtime evaluates them in their own stack frame rather than
/// contributing to the parent's already-deep body evaluation.
struct ModelAdvancedParamsSection: View {
    @Environment(\.theme) private var theme

    @Binding var showAdvancedParams: Bool

    @Binding var advStreamResponse: Bool?
    @Binding var advStreamDeltaChunkSize: Int?
    @Binding var advFunctionCalling: String?
    @Binding var advCompactTokenThreshold: Int?
    @Binding var advReasoningEffort: String?
    @Binding var advReasoningTagsEnabled: Bool?
    @Binding var advReasoningTagStart: String?
    @Binding var advReasoningTagEnd: String?
    @Binding var advSeed: Int?
    @Binding var advStopSequences: String?
    @Binding var advTemperature: Double?
    @Binding var advLogitBias: String?
    @Binding var advMaxTokens: Int?
    @Binding var advTopK: Int?
    @Binding var advTopP: Double?
    @Binding var advMinP: Double?
    @Binding var advFrequencyPenalty: Double?
    @Binding var advPresencePenalty: Double?
    @Binding var advMirostat: Int?
    @Binding var advMirostatEta: Double?
    @Binding var advMirostatTau: Double?
    @Binding var advRepeatLastN: Int?
    @Binding var advTfsZ: Double?
    @Binding var advRepeatPenalty: Double?
    @Binding var advUseMmap: Bool?
    @Binding var advUseMlock: Bool?
    @Binding var advThink: Bool?
    @Binding var advThinkCustom: String?
    @Binding var advFormat: String?
    @Binding var advNumKeep: Int?
    @Binding var advNumCtx: Int?
    @Binding var advNumBatch: Int?
    @Binding var advNumThread: Int?
    @Binding var advNumGpu: Int?
    @Binding var advKeepAlive: String?
    @Binding var customParams: [(key: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAdvancedParams.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack {
                    Text("Advanced Params")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, 4)
                    Spacer()
                    Image(systemName: showAdvancedParams ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            AnimatedPresence(visible: showAdvancedParams) {
                advancedParamsContent
            }
        }
    }

    // Split into two halves to keep individual body depth low
    private var advancedParamsContent: some View {
        VStack(spacing: 0) {
            advParamsFirstHalf
            advParamsSecondHalf
        }
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
        )
    }

    // First half: stream, function calling, reasoning, seed, stop, temperature, logit, max_tokens, top_k, top_p, min_p, freq, presence
    private var advParamsFirstHalf: some View {
        VStack(spacing: 0) {
            advBoolRow(label: "Stream Chat Response", value: $advStreamResponse)
            divider
            advIntSliderRow(label: "Stream Delta Chunk Size", value: $advStreamDeltaChunkSize, range: 1...128, step: 1, defaultValue: 1)
            divider
            advNativeToggleRow(label: "Function Calling", value: $advFunctionCalling)
            divider
            advIntSliderRow(label: "Context Compaction Threshold (tokens)", value: $advCompactTokenThreshold,
                            range: 1000...1_000_000, step: 1000, defaultValue: 80000)
            divider
            advTextRow(label: "Reasoning Effort", placeholder: "e.g. low, medium, high", value: $advReasoningEffort)
            divider
            advReasoningTagsRow
            divider
            advIntSliderRow(label: "Seed", value: $advSeed, range: 0...9999, step: 1)
            divider
            advTextRow(label: "Stop Sequence", placeholder: "Comma-separated", value: $advStopSequences)
            divider
            advDoubleSliderRow(label: "Temperature", tooltip: "The temperature of the model. Increasing the temperature will make the model answer more creatively.", value: $advTemperature, range: 0...2, step: 0.05)
            divider
            advTextRow(label: "logit_bias", placeholder: "Enter comma-separated \"token:bias_value\" pairs (example: 5432:100, 413:-100)", value: $advLogitBias)
            divider
            advIntSliderRow(label: "max_tokens", value: $advMaxTokens, range: 0...131072, step: 128)
            divider
            advIntSliderRow(label: "top_k", value: $advTopK, range: 0...1000, step: 1)
            divider
            advDoubleSliderRow(label: "top_p", tooltip: nil, value: $advTopP, range: 0...1, step: 0.05)
            divider
            advDoubleSliderRow(label: "min_p", tooltip: nil, value: $advMinP, range: 0...1, step: 0.05)
            divider
            advDoubleSliderRow(label: "frequency_penalty", tooltip: nil, value: $advFrequencyPenalty, range: -2...2, step: 0.05)
            divider
            advDoubleSliderRow(label: "presence_penalty", tooltip: nil, value: $advPresencePenalty, range: -2...2, step: 0.05)
        }
    }

    // Second half: mirostat, repeat, use_mmap, use_mlock, think, format, num_keep, num_ctx, num_batch, num_thread, num_gpu, keep_alive, custom
    private var advParamsSecondHalf: some View {
        VStack(spacing: 0) {
            divider
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable Mirostat sampling for controlling perplexity.")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            advIntSliderRow(label: "mirostat", value: $advMirostat, range: 0...2, step: 1)
            divider
            advDoubleSliderRow(label: "mirostat_eta", tooltip: nil, value: $advMirostatEta, range: 0...1, step: 0.01)
            divider
            advDoubleSliderRow(label: "mirostat_tau", tooltip: nil, value: $advMirostatTau, range: 0...10, step: 0.1)
            divider
            advIntSliderRow(label: "repeat_last_n", value: $advRepeatLastN, range: 0...128, step: 1)
            divider
            advDoubleSliderRow(label: "tfs_z", tooltip: nil, value: $advTfsZ, range: 0...2, step: 0.05)
            divider
            advDoubleSliderRow(label: "repeat_penalty", tooltip: nil, value: $advRepeatPenalty, range: 0...2, step: 0.01)
            divider
            advBoolRow(label: "use_mmap", value: $advUseMmap, defaultValue: true)
            divider
            advBoolRow(label: "use_mlock", value: $advUseMlock, defaultValue: false)
            divider
            thinkRow
            divider
            advTextRow(label: "format (Ollama)", placeholder: "e.g. json", value: $advFormat)
            divider
            advIntSliderRow(label: "num_keep (Ollama)", value: $advNumKeep, range: 0...10240000, step: 1)
            divider
            advIntSliderRow(label: "num_ctx (Ollama)", value: $advNumCtx, range: 512...10240000, step: 512)
            divider
            advIntSliderRow(label: "num_batch (Ollama)", value: $advNumBatch, range: 256...8192, step: 256)
            divider
            advIntSliderRow(label: "num_thread (Ollama)", value: $advNumThread, range: 1...256, step: 1)
            divider
            VStack(alignment: .leading, spacing: 4) {
                Text("Set the number of layers, which will be off-loaded to GPU. Increasing this value can significantly improve performance for models that are optimized for GPU acceleration but may also consume more power and GPU resources.")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            advIntSliderRow(label: "num_gpu (Ollama)", value: $advNumGpu, range: 0...256, step: 1)
            divider
            advTextRow(label: "keep_alive (Ollama)", placeholder: "e.g. 5m", value: $advKeepAlive)
            divider
            customParamsSection
        }
    }

    private var divider: some View {
        Divider().background(theme.inputBorder.opacity(0.3))
    }

    // MARK: - Reasoning Tags Row
    // 4 states matching Open WebUI (cycling pill pattern):
    //   Default  → advReasoningTagsEnabled == nil && advReasoningTagStart == nil
    //   Enabled  → advReasoningTagsEnabled == true
    //   Disabled → advReasoningTagsEnabled == false
    //   Custom   → advReasoningTagStart != nil (advReasoningTagsEnabled ignored)

    private var currentReasoningIsCustom: Bool {
        advReasoningTagStart != nil
    }

    private var currentReasoningModeLabel: String {
        if currentReasoningIsCustom { return "Custom" }
        guard let enabled = advReasoningTagsEnabled else { return "Default" }
        return enabled ? "Enabled" : "Disabled"
    }

    private var reasoningTagsIsActive: Bool {
        advReasoningTagsEnabled != nil || currentReasoningIsCustom
    }

    /// Cycle: Enabled → Disabled → Custom → Enabled
    private func cycleReasoningMode() {
        if currentReasoningIsCustom {
            // Custom → Enabled
            advReasoningTagStart = nil
            advReasoningTagEnd = nil
            advReasoningTagsEnabled = true
        } else if let enabled = advReasoningTagsEnabled {
            if enabled {
                // Enabled → Disabled
                advReasoningTagsEnabled = false
            } else {
                // Disabled → Custom
                advReasoningTagsEnabled = nil
                advReasoningTagStart = ""
                advReasoningTagEnd = ""
            }
        } else {
            // Default → Enabled (via initial activation)
            advReasoningTagsEnabled = true
        }
        Haptics.play(.light)
    }

    private var advReasoningTagsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Reasoning Tags")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                // Single pill cycles: Default → Enabled → Disabled → Custom → Default
                Button {
                    cycleReasoningMode()
                } label: {
                    Text(reasoningTagsIsActive ? currentReasoningModeLabel : "Default")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(theme.brandPrimary.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)

            // Custom text fields (only shown in Custom mode)
            if currentReasoningIsCustom {
                HStack(spacing: Spacing.md) {
                    TextField("<think>", text: Binding(
                        get: { advReasoningTagStart ?? "" },
                        set: { advReasoningTagStart = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .padding(8)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    TextField("</think>", text: Binding(
                        get: { advReasoningTagEnd ?? "" },
                        set: { advReasoningTagEnd = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .padding(8)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: - Custom Params Section

    private var customParamsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Custom Parameters")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    customParams.append((key: "", value: ""))
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "plus.circle")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)

            ForEach(Array(customParams.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: Spacing.sm) {
                    TextField("Key", text: Binding(
                        get: { customParams[idx].key },
                        set: { customParams[idx].key = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .frame(maxWidth: .infinity)

                    Text(":").foregroundStyle(theme.textTertiary)

                    TextField("JSON or text", text: Binding(
                        get: { customParams[idx].value },
                        set: { customParams[idx].value = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .frame(maxWidth: .infinity)

                    Button {
                        customParams.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .scaledFont(size: 16)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 8)
                Divider().background(theme.inputBorder.opacity(0.3))
            }
        }
    }

    // MARK: - Reusable Pill

    private var defaultPill: some View {
        Text("Default")
            .scaledFont(size: 11)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(theme.surfaceContainer)
            .clipShape(Capsule())
    }

    // MARK: - Row Builders

    /// `think` (Ollama): Default → On → Custom level → Off → Default — same cycle
    /// as the web UI's AdvancedParams, where Custom stores an effort string.
    @ViewBuilder
    private var thinkRow: some View {
        let label: String = {
            if advThinkCustom != nil { return "Custom" }
            switch advThink {
            case .some(true): return "On"
            case .some(false): return "Off"
            case .none: return "Default"
            }
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("think (Ollama)")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button {
                    if advThinkCustom != nil {
                        advThinkCustom = nil; advThink = false
                    } else {
                        switch advThink {
                        case .none: advThink = true
                        case .some(true): advThink = nil; advThinkCustom = "medium"
                        case .some(false): advThink = nil
                        }
                    }
                    Haptics.play(.light)
                } label: {
                    Text(label)
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(theme.brandPrimary.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if advThinkCustom != nil {
                TextField("e.g. 'low', 'medium', 'high'", text: Binding(
                    get: { advThinkCustom ?? "" },
                    set: { advThinkCustom = $0 }
                ))
                .scaledFont(size: 13)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    /// Single cycling pill: Default → On → Off → Default
    @ViewBuilder
    private func advBoolRow(label: String, value: Binding<Bool?>, defaultValue: Bool = false) -> some View {
        let current = value.wrappedValue
        let currentLabel: String = {
            switch current {
            case .some(true):  return "On"
            case .some(false): return "Off"
            case .none:        return "Default"
            }
        }()
        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                // Cycle: nil (Default) → true (On) → false (Off) → nil
                switch current {
                case .none:        value.wrappedValue = true
                case .some(true):  value.wrappedValue = false
                case .some(false): value.wrappedValue = nil
                }
                Haptics.play(.light)
            } label: {
                Text(currentLabel)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.brandPrimary.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func advDoubleSliderRow(label: String, tooltip: String?, value: Binding<Double?>, range: ClosedRange<Double>, step: Double) -> some View {
        let isCustom = value.wrappedValue != nil
        VStack(alignment: .leading, spacing: 4) {
            if let tip = tooltip {
                Text(tip)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            HStack {
                Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                Spacer()
                if isCustom {
                    Text(String(format: "%.2f", value.wrappedValue ?? 0))
                        .scaledFont(size: 12, weight: .semibold).foregroundStyle(theme.brandPrimary).monospacedDigit()
                    Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                } else {
                    Button { value.wrappedValue = (range.lowerBound + range.upperBound) / 2; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, tooltip == nil ? 10 : 2)

            if isCustom {
                Slider(value: Binding(get: { value.wrappedValue ?? range.lowerBound }, set: { value.wrappedValue = $0 }), in: range, step: step)
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 10)
            }
        }
    }

    @ViewBuilder
    private func advIntSliderRow(label: String, value: Binding<Int?>, range: ClosedRange<Double>, step: Double, defaultValue: Int? = nil) -> some View {
        let isCustom = value.wrappedValue != nil
        let activationValue = defaultValue ?? Int((range.lowerBound + range.upperBound) / 2)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                Spacer()
                if isCustom {
                    Text("\(value.wrappedValue ?? 0)")
                        .scaledFont(size: 12, weight: .semibold).foregroundStyle(theme.brandPrimary).monospacedDigit()
                    Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                } else {
                    Button { value.wrappedValue = activationValue; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, 10)

            if isCustom {
                Slider(value: Binding(get: { Double(value.wrappedValue ?? Int(range.lowerBound)) }, set: { value.wrappedValue = Int($0) }), in: range, step: step)
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 10)
            }
        }
    }

    @ViewBuilder
    private func advTextRow(label: String, placeholder: String, value: Binding<String?>) -> some View {
        let isCustom = value.wrappedValue != nil
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                if isCustom {
                    TextField(placeholder, text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 }))
                        .scaledFont(size: 13).foregroundStyle(theme.textSecondary)
                        .autocorrectionDisabled().autocapitalization(.none)
                } else {
                    Text(placeholder).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            if isCustom {
                Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            } else {
                Button { value.wrappedValue = ""; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    /// Single cycling pill for function_calling: Default → Native → Default
    @ViewBuilder
    private func advNativeToggleRow(label: String, value: Binding<String?>) -> some View {
        let isNative = value.wrappedValue == "native"
        let currentLabel = isNative ? "Native" : "Default"
        HStack {
            Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                value.wrappedValue = isNative ? nil : "native"
                Haptics.play(.light)
            } label: {
                Text(currentLabel)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.brandPrimary.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func advPickerRow(label: String, value: Binding<String?>, options: [String]) -> some View {
        let isCustom = value.wrappedValue != nil
        HStack {
            Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
            Spacer()
            if isCustom {
                Picker("", selection: Binding(get: { value.wrappedValue ?? options.first ?? "" }, set: { value.wrappedValue = $0 })) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).tint(theme.brandPrimary).scaledFont(size: 14)
                Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            } else {
                Button { value.wrappedValue = options.first ?? ""; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }
}

// MARK: - ModelToolsAndCapabilitiesSection (extracted to prevent stack overflow)

/// Tools, Skills, Filters, Capabilities, Default Features, and Builtin Tools
/// are extracted into their own struct so they evaluate in a separate stack frame.
struct ModelToolsAndCapabilitiesSection: View {
    @Environment(\.theme) private var theme

    // Tools, Skills, Filters
    @Binding var selectedToolIds: Set<String>
    @Binding var allTools: [(id: String, name: String)]
    @Binding var isFetchingToolsAndFunctions: Bool
    @Binding var selectedActionIds: Set<String>
    @Binding var allActions: [(id: String, name: String)]
    /// Action-type functions with global/active state for the "Actions" section.
    @Binding var allActionFunctions: [(id: String, name: String, isGlobal: Bool)]
    @Binding var selectedActionFunctionIds: Set<String>
    @Binding var selectedFilterIds: Set<String>
    @Binding var defaultFilterIds: Set<String>
    @Binding var allFilters: [(id: String, name: String, isGlobal: Bool, hasToggle: Bool)]

    // Capabilities
    @Binding var capVision: Bool
    @Binding var capFileUpload: Bool
    @Binding var capFileContext: Bool
    @Binding var capWebSearch: Bool
    @Binding var capImageGeneration: Bool
    @Binding var capCodeInterpreter: Bool
    @Binding var capTerminal: Bool
    @Binding var capUsage: Bool
    @Binding var capCitations: Bool
    @Binding var capStatusUpdates: Bool
    @Binding var capMemory: Bool
    @Binding var capBuiltinTools: Bool

    // Default Terminal
    @Binding var terminalId: String
    var terminalServers: [TerminalServer]

    // Default Features
    @Binding var defaultWebSearch: Bool
    @Binding var defaultImageGen: Bool
    @Binding var defaultCodeInterpreter: Bool

    // Builtin Tools
    @Binding var builtinTime: Bool
    @Binding var builtinUserInput: Bool
    @Binding var builtinMemory: Bool
    @Binding var builtinChats: Bool
    @Binding var builtinNotes: Bool
    @Binding var builtinKnowledge: Bool
    @Binding var builtinFiles: Bool
    @Binding var builtinChannels: Bool
    @Binding var builtinNotifications: Bool
    @Binding var builtinTaskManagement: Bool
    @Binding var builtinAutomations: Bool
    @Binding var builtinCalendar: Bool
    @Binding var builtinSubagents: Bool
    @Binding var builtinWebSearch: Bool
    @Binding var builtinImageGen: Bool
    @Binding var builtinCodeInterpreter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            toolsSectionView
            skillsSectionView
            filtersSectionView
            actionFunctionsSectionView
            capabilitiesSectionView
            // Matches web ModelEditor: Default Features only when at least one of
            // web_search / image_generation / code_interpreter capability is on.
            if capWebSearch || capImageGeneration || capCodeInterpreter {
                defaultFeaturesSectionView
            }
            if capBuiltinTools {
                builtinToolsSectionView
            }
            if capTerminal && !terminalServers.isEmpty {
                terminalSectionView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: capBuiltinTools)
        .animation(.easeInOut(duration: 0.2), value: capTerminal)
    }

    // MARK: - Tools

    private var toolsSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Tools")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("Loading tools…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allTools.isEmpty {
                fieldCard {
                    Text("No tools available. Add tools in the Tools workspace first.")
                        .scaledFont(size: 13).foregroundStyle(theme.textTertiary).padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allTools, id: \.id) { tool in
                            setCheckbox(tool.name, id: tool.id, selection: $selectedToolIds)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
                Text("To select toolkits here, add them to the \"Tools\" workspace first.")
                    .scaledFont(size: 12).foregroundStyle(theme.textTertiary).padding(.leading, 4)
            }
        }
    }

    // MARK: - Skills

    private var skillsSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Skills")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("Loading skills…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allActions.isEmpty {
                fieldCard {
                    Text("No skills available. Add skills in the Skills workspace first.")
                        .scaledFont(size: 13).foregroundStyle(theme.textTertiary).padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allActions, id: \.id) { action in
                            setCheckbox(action.name, id: action.id, selection: $selectedActionIds)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
                Text("To select skills here, add them to the \"Skills\" workspace first.")
                    .scaledFont(size: 12).foregroundStyle(theme.textTertiary).padding(.leading, 4)
            }
        }
    }

    // MARK: - Filters

    /// Shows filter functions with global lock support.
    /// Global filters are always checked and disabled (non-editable) with a 🔒 icon.
    /// Per-model filters are editable checkboxes.
    private var filtersSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Filters")
            if isFetchingToolsAndFunctions {
                fieldCard {
                    HStack {
                        ProgressView().controlSize(.small).tint(theme.brandPrimary)
                        Text("Loading filters…").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    }
                    .padding(Spacing.md)
                }
            } else if allFilters.isEmpty {
                fieldCard {
                    Text("No filters available.")
                        .scaledFont(size: 13).foregroundStyle(theme.textTertiary).padding(Spacing.md)
                }
            } else {
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allFilters, id: \.id) { filter in
                            let isGlobal = filter.isGlobal
                            let isSelected = selectedFilterIds.contains(filter.id)
                            Button {
                                guard !isGlobal else { return }
                                if isSelected {
                                    selectedFilterIds.remove(filter.id)
                                } else {
                                    selectedFilterIds.insert(filter.id)
                                }
                                Haptics.play(.light)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                        .scaledFont(size: 16)
                                        .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                                    Text(filter.name).scaledFont(size: 13)
                                        .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    if isGlobal {
                                        Image(systemName: "lock.fill")
                                            .scaledFont(size: 9)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isGlobal)
                            .opacity(isGlobal ? 0.7 : 1.0)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
                // Only toggleable filters can have a meaningful "default on/off" state.
                let checkedFilters = allFilters.filter { selectedFilterIds.contains($0.id) && $0.hasToggle }
                if !checkedFilters.isEmpty {
                    sectionHeader("Default Filters")
                    fieldCard {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                            ForEach(checkedFilters, id: \.id) { filter in
                                setCheckbox(filter.name, id: filter.id, selection: $defaultFilterIds)
                            }
                        }
                        .padding(.vertical, 4).padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    // MARK: - Action Functions

    /// Shows action-type functions (e.g. "Generate Image") with global lock support.
    /// Global actions are always checked and disabled (non-editable).
    /// Per-model actions are editable checkboxes.
    private var actionFunctionsSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !allActionFunctions.isEmpty {
                sectionHeader("Actions")
                fieldCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                        ForEach(allActionFunctions, id: \.id) { fn in
                            let isGlobal = fn.isGlobal
                            let isSelected = selectedActionFunctionIds.contains(fn.id)
                            Button {
                                guard !isGlobal else { return } // Global actions cannot be toggled
                                if isSelected {
                                    selectedActionFunctionIds.remove(fn.id)
                                } else {
                                    selectedActionFunctionIds.insert(fn.id)
                                }
                                Haptics.play(.light)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                        .scaledFont(size: 16)
                                        .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                                    Text(fn.name).scaledFont(size: 13)
                                        .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    if isGlobal {
                                        Image(systemName: "lock.fill")
                                            .scaledFont(size: 9)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isGlobal)
                            .opacity(isGlobal ? 0.7 : 1.0)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
            }
        }
    }

    // MARK: - Capabilities

    private var capabilitiesSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Capabilities")
            fieldCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    capCheckbox("Vision", value: $capVision)
                    capCheckbox("File Upload", value: $capFileUpload)
                    // Web UI hides File Context when File Upload is disabled.
                    if capFileUpload {
                        capCheckbox("File Context", value: $capFileContext)
                    }
                    capCheckbox("Web Search", value: $capWebSearch)
                    capCheckbox("Image Generation", value: $capImageGeneration)
                    capCheckbox("Code Interpreter", value: $capCodeInterpreter)
                    capCheckbox("Terminal", value: $capTerminal)
                    capCheckbox("Usage", value: $capUsage)
                    capCheckbox("Citations", value: $capCitations)
                    capCheckbox("Status Updates", value: $capStatusUpdates)
                    capCheckbox("Memory", value: $capMemory)
                    capCheckbox("Builtin Tools", value: $capBuiltinTools)
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Default Features

    private var defaultFeaturesSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Default Features")
            fieldCard {
                HStack(spacing: 0) {
                    // Only features whose capability is enabled (web availableFeatures).
                    if capWebSearch { capCheckbox("Web Search", value: $defaultWebSearch) }
                    if capImageGeneration { capCheckbox("Image Generation", value: $defaultImageGen) }
                    if capCodeInterpreter { capCheckbox("Code Interpreter", value: $defaultCodeInterpreter) }
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Default Terminal

    /// Mirrors web `TerminalSelector` — picks the terminal a new chat with this model
    /// starts with (`meta.terminalId`). Only shown when the Terminal capability is on
    /// and at least one terminal server is configured.
    private var terminalSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Terminal")
            fieldCard {
                Menu {
                    Button {
                        terminalId = ""
                        Haptics.play(.light)
                    } label: {
                        if terminalId.isEmpty { Label("None", systemImage: "checkmark") } else { Text("None") }
                    }
                    ForEach(terminalServers) { server in
                        Button {
                            terminalId = server.id
                            Haptics.play(.light)
                        } label: {
                            if terminalId == server.id {
                                Label(server.displayName, systemImage: "checkmark")
                            } else {
                                Text(server.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "terminal")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                        Text(selectedTerminalLabel)
                            .scaledFont(size: 15)
                            .foregroundStyle(terminalId.isEmpty ? theme.textTertiary : theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedTerminalLabel: String {
        if terminalId.isEmpty { return String(localized: "None") }
        // Keep showing the raw ID if the saved terminal no longer exists.
        return terminalServers.first(where: { $0.id == terminalId })?.displayName ?? terminalId
    }

    // MARK: - Builtin Tools

    private var builtinToolsSectionView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Builtin Tools")
            fieldCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    capCheckbox("Time & Calculation", value: $builtinTime)
                    capCheckbox("Ask User", value: $builtinUserInput)
                    capCheckbox("Memory", value: $builtinMemory)
                    capCheckbox("Chat History", value: $builtinChats)
                    capCheckbox("Notes", value: $builtinNotes)
                    capCheckbox("Knowledge Base", value: $builtinKnowledge)
                    capCheckbox("Files", value: $builtinFiles)
                    capCheckbox("Channels", value: $builtinChannels)
                    capCheckbox("Notifications", value: $builtinNotifications)
                    capCheckbox("Task Management", value: $builtinTaskManagement)
                    capCheckbox("Automations", value: $builtinAutomations)
                    capCheckbox("Calendar", value: $builtinCalendar)
                    capCheckbox("Sub-agents", value: $builtinSubagents)
                    capCheckbox("Web Search", value: $builtinWebSearch)
                    capCheckbox("Image Generation", value: $builtinImageGen)
                    capCheckbox("Code Interpreter", value: $builtinCodeInterpreter)
                }
                .padding(.vertical, 4).padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func setCheckbox(_ label: String, id: String, selection: Binding<Set<String>>) -> some View {
        let isSelected = selection.wrappedValue.contains(id)
        Button {
            if isSelected { selection.wrappedValue.remove(id) } else { selection.wrappedValue.insert(id) }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .scaledFont(size: 16)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
                Text(label).scaledFont(size: 13)
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func capCheckbox(_ label: String, value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                    .scaledFont(size: 16)
                    .foregroundStyle(value.wrappedValue ? theme.brandPrimary : theme.textTertiary)
                Text(label).scaledFont(size: 13)
                    .foregroundStyle(value.wrappedValue ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(theme.surfaceContainer.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
            )
    }
}
