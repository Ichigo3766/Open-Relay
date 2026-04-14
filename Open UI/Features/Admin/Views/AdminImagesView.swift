import SwiftUI
import UniformTypeIdentifiers

// MARK: - Admin Images View

/// The admin "Images" tab — configure image generation and editing settings.
struct AdminImagesView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminImagesViewModel()
    @State private var showImportPicker = false
    @State private var importForEdit = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    if viewModel.isLoading {
                        sectionLoadingView()
                    } else {
                        createImageSection
                        editImageSection
                    }
                    Spacer(minLength: 100)
                }
                .padding(.top, Spacing.md)
            }
            .background(theme.background)

            floatingSaveButton
        }
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.load()
        }
        .sheet(isPresented: $viewModel.showWorkflowEditor) {
            WorkflowEditorSheet(viewModel: viewModel)
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        viewModel.importWorkflowJSON(data, forEdit: importForEdit)
                    }
                }
            }
        }
    }

    // MARK: - Floating Save Button

    private var floatingSaveButton: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if let error = viewModel.error {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .scaledFont(size: 11)
                    Text(error)
                        .scaledFont(size: 12)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 6)
                .background(theme.error)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button {
                Task { await viewModel.save() }
                Haptics.play(.light)
            } label: {
                HStack(spacing: Spacing.xs) {
                    if viewModel.isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else if viewModel.success {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 14)
                        Text("Saved")
                            .scaledFont(size: 14, weight: .semibold)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .scaledFont(size: 14, weight: .semibold)
                        Text("Save")
                            .scaledFont(size: 14, weight: .semibold)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(viewModel.success ? Color.green : theme.brandPrimary)
                .clipShape(Capsule())
                .shadow(color: (viewModel.success ? Color.green : theme.brandPrimary).opacity(0.4), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving)
            .animation(.easeInOut(duration: 0.2), value: viewModel.success)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isSaving)
        }
        .padding(.trailing, Spacing.screenPadding)
        .padding(.bottom, Spacing.lg)
        .animation(.easeInOut(duration: 0.25), value: viewModel.error)
    }

    // MARK: - Create Image Section

    private var createImageSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "photo.artframe", title: "Create Image")

            SettingsSection {
                inlineToggleRow(title: "Image Generation", isOn: $viewModel.config.enableImageGeneration)

                if viewModel.config.enableImageGeneration {
                    // Model — editable text field with optional picker from server models
                    Divider().padding(.leading, Spacing.md)
                    modelFieldRow(
                        title: "Model",
                        text: $viewModel.config.imageGenerationModel,
                        availableModels: viewModel.models
                    )

                    Divider().padding(.leading, Spacing.md)
                    inlineTextFieldRow(title: "Image Size", placeholder: "1024x1024", text: $viewModel.config.imageSize)

                    Divider().padding(.leading, Spacing.md)
                    inlineTextFieldRow(
                        title: "Steps",
                        placeholder: "4",
                        text: Binding(
                            get: { String(viewModel.config.imageSteps) },
                            set: { viewModel.config.imageSteps = Int($0) ?? 4 }
                        ),
                        keyboardType: .numberPad
                    )

                    Divider().padding(.leading, Spacing.md)
                    inlineToggleRow(title: "Image Prompt Generation", isOn: $viewModel.config.enableImagePromptGeneration)

                    Divider().padding(.leading, Spacing.md)
                    inlinePickerRow(
                        title: "Image Generation Engine",
                        selection: $viewModel.config.imageGenerationEngine,
                        options: [
                            ("openai", "Default (Open AI)"),
                            ("comfyui", "ComfyUI"),
                            ("automatic1111", "Automatic1111"),
                            ("gemini", "Gemini")
                        ]
                    )

                    // Engine-specific fields
                    switch viewModel.config.imageGenerationEngine {
                    case "openai":
                        openAIFields(
                            baseURL: $viewModel.config.imagesOpenAIAPIBaseURL,
                            apiKey: $viewModel.config.imagesOpenAIAPIKey,
                            showKey: viewModel.showOpenAIKey,
                            toggleKey: { viewModel.showOpenAIKey.toggle() },
                            apiVersion: $viewModel.config.imagesOpenAIAPIVersion
                        )
                    case "comfyui":
                        comfyUIFields(
                            baseURL: $viewModel.config.comfyUIBaseURL,
                            apiKey: $viewModel.config.comfyUIAPIKey,
                            showKey: viewModel.showComfyUIKey,
                            toggleKey: { viewModel.showComfyUIKey.toggle() },
                            workflow: viewModel.config.comfyUIWorkflow,
                            nodes: $viewModel.config.comfyUIWorkflowNodes,
                            isEdit: false
                        )
                    case "automatic1111":
                        automatic1111Fields
                    case "gemini":
                        geminiFields(
                            baseURL: $viewModel.config.imagesGeminiAPIBaseURL,
                            apiKey: $viewModel.config.imagesGeminiAPIKey,
                            showKey: viewModel.showGeminiKey,
                            toggleKey: { viewModel.showGeminiKey.toggle() },
                            endpointMethod: $viewModel.config.imagesGeminiEndpointMethod
                        )
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: - Edit Image Section

    private var editImageSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "pencil.and.outline", title: "Edit Image")

            SettingsSection {
                inlineToggleRow(title: "Image Edit", isOn: $viewModel.config.enableImageEdit)

                if viewModel.config.enableImageEdit {
                    Divider().padding(.leading, Spacing.md)
                    inlinePickerRow(
                        title: "Image Edit Engine",
                        selection: $viewModel.config.imageEditEngine,
                        options: [
                            ("openai", "Default (Open AI)"),
                            ("comfyui", "ComfyUI"),
                            ("gemini", "Gemini")
                        ]
                    )

                    switch viewModel.config.imageEditEngine {
                    case "openai":
                        openAIFields(
                            baseURL: $viewModel.config.imagesEditOpenAIAPIBaseURL,
                            apiKey: $viewModel.config.imagesEditOpenAIAPIKey,
                            showKey: viewModel.showEditOpenAIKey,
                            toggleKey: { viewModel.showEditOpenAIKey.toggle() },
                            apiVersion: $viewModel.config.imagesEditOpenAIAPIVersion
                        )
                    case "comfyui":
                        comfyUIFields(
                            baseURL: $viewModel.config.imagesEditComfyUIBaseURL,
                            apiKey: $viewModel.config.imagesEditComfyUIAPIKey,
                            showKey: viewModel.showEditComfyUIKey,
                            toggleKey: { viewModel.showEditComfyUIKey.toggle() },
                            workflow: viewModel.config.imagesEditComfyUIWorkflow,
                            nodes: $viewModel.config.imagesEditComfyUIWorkflowNodes,
                            isEdit: true
                        )
                    case "gemini":
                        geminiFields(
                            baseURL: $viewModel.config.imagesEditGeminiAPIBaseURL,
                            apiKey: $viewModel.config.imagesEditGeminiAPIKey,
                            showKey: viewModel.showEditGeminiKey,
                            toggleKey: { viewModel.showEditGeminiKey.toggle() },
                            endpointMethod: .constant("")
                        )
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: - OpenAI Engine Fields

    private func openAIFields(
        baseURL: Binding<String>,
        apiKey: Binding<String>,
        showKey: Bool,
        toggleKey: @escaping () -> Void,
        apiVersion: Binding<String>
    ) -> some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "API Base URL", placeholder: "https://api.openai.com/v1", text: baseURL, keyboardType: .URL)

            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(title: "API Key", placeholder: "sk-...", text: apiKey, isVisible: showKey, onToggleVisibility: toggleKey)

            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "API Version", placeholder: "Optional", text: apiVersion, showDivider: false)
        }
    }

    // MARK: - ComfyUI Engine Fields

    private func comfyUIFields(
        baseURL: Binding<String>,
        apiKey: Binding<String>,
        showKey: Bool,
        toggleKey: @escaping () -> Void,
        workflow: String,
        nodes: Binding<[ImageWorkflowNode]>,
        isEdit: Bool
    ) -> some View {
        Group {
            Divider().padding(.leading, Spacing.md)

            // Base URL with verify button
            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("ComfyUI Base URL")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                    TextField("http://localhost:8188", text: baseURL)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Spacer()

                Button {
                    Task { await viewModel.verifyURL() }
                } label: {
                    Group {
                        if viewModel.isVerifying {
                            ProgressView().controlSize(.small)
                        } else if let result = viewModel.verifyResult {
                            Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result ? Color.green : theme.error)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(theme.brandPrimary)
                        }
                    }
                    .scaledFont(size: 16)
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(title: "ComfyUI API Key", placeholder: "API Key", text: apiKey, isVisible: showKey, onToggleVisibility: toggleKey)

            Divider().padding(.leading, Spacing.md)

            // Workflow section
            workflowSection(workflow: workflow, isEdit: isEdit)

            Divider().padding(.leading, Spacing.md)

            // Workflow nodes
            workflowNodesSection(nodes: nodes, isEdit: isEdit)
        }
    }

    // MARK: - Automatic1111 Fields

    private var automatic1111Fields: some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "Base URL", placeholder: "http://localhost:7860", text: $viewModel.config.automatic1111BaseURL, keyboardType: .URL)

            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(
                title: "API Auth",
                placeholder: "user:password",
                text: $viewModel.config.automatic1111APIAuth,
                isVisible: viewModel.showAutoAuth,
                onToggleVisibility: { viewModel.showAutoAuth.toggle() }
            )
        }
    }

    // MARK: - Gemini Fields

    private func geminiFields(
        baseURL: Binding<String>,
        apiKey: Binding<String>,
        showKey: Bool,
        toggleKey: @escaping () -> Void,
        endpointMethod: Binding<String>
    ) -> some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "API Base URL", placeholder: "https://generativelanguage.googleapis.com", text: baseURL, keyboardType: .URL)

            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(title: "API Key", placeholder: "API Key", text: apiKey, isVisible: showKey, onToggleVisibility: toggleKey)

            if endpointMethod.wrappedValue != "" || !endpointMethod.wrappedValue.isEmpty {
                Divider().padding(.leading, Spacing.md)
                inlineTextFieldRow(title: "Endpoint Method", placeholder: "", text: endpointMethod, showDivider: false)
            }
        }
    }

    // MARK: - Workflow Section

    private func workflowSection(workflow: String, isEdit: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ComfyUI Workflow")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                    Text("Make sure to export a workflow.json file as API format from ComfyUI.")
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()

                HStack(spacing: Spacing.sm) {
                    Button("Edit") {
                        viewModel.openWorkflowEditor(forEdit: isEdit)
                    }
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)

                    Button("Upload") {
                        importForEdit = isEdit
                        showImportPicker = true
                    }
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
                }
            }

            if !workflow.isEmpty {
                Text(workflow.prefix(120) + (workflow.count > 120 ? "…" : ""))
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
                    .font(.system(.caption2, design: .monospaced))
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    // MARK: - Workflow Nodes Section

    private func workflowNodesSection(nodes: Binding<[ImageWorkflowNode]>, isEdit: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("ComfyUI Workflow Nodes")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, Spacing.md)

            ForEach(nodes.indices, id: \.self) { index in
                let node = nodes[index]
                let isRequired = node.wrappedValue.type == "prompt" || node.wrappedValue.type == "image"

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(node.wrappedValue.type.capitalized)
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        if isRequired {
                            Text("*")
                                .scaledFont(size: 13, weight: .bold)
                                .foregroundStyle(theme.error)
                        }
                    }

                    HStack(spacing: Spacing.sm) {
                        Text(node.wrappedValue.key)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .font(.system(.footnote, design: .monospaced))

                        Text(":")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textTertiary)

                        if node.wrappedValue.nodeIds.isEmpty {
                            Text("Node Ids")
                                .scaledFont(size: 13)
                                .foregroundStyle(theme.textTertiary)
                        } else {
                            TextField(
                                "Node IDs",
                                text: Binding(
                                    get: { node.wrappedValue.nodeIds.joined(separator: ", ") },
                                    set: { newValue in
                                        nodes[index].wrappedValue.nodeIds = newValue
                                            .split(separator: ",")
                                            .map { $0.trimmingCharacters(in: .whitespaces) }
                                            .filter { !$0.isEmpty }
                                    }
                                )
                            )
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textPrimary)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)

                if index < nodes.count - 1 {
                    Divider().padding(.leading, Spacing.md + Spacing.sm)
                }
            }

            if nodes.contains(where: { $0.wrappedValue.type == "prompt" || $0.wrappedValue.type == "image" }) {
                Text("*Prompt node ID(s) are required for image generation")
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
            }
        }
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    // MARK: - Shared Row Builders

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            Text(title.uppercased())
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .tracking(0.8)
            Spacer()
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    private func sectionLoadingView() -> some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.regular)
                .padding(.vertical, Spacing.lg)
            Spacer()
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, 100)
    }

    private func inlineToggleRow(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(theme.brandPrimary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    private func inlineTextFieldRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        showDivider: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)
            TextField(placeholder, text: text)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    /// A model field that shows as a text field for custom input, with a Menu picker
    /// when server models are available — user can type a custom name OR pick from the list.
    private func modelFieldRow(
        title: String,
        text: Binding<String>,
        availableModels: [ImageModelItem]
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                TextField("Model name", text: text)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if !availableModels.isEmpty {
                Menu {
                    ForEach(availableModels) { model in
                        Button {
                            text.wrappedValue = model.id
                        } label: {
                            HStack {
                                Text(model.name)
                                if text.wrappedValue == model.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: 28, height: 28)
                        .background(theme.brandPrimary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    private func inlinePickerRow(
        title: String,
        selection: Binding<String>,
        options: [(value: String, label: String)]
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Text(title)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()
            Menu {
                ForEach(options, id: \.value) { option in
                    Button {
                        selection.wrappedValue = option.value
                    } label: {
                        HStack {
                            Text(option.label)
                            if selection.wrappedValue == option.value {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options.first(where: { $0.value == selection.wrappedValue })?.label ?? selection.wrappedValue)
                        .scaledFont(size: 14)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(size: 10)
                }
                .foregroundStyle(theme.brandPrimary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }

    private func inlineSecureRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        isVisible: Bool,
        onToggleVisibility: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                Group {
                    if isVisible {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            Spacer()
            Button(action: onToggleVisibility) {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }
}

// MARK: - Workflow Editor Sheet

struct WorkflowEditorSheet: View {
    @Bindable var viewModel: AdminImagesViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var jsonError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = jsonError {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .scaledFont(size: 12)
                        Text(error)
                            .scaledFont(size: 12)
                            .lineLimit(2)
                    }
                    .foregroundStyle(theme.error)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.error.opacity(0.08))
                }

                TextEditor(text: $viewModel.workflowEditorText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(theme.background)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .navigationTitle(viewModel.editingWorkflowIsEdit ? "Edit Workflow" : "Create Workflow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: Spacing.sm) {
                        // Format button
                        Button {
                            viewModel.workflowEditorText = viewModel.prettyPrintJSON(viewModel.workflowEditorText)
                            validateJSON()
                        } label: {
                            Image(systemName: "text.alignleft")
                                .scaledFont(size: 14)
                        }

                        // Save button
                        Button("Save") {
                            if validateJSON() {
                                viewModel.saveWorkflowFromEditor()
                                dismiss()
                            }
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    @discardableResult
    private func validateJSON() -> Bool {
        guard let data = viewModel.workflowEditorText.data(using: .utf8) else {
            jsonError = "Invalid text encoding"
            return false
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            jsonError = nil
            return true
        } catch {
            jsonError = "Invalid JSON: \(error.localizedDescription)"
            return false
        }
    }
}
