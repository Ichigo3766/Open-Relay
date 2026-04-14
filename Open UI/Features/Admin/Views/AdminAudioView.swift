import SwiftUI

// MARK: - Admin Audio View

/// The admin "Audio" tab — configure TTS and STT settings.
struct AdminAudioView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminAudioViewModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    if viewModel.isLoading {
                        sectionLoadingView()
                    } else {
                        ttsSection
                        sttSection
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

    // MARK: - TTS Section

    private var ttsSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "speaker.wave.2", title: "Text-to-Speech")

            SettingsSection {
                // Engine picker
                inlinePickerRow(
                    title: "TTS Engine",
                    selection: $viewModel.config.tts.engine,
                    options: [
                        ("", "Web API"),
                        ("transformers", "Transformers (Local)"),
                        ("openai", "OpenAI"),
                        ("elevenlabs", "ElevenLabs"),
                        ("azure", "Azure AI Speech")
                    ]
                )

                // Engine-specific fields
                switch viewModel.config.tts.engine {
                case "openai":
                    ttsOpenAIFields
                case "elevenlabs":
                    ttsElevenLabsFields
                case "azure":
                    ttsAzureFields
                case "":
                    // Web API — show API Key field
                    Divider().padding(.leading, Spacing.md)
                    inlineSecureRow(
                        title: "API Key",
                        placeholder: "API Key",
                        text: $viewModel.config.tts.apiKey,
                        isVisible: viewModel.showTTSApiKey,
                        onToggleVisibility: { viewModel.showTTSApiKey.toggle() }
                    )
                default:
                    EmptyView()
                }

                // TTS Model
                Divider().padding(.leading, Spacing.md)
                modelFieldRow(
                    title: "TTS Model",
                    text: $viewModel.config.tts.model,
                    availableItems: viewModel.ttsModels
                )

                // TTS Voice
                Divider().padding(.leading, Spacing.md)
                modelFieldRow(
                    title: "TTS Voice",
                    text: $viewModel.config.tts.voice,
                    availableItems: viewModel.voices
                )

                // Additional Parameters (JSON)
                Divider().padding(.leading, Spacing.md)
                inlineTextFieldRow(
                    title: "Additional Parameters",
                    placeholder: "{}",
                    text: $viewModel.config.tts.openAIParamsJSON
                )

                // Response Splitting
                Divider().padding(.leading, Spacing.md)
                inlinePickerRow(
                    title: "Response Splitting",
                    selection: $viewModel.config.tts.splitOn,
                    options: [
                        ("punctuation", "Punctuation"),
                        ("paragraphs", "Paragraphs"),
                        ("none", "None")
                    ]
                )

                Text("Control how text is split for TTS processing. Punctuation provides the most natural pauses.")
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.chatBubblePadding)
            }
        }
    }

    // MARK: - TTS OpenAI Fields

    private var ttsOpenAIFields: some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "API Base URL", placeholder: "https://api.openai.com/v1", text: $viewModel.config.tts.openAIAPIBaseURL, keyboardType: .URL)

            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(
                title: "API Key",
                placeholder: "sk-...",
                text: $viewModel.config.tts.openAIAPIKey,
                isVisible: viewModel.showTTSOpenAIKey,
                onToggleVisibility: { viewModel.showTTSOpenAIKey.toggle() }
            )
        }
    }

    // MARK: - TTS ElevenLabs Fields

    private var ttsElevenLabsFields: some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(
                title: "API Key",
                placeholder: "API Key",
                text: $viewModel.config.tts.apiKey,
                isVisible: viewModel.showTTSApiKey,
                onToggleVisibility: { viewModel.showTTSApiKey.toggle() }
            )
        }
    }

    // MARK: - TTS Azure Fields

    private var ttsAzureFields: some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "Speech Region", placeholder: "eastus", text: $viewModel.config.tts.azureSpeechRegion)

            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "Base URL", placeholder: "https://...", text: $viewModel.config.tts.azureSpeechBaseURL, keyboardType: .URL)

            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "Output Format", placeholder: "audio-24khz-160kbitrate-mono-mp3", text: $viewModel.config.tts.azureSpeechOutputFormat)
        }
    }

    // MARK: - STT Section

    private var sttSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "mic", title: "Speech-to-Text")

            SettingsSection {
                // Engine picker
                inlinePickerRow(
                    title: "STT Engine",
                    selection: $viewModel.config.stt.engine,
                    options: [
                        ("whisper-local", "Whisper (Local)"),
                        ("openai", "OpenAI"),
                        ("web", "Web API"),
                        ("deepgram", "Deepgram"),
                        ("azure", "Azure AI Speech"),
                        ("mistral", "MistralAI")
                    ]
                )

                // Engine-specific fields
                switch viewModel.config.stt.engine {
                case "openai":
                    sttOpenAIFields
                case "whisper-local":
                    sttWhisperFields
                case "deepgram":
                    sttDeepgramFields
                case "azure":
                    sttAzureFields
                case "mistral":
                    sttMistralFields
                default:
                    EmptyView()
                }

                // STT Model
                Divider().padding(.leading, Spacing.md)
                inlineTextFieldRow(title: "STT Model", placeholder: "whisper-1", text: $viewModel.config.stt.model)

                // Supported MIME Types
                Divider().padding(.leading, Spacing.md)
                inlineTextFieldRow(
                    title: "Supported MIME Types",
                    placeholder: "audio/wav, audio/mpeg, ...",
                    text: Binding(
                        get: { viewModel.supportedMIMETypesString },
                        set: { viewModel.supportedMIMETypesString = $0 }
                    )
                )
            }
        }
    }

    // MARK: - STT OpenAI Fields

    private var sttOpenAIFields: some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "API Base URL", placeholder: "https://api.openai.com/v1", text: $viewModel.config.stt.openAIAPIBaseURL, keyboardType: .URL)

            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(
                title: "API Key",
                placeholder: "sk-...",
                text: $viewModel.config.stt.openAIAPIKey,
                isVisible: viewModel.showSTTOpenAIKey,
                onToggleVisibility: { viewModel.showSTTOpenAIKey.toggle() }
            )
        }
    }

    // MARK: - STT Whisper Fields

    private var sttWhisperFields: some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "Whisper Model", placeholder: "base", text: $viewModel.config.stt.whisperModel)
        }
    }

    // MARK: - STT Deepgram Fields

    private var sttDeepgramFields: some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(
                title: "Deepgram API Key",
                placeholder: "API Key",
                text: $viewModel.config.stt.deepgramAPIKey,
                isVisible: viewModel.showSTTDeepgramKey,
                onToggleVisibility: { viewModel.showSTTDeepgramKey.toggle() }
            )
        }
    }

    // MARK: - STT Azure Fields

    private var sttAzureFields: some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(
                title: "Azure API Key",
                placeholder: "API Key",
                text: $viewModel.config.stt.azureAPIKey,
                isVisible: viewModel.showSTTAzureKey,
                onToggleVisibility: { viewModel.showSTTAzureKey.toggle() }
            )

            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "Azure Region", placeholder: "eastus", text: $viewModel.config.stt.azureRegion)

            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "Azure Locales", placeholder: "en-US", text: $viewModel.config.stt.azureLocales)

            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "Azure Base URL", placeholder: "https://...", text: $viewModel.config.stt.azureBaseURL, keyboardType: .URL)

            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "Max Speakers", placeholder: "0", text: $viewModel.config.stt.azureMaxSpeakers, keyboardType: .numberPad)
        }
    }

    // MARK: - STT Mistral Fields

    private var sttMistralFields: some View {
        Group {
            Divider().padding(.leading, Spacing.md)
            inlineTextFieldRow(title: "API Base URL", placeholder: "https://api.mistral.ai/v1", text: $viewModel.config.stt.mistralAPIBaseURL, keyboardType: .URL)

            Divider().padding(.leading, Spacing.md)
            inlineSecureRow(
                title: "Mistral API Key",
                placeholder: "API Key",
                text: $viewModel.config.stt.mistralAPIKey,
                isVisible: viewModel.showSTTMistralKey,
                onToggleVisibility: { viewModel.showSTTMistralKey.toggle() }
            )

            Divider().padding(.leading, Spacing.md)
            inlineToggleRow(title: "Use Chat Completions", isOn: $viewModel.config.stt.mistralUseChatCompletions)
        }
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

    /// A field that shows as a text field for custom input, with a Menu picker
    /// when items are available — user can type a custom value OR pick from the list.
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
                    ForEach(availableItems, id: \.id) { item in
                        Button {
                            text.wrappedValue = item.id
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
