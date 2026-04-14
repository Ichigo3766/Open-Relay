import SwiftUI

// MARK: - Admin Web Search View

/// The admin "Web Search" tab — configure web search engines, loaders, and YouTube settings.
struct AdminWebSearchView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminWebSearchViewModel()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    generalSection
                    loaderSection
                    youtubeSection
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
                .padding(.vertical, 10)
                .background(
                    viewModel.success
                        ? Color.green
                        : theme.brandPrimary,
                    in: RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving)
            .animation(.easeInOut(duration: 0.2), value: viewModel.success)
        }
        .padding(.trailing, Spacing.screenPadding)
        .padding(.bottom, Spacing.lg)
    }

    // MARK: - General Section

    private var generalSection: some View {
        SettingsSection(header: "General") {
            inlineToggleRow(
                title: "Web Search",
                isOn: $viewModel.retrievalConfig.web.enableWebSearch,
                showDivider: true
            )

            inlinePickerRow(
                title: "Web Search Engine",
                selection: $viewModel.retrievalConfig.web.webSearchEngine,
                options: searchEngineOptions
            )

            // Engine-specific fields
            engineSpecificFields

            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Search Result Count")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                    TextField("3", value: $viewModel.retrievalConfig.web.searchResultCount, format: .number)
                        .scaledFont(size: 15)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Concurrent Requests")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                    TextField("10", value: $viewModel.retrievalConfig.web.searchConcurrentRequests, format: .number)
                        .scaledFont(size: 15)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            Divider().padding(.leading, Spacing.md)

            inlineTextFieldRow(
                title: "Fetch URL Content Length Limit",
                placeholder: "0",
                text: Binding(
                    get: { String(viewModel.retrievalConfig.web.fetchPageContentLengthLimit) },
                    set: { viewModel.retrievalConfig.web.fetchPageContentLengthLimit = Int($0) ?? 0 }
                ),
                keyboardType: .numberPad
            )

            inlineTextFieldRow(
                title: "Domain Filter List",
                placeholder: "e.g. example.com, docs.ai",
                text: $viewModel.domainFilterListString
            )

            inlineToggleRow(
                title: "Bypass Embedding and Retrieval",
                isOn: $viewModel.retrievalConfig.web.bypassEmbeddingAndRetrieval,
                showDivider: true
            )

            inlineToggleRow(
                title: "Bypass Web Loader",
                isOn: $viewModel.retrievalConfig.web.bypassWebLoader,
                showDivider: true
            )

            inlineToggleRow(
                title: "Trust Proxy Environment",
                isOn: $viewModel.retrievalConfig.web.trustProxyEnvironment,
                showDivider: false
            )
        }
        .padding(.horizontal, Spacing.sm)
    }

    // MARK: - Engine-Specific Fields

    @ViewBuilder
    private var engineSpecificFields: some View {
        let engine = viewModel.retrievalConfig.web.webSearchEngine

        switch engine {
        case "searxng":
            inlineTextFieldRow(title: "SearXNG Query URL", placeholder: "http://...", text: $viewModel.retrievalConfig.web.searxngQueryURL)
            inlineTextFieldRow(title: "Language", placeholder: "en", text: $viewModel.retrievalConfig.web.searxngLanguage)

        case "google_pse":
            inlineSecureRow(title: "API Key", placeholder: "Enter Google PSE API Key", text: $viewModel.retrievalConfig.web.googlePSEAPIKey, isVisible: viewModel.showGooglePSEKey) { viewModel.showGooglePSEKey.toggle() }
            inlineTextFieldRow(title: "Engine ID", placeholder: "Enter Engine ID", text: $viewModel.retrievalConfig.web.googlePSEEngineID)

        case "brave":
            inlineSecureRow(title: "API Key", placeholder: "Enter Brave API Key", text: $viewModel.retrievalConfig.web.braveSearchAPIKey, isVisible: viewModel.showBraveKey) { viewModel.showBraveKey.toggle() }

        case "kagi":
            inlineSecureRow(title: "API Key", placeholder: "Enter Kagi API Key", text: $viewModel.retrievalConfig.web.kagiSearchAPIKey, isVisible: viewModel.showKagiKey) { viewModel.showKagiKey.toggle() }

        case "mojeek":
            inlineSecureRow(title: "API Key", placeholder: "Enter Mojeek API Key", text: $viewModel.retrievalConfig.web.mojeekSearchAPIKey, isVisible: viewModel.showMojeekKey) { viewModel.showMojeekKey.toggle() }

        case "bocha":
            inlineSecureRow(title: "API Key", placeholder: "Enter Bocha API Key", text: $viewModel.retrievalConfig.web.bochaSearchAPIKey, isVisible: viewModel.showBochaKey) { viewModel.showBochaKey.toggle() }

        case "serpstack":
            inlineSecureRow(title: "API Key", placeholder: "Enter Serpstack API Key", text: $viewModel.retrievalConfig.web.serpstackAPIKey, isVisible: viewModel.showSerpstackKey) { viewModel.showSerpstackKey.toggle() }
            inlineToggleRow(title: "HTTPS", isOn: $viewModel.retrievalConfig.web.serpstackHTTPS, showDivider: true)

        case "serper":
            inlineSecureRow(title: "API Key", placeholder: "Enter Serper API Key", text: $viewModel.retrievalConfig.web.serperAPIKey, isVisible: viewModel.showSerperKey) { viewModel.showSerperKey.toggle() }

        case "serply":
            inlineSecureRow(title: "API Key", placeholder: "Enter Serply API Key", text: $viewModel.retrievalConfig.web.serplyAPIKey, isVisible: viewModel.showSerplyKey) { viewModel.showSerplyKey.toggle() }

        case "searchapi":
            inlineSecureRow(title: "API Key", placeholder: "Enter SearchAPI API Key", text: $viewModel.retrievalConfig.web.searchAPIAPIKey, isVisible: viewModel.showSearchAPIKey) { viewModel.showSearchAPIKey.toggle() }
            inlineTextFieldRow(title: "Engine", placeholder: "google", text: $viewModel.retrievalConfig.web.searchAPIEngine)

        case "serpapi":
            inlineSecureRow(title: "API Key", placeholder: "Enter SerpAPI API Key", text: $viewModel.retrievalConfig.web.serpAPIAPIKey, isVisible: viewModel.showSerpAPIKey) { viewModel.showSerpAPIKey.toggle() }
            inlineTextFieldRow(title: "Engine", placeholder: "google", text: $viewModel.retrievalConfig.web.serpAPIEngine)

        case "tavily":
            inlineSecureRow(title: "API Key", placeholder: "Enter Tavily API Key", text: $viewModel.retrievalConfig.web.tavilyAPIKey, isVisible: viewModel.showTavilyKey) { viewModel.showTavilyKey.toggle() }
            inlineTextFieldRow(title: "Extract Depth", placeholder: "basic", text: $viewModel.retrievalConfig.web.tavilyExtractDepth)

        case "jina":
            inlineSecureRow(title: "API Key", placeholder: "Enter Jina API Key", text: $viewModel.retrievalConfig.web.jinaAPIKey, isVisible: viewModel.showJinaKey) { viewModel.showJinaKey.toggle() }

        case "bing":
            inlineSecureRow(title: "Subscription Key", placeholder: "Enter Bing Subscription Key", text: $viewModel.retrievalConfig.web.bingSearchV7SubscriptionKey, isVisible: viewModel.showBingKey) { viewModel.showBingKey.toggle() }
            inlineTextFieldRow(title: "Endpoint", placeholder: "https://api.bing.microsoft.com/v7.0/search", text: $viewModel.retrievalConfig.web.bingSearchV7Endpoint)
            inlineTextFieldRow(title: "Region", placeholder: "en-US", text: $viewModel.retrievalConfig.web.bingSearchV7Region)

        case "exa":
            inlineSecureRow(title: "API Key", placeholder: "Enter Exa API Key", text: $viewModel.retrievalConfig.web.exaAPIKey, isVisible: viewModel.showExaKey) { viewModel.showExaKey.toggle() }

        case "perplexity":
            inlineSecureRow(title: "API Key", placeholder: "Enter Perplexity API Key", text: $viewModel.retrievalConfig.web.perplexityAPIKey, isVisible: viewModel.showPerplexityKey) { viewModel.showPerplexityKey.toggle() }

        case "sougou":
            inlineSecureRow(title: "API SID", placeholder: "Enter Sougou API SID", text: $viewModel.retrievalConfig.web.sougouAPISID, isVisible: viewModel.showSougouSID) { viewModel.showSougouSID.toggle() }
            inlineSecureRow(title: "API SK", placeholder: "Enter Sougou API SK", text: $viewModel.retrievalConfig.web.sougouAPISK, isVisible: viewModel.showSougouSK) { viewModel.showSougouSK.toggle() }

        case "firecrawl":
            inlineSecureRow(title: "API Key", placeholder: "Enter Firecrawl API Key", text: $viewModel.retrievalConfig.web.firecrawlAPIKey, isVisible: viewModel.showFirecrawlKey) { viewModel.showFirecrawlKey.toggle() }
            inlineTextFieldRow(title: "API Base URL", placeholder: "https://api.firecrawl.dev", text: $viewModel.retrievalConfig.web.firecrawlAPIBaseURL)

        case "external":
            inlineTextFieldRow(title: "External Search URL", placeholder: "http://...", text: $viewModel.retrievalConfig.web.externalSearchURL)
            inlineSecureRow(title: "API Key", placeholder: "Enter External Search API Key", text: $viewModel.retrievalConfig.web.externalSearchAPIKey, isVisible: viewModel.showExternalSearchKey) { viewModel.showExternalSearchKey.toggle() }

        case "yandex":
            inlineSecureRow(title: "API Key", placeholder: "Enter Yandex API Key", text: $viewModel.retrievalConfig.web.yandexSearchAPIKey, isVisible: viewModel.showYandexKey) { viewModel.showYandexKey.toggle() }
            inlineTextFieldRow(title: "Folder ID", placeholder: "Enter Folder ID", text: $viewModel.retrievalConfig.web.yandexSearchFolderID)
            inlineTextFieldRow(title: "Language", placeholder: "en", text: $viewModel.retrievalConfig.web.yandexSearchLang)

        case "youcom":
            inlineSecureRow(title: "API Key", placeholder: "Enter You.com API Key", text: $viewModel.retrievalConfig.web.youSearchAPIKey, isVisible: viewModel.showYouKey) { viewModel.showYouKey.toggle() }

        case "ollama_cloud":
            inlineSecureRow(title: "API Key", placeholder: "Enter Ollama Cloud API Key", text: $viewModel.retrievalConfig.web.ollamaCloudAPIKey, isVisible: viewModel.showOllamaCloudKey) { viewModel.showOllamaCloudKey.toggle() }
            inlineTextFieldRow(title: "API URL", placeholder: "http://...", text: $viewModel.retrievalConfig.web.ollamaCloudAPIURL)
            inlineTextFieldRow(title: "Model", placeholder: "Enter Model", text: $viewModel.retrievalConfig.web.ollamaCloudModel)

        case "perplexity_search":
            inlineSecureRow(title: "API Key", placeholder: "Enter Perplexity Search API Key", text: $viewModel.retrievalConfig.web.perplexitySearchAPIKey, isVisible: viewModel.showPerplexitySearchKey) { viewModel.showPerplexitySearchKey.toggle() }
            inlineTextFieldRow(title: "API URL", placeholder: "http://...", text: $viewModel.retrievalConfig.web.perplexitySearchAPIURL)
            inlineTextFieldRow(title: "Model", placeholder: "Enter Model", text: $viewModel.retrievalConfig.web.perplexitySearchModel)

        case "DDGS":
            inlineTextFieldRow(title: "Proxy", placeholder: "http://...", text: $viewModel.retrievalConfig.web.ddgsProxy)

        default:
            EmptyView()
        }
    }

    // MARK: - Loader Section

    private var loaderSection: some View {
        SettingsSection(header: "Loader") {
            inlinePickerRow(
                title: "Web Loader Engine",
                selection: $viewModel.retrievalConfig.web.webLoaderEngine,
                options: [
                    (value: "", label: "Default"),
                    (value: "playwright", label: "Playwright"),
                    (value: "firecrawl", label: "Firecrawl"),
                    (value: "tavily", label: "Tavily"),
                    (value: "external", label: "External"),
                ]
            )

            // Loader-engine-specific fields
            loaderEngineSpecificFields

            inlineTextFieldRow(
                title: "Timeout",
                placeholder: "15",
                text: Binding(
                    get: { String(viewModel.retrievalConfig.web.webLoaderTimeout) },
                    set: { viewModel.retrievalConfig.web.webLoaderTimeout = Int($0) ?? 15 }
                ),
                keyboardType: .numberPad
            )

            inlineToggleRow(
                title: "Verify SSL Certificate",
                isOn: $viewModel.retrievalConfig.web.webLoaderVerifySSL,
                showDivider: true
            )

            inlineTextFieldRow(
                title: "Concurrent Requests",
                placeholder: "10",
                text: Binding(
                    get: { String(viewModel.retrievalConfig.web.webLoaderConcurrentRequests) },
                    set: { viewModel.retrievalConfig.web.webLoaderConcurrentRequests = Int($0) ?? 10 }
                ),
                keyboardType: .numberPad,
                showDivider: false
            )
        }
        .padding(.horizontal, Spacing.sm)
    }

    @ViewBuilder
    private var loaderEngineSpecificFields: some View {
        let engine = viewModel.retrievalConfig.web.webLoaderEngine

        switch engine {
        case "playwright":
            inlineTextFieldRow(title: "WebSocket URL", placeholder: "ws://...", text: $viewModel.retrievalConfig.web.playwrightWSURL)
            inlineTextFieldRow(
                title: "Timeout (ms)",
                placeholder: "60000",
                text: Binding(
                    get: { String(viewModel.retrievalConfig.web.playwrightTimeout) },
                    set: { viewModel.retrievalConfig.web.playwrightTimeout = Int($0) ?? 60000 }
                ),
                keyboardType: .numberPad
            )

        case "firecrawl":
            inlineSecureRow(title: "API Key", placeholder: "Enter Firecrawl Loader API Key", text: $viewModel.retrievalConfig.web.firecrawlLoaderAPIKey, isVisible: viewModel.showFirecrawlLoaderKey) { viewModel.showFirecrawlLoaderKey.toggle() }
            inlineTextFieldRow(title: "API Base URL", placeholder: "https://api.firecrawl.dev", text: $viewModel.retrievalConfig.web.firecrawlLoaderAPIBaseURL)
            inlineTextFieldRow(
                title: "Timeout (ms)",
                placeholder: "60000",
                text: Binding(
                    get: { String(viewModel.retrievalConfig.web.firecrawlLoaderTimeout) },
                    set: { viewModel.retrievalConfig.web.firecrawlLoaderTimeout = Int($0) ?? 60000 }
                ),
                keyboardType: .numberPad
            )

        case "tavily":
            inlineSecureRow(title: "API Key", placeholder: "Enter Tavily Loader API Key", text: $viewModel.retrievalConfig.web.tavilyLoaderAPIKey, isVisible: viewModel.showTavilyLoaderKey) { viewModel.showTavilyLoaderKey.toggle() }
            inlineTextFieldRow(title: "Extract Depth", placeholder: "basic", text: $viewModel.retrievalConfig.web.tavilyLoaderExtractDepth)

        case "external":
            inlineTextFieldRow(title: "External Loader URL", placeholder: "http://...", text: $viewModel.retrievalConfig.web.externalLoaderURL)
            inlineSecureRow(title: "API Key", placeholder: "Enter External Loader API Key", text: $viewModel.retrievalConfig.web.externalLoaderAPIKey, isVisible: viewModel.showExternalLoaderKey) { viewModel.showExternalLoaderKey.toggle() }

        default:
            EmptyView()
        }
    }

    // MARK: - YouTube Section

    private var youtubeSection: some View {
        SettingsSection(header: "YouTube") {
            inlineTextFieldRow(
                title: "Youtube Language",
                placeholder: "en",
                text: $viewModel.retrievalConfig.web.youtubeLanguage
            )

            inlineTextFieldRow(
                title: "Youtube Proxy URL",
                placeholder: "http://...",
                text: $viewModel.retrievalConfig.web.youtubeProxyURL,
                showDivider: false
            )
        }
        .padding(.horizontal, Spacing.sm)
    }

    // MARK: - Search Engine Options

    private var searchEngineOptions: [(value: String, label: String)] {
        [
            (value: "", label: "None"),
            (value: "ollama_cloud", label: "Ollama Cloud"),
            (value: "perplexity_search", label: "Perplexity Search"),
            (value: "searxng", label: "SearXNG"),
            (value: "yacy", label: "YaCy"),
            (value: "google_pse", label: "Google PSE"),
            (value: "brave", label: "Brave"),
            (value: "kagi", label: "Kagi"),
            (value: "mojeek", label: "Mojeek"),
            (value: "bocha", label: "Bocha"),
            (value: "serpstack", label: "Serpstack"),
            (value: "serper", label: "Serper"),
            (value: "serply", label: "Serply"),
            (value: "searchapi", label: "SearchAPI"),
            (value: "serpapi", label: "SerpAPI"),
            (value: "DDGS", label: "DDGS"),
            (value: "tavily", label: "Tavily"),
            (value: "jina", label: "Jina"),
            (value: "bing", label: "Bing"),
            (value: "exa", label: "Exa"),
            (value: "perplexity", label: "Perplexity"),
            (value: "sougou", label: "Sougou"),
            (value: "firecrawl", label: "Firecrawl"),
            (value: "external", label: "External"),
            (value: "yandex", label: "Yandex"),
            (value: "youcom", label: "You.com"),
        ]
    }

    // MARK: - Row Builders

    private func inlineToggleRow(
        title: String,
        isOn: Binding<Bool>,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
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
