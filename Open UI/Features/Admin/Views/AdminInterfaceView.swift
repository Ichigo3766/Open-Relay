import SwiftUI

// MARK: - Admin Interface View

/// The admin "Interface" tab — configure task models, generation toggles, and prompt templates.
/// Layout matches the web UI: each prompt template is grouped with its generation toggle.
struct AdminInterfaceView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminInterfaceViewModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    if viewModel.isLoading {
                        sectionLoadingView()
                    } else {
                        taskModelSection
                        titleGenerationSection
                        voiceModeSection
                        followUpSection
                        tagsSection
                        querySection
                        autocompleteSection
                        imagePromptSection
                        toolsPromptSection
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
    }

    // MARK: - Floating Save Button

    private var floatingSaveButton: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if let warning = viewModel.modelWarning {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 11)
                    Text(warning)
                        .scaledFont(size: 12)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 6)
                .background(.orange)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

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
        .animation(.easeInOut(duration: 0.25), value: viewModel.modelWarning)
    }

    // MARK: - Task Model Section

    private var taskModelSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "cpu", title: "Task Model")

            SettingsSection {
                modelFieldRow(
                    title: "Local Task Model",
                    text: $viewModel.config.taskModel,
                    availableItems: viewModel.models
                )

                Divider().padding(.horizontal, Spacing.md)

                modelFieldRow(
                    title: "External Task Model",
                    text: $viewModel.config.taskModelExternal,
                    availableItems: viewModel.models
                )
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Title Generation (toggle + prompt)

    private var titleGenerationSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "textformat", title: "Title Generation")

            SettingsSection {
                inlineToggleRow(
                    title: "Title Generation",
                    isOn: $viewModel.config.enableTitleGeneration
                )

                if viewModel.config.enableTitleGeneration {
                    Divider().padding(.horizontal, Spacing.md)

                    promptEditorRow(
                        title: "Title Generation Prompt",
                        text: $viewModel.config.titleGenerationPromptTemplate
                    )
                }
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Voice Mode (toggle + prompt)

    private var voiceModeSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "waveform", title: "Voice Mode Custom Prompt")

            SettingsSection {
                promptEditorRow(
                    title: "Voice Mode Prompt",
                    text: $viewModel.config.voiceModePromptTemplate
                )
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Follow Up Generation (toggle + prompt)

    private var followUpSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "arrowshape.turn.up.right", title: "Follow Up Generation")

            SettingsSection {
                inlineToggleRow(
                    title: "Follow Up Generation",
                    isOn: $viewModel.config.enableFollowUpGeneration
                )

                if viewModel.config.enableFollowUpGeneration {
                    Divider().padding(.horizontal, Spacing.md)

                    promptEditorRow(
                        title: "Follow Up Generation Prompt",
                        text: $viewModel.config.followUpGenerationPromptTemplate
                    )
                }
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Tags Generation (toggle + prompt)

    private var tagsSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "tag", title: "Tags Generation")

            SettingsSection {
                inlineToggleRow(
                    title: "Tags Generation",
                    isOn: $viewModel.config.enableTagsGeneration
                )

                if viewModel.config.enableTagsGeneration {
                    Divider().padding(.horizontal, Spacing.md)

                    promptEditorRow(
                        title: "Tags Generation Prompt",
                        text: $viewModel.config.tagsGenerationPromptTemplate
                    )
                }
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Query Generation (retrieval + web search toggles + prompt)

    private var querySection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "magnifyingglass", title: "Query Generation")

            SettingsSection {
                inlineToggleRow(
                    title: "Retrieval Query Generation",
                    isOn: $viewModel.config.enableRetrievalQueryGeneration
                )

                Divider().padding(.horizontal, Spacing.md)

                inlineToggleRow(
                    title: "Web Search Query Generation",
                    isOn: $viewModel.config.enableSearchQueryGeneration
                )

                if viewModel.config.enableRetrievalQueryGeneration || viewModel.config.enableSearchQueryGeneration {
                    Divider().padding(.horizontal, Spacing.md)

                    promptEditorRow(
                        title: "Query Generation Prompt",
                        text: $viewModel.config.queryGenerationPromptTemplate
                    )
                }
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Autocomplete Generation (toggle + max length)

    private var autocompleteSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "text.cursor", title: "Autocomplete Generation")

            SettingsSection {
                inlineToggleRow(
                    title: "Autocomplete Generation",
                    isOn: $viewModel.config.enableAutocompleteGeneration
                )

                if viewModel.config.enableAutocompleteGeneration {
                    Divider().padding(.horizontal, Spacing.md)

                    inlineTextFieldRow(
                        title: "Autocomplete Generation Input Max Length",
                        placeholder: "-1 for unlimited",
                        text: $viewModel.autocompleteMaxLengthString,
                        keyboardType: .numbersAndPunctuation
                    )
                }
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Image Prompt Generation (standalone prompt)

    private var imagePromptSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "photo", title: "Image Prompt Generation")

            SettingsSection {
                promptEditorRow(
                    title: "Image Prompt Generation Prompt",
                    text: $viewModel.config.imagePromptGenerationPromptTemplate
                )
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Tools Function Calling (standalone prompt)

    private var toolsPromptSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "wrench.and.screwdriver", title: "Tools Function Calling")

            SettingsSection {
                promptEditorRow(
                    title: "Tools Function Calling Prompt",
                    text: $viewModel.config.toolsFunctionCallingPromptTemplate
                )
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
    }

    // MARK: - Row Builders

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            Text(title)
                .scaledFont(size: 16, weight: .bold)
                .foregroundStyle(theme.textPrimary)
            Spacer()
        }
    }

    private func sectionLoadingView() -> some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Loading interface settings…")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(theme.surfaceContainer)
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
        keyboardType: UIKeyboardType = .default
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

    /// A field that shows as a text field for custom input, with a Menu picker.
    /// When a non-public model is selected from the picker, the selection is rejected.
    private func modelFieldRow(
        title: String,
        text: Binding<String>,
        availableItems: [(id: String, name: String)]
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                TextField("Enter or select", text: text)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if !availableItems.isEmpty {
                Menu {
                    // Empty option to clear
                    Button {
                        text.wrappedValue = ""
                        viewModel.modelWarning = nil
                    } label: {
                        HStack {
                            Text("(Default)")
                            if text.wrappedValue.isEmpty {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    ForEach(availableItems, id: \.id) { item in
                        Button {
                            if viewModel.isModelPublic(item.id) {
                                text.wrappedValue = item.id
                            }
                            // If not public, warning is set but value stays unchanged
                        } label: {
                            HStack {
                                Text(item.name)
                                if text.wrappedValue == item.id {
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

    /// A multiline text editor for prompt templates.
    private func promptEditorRow(
        title: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)

            TextEditor(text: text)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80, maxHeight: 200)
                .padding(Spacing.xs)
                .background(theme.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                        .strokeBorder(theme.inputBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.chatBubblePadding)
    }
}
