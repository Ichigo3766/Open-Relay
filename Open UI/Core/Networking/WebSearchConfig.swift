import Foundation

// MARK: - Web Search Config

/// The `web` nested object inside `RetrievalConfig`.
/// Keys are SCREAMING_SNAKE_CASE — uses the same fault-tolerant decoder pattern.
struct WebSearchConfig: Codable, Sendable {
    // General
    var enableWebSearch: Bool
    var webSearchEngine: String
    var searchResultCount: Int
    var searchConcurrentRequests: Int
    var fetchPageContentLengthLimit: Int
    var domainFilterList: [String]
    var bypassEmbeddingAndRetrieval: Bool
    var bypassWebLoader: Bool
    var trustProxyEnvironment: Bool

    // SearXNG
    var searxngQueryURL: String
    var searxngLanguage: String

    // Google PSE
    var googlePSEAPIKey: String
    var googlePSEEngineID: String

    // Brave
    var braveSearchAPIKey: String

    // Kagi
    var kagiSearchAPIKey: String

    // Mojeek
    var mojeekSearchAPIKey: String

    // Bocha
    var bochaSearchAPIKey: String

    // Serpstack
    var serpstackAPIKey: String
    var serpstackHTTPS: Bool

    // Serper
    var serperAPIKey: String

    // Serply
    var serplyAPIKey: String

    // SearchAPI
    var searchAPIAPIKey: String
    var searchAPIEngine: String

    // SerpAPI
    var serpAPIAPIKey: String
    var serpAPIEngine: String

    // Tavily
    var tavilyAPIKey: String
    var tavilyExtractDepth: String

    // Jina
    var jinaAPIKey: String

    // Bing
    var bingSearchV7SubscriptionKey: String
    var bingSearchV7Endpoint: String
    var bingSearchV7Region: String

    // Exa
    var exaAPIKey: String

    // Perplexity
    var perplexityAPIKey: String

    // Sougou
    var sougouAPISID: String
    var sougouAPISK: String

    // Firecrawl
    var firecrawlAPIKey: String
    var firecrawlAPIBaseURL: String

    // External (general)
    var externalSearchURL: String
    var externalSearchAPIKey: String

    // Yandex
    var yandexSearchAPIKey: String
    var yandexSearchFolderID: String
    var yandexSearchLang: String

    // YouCom
    var youSearchAPIKey: String

    // Ollama Cloud
    var ollamaCloudAPIKey: String
    var ollamaCloudAPIURL: String
    var ollamaCloudModel: String

    // Perplexity Search
    var perplexitySearchAPIKey: String
    var perplexitySearchAPIURL: String
    var perplexitySearchModel: String

    // DDGS
    var ddgsProxy: String

    // Loader
    var webLoaderEngine: String
    var playwrightWSURL: String
    var playwrightTimeout: Int
    var firecrawlLoaderAPIKey: String
    var firecrawlLoaderAPIBaseURL: String
    var firecrawlLoaderTimeout: Int
    var tavilyLoaderAPIKey: String
    var tavilyLoaderExtractDepth: String
    var externalLoaderURL: String
    var externalLoaderAPIKey: String
    var webLoaderTimeout: Int
    var webLoaderVerifySSL: Bool
    var webLoaderConcurrentRequests: Int

    // YouTube
    var youtubeLanguage: String
    var youtubeProxyURL: String

    enum CodingKeys: String, CodingKey {
        case enableWebSearch = "ENABLE_WEB_SEARCH"
        case webSearchEngine = "WEB_SEARCH_ENGINE"
        case searchResultCount = "WEB_SEARCH_RESULT_COUNT"
        case searchConcurrentRequests = "WEB_SEARCH_CONCURRENT_REQUESTS"
        case fetchPageContentLengthLimit = "WEB_SEARCH_FETCH_PAGE_CONTENT_LENGTH_LIMIT"
        case domainFilterList = "WEB_SEARCH_DOMAIN_FILTER_LIST"
        case bypassEmbeddingAndRetrieval = "BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL"
        case bypassWebLoader = "BYPASS_WEB_LOADER"
        case trustProxyEnvironment = "WEB_SEARCH_TRUST_ENV"
        case searxngQueryURL = "SEARXNG_QUERY_URL"
        case searxngLanguage = "SEARXNG_LANGUAGE"
        case googlePSEAPIKey = "GOOGLE_PSE_API_KEY"
        case googlePSEEngineID = "GOOGLE_PSE_ENGINE_ID"
        case braveSearchAPIKey = "BRAVE_SEARCH_API_KEY"
        case kagiSearchAPIKey = "KAGI_SEARCH_API_KEY"
        case mojeekSearchAPIKey = "MOJEEK_SEARCH_API_KEY"
        case bochaSearchAPIKey = "BOCHA_SEARCH_API_KEY"
        case serpstackAPIKey = "SERPSTACK_API_KEY"
        case serpstackHTTPS = "SERPSTACK_HTTPS"
        case serperAPIKey = "SERPER_API_KEY"
        case serplyAPIKey = "SERPLY_API_KEY"
        case searchAPIAPIKey = "SEARCHAPI_API_KEY"
        case searchAPIEngine = "SEARCHAPI_ENGINE"
        case serpAPIAPIKey = "SERPAPI_API_KEY"
        case serpAPIEngine = "SERPAPI_ENGINE"
        case tavilyAPIKey = "TAVILY_API_KEY"
        case tavilyExtractDepth = "TAVILY_EXTRACT_DEPTH"
        case jinaAPIKey = "JINA_API_KEY"
        case bingSearchV7SubscriptionKey = "BING_SEARCH_V7_SUBSCRIPTION_KEY"
        case bingSearchV7Endpoint = "BING_SEARCH_V7_ENDPOINT"
        case bingSearchV7Region = "BING_SEARCH_V7_REGION"
        case exaAPIKey = "EXA_API_KEY"
        case perplexityAPIKey = "PERPLEXITY_API_KEY"
        case sougouAPISID = "SOUGOU_API_SID"
        case sougouAPISK = "SOUGOU_API_SK"
        case firecrawlAPIKey = "FIRECRAWL_API_KEY"
        case firecrawlAPIBaseURL = "FIRECRAWL_API_BASE_URL"
        case externalSearchURL = "EXTERNAL_WEB_SEARCH_URL"
        case externalSearchAPIKey = "EXTERNAL_WEB_SEARCH_API_KEY"
        case yandexSearchAPIKey = "YANDEX_SEARCH_API_KEY"
        case yandexSearchFolderID = "YANDEX_SEARCH_FOLDER_ID"
        case yandexSearchLang = "YANDEX_SEARCH_LANG"
        case youSearchAPIKey = "YOU_SEARCH_API_KEY"
        case ollamaCloudAPIKey = "OLLAMA_CLOUD_API_KEY"
        case ollamaCloudAPIURL = "OLLAMA_CLOUD_API_URL"
        case ollamaCloudModel = "OLLAMA_CLOUD_MODEL"
        case perplexitySearchAPIKey = "PERPLEXITY_SEARCH_API_KEY"
        case perplexitySearchAPIURL = "PERPLEXITY_SEARCH_API_URL"
        case perplexitySearchModel = "PERPLEXITY_SEARCH_MODEL"
        case ddgsProxy = "DDGS_PROXY"
        case webLoaderEngine = "WEB_LOADER_ENGINE"
        case playwrightWSURL = "PLAYWRIGHT_WS_URL"
        case playwrightTimeout = "PLAYWRIGHT_TIMEOUT"
        case firecrawlLoaderAPIKey = "FIRECRAWL_LOADER_API_KEY"
        case firecrawlLoaderAPIBaseURL = "FIRECRAWL_LOADER_API_BASE_URL"
        case firecrawlLoaderTimeout = "FIRECRAWL_LOADER_TIMEOUT"
        case tavilyLoaderAPIKey = "TAVILY_LOADER_API_KEY"
        case tavilyLoaderExtractDepth = "TAVILY_LOADER_EXTRACT_DEPTH"
        case externalLoaderURL = "EXTERNAL_WEB_LOADER_URL"
        case externalLoaderAPIKey = "EXTERNAL_WEB_LOADER_API_KEY"
        case webLoaderTimeout = "WEB_LOADER_TIMEOUT"
        case webLoaderVerifySSL = "WEB_LOADER_VERIFY_SSL"
        case webLoaderConcurrentRequests = "WEB_LOADER_CONCURRENT_REQUESTS"
        case youtubeLanguage = "YOUTUBE_LANGUAGE"
        case youtubeProxyURL = "YOUTUBE_PROXY_URL"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enableWebSearch = (try? c.decode(Bool.self, forKey: .enableWebSearch)) ?? false
        webSearchEngine = (try? c.decode(String.self, forKey: .webSearchEngine)) ?? ""
        searchResultCount = (try? c.decode(Int.self, forKey: .searchResultCount)) ?? 3
        searchConcurrentRequests = (try? c.decode(Int.self, forKey: .searchConcurrentRequests)) ?? 10
        fetchPageContentLengthLimit = (try? c.decode(Int.self, forKey: .fetchPageContentLengthLimit)) ?? 0
        domainFilterList = (try? c.decode([String].self, forKey: .domainFilterList)) ?? []
        bypassEmbeddingAndRetrieval = (try? c.decode(Bool.self, forKey: .bypassEmbeddingAndRetrieval)) ?? false
        bypassWebLoader = (try? c.decode(Bool.self, forKey: .bypassWebLoader)) ?? false
        trustProxyEnvironment = (try? c.decode(Bool.self, forKey: .trustProxyEnvironment)) ?? false
        searxngQueryURL = (try? c.decode(String.self, forKey: .searxngQueryURL)) ?? ""
        searxngLanguage = (try? c.decode(String.self, forKey: .searxngLanguage)) ?? ""
        googlePSEAPIKey = (try? c.decode(String.self, forKey: .googlePSEAPIKey)) ?? ""
        googlePSEEngineID = (try? c.decode(String.self, forKey: .googlePSEEngineID)) ?? ""
        braveSearchAPIKey = (try? c.decode(String.self, forKey: .braveSearchAPIKey)) ?? ""
        kagiSearchAPIKey = (try? c.decode(String.self, forKey: .kagiSearchAPIKey)) ?? ""
        mojeekSearchAPIKey = (try? c.decode(String.self, forKey: .mojeekSearchAPIKey)) ?? ""
        bochaSearchAPIKey = (try? c.decode(String.self, forKey: .bochaSearchAPIKey)) ?? ""
        serpstackAPIKey = (try? c.decode(String.self, forKey: .serpstackAPIKey)) ?? ""
        serpstackHTTPS = (try? c.decode(Bool.self, forKey: .serpstackHTTPS)) ?? true
        serperAPIKey = (try? c.decode(String.self, forKey: .serperAPIKey)) ?? ""
        serplyAPIKey = (try? c.decode(String.self, forKey: .serplyAPIKey)) ?? ""
        searchAPIAPIKey = (try? c.decode(String.self, forKey: .searchAPIAPIKey)) ?? ""
        searchAPIEngine = (try? c.decode(String.self, forKey: .searchAPIEngine)) ?? ""
        serpAPIAPIKey = (try? c.decode(String.self, forKey: .serpAPIAPIKey)) ?? ""
        serpAPIEngine = (try? c.decode(String.self, forKey: .serpAPIEngine)) ?? ""
        tavilyAPIKey = (try? c.decode(String.self, forKey: .tavilyAPIKey)) ?? ""
        tavilyExtractDepth = (try? c.decode(String.self, forKey: .tavilyExtractDepth)) ?? "basic"
        jinaAPIKey = (try? c.decode(String.self, forKey: .jinaAPIKey)) ?? ""
        bingSearchV7SubscriptionKey = (try? c.decode(String.self, forKey: .bingSearchV7SubscriptionKey)) ?? ""
        bingSearchV7Endpoint = (try? c.decode(String.self, forKey: .bingSearchV7Endpoint)) ?? "https://api.bing.microsoft.com/v7.0/search"
        bingSearchV7Region = (try? c.decode(String.self, forKey: .bingSearchV7Region)) ?? ""
        exaAPIKey = (try? c.decode(String.self, forKey: .exaAPIKey)) ?? ""
        perplexityAPIKey = (try? c.decode(String.self, forKey: .perplexityAPIKey)) ?? ""
        sougouAPISID = (try? c.decode(String.self, forKey: .sougouAPISID)) ?? ""
        sougouAPISK = (try? c.decode(String.self, forKey: .sougouAPISK)) ?? ""
        firecrawlAPIKey = (try? c.decode(String.self, forKey: .firecrawlAPIKey)) ?? ""
        firecrawlAPIBaseURL = (try? c.decode(String.self, forKey: .firecrawlAPIBaseURL)) ?? "https://api.firecrawl.dev"
        externalSearchURL = (try? c.decode(String.self, forKey: .externalSearchURL)) ?? ""
        externalSearchAPIKey = (try? c.decode(String.self, forKey: .externalSearchAPIKey)) ?? ""
        yandexSearchAPIKey = (try? c.decode(String.self, forKey: .yandexSearchAPIKey)) ?? ""
        yandexSearchFolderID = (try? c.decode(String.self, forKey: .yandexSearchFolderID)) ?? ""
        yandexSearchLang = (try? c.decode(String.self, forKey: .yandexSearchLang)) ?? ""
        youSearchAPIKey = (try? c.decode(String.self, forKey: .youSearchAPIKey)) ?? ""
        ollamaCloudAPIKey = (try? c.decode(String.self, forKey: .ollamaCloudAPIKey)) ?? ""
        ollamaCloudAPIURL = (try? c.decode(String.self, forKey: .ollamaCloudAPIURL)) ?? ""
        ollamaCloudModel = (try? c.decode(String.self, forKey: .ollamaCloudModel)) ?? ""
        perplexitySearchAPIKey = (try? c.decode(String.self, forKey: .perplexitySearchAPIKey)) ?? ""
        perplexitySearchAPIURL = (try? c.decode(String.self, forKey: .perplexitySearchAPIURL)) ?? ""
        perplexitySearchModel = (try? c.decode(String.self, forKey: .perplexitySearchModel)) ?? ""
        ddgsProxy = (try? c.decode(String.self, forKey: .ddgsProxy)) ?? ""
        webLoaderEngine = (try? c.decode(String.self, forKey: .webLoaderEngine)) ?? ""
        playwrightWSURL = (try? c.decode(String.self, forKey: .playwrightWSURL)) ?? ""
        playwrightTimeout = (try? c.decode(Int.self, forKey: .playwrightTimeout)) ?? 60000
        firecrawlLoaderAPIKey = (try? c.decode(String.self, forKey: .firecrawlLoaderAPIKey)) ?? ""
        firecrawlLoaderAPIBaseURL = (try? c.decode(String.self, forKey: .firecrawlLoaderAPIBaseURL)) ?? "https://api.firecrawl.dev"
        firecrawlLoaderTimeout = (try? c.decode(Int.self, forKey: .firecrawlLoaderTimeout)) ?? 60000
        tavilyLoaderAPIKey = (try? c.decode(String.self, forKey: .tavilyLoaderAPIKey)) ?? ""
        tavilyLoaderExtractDepth = (try? c.decode(String.self, forKey: .tavilyLoaderExtractDepth)) ?? "basic"
        externalLoaderURL = (try? c.decode(String.self, forKey: .externalLoaderURL)) ?? ""
        externalLoaderAPIKey = (try? c.decode(String.self, forKey: .externalLoaderAPIKey)) ?? ""
        webLoaderTimeout = (try? c.decode(Int.self, forKey: .webLoaderTimeout)) ?? 15
        webLoaderVerifySSL = (try? c.decode(Bool.self, forKey: .webLoaderVerifySSL)) ?? true
        webLoaderConcurrentRequests = (try? c.decode(Int.self, forKey: .webLoaderConcurrentRequests)) ?? 10
        youtubeLanguage = (try? c.decode(String.self, forKey: .youtubeLanguage)) ?? "en"
        youtubeProxyURL = (try? c.decode(String.self, forKey: .youtubeProxyURL)) ?? ""
    }

    init() {
        enableWebSearch = false; webSearchEngine = ""; searchResultCount = 3
        searchConcurrentRequests = 10; fetchPageContentLengthLimit = 0; domainFilterList = []
        bypassEmbeddingAndRetrieval = false; bypassWebLoader = false; trustProxyEnvironment = false
        searxngQueryURL = ""; searxngLanguage = ""
        googlePSEAPIKey = ""; googlePSEEngineID = ""
        braveSearchAPIKey = ""; kagiSearchAPIKey = ""; mojeekSearchAPIKey = ""; bochaSearchAPIKey = ""
        serpstackAPIKey = ""; serpstackHTTPS = true; serperAPIKey = ""; serplyAPIKey = ""
        searchAPIAPIKey = ""; searchAPIEngine = ""; serpAPIAPIKey = ""; serpAPIEngine = ""
        tavilyAPIKey = ""; tavilyExtractDepth = "basic"; jinaAPIKey = ""
        bingSearchV7SubscriptionKey = ""; bingSearchV7Endpoint = "https://api.bing.microsoft.com/v7.0/search"; bingSearchV7Region = ""
        exaAPIKey = ""; perplexityAPIKey = ""
        sougouAPISID = ""; sougouAPISK = ""
        firecrawlAPIKey = ""; firecrawlAPIBaseURL = "https://api.firecrawl.dev"
        externalSearchURL = ""; externalSearchAPIKey = ""
        yandexSearchAPIKey = ""; yandexSearchFolderID = ""; yandexSearchLang = ""
        youSearchAPIKey = ""
        ollamaCloudAPIKey = ""; ollamaCloudAPIURL = ""; ollamaCloudModel = ""
        perplexitySearchAPIKey = ""; perplexitySearchAPIURL = ""; perplexitySearchModel = ""
        ddgsProxy = ""
        webLoaderEngine = ""; playwrightWSURL = ""; playwrightTimeout = 60000
        firecrawlLoaderAPIKey = ""; firecrawlLoaderAPIBaseURL = "https://api.firecrawl.dev"
        firecrawlLoaderTimeout = 60000; tavilyLoaderAPIKey = ""; tavilyLoaderExtractDepth = "basic"
        externalLoaderURL = ""; externalLoaderAPIKey = ""
        webLoaderTimeout = 15; webLoaderVerifySSL = true; webLoaderConcurrentRequests = 10
        youtubeLanguage = "en"; youtubeProxyURL = ""
    }
}
