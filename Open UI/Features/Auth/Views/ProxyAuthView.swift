import SwiftUI
import WebKit
import os.log

// MARK: - Proxy Auth WebView

/// A WKWebView that loads the server URL and detects when the user has successfully
/// authenticated through an upstream auth proxy (Authelia, Authentik, Keycloak,
/// oauth2-proxy, Pangolin, etc.).
///
/// Detection strategy (layered):
/// 1. Cross-domain proxy (Authelia on a subdomain): `hasLeftServerDomain` → returns to server domain → immediate success
/// 2. Same-domain proxy (path-based Authentik / oauth2-proxy on same host):
///    a. Password-field check: if current page still has a password input → still on proxy login, skip
///    b. DOM/JS check: look for OpenWebUI-specific elements (auth-page id, favicon path, chat div, page title)
///    c. Path check: `/auth`, `/oauth/`, `/api/v1/auths/` paths → known OpenWebUI routes
///    d. `/api/config` HTTP probe as final fallback
/// 3. JWT capture: after proxy auth, if oauth2-proxy uses trusted headers and OpenWebUI
///    auto-authenticated the user, capture the JWT from document.cookie or localStorage
///    and return it alongside the cookies for a one-step sign-in.
struct ProxyAuthWebView: UIViewRepresentable {
    let serverURL: String
    /// Called with captured cookies (name→value), WebView User-Agent, and optional JWT token
    /// once proxy auth is detected as complete.
    let onSuccess: ([String: String], String, String?) -> Void
    let onFailed: () -> Void
    /// Called when the user taps the manual "Continue" button — triggers immediate capture.
    let onManualCapture: (@escaping () -> Void) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(serverURL: serverURL, onSuccess: onSuccess, onFailed: onFailed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use the default data store so saved passwords / autofill works,
        // making the proxy login experience smooth for the user.
        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Use a realistic Mobile Safari UA for maximum proxy compatibility
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        context.coordinator.webView = webView

        // Wire up the manual capture callback so the parent View can trigger it
        onManualCapture {
            context.coordinator.manualCapture()
        }

        if let url = URL(string: serverURL) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        let serverURL: String
        let onSuccess: ([String: String], String, String?) -> Void
        let onFailed: () -> Void
        weak var webView: WKWebView?

        private var timeoutTimer: Timer?
        private var didSucceed = false

        /// Debounce: prevents firing multiple detection checks in rapid succession
        /// (e.g. page A redirects to page B on the same domain, triggering two didFinish events).
        private var detectionTask: Task<Void, Never>?

        /// Tracks whether the WebView has navigated away from the server domain
        /// to the auth portal. We only trigger success detection AFTER the user
        /// has been to the proxy login page and come back.
        private var hasLeftServerDomain = false

        private let logger = Logger(subsystem: "com.openui", category: "ProxyAuth")

        init(
            serverURL: String,
            onSuccess: @escaping ([String: String], String, String?) -> Void,
            onFailed: @escaping () -> Void
        ) {
            self.serverURL = serverURL
            self.onSuccess = onSuccess
            self.onFailed = onFailed
        }

        deinit {
            timeoutTimer?.invalidate()
            detectionTask?.cancel()
        }

        // MARK: - Navigation Delegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if didSucceed {
                decisionHandler(.cancel)
                return
            }

            if let url = navigationAction.request.url {
                if !isOnServerDomain(url) {
                    hasLeftServerDomain = true
                    logger.debug("ProxyAuth: navigating to auth portal: \(url.host ?? url.absoluteString)")
                }
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didSucceed else { return }
            guard let currentURL = webView.url else { return }

            logger.debug("ProxyAuth: page finished: \(currentURL.absoluteString)")

            // Primary success condition: left server domain (cross-domain proxy) and returned.
            if hasLeftServerDomain && isOnServerDomain(currentURL) {
                logger.info("ProxyAuth: returned to server domain after auth portal — capturing cookies immediately")
                captureSessionAndSucceed()
                return
            }

            // Secondary success condition: same-domain proxy.
            // Debounce: cancel any in-flight check before starting a new one.
            if isOnServerDomain(currentURL) {
                detectionTask?.cancel()
                detectionTask = Task { [weak self] in
                    guard let self else { return }
                    // Small debounce to let the page settle and JS to run
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                    guard !Task.isCancelled, !self.didSucceed else { return }
                    await self.runSameDomainDetection(url: currentURL)
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard !didSucceed else { return }

            if timeoutTimer == nil {
                timeoutTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
                    guard let self, !self.didSucceed else { return }
                    self.logger.warning("ProxyAuth: timed out after 3 minutes")
                    DispatchQueue.main.async { self.onFailed() }
                }
            }

            // Fast path for cross-domain proxy redirect-back
            if let url = webView.url, hasLeftServerDomain && isOnServerDomain(url) {
                logger.info("ProxyAuth: server domain detected on provisional navigation — capturing cookies")
                captureSessionAndSucceed()
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            guard !didSucceed else { return }
            if let url = webView.url, hasLeftServerDomain && isOnServerDomain(url) {
                logger.info("ProxyAuth: server redirect back to server domain — capturing cookies")
                captureSessionAndSucceed()
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            logger.warning("ProxyAuth: navigation failed: \(error.localizedDescription)")
        }

        // MARK: - Manual Capture (Continue button)

        /// Called by the parent View when the user taps "Continue".
        /// Bypasses all detection logic and captures immediately.
        func manualCapture() {
            guard !didSucceed else { return }
            logger.info("ProxyAuth: manual capture triggered by user")
            detectionTask?.cancel()
            captureSessionAndSucceed()
        }

        // MARK: - Same-Domain Detection Pipeline

        /// Runs the layered detection pipeline for same-domain proxies.
        /// Tries up to 3 times with 250ms between attempts to handle JS timing.
        @MainActor
        private func runSameDomainDetection(url: URL) async {
            let path = url.path.lowercased()

            // Check 1: Is this a known OpenWebUI-owned path?
            // These paths confirm we're past the proxy → capture immediately.
            if isKnownOpenWebUIPath(path) {
                logger.info("ProxyAuth: known OpenWebUI path '\(path)' on server domain — checking for JWT then capturing")
                captureSessionAndSucceed()
                return
            }

            // Check 2: Password field — if present, still on proxy login page. Skip.
            guard let webView else { return }
            let hasPassword = await evaluatePasswordFieldPresent(in: webView)
            if hasPassword {
                logger.debug("ProxyAuth: page has password field — still on proxy login, waiting")
                return
            }

            // Check 3: DOM-based OpenWebUI detection (3 attempts × 250ms)
            for attempt in 0..<3 {
                guard !Task.isCancelled, !didSucceed else { return }

                let looksLikeOpenWebUI = await evaluateOpenWebUIPresent(in: webView)
                if looksLikeOpenWebUI {
                    logger.info("ProxyAuth: DOM check confirms OpenWebUI on server domain (attempt \(attempt + 1)) — capturing")
                    captureSessionAndSucceed()
                    return
                }

                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            guard !Task.isCancelled, !didSucceed else { return }

            // Check 4: /api/config HTTP probe as final fallback
            if await checkAPIConfigReachable() {
                logger.info("ProxyAuth: /api/config probe returned 200 on server domain — capturing")
                captureSessionAndSucceed()
            }
        }

        /// Returns true if the URL path is an OpenWebUI-owned post-auth route,
        /// meaning the proxy login is complete and OpenWebUI has taken over.
        /// NOTE: `/auth` is intentionally NOT here — it's the OpenWebUI login page,
        /// not a post-auth indicator. We'd immediately capture empty cookies and fail.
        private func isKnownOpenWebUIPath(_ path: String) -> Bool {
            if path.contains("/oauth/") { return true }      // OAuth callback — post-proxy
            if path.contains("/api/v1/auths/") { return true } // API auth call — post-proxy
            return false
        }

        // MARK: - JavaScript Evaluations

        /// Returns true if the page still has a password input — meaning we're still on a proxy login page.
        private func evaluatePasswordFieldPresent(in webView: WKWebView) async -> Bool {
            let js = """
            (function() {
                return document.querySelector(
                    'input[type="password"], input[name="password"], #password'
                ) !== null ? "true" : "false";
            })()
            """
            guard let result = try? await webView.evaluateJavaScript(js) else { return false }
            return (result as? String) == "true"
        }

        /// Returns true if the page looks like an OpenWebUI page (has known DOM markers).
        private func evaluateOpenWebUIPresent(in webView: WKWebView) async -> Bool {
            let js = """
            (function() {
                var title = (document.title || "").toLowerCase();
                var hasKnownIds =
                    document.getElementById("auth-page") !== null ||
                    document.getElementById("auth-container") !== null;
                var hasBrandMarkers =
                    document.querySelector('link[rel*="icon"][href*="/static/favicon"]') !== null;
                var hasUiMarkers =
                    document.querySelector('div[class*="chat"]') !== null ||
                    document.querySelector('[data-testid]') !== null;
                var hasTitleMarker =
                    title.includes("open webui") || title.includes("chat");
                return (hasKnownIds || hasBrandMarkers || hasUiMarkers || hasTitleMarker)
                    ? "true" : "false";
            })()
            """
            guard let result = try? await webView.evaluateJavaScript(js) else { return false }
            return (result as? String) == "true"
        }

        // MARK: - JWT Capture

        /// Tries to capture a JWT token from the WebView's cookie or localStorage.
        /// Used when oauth2-proxy with trusted headers auto-authenticates the user in OpenWebUI.
        /// Returns the JWT string if found, nil otherwise.
        private func captureJWTFromWebView() async -> String? {
            guard let webView else { return nil }

            // Strategy 1: document.cookie token=...
            let cookieJS = """
            (function() {
                var cookies = document.cookie.split(";");
                for (var i = 0; i < cookies.length; i++) {
                    var c = cookies[i].trim();
                    if (c.startsWith("token=")) { return c.substring(6); }
                }
                return "";
            })()
            """
            if let result = try? await webView.evaluateJavaScript(cookieJS),
               let raw = result as? String {
                let cleaned = cleanJSString(raw)
                if isValidJWT(cleaned) {
                    logger.info("ProxyAuth: JWT captured from document.cookie")
                    return cleaned
                }
            }

            // Strategy 2: localStorage
            if let result = try? await webView.evaluateJavaScript("localStorage.getItem('token')"),
               let raw = result as? String {
                let cleaned = cleanJSString(raw)
                if isValidJWT(cleaned) {
                    logger.info("ProxyAuth: JWT captured from localStorage")
                    return cleaned
                }
            }

            logger.debug("ProxyAuth: no JWT found in WebView (proxy may not use trusted headers)")
            return nil
        }

        private func cleanJSString(_ value: String) -> String {
            var s = value
            if s.hasPrefix("\"") && s.hasSuffix("\"") {
                s = String(s.dropFirst().dropLast())
            }
            return s.trimmingCharacters(in: .whitespaces)
        }

        /// Basic JWT format validation: 3 dot-separated segments, minimum 50 chars.
        private func isValidJWT(_ value: String) -> Bool {
            guard !value.isEmpty else { return false }
            let bad = ["null", "undefined", "false", "true", ""]
            guard !bad.contains(value) else { return false }
            let segments = value.split(separator: ".", omittingEmptySubsequences: false)
            return segments.count == 3 && value.count >= 50
        }

        // MARK: - /api/config HTTP Probe (fallback)

        /// Probes `GET {serverURL}/api/config` using cookies from HTTPCookieStorage.shared.
        /// Returns true if the endpoint responds with HTTP 200 and valid JSON.
        private func checkAPIConfigReachable() async -> Bool {
            guard let baseURL = URL(string: serverURL) else { return false }
            let configURL = baseURL.appendingPathComponent("api/config")

            var request = URLRequest(url: configURL)
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.httpCookieStorage = HTTPCookieStorage.shared
            sessionConfig.httpCookieAcceptPolicy = .always
            sessionConfig.httpShouldSetCookies = true
            sessionConfig.timeoutIntervalForRequest = 8
            let session = URLSession(configuration: sessionConfig)

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return false }
                guard http.statusCode == 200 else {
                    logger.debug("ProxyAuth /api/config probe: status \(http.statusCode) — not authenticated yet")
                    return false
                }
                guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    logger.debug("ProxyAuth /api/config probe: 200 but body is not JSON — still proxied")
                    return false
                }
                return true
            } catch {
                logger.debug("ProxyAuth /api/config probe failed: \(error.localizedDescription)")
                return false
            }
        }

        // MARK: - Domain Check

        private func isOnServerDomain(_ url: URL) -> Bool {
            guard let serverHost = URL(string: serverURL)?.host?.lowercased(),
                  let currentHost = url.host?.lowercased() else { return false }
            return currentHost == serverHost || currentHost.hasSuffix(".\(serverHost)")
        }

        // MARK: - Cookie + JWT Capture

        /// Captures all WKWebView cookies, attempts JWT capture, then fires onSuccess.
        func captureSessionAndSucceed() {
            guard !didSucceed, let webView else { return }
            didSucceed = true
            timeoutTimer?.invalidate()
            timeoutTimer = nil
            detectionTask?.cancel()

            logger.info("ProxyAuth: capturing session")

            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
                guard let self else { return }

                var cookieDict: [String: String] = [:]
                for cookie in cookies {
                    cookieDict[cookie.name] = cookie.value
                }
                self.logger.info("ProxyAuth: captured \(cookieDict.count) cookies")

                // Get the WebView User-Agent, then try to capture JWT
                webView?.evaluateJavaScript("navigator.userAgent") { [weak self, weak webView] ua, _ in
                    guard let self else { return }
                    let userAgent = (ua as? String) ?? ""

                    // Attempt JWT capture (for oauth2-proxy trusted-header setups)
                    Task { @MainActor [weak self, weak webView] in
                        guard let self else { return }
                        var jwtToken: String? = nil
                        if webView != nil {
                            // Try up to 3 times with 250ms delay (JS may not have run yet)
                            for _ in 0..<3 {
                                jwtToken = await self.captureJWTFromWebView()
                                if jwtToken != nil { break }
                                try? await Task.sleep(nanoseconds: 250_000_000)
                            }
                        }
                        if jwtToken != nil {
                            self.logger.info("ProxyAuth: JWT token captured — user will skip second sign-in")
                        }
                        self.onSuccess(cookieDict, userAgent, jwtToken)
                    }
                }
            }
        }
    }
}

// MARK: - Proxy Auth Sheet View

/// Full-screen sheet shown when the server is behind an authentication proxy.
/// Presents a WKWebView so the user can log in through the proxy portal
/// (Authelia, Authentik, Keycloak, etc.), then captures the session cookies
/// (and optionally a JWT for trusted-header setups) and resumes automatically.
struct ProxyAuthView: View {
    let serverURL: String
    /// Called with captured cookies, WebView User-Agent, and optional JWT token on success.
    let onSuccess: ([String: String], String, String?) -> Void
    let onDismiss: () -> Void

    @State private var isWaiting = true
    @State private var didFail = false
    @State private var manualCapture: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ProxyAuthWebView(
                    serverURL: serverURL,
                    onSuccess: { cookies, userAgent, jwtToken in
                        isWaiting = false
                        onSuccess(cookies, userAgent, jwtToken)
                    },
                    onFailed: {
                        isWaiting = false
                        didFail = true
                    },
                    onManualCapture: { captureAction in
                        manualCapture = captureAction
                    }
                )
                .ignoresSafeArea(edges: .bottom)

                // Top status banner (spinner while waiting)
                if isWaiting {
                    VStack(spacing: Spacing.sm) {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                                .tint(theme.brandPrimary)
                            Text("Sign in through your proxy — authentication will be detected automatically.")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                        .padding(.top, Spacing.sm)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Persistent bottom banner with manual "Continue" escape hatch.
                // Always visible so the user is never stuck regardless of proxy setup.
                if isWaiting {
                    VStack(spacing: Spacing.xs) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textTertiary)
                            Text("Tap Continue if you have signed in and the screen hasn't advanced.")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button {
                            manualCapture?()
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Text("Continue")
                                    .scaledFont(size: 15, weight: .semibold)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(theme.brandPrimary)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                        }
                        .padding(.horizontal, Spacing.md)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
            .alert("Sign In Timed Out", isPresented: $didFail) {
                Button("Try Again") {
                    didFail = false
                    isWaiting = true
                }
                Button("Cancel", role: .cancel) {
                    onDismiss()
                }
            } message: {
                Text("The sign-in process took too long. Please try again.")
            }
        }
    }
}
