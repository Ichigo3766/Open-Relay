import SwiftUI
import PhotosUI

/// Sheet for creating a new folder — shows full settings matching the web UI:
/// name, background image, system prompt, and knowledge.
///
/// On save, calls `onCreate` with the name plus optional data/meta.
struct CreateFolderSheet: View {
    // MARK: - Inputs

    let apiClient: APIClient?
    var onCreate: (String, FolderData?, FolderMeta?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    // MARK: - State

    @State private var folderName = ""
    @State private var systemPrompt = ""
    @State private var attachedKnowledge: [FolderKnowledgeItem] = []
    @State private var backgroundImageUrl: String?

    @State private var allKnowledgeItems: [KnowledgeItem] = []
    @State private var isLoadingKnowledge = false

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isUploadingImage = false

    @State private var allModels: [AIModel] = []
    @State private var isLoadingModels = false
    @State private var selectedModelIds: [String] = []
    @State private var showModelPicker = false

    @State private var showKnowledgePicker = false
    @FocusState private var nameFocused: Bool
    @FocusState private var promptFocused: Bool

    // MARK: - Rename-Only Init (backward compat for inline rename flows)

    /// Lightweight rename-only variant — shows just a name field (no full settings).
    /// Used by ChatListView and other places that only need to rename an existing folder.
    init(existingName: String, onRename: @escaping (String) -> Void) {
        self.apiClient = nil
        self.onCreate = { name, _, _ in onRename(name) }
        _folderName = State(initialValue: existingName)
    }

    // MARK: - Full Create Init

    init(
        apiClient: APIClient? = nil,
        onCreate: @escaping (String, FolderData?, FolderMeta?) -> Void
    ) {
        self.apiClient = apiClient
        self.onCreate = onCreate
    }

    // MARK: - Computed

    private var isActionEnabled: Bool {
        !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    // Folder name
                    nameSection

                    Divider().padding(.horizontal, Spacing.md)

                    // Background image
                    backgroundSection

                    Divider().padding(.horizontal, Spacing.md)

                    // System prompt
                    systemPromptSection

                    Divider().padding(.horizontal, Spacing.md)

                    // Default Models
                    modelsSection

                    Divider().padding(.horizontal, Spacing.md)

                    // Knowledge
                    knowledgeSection

                    Spacer(minLength: Spacing.xl)
                }
                .padding(.top, Spacing.md)
            }
            .navigationTitle(String(localized: "Create Folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { commitCreate() }
                        .fontWeight(.semibold)
                        .disabled(!isActionEnabled)
                }
            }
            .background(theme.background)
            .task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await loadKnowledge() }
                    group.addTask { await loadModels() }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    nameFocused = true
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.background)
        .sheet(isPresented: $showKnowledgePicker) {
            knowledgePickerSheet
        }
        .sheet(isPresented: $showModelPicker) {
            modelPickerSheet
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("Folder Name")
            TextField(String(localized: "Enter folder name"), text: $folderName)
                .focused($nameFocused)
                .scaledFont(size: 16)
                .padding(Spacing.md)
                .background(theme.inputBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(nameFocused ? theme.brandPrimary : theme.inputBorder,
                                lineWidth: nameFocused ? 1.5 : 1)
                )
                .padding(.horizontal, Spacing.md)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .onSubmit { if isActionEnabled { commitCreate() } }
        }
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                sectionLabel("Folder Background Image")
                Spacer()
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    if isUploadingImage {
                        ProgressView().controlSize(.small).padding(.trailing, Spacing.md)
                    } else {
                        Text("Upload")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                            .padding(.trailing, Spacing.md)
                    }
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    guard let newItem else { return }
                    Task {
                        isUploadingImage = true
                        if let data = try? await newItem.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data),
                           let jpegData = uiImage.jpegData(compressionQuality: 0.8) {
                            let base64 = jpegData.base64EncodedString()
                            backgroundImageUrl = "data:image/jpeg;base64,\(base64)"
                        }
                        isUploadingImage = false
                    }
                }
            }

            if let url = backgroundImageUrl, !url.isEmpty {
                HStack {
                    Image(systemName: url.hasPrefix("data:") ? "photo.fill" : "photo")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                    Text(url.hasPrefix("data:") ? "Image selected" : url)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        backgroundImageUrl = nil
                        selectedPhotoItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(.horizontal, Spacing.md)
            }
        }
    }

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("System Prompt")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $systemPrompt)
                    .focused($promptFocused)
                    .scaledFont(size: 15)
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(Spacing.sm)
                    .background(theme.inputBackground, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(promptFocused ? theme.brandPrimary : theme.inputBorder,
                                    lineWidth: promptFocused ? 1.5 : 1)
                    )
                    .scrollContentBackground(.hidden)
                if systemPrompt.isEmpty {
                    Text("Write your model system prompt content here\ne.g.) You are Mario from Super Mario Bros, acting as an assistant.")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, Spacing.sm + 4)
                        .padding(.leading, Spacing.sm + 4)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, Spacing.md)
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("Default Model")

            if !selectedModelIds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(selectedModelIds, id: \.self) { modelId in
                            let displayName = allModels.first(where: { $0.id == modelId })?.name ?? modelId
                            HStack(spacing: 4) {
                                Text(displayName)
                                    .scaledFont(size: 13, weight: .medium)
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Button {
                                    selectedModelIds.removeAll { $0 == modelId }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .scaledFont(size: 14)
                                        .foregroundStyle(theme.textTertiary)
                                }
                            }
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .background(theme.inputBackground, in: Capsule())
                            .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                }
                .padding(.bottom, Spacing.xs)
            }

            HStack {
                Button {
                    showModelPicker = true
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "cpu").scaledFont(size: 14)
                        }
                        Text("Select Model").scaledFont(size: 14, weight: .medium)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(theme.inputBackground, in: Capsule())
                    .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)

            if selectedModelIds.isEmpty {
                Text("Set a default model for all new chats created in this folder.")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("Knowledge")

            if !attachedKnowledge.isEmpty {
                VStack(spacing: Spacing.xs) {
                    ForEach(attachedKnowledge) { item in
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: iconName(for: item.type))
                                .scaledFont(size: 14)
                                .foregroundStyle(iconColor(for: item.type))
                                .frame(width: 20)
                            Text(item.name)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                attachedKnowledge.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs)
                    }
                }
                .padding(.bottom, Spacing.xs)
            }

            HStack {
                Button {
                    showKnowledgePicker = true
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if isLoadingKnowledge {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "book.closed").scaledFont(size: 14)
                        }
                        Text("Select Knowledge").scaledFont(size: 14, weight: .medium)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(theme.inputBackground, in: Capsule())
                    .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)

            if attachedKnowledge.isEmpty {
                Text("To attach knowledge base here, add them to the \"Knowledge\" workspace first.")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - Model Picker Sheet

    private var modelPickerSheet: some View {
        NavigationStack {
            List {
                ForEach(allModels.filter { !selectedModelIds.contains($0.id) }) { model in
                    Button {
                        if !selectedModelIds.contains(model.id) {
                            selectedModelIds.append(model.id)
                        }
                        showModelPicker = false
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "cpu")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.brandPrimary)
                                .frame(width: 24)
                            Text(model.name)
                                .scaledFont(size: 15)
                                .foregroundStyle(theme.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(String(localized: "Select Model"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { showModelPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Knowledge Picker Sheet

    private var knowledgePickerSheet: some View {
        NavigationStack {
            KnowledgePickerView(
                query: "",
                items: allKnowledgeItems.filter { item in
                    !attachedKnowledge.contains(where: { $0.id == item.id })
                },
                isLoading: isLoadingKnowledge,
                onSelect: { item in
                    let ki = FolderKnowledgeItem(id: item.id, name: item.name, type: item.type.rawValue)
                    if !attachedKnowledge.contains(where: { $0.id == item.id }) {
                        attachedKnowledge.append(ki)
                    }
                    showKnowledgePicker = false
                },
                onDismiss: { showKnowledgePicker = false }
            )
            .navigationTitle(String(localized: "Select Knowledge"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { showKnowledgePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Model Loading

    private func loadModels() async {
        guard let api = apiClient else { return }
        isLoadingModels = true
        do {
            allModels = try await api.getModels()
        } catch {
            allModels = []
        }
        isLoadingModels = false
    }

    // MARK: - Knowledge Loading

    private func loadKnowledge() async {
        guard let api = apiClient else { return }
        isLoadingKnowledge = true
        do {
            async let collectionsReq = api.getKnowledgeItems()
            async let filesReq = (try? await api.getKnowledgeFileItems()) ?? []
            let (collections, files) = try await (collectionsReq, filesReq)
            allKnowledgeItems = collections + files
        } catch {
            allKnowledgeItems = []
        }
        isLoadingKnowledge = false
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, Spacing.md)
    }

    private func commitCreate() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let data: FolderData? = {
            if prompt.isEmpty && attachedKnowledge.isEmpty && selectedModelIds.isEmpty { return nil }
            return FolderData(
                modelIds: selectedModelIds,
                systemPrompt: prompt.isEmpty ? nil : prompt,
                knowledgeItems: attachedKnowledge
            )
        }()

        let meta: FolderMeta? = {
            if let url = backgroundImageUrl, !url.isEmpty {
                return FolderMeta(backgroundImageUrl: url)
            }
            return nil
        }()

        dismiss()
        onCreate(name, data, meta)
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "collection": return "cylinder.split.1x2"
        case "file": return "doc.text"
        default: return "folder"
        }
    }

    private func iconColor(for type: String) -> Color {
        switch type {
        case "collection": return .purple
        case "file": return .blue
        default: return theme.brandPrimary
        }
    }
}
