import SwiftUI

// MARK: - Admin Documents View

/// The admin "Documents" tab — configure document extraction, text splitting, embedding, retrieval, files, and integrations.
struct AdminDocumentsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminDocumentsViewModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    generalSection
                    if !viewModel.retrievalConfig.bypassEmbeddingAndRetrieval {
                        textSplittingSection
                        embeddingSection
                        retrievalSection
                    }
                    filesSection
                    integrationSection
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

    // MARK: - General Section

    private var generalSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "doc.text", title: "General")

            if viewModel.isLoading {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlinePickerRow(
                        title: "Content Extraction Engine",
                        selection: $viewModel.retrievalConfig.contentExtractionEngine,
                        options: [
                            ("", "Default"),
                            ("external", "External"),
                            ("tika", "Tika"),
                            ("docling", "Docling"),
                            ("datalab_marker", "Datalab Marker API"),
                            ("document_intelligence", "Document Intelligence"),
                            ("mistral_ocr", "Mistral OCR"),
                            ("mineru", "MinerU")
                        ]
                    )

                    // Conditional engine-specific fields
                    let engine = viewModel.retrievalConfig.contentExtractionEngine

                    if engine == "external" {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "External Loader URL", placeholder: "http://...", text: $viewModel.retrievalConfig.externalDocumentLoaderURL, keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineSecureRow(title: "External Loader API Key", placeholder: "API Key", text: $viewModel.retrievalConfig.externalDocumentLoaderAPIKey, isVisible: viewModel.showExternalDocLoaderKey, onToggleVisibility: { viewModel.showExternalDocLoaderKey.toggle() })
                    }

                    if engine == "tika" {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Tika Server URL", placeholder: "http://tika:9998", text: $viewModel.retrievalConfig.tikaServerURL, keyboardType: .URL)
                    }

                    if engine == "docling" {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Docling Server URL", placeholder: "http://host.docker.internal:5001", text: $viewModel.retrievalConfig.doclingServerURL, keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineSecureRow(title: "Docling API Key", placeholder: "API Key", text: $viewModel.retrievalConfig.doclingAPIKey, isVisible: viewModel.showDoclingAPIKey, onToggleVisibility: { viewModel.showDoclingAPIKey.toggle() })
                        Divider().padding(.leading, Spacing.md)
                        inlineTextAreaRow(title: "Parameters", placeholder: "{}", text: $viewModel.retrievalConfig.doclingParams)
                    }

                    if engine == "datalab_marker" {
                        Divider().padding(.leading, Spacing.md)
                        inlineSecureRow(title: "Datalab Marker API Key", placeholder: "API Key", text: $viewModel.retrievalConfig.datalabMarkerAPIKey, isVisible: viewModel.showDatalabMarkerAPIKey, onToggleVisibility: { viewModel.showDatalabMarkerAPIKey.toggle() })
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Base URL", placeholder: "https://...", text: $viewModel.retrievalConfig.datalabMarkerAPIBaseURL, keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Additional Config", placeholder: "", text: $viewModel.retrievalConfig.datalabMarkerAdditionalConfig)
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Skip Cache", isOn: $viewModel.retrievalConfig.datalabMarkerSkipCache)
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Force OCR", isOn: $viewModel.retrievalConfig.datalabMarkerForceOCR)
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Paginate", isOn: $viewModel.retrievalConfig.datalabMarkerPaginate)
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Strip Existing OCR", isOn: $viewModel.retrievalConfig.datalabMarkerStripExistingOCR)
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Disable Image Extraction", isOn: $viewModel.retrievalConfig.datalabMarkerDisableImageExtraction)
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Format Lines", isOn: $viewModel.retrievalConfig.datalabMarkerFormatLines)
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Use LLM", isOn: $viewModel.retrievalConfig.datalabMarkerUseLLM)
                        Divider().padding(.leading, Spacing.md)
                        inlinePickerRow(title: "Output Format", selection: $viewModel.retrievalConfig.datalabMarkerOutputFormat, options: [
                            ("markdown", "Markdown"),
                            ("json", "JSON"),
                            ("html", "HTML")
                        ])
                    }

                    if engine == "document_intelligence" {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Endpoint", placeholder: "https://...", text: $viewModel.retrievalConfig.documentIntelligenceEndpoint, keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineSecureRow(title: "Key", placeholder: "API Key", text: $viewModel.retrievalConfig.documentIntelligenceKey, isVisible: viewModel.showDocIntelligenceKey, onToggleVisibility: { viewModel.showDocIntelligenceKey.toggle() })
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Model", placeholder: "prebuilt-layout", text: $viewModel.retrievalConfig.documentIntelligenceModel)
                    }

                    if engine == "mistral_ocr" {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "API Base URL", placeholder: "https://api.mistral.ai/v1", text: $viewModel.retrievalConfig.mistralOCRAPIBaseURL, keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineSecureRow(title: "API Key", placeholder: "API Key", text: $viewModel.retrievalConfig.mistralOCRAPIKey, isVisible: viewModel.showMistralOCRKey, onToggleVisibility: { viewModel.showMistralOCRKey.toggle() })
                    }

                    if engine == "mineru" {
                        Divider().padding(.leading, Spacing.md)
                        inlinePickerRow(title: "API Mode", selection: $viewModel.retrievalConfig.mineruAPIMode, options: [
                            ("local", "Local"),
                            ("api", "API")
                        ])
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "API URL", placeholder: "http://localhost:8000", text: $viewModel.retrievalConfig.mineruAPIURL, keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineSecureRow(title: "API Key", placeholder: "API Key", text: $viewModel.retrievalConfig.mineruAPIKey, isVisible: viewModel.showMineruAPIKey, onToggleVisibility: { viewModel.showMineruAPIKey.toggle() })
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Timeout (seconds)", placeholder: "300", text: $viewModel.retrievalConfig.mineruAPITimeout, keyboardType: .numberPad)
                        Divider().padding(.leading, Spacing.md)
                        inlineTextAreaRow(title: "Parameters", placeholder: "{}", text: $viewModel.retrievalConfig.mineruParams)
                    }

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(title: "PDF Extract Images (OCR)", isOn: $viewModel.retrievalConfig.pdfExtractImages)

                    Divider().padding(.leading, Spacing.md)

                    inlinePickerRow(
                        title: "PDF Loader Mode",
                        selection: $viewModel.retrievalConfig.pdfLoaderMode,
                        options: [
                            ("single", "Single"),
                            ("page", "Page")
                        ]
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Bypass Embedding and Retrieval",
                        isOn: $viewModel.retrievalConfig.bypassEmbeddingAndRetrieval,
                        showDivider: false
                    )
                }
            }
        }
    }

    // MARK: - Text Splitting Section

    private var textSplittingSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "scissors", title: "Text Splitting")

            if viewModel.isLoading {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlinePickerRow(
                        title: "Text Splitter",
                        selection: $viewModel.retrievalConfig.textSplitter,
                        options: [
                            ("", "Default (Character)"),
                            ("token", "Token (Tiktoken)")
                        ]
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Markdown Header Text Splitter",
                        isOn: $viewModel.retrievalConfig.enableMarkdownHeaderTextSplitter
                    )

                    Divider().padding(.leading, Spacing.md)

                    HStack(spacing: Spacing.md) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Chunk Size")
                                .scaledFont(size: 14, weight: .medium)
                                .foregroundStyle(theme.textSecondary)
                            TextField("1024", text: Binding(
                                get: { String(viewModel.retrievalConfig.chunkSize) },
                                set: { viewModel.retrievalConfig.chunkSize = Int($0) ?? 1024 }
                            ))
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                        }

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Chunk Overlap")
                                .scaledFont(size: 14, weight: .medium)
                                .foregroundStyle(theme.textSecondary)
                            TextField("200", text: Binding(
                                get: { String(viewModel.retrievalConfig.chunkOverlap) },
                                set: { viewModel.retrievalConfig.chunkOverlap = Int($0) ?? 200 }
                            ))
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.chatBubblePadding)

                    if viewModel.retrievalConfig.enableMarkdownHeaderTextSplitter {
                        Divider().padding(.leading, Spacing.md)

                        inlineTextFieldRow(
                            title: "Chunk Min Size Target",
                            placeholder: "0",
                            text: Binding(
                                get: { String(viewModel.retrievalConfig.chunkMinSizeTarget) },
                                set: { viewModel.retrievalConfig.chunkMinSizeTarget = Int($0) ?? 0 }
                            ),
                            keyboardType: .numberPad,
                            showDivider: false
                        )
                    }
                }
            }
        }
    }

    // MARK: - Embedding Section

    private var embeddingSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "cube", title: "Embedding")

            if viewModel.isLoading {
                sectionLoadingView()
            } else {
                SettingsSection(footer: "After updating or changing the embedding model, you must reindex the knowledge base for the changes to take effect.") {
                    inlinePickerRow(
                        title: "Embedding Model Engine",
                        selection: $viewModel.embeddingConfig.ragEmbeddingEngine,
                        options: [
                            ("", "Default"),
                            ("openai", "OpenAI"),
                            ("ollama", "Ollama"),
                            ("azure_openai", "Azure OpenAI")
                        ]
                    )

                    let embEngine = viewModel.embeddingConfig.ragEmbeddingEngine

                    if embEngine == "openai" {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "API URL", placeholder: "http://...", text: $viewModel.embeddingConfig.openaiConfig.url, keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineSecureRow(title: "API Key", placeholder: "API Key", text: $viewModel.embeddingConfig.openaiConfig.key, isVisible: viewModel.showOpenAIEmbeddingKey, onToggleVisibility: { viewModel.showOpenAIEmbeddingKey.toggle() })
                    }

                    if embEngine == "ollama" {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "API URL", placeholder: "http://host.docker.internal:11434", text: $viewModel.embeddingConfig.ollamaConfig.url, keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineSecureRow(title: "API Key", placeholder: "API Key", text: $viewModel.embeddingConfig.ollamaConfig.key, isVisible: viewModel.showOllamaEmbeddingKey, onToggleVisibility: { viewModel.showOllamaEmbeddingKey.toggle() })
                    }

                    if embEngine == "azure_openai" {
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "API URL", placeholder: "https://...", text: $viewModel.embeddingConfig.azureOpenAIConfig.url, keyboardType: .URL)
                        Divider().padding(.leading, Spacing.md)
                        inlineSecureRow(title: "API Key", placeholder: "API Key", text: $viewModel.embeddingConfig.azureOpenAIConfig.key, isVisible: viewModel.showAzureEmbeddingKey, onToggleVisibility: { viewModel.showAzureEmbeddingKey.toggle() })
                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "API Version", placeholder: "", text: $viewModel.embeddingConfig.azureOpenAIConfig.version)
                    }

                    Divider().padding(.leading, Spacing.md)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Embedding Model")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                        TextField("Model name", text: $viewModel.embeddingConfig.ragEmbeddingModel)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.chatBubblePadding)

                    Divider().padding(.leading, Spacing.md)

                    inlineTextFieldRow(
                        title: "Embedding Batch Size",
                        placeholder: "64",
                        text: Binding(
                            get: { String(viewModel.embeddingConfig.ragEmbeddingBatchSize) },
                            set: { viewModel.embeddingConfig.ragEmbeddingBatchSize = Int($0) ?? 64 }
                        ),
                        keyboardType: .numberPad
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineToggleRow(
                        title: "Async Embedding Processing",
                        isOn: $viewModel.embeddingConfig.enableAsyncEmbedding
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineTextFieldRow(
                        title: "Embedding Concurrent Requests",
                        placeholder: "0",
                        text: Binding(
                            get: { String(viewModel.embeddingConfig.ragEmbeddingConcurrentRequests) },
                            set: { viewModel.embeddingConfig.ragEmbeddingConcurrentRequests = Int($0) ?? 0 }
                        ),
                        keyboardType: .numberPad,
                        showDivider: false
                    )
                }
            }
        }
    }

    // MARK: - Retrieval Section

    private var retrievalSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "magnifyingglass.circle", title: "Retrieval")

            if viewModel.isLoading {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineToggleRow(title: "Full Context Mode", isOn: $viewModel.retrievalConfig.ragFullContext)

                    if !viewModel.retrievalConfig.ragFullContext {
                        Divider().padding(.leading, Spacing.md)

                        inlineToggleRow(title: "Hybrid Search", isOn: $viewModel.retrievalConfig.enableRagHybridSearch)

                        if viewModel.retrievalConfig.enableRagHybridSearch {
                        Divider().padding(.leading, Spacing.md)
                        inlineToggleRow(title: "Enrich Hybrid Search Text", isOn: $viewModel.retrievalConfig.enableRagHybridSearchEnrichedTexts)

                        Divider().padding(.leading, Spacing.md)
                        inlinePickerRow(
                            title: "Reranking Engine",
                            selection: $viewModel.retrievalConfig.ragRerankingEngine,
                            options: [
                                ("", "Default"),
                                ("external", "External")
                            ]
                        )

                        if viewModel.retrievalConfig.ragRerankingEngine == "external" {
                            Divider().padding(.leading, Spacing.md)
                            // API Base URL + API Key on same row (matches web UI)
                            HStack(spacing: Spacing.sm) {
                                TextField("API Base URL", text: $viewModel.retrievalConfig.ragExternalRerankerURL)
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textPrimary)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                Group {
                                    if viewModel.showRerankingAPIKey {
                                        TextField("API Key", text: $viewModel.retrievalConfig.ragExternalRerankerAPIKey)
                                    } else {
                                        SecureField("API Key", text: $viewModel.retrievalConfig.ragExternalRerankerAPIKey)
                                    }
                                }
                                .scaledFont(size: 15)
                                .foregroundStyle(theme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                                Button {
                                    viewModel.showRerankingAPIKey.toggle()
                                } label: {
                                    Image(systemName: viewModel.showRerankingAPIKey ? "eye.slash" : "eye")
                                        .scaledFont(size: 14)
                                        .foregroundStyle(theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.chatBubblePadding)
                        }

                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(title: "Reranking Model", placeholder: "Set reranking model (e.g. BAAI/bge-reranker-v2-m3)", text: $viewModel.retrievalConfig.ragRerankingModel)

                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(
                            title: "Top K",
                            placeholder: "10",
                            text: Binding(
                                get: { String(viewModel.retrievalConfig.topK) },
                                set: { viewModel.retrievalConfig.topK = Int($0) ?? 10 }
                            ),
                            keyboardType: .numberPad
                        )

                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(
                            title: "Top K Reranker",
                            placeholder: "5",
                            text: Binding(
                                get: { String(viewModel.retrievalConfig.topKReranker) },
                                set: { viewModel.retrievalConfig.topKReranker = Int($0) ?? 5 }
                            ),
                            keyboardType: .numberPad
                        )

                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(
                            title: "Relevance Threshold",
                            placeholder: "0.0",
                            subtitle: "If you set a minimum score, the search will only return documents with a score greater than or equal to the minimum score.",
                            text: Binding(
                                get: { String(viewModel.retrievalConfig.relevanceThreshold) },
                                set: { viewModel.retrievalConfig.relevanceThreshold = Double($0) ?? 0.0 }
                            ),
                            keyboardType: .decimalPad
                        )

                        Divider().padding(.leading, Spacing.md)
                        inlineTextFieldRow(
                            title: "BM25 Weight",
                            placeholder: "0.5",
                            subtitle: "0 = fully semantic, 1 = fully lexical",
                            text: Binding(
                                get: { String(viewModel.retrievalConfig.hybridBM25Weight) },
                                set: { viewModel.retrievalConfig.hybridBM25Weight = Double($0) ?? 0.5 }
                            ),
                            keyboardType: .decimalPad
                        )
                        }
                    }

                    Divider().padding(.leading, Spacing.md)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("RAG Template")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                        TextField("Template…", text: $viewModel.retrievalConfig.ragTemplate, axis: .vertical)
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(4...12)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.chatBubblePadding)
                }
            }
        }
    }

    // MARK: - Files Section

    private var filesSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "folder", title: "Files")

            if viewModel.isLoading {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineTextFieldRow(
                        title: "Allowed File Extensions",
                        placeholder: "e.g. pdf, docx, txt",
                        text: $viewModel.allowedFileExtensionsString
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineTextFieldRow(
                        title: "Max Upload Size",
                        placeholder: "Leave empty for unlimited",
                        text: $viewModel.fileMaxSizeString,
                        keyboardType: .numberPad
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineTextFieldRow(
                        title: "Max Upload Count",
                        placeholder: "Leave empty for unlimited",
                        text: $viewModel.fileMaxCountString,
                        keyboardType: .numberPad
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineTextFieldRow(
                        title: "Image Compression Width",
                        placeholder: "Leave empty for no compression",
                        text: $viewModel.fileImageCompressionWidthString,
                        keyboardType: .numberPad
                    )

                    Divider().padding(.leading, Spacing.md)

                    inlineTextFieldRow(
                        title: "Image Compression Height",
                        placeholder: "Leave empty for no compression",
                        text: $viewModel.fileImageCompressionHeightString,
                        keyboardType: .numberPad,
                        showDivider: false
                    )
                }
            }
        }
    }

    // MARK: - Integration Section

    private var integrationSection: some View {
        VStack(spacing: Spacing.sm) {
            sectionHeader(icon: "link.circle", title: "Integration")

            if viewModel.isLoading {
                sectionLoadingView()
            } else {
                SettingsSection {
                    inlineToggleRow(title: "Google Drive", isOn: $viewModel.retrievalConfig.enableGoogleDriveIntegration)
                    Divider().padding(.leading, Spacing.md)
                    inlineToggleRow(title: "OneDrive", isOn: $viewModel.retrievalConfig.enableOneDriveIntegration, showDivider: false)
                }
            }
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
    }

    private func inlineToggleRow(
        title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
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

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlineTextFieldRow(
        title: String,
        placeholder: String,
        subtitle: String? = nil,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
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

                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
    }

    private func inlineTextAreaRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textSecondary)

                TextField(placeholder, text: text, axis: .vertical)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider().padding(.leading, Spacing.md)
            }
        }
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
                .layoutPriority(1)

            Spacer(minLength: Spacing.xs)

            Menu {
                ForEach(options, id: \.value) { option in
                    Button {
                        selection.wrappedValue = option.value
                    } label: {
                        if selection.wrappedValue == option.value {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options.first(where: { $0.value == selection.wrappedValue })?.label ?? "")
                        .scaledFont(size: 15)
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
