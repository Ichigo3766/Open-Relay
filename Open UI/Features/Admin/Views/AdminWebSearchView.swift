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

    // MARK: - Field Spec

    /// One editable server key. Mirrors the fields `WebSearch.svelte` renders.
    private enum FieldKind { case text, secure, int, numericString, toggle, list, picker([(String, String)]) }
    private struct Field { let key: String; let title: String; let placeholder: String; let kind: FieldKind }

    private func f(_ key: String, _ title: String, _ placeholder: String = "", _ kind: FieldKind = .text) -> Field {
        Field(key: key, title: title, placeholder: placeholder, kind: kind)
    }

    /// Engine-specific fields — exact keys and grouping from the web UI.
    private func engineFields(_ engine: String) -> [Field] {
        switch engine {
        case "ollama_cloud": return [f("OLLAMA_CLOUD_WEB_SEARCH_API_KEY", "Ollama Cloud API Key", "Enter Ollama Cloud API Key", .secure)]
        case "perplexity_search": return [
            f("PERPLEXITY_SEARCH_API_URL", "Perplexity Search API URL", "https://api.perplexity.ai/search"),
            f("PERPLEXITY_API_KEY", "Perplexity API Key", "Enter Perplexity API Key", .secure)]
        case "searxng": return [
            f("SEARXNG_QUERY_URL", "SearXNG Query URL", "Enter Searxng Query URL"),
            f("SEARXNG_LANGUAGE", "Search Language", "all, en, es, de, fr…")]
        case "yacy": return [
            f("YACY_QUERY_URL", "YaCy Instance URL", "http://yacy.example.com:8090"),
            f("YACY_USERNAME", "YaCy Username", "Enter Yacy Username"),
            f("YACY_PASSWORD", "YaCy Password", "Enter Yacy Password", .secure)]
        case "google_pse": return [
            f("GOOGLE_PSE_API_KEY", "Google PSE API Key", "Enter Google PSE API Key", .secure),
            f("GOOGLE_PSE_ENGINE_ID", "Google PSE Engine ID", "Enter Google PSE Engine Id")]
        case "brave": return [f("BRAVE_SEARCH_API_KEY", "Brave Search API Key", "Enter Brave Search API Key", .secure)]
        case "brave_llm_context": return [
            f("BRAVE_SEARCH_API_KEY", "Brave Search API Key", "Enter Brave Search API Key", .secure),
            f("BRAVE_SEARCH_CONTEXT_TOKENS", "Context Tokens", "1024–32768 (default 8192)", .int)]
        case "kagi": return [f("KAGI_SEARCH_API_KEY", "Kagi Search API Key", "Enter Kagi Search API Key", .secure)]
        case "mojeek": return [f("MOJEEK_SEARCH_API_KEY", "Mojeek Search API Key", "Enter Mojeek Search API Key", .secure)]
        case "bocha": return [f("BOCHA_SEARCH_API_KEY", "Bocha Search API Key", "Enter Bocha Search API Key", .secure)]
        case "serpstack": return [
            f("SERPSTACK_API_KEY", "Serpstack API Key", "Enter Serpstack API Key", .secure),
            f("SERPSTACK_HTTPS", "Use HTTPS", "", .toggle)]
        case "serper": return [f("SERPER_API_KEY", "Serper API Key", "Enter Serper API Key", .secure)]
        case "serphouse": return [
            f("SERPHOUSE_API_KEY", "SERPHouse API Key", "Enter SERPHouse API Key", .secure),
            f("SERPHOUSE_DOMAIN", "SERPHouse Domain", "google.com")]
        case "serply": return [f("SERPLY_API_KEY", "Serply API Key", "Enter Serply API Key", .secure)]
        case "tavily": return [f("TAVILY_API_KEY", "Tavily API Key", "Enter Tavily API Key", .secure)]
        case "staan": return [
            f("STAAN_API_KEY", "Staan API Key", "Enter Staan API Key", .secure),
            f("STAAN_MARKET", "Market", "e.g. en-us"),
            f("STAAN_MAX_SNIPPETS", "Max Snippets", "0", .int)]
        case "searchapi": return [
            f("SEARCHAPI_API_KEY", "SearchApi API Key", "Enter SearchApi API Key", .secure),
            f("SEARCHAPI_ENGINE", "SearchApi Engine", "Enter SearchApi Engine")]
        case "serpapi": return [
            f("SERPAPI_API_KEY", "SerpApi API Key", "Enter SerpApi API Key", .secure),
            f("SERPAPI_ENGINE", "SerpApi Engine", "Enter SerpApi Engine")]
        case "jina": return [
            f("JINA_API_BASE_URL", "Jina API Base URL", "Enter Jina API Base URL"),
            f("JINA_API_KEY", "Jina API Key", "Enter Jina API Key", .secure)]
        case "bing": return [
            f("BING_SEARCH_V7_ENDPOINT", "Bing Search V7 Endpoint", "Enter Bing Search V7 Endpoint"),
            f("BING_SEARCH_V7_SUBSCRIPTION_KEY", "Bing Search V7 Subscription Key", "Enter Subscription Key", .secure)]
        case "exa": return [
            f("EXA_API_KEY", "Exa API Key", "Enter Exa API Key", .secure),
            f("EXA_MAX_CONTENT_LENGTH", "Max Content Length", "No limit", .int)]
        case "perplexity": return [
            f("PERPLEXITY_API_KEY", "Perplexity API Key", "Enter Perplexity API Key", .secure),
            f("PERPLEXITY_MODEL", "Perplexity Model", "", .picker([
                ("sonar", "Sonar"), ("sonar-pro", "Sonar Pro"), ("sonar-reasoning", "Sonar Reasoning"),
                ("sonar-reasoning-pro", "Sonar Reasoning Pro"), ("sonar-deep-research", "Sonar Deep Research")])),
            f("PERPLEXITY_SEARCH_CONTEXT_USAGE", "Search Context Usage", "", .picker([
                ("low", "Low"), ("medium", "Medium"), ("high", "High")]))]
        case "microsoft_web_iq": return microsoftWebIQFields
        case "sougou": return [
            f("SOUGOU_API_SID", "Sougou Search API sID", "Enter Sougou Search API sID", .secure),
            f("SOUGOU_API_SK", "Sougou Search API SK", "Enter Sougou Search API SK", .secure)]
        case "firecrawl": return [
            f("FIRECRAWL_API_BASE_URL", "Firecrawl API Base URL", "https://api.firecrawl.dev"),
            f("FIRECRAWL_API_KEY", "Firecrawl API Key", "Enter Firecrawl API Key", .secure),
            f("FIRECRAWL_TIMEOUT", "Firecrawl Timeout (s)", "Enter Firecrawl Timeout", .numericString)]
        case "external": return [
            f("EXTERNAL_WEB_SEARCH_URL", "External Web Search URL", "Enter External Web Search URL"),
            f("EXTERNAL_WEB_SEARCH_API_KEY", "External Web Search API Key", "Enter External Web Search API Key", .secure)]
        case "yandex": return [
            f("YANDEX_WEB_SEARCH_URL", "Yandex Web Search URL", "Enter Yandex Web Search URL"),
            f("YANDEX_WEB_SEARCH_API_KEY", "Yandex Web Search API Key", "Enter Yandex Web Search API Key", .secure),
            f("YANDEX_WEB_SEARCH_CONFIG", "Yandex Web Search Config", "JSON config")]
        case "youcom": return [f("YOUCOM_API_KEY", "You.com API Key", "Enter You.com API Key", .secure)]
        case "linkup": return [f("LINKUP_API_KEY", "Linkup API Key", "Enter Linkup API Key", .secure)]
        case "openserp": return [f("OPENSERP_BASE_URL", "OpenSERP Base URL", "Enter OpenSERP Base URL")]
        case "duckduckgo": return [f("DDGS_BACKEND", "DDGS Backend", "", .picker([
            ("auto", "Auto (Random)"), ("bing", "Bing"), ("brave", "Brave"), ("duckduckgo", "DuckDuckGo"),
            ("google", "Google"), ("grokipedia", "Grokipedia"), ("mojeek", "Mojeek"),
            ("wikipedia", "Wikipedia"), ("yahoo", "Yahoo"), ("yandex", "Yandex")]))]
        default: return []
        }
    }

    private var microsoftWebIQFields: [Field] {
        [f("MICROSOFT_WEB_IQ_API_BASE_URL", "Microsoft Web IQ API Base URL", "Enter Microsoft Web IQ API Base URL"),
         f("MICROSOFT_WEB_IQ_API_KEY", "Microsoft Web IQ API Key", "Enter Microsoft Web IQ API Key", .secure),
         f("MICROSOFT_WEB_IQ_LANGUAGE", "Language", "en")]
    }

    /// Loader-specific fields. Like the web UI, Firecrawl/Tavily/Web IQ share their
    /// credentials with the search engine of the same name, so they're only shown
    /// here when that engine isn't already selected above.
    private func loaderFields(_ loader: String, searchEngine: String) -> [Field] {
        switch loader {
        case "", "safe_web": return [
            f("WEB_LOADER_TIMEOUT", "Timeout (s)", "Default", .numericString),
            f("ENABLE_WEB_LOADER_SSL_VERIFICATION", "Verify SSL Certificate", "", .toggle)]
        case "playwright": return [
            f("PLAYWRIGHT_WS_URL", "Playwright WebSocket URL", "ws://localhost:3000"),
            f("PLAYWRIGHT_TIMEOUT", "Playwright Timeout (ms)", "10000", .int)]
        case "firecrawl": return searchEngine == "firecrawl" ? [] : [
            f("FIRECRAWL_API_BASE_URL", "Firecrawl API Base URL", "https://api.firecrawl.dev"),
            f("FIRECRAWL_API_KEY", "Firecrawl API Key", "Enter Firecrawl API Key", .secure)]
        case "tavily":
            var fields = [f("TAVILY_EXTRACT_DEPTH", "Tavily Extract Depth", "", .picker([("basic", "Basic"), ("advanced", "Advanced")]))]
            if searchEngine != "tavily" { fields.append(f("TAVILY_API_KEY", "Tavily API Key", "Enter Tavily API Key", .secure)) }
            return fields
        case "microsoft_web_iq": return searchEngine == "microsoft_web_iq" ? [] : microsoftWebIQFields
        case "external": return [
            f("EXTERNAL_WEB_LOADER_URL", "External Web Loader URL", "Enter External Web Loader URL"),
            f("EXTERNAL_WEB_LOADER_API_KEY", "External Web Loader API Key", "Enter External Web Loader API Key", .secure)]
        default: return []
        }
    }

    /// Boolean keys whose server default (config.py) is True — used only when the
    /// key is absent from the GET response.
    private static let defaultOnKeys: Set<String> = [
        "ENABLE_WEB_LOADER_SSL_VERIFICATION", "WEB_SEARCH_TRUST_ENV", "SERPSTACK_HTTPS"
    ]

    private static let searchEngines: [(String, String)] = [
        ("", "None"), ("ollama_cloud", "Ollama Cloud"), ("perplexity_search", "Perplexity Search"),
        ("searxng", "SearXNG"), ("yacy", "YaCy"), ("google_pse", "Google PSE"), ("brave", "Brave"),
        ("brave_llm_context", "Brave LLM Context"), ("kagi", "Kagi"), ("mojeek", "Mojeek"), ("bocha", "Bocha"),
        ("serpstack", "Serpstack"), ("serper", "Serper"), ("serphouse", "SERPHouse"), ("serply", "Serply"),
        ("searchapi", "SearchApi"), ("serpapi", "SerpApi"), ("duckduckgo", "DDGS"), ("tavily", "Tavily"),
        ("staan", "Staan"), ("jina", "Jina"), ("bing", "Bing"), ("exa", "Exa"), ("perplexity", "Perplexity"),
        ("microsoft_web_iq", "Microsoft Web IQ"), ("sougou", "Sougou"), ("firecrawl", "Firecrawl"),
        ("external", "External"), ("yandex", "Yandex"), ("youcom", "You.com"), ("linkup", "Linkup"),
        ("openserp", "OpenSERP")
    ]

    private static let loaderEngines: [(String, String)] = [
        ("", "Default"), ("playwright", "Playwright"), ("firecrawl", "Firecrawl"),
        ("tavily", "Tavily"), ("microsoft_web_iq", "Microsoft Web IQ"), ("external", "External")
    ]

    /// Picker options, keeping an unknown current value selectable so it's never silently changed.
    private func options(_ base: [(String, String)], current: String) -> [(value: String, label: String)] {
        var opts = base.map { (value: $0.0, label: $0.1) }
        if !opts.contains(where: { $0.value == current }) { opts.append((value: current, label: current)) }
        return opts
    }

    // MARK: - Field Rendering

    @ViewBuilder
    private func fieldRow(_ field: Field, showDivider: Bool = true) -> some View {
        switch field.kind {
        case .text:
            inlineTextFieldRow(title: field.title, placeholder: field.placeholder,
                               text: Binding(get: { viewModel.string(field.key) }, set: { viewModel.setString(field.key, $0) }),
                               showDivider: showDivider)
        case .secure:
            inlineSecureRow(title: field.title, placeholder: field.placeholder,
                            text: Binding(get: { viewModel.string(field.key) }, set: { viewModel.setString(field.key, $0) }),
                            isVisible: viewModel.revealedKeys.contains(field.key)) {
                if viewModel.revealedKeys.contains(field.key) { viewModel.revealedKeys.remove(field.key) }
                else { viewModel.revealedKeys.insert(field.key) }
            }
            if showDivider { Divider().padding(.leading, Spacing.md) }
        case .int:
            inlineTextFieldRow(title: field.title, placeholder: field.placeholder,
                               text: Binding(get: { viewModel.intText(field.key) }, set: { viewModel.setInt(field.key, $0) }),
                               keyboardType: .numberPad, showDivider: showDivider)
        case .numericString:
            inlineTextFieldRow(title: field.title, placeholder: field.placeholder,
                               text: Binding(get: { viewModel.string(field.key) }, set: { viewModel.setNumericString(field.key, $0) }),
                               keyboardType: .numberPad, showDivider: showDivider)
        case .toggle:
            inlineToggleRow(title: field.title,
                            isOn: Binding(get: { viewModel.bool(field.key, default: Self.defaultOnKeys.contains(field.key)) },
                                          set: { viewModel.setBool(field.key, $0) }),
                            showDivider: showDivider)
        case .list:
            inlineTextFieldRow(title: field.title, placeholder: field.placeholder,
                               text: Binding(get: { viewModel.listText(field.key) }, set: { viewModel.setList(field.key, $0) }),
                               showDivider: showDivider)
        case .picker(let opts):
            inlinePickerRow(title: field.title,
                            selection: Binding(get: { viewModel.string(field.key) }, set: { viewModel.setString(field.key, $0) }),
                            options: options(opts, current: viewModel.string(field.key)))
            if showDivider { Divider().padding(.leading, Spacing.md) }
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        let engine = viewModel.retrievalConfig.web.webSearchEngine
        return SettingsSection(header: "General") {
            fieldRow(f("ENABLE_WEB_SEARCH", "Web Search", "", .toggle))
            inlinePickerRow(
                title: "Web Search Engine",
                selection: Binding(get: { engine }, set: { viewModel.retrievalConfig.web.webSearchEngine = $0 }),
                options: options(Self.searchEngines, current: engine)
            )
            Divider().padding(.leading, Spacing.md)
            ForEach(engineFields(engine), id: \.key) { fieldRow($0) }
            fieldRow(f("WEB_SEARCH_RESULT_COUNT", "Search Result Count", "3", .int))
            fieldRow(f("WEB_SEARCH_CONCURRENT_REQUESTS", "Concurrent Requests", "10", .int))
            fieldRow(f("WEB_FETCH_MAX_CONTENT_LENGTH", "Fetch URL Content Length Limit", "No limit", .int))
            fieldRow(f("WEB_SEARCH_DOMAIN_FILTER_LIST", "Domain Filter List", "e.g. example.com, docs.ai", .list))
            fieldRow(f("BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL", "Bypass Embedding and Retrieval", "", .toggle))
            fieldRow(f("BYPASS_WEB_SEARCH_WEB_LOADER", "Bypass Web Loader", "", .toggle))
            fieldRow(f("WEB_SEARCH_TRUST_ENV", "Trust Proxy Environment", "", .toggle))
            fieldRow(f("ENABLE_WEB_SEARCH_CONFIRMATION", "Ask Before Searching", "", .toggle),
                     showDivider: viewModel.bool("ENABLE_WEB_SEARCH_CONFIRMATION"))
            if viewModel.bool("ENABLE_WEB_SEARCH_CONFIRMATION") {
                fieldRow(f("WEB_SEARCH_CONFIRMATION_CONTENT", "Confirmation Message", "Default"), showDivider: false)
            }
            if engine == "linkup" {
                Divider().padding(.leading, Spacing.md)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Linkup Parameters (JSON)")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                    TextField("{\n  \"depth\": \"standard\"\n}", text: $viewModel.linkupParamsText, axis: .vertical)
                        .scaledFont(size: 13)
                        .lineLimit(3...10)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.chatBubblePadding)
            }
        }
        .padding(.horizontal, Spacing.sm)
    }

    // MARK: - Loader Section

    private var loaderSection: some View {
        let loader = viewModel.retrievalConfig.web.webLoaderEngine
        let engine = viewModel.retrievalConfig.web.webSearchEngine
        return SettingsSection(header: "Loader") {
            inlinePickerRow(
                title: "Web Loader Engine",
                selection: Binding(get: { loader }, set: { viewModel.retrievalConfig.web.webLoaderEngine = $0 }),
                options: options(Self.loaderEngines, current: loader)
            )
            Divider().padding(.leading, Spacing.md)
            ForEach(loaderFields(loader, searchEngine: engine), id: \.key) { fieldRow($0) }
            fieldRow(f("WEB_LOADER_CONCURRENT_REQUESTS", "Concurrent Requests", "10", .int), showDivider: false)
        }
        .padding(.horizontal, Spacing.sm)
    }

    // MARK: - YouTube Section

    private var youtubeSection: some View {
        SettingsSection(header: "YouTube") {
            fieldRow(f("YOUTUBE_LOADER_LANGUAGE", "Youtube Language", "en", .list))
            fieldRow(f("YOUTUBE_LOADER_PROXY_URL", "Youtube Proxy URL", "http://..."), showDivider: false)
        }
        .padding(.horizontal, Spacing.sm)
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
