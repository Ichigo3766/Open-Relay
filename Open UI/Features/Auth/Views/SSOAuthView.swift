import SwiftUI
import WebKit
import os.log

/// SSO Authentication view using WKWebView to handle OAuth/OIDC flows.
///
/// When a specific OAuth provider is selected (e.g. "google"), this view loads
/// `/oauth/{provider}/login` directly — bypassing the OpenWebUI `/auth` page and
/// taking the user straight to the provider's login screen.
///
/// For generic trusted-header SSO (no specific provider), `/auth` is loaded instead.
///
/// The view uses the **default persistent** WKWebsiteDataStore so that iCloud
/// Keychain autofill and saved passwords work correctly.
struct SSOAuthView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var ssoState = SSOWebViewState()

    /// The OAuth provider key to use (e.g. "google", "microsoft").
    /// If nil, falls back to loading the generic /auth page.
    private var provider: String? { viewModel.selectedSSOProvider }

    /// Human-readable name for the nav title.
    private var providerDisplayName: String {
        guard let provider else { return "SSO Sign In" }
        return viewModel.oauthProviders?.displayName(for: provider)
            ?? provider.capitalized
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = ssoState.error {
                errorStateView(error)
            } else {
                ZStack {
                    SSOWebViewRepresentable(
                        serverURL: viewModel.serverURL,
                        provider: provider,
                        state: $ssoState,
                        onTokenCaptured: { token in
                            Task { await viewModel.loginWithSSOToken(token) }
                        }
                    )

                    if ssoState.isLoading {
                        loadingOverlay
                    }
                }
            }
        }
        .navigationTitle("Sign in with \(providerDisplayName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    viewModel.selectedSSOProvider = nil
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    ssoState.shouldReload = true
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            theme.background.opacity(0.85)

            VStack(spacing: Spacing.md) {
                ProgressView()
                    .scaleEffect(1.2)

                Text(ssoState.tokenCaptured ? "Authenticating..." : "Loading login page...")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func errorStateView(_ error: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "exclamationmark.circle")
                .scaledFont(size: 48)
                .foregroundStyle(theme.error)

            Text("Sign In Failed")
                .scaledFont(size: 20, weight: .semibold)
                .foregroundStyle(theme.textPrimary)

            Text(error)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: Spacing.sm) {
                Button {
                    ssoState.error = nil
                    ssoState.shouldReload = true
                } label: {
                    Text("Retry")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.buttonPrimaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: TouchTarget.comfortable)
                }
                .background(theme.buttonPrimary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button))

                Button {
                    viewModel.selectedSSOProvider = nil
                    viewModel.goBack()
                } label: {
                    Text("Back")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: TouchTarget.comfortable)
                }
                .background(theme.buttonSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button))
            }
            .padding(.horizontal, Spacing.screenPadding)

            Spacer()
        }
        .padding(Spacing.screenPadding)
    }
}

// MARK: - SSO WebView State

/// Observable state for the SSO WebView flow.
@Observable
final class SSOWebViewState {
    var isLoading: Bool = true
    var tokenCaptured: Bool = false
    var error: String?
    var shouldReload: Bool = false
}

// MARK: - SSO WebView Representable

/// UIViewRepresentable wrapping WKWebView for SSO authentication.
///
/// Uses the default persistent data store so that:
/// - iCloud Keychain autofill works
/// - Saved passwords are suggested by the system
/// - Session cookies persist across reloads within this view
struct SSOWebViewRepresentable: UIViewRepresentable {
    let serverURL: String
    /// Optional OAuth provider key. When set, loads `/oauth/{provider}/login`
    /// directly instead of the generic `/auth` page.
    let provider: String?
    @Binding var state: SSOWebViewState
    let onTokenCaptured: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            state: $state,
            onTokenCaptured: onTokenCaptured,
            serverURL: serverURL,
            provider: provider
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use the default persistent data store — this is what enables
        // iCloud Keychain autofill and saved password suggestions.
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // WKUIDelegate is needed so that providers (e.g. Microsoft) that open
        // account pickers or consent screens via window.open() / target="_blank"
        // are rendered inside this same WebView rather than being silently dropped.
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Set a realistic mobile Safari user agent for maximum OAuth compatibility.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        context.coordinator.webView = webView
        context.coordinator.loadLoginPage()

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if state.shouldReload {
            state.shouldReload = false
            state.tokenCaptured = false
            state.error = nil
            state.isLoading = true
            context.coordinator.loadLoginPage()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var state: SSOWebViewState
        let onTokenCaptured: (String) -> Void
        let serverURL: String
        let provider: String?
        weak var webView: WKWebView?
        private let logger = Logger(subsystem: "com.openui", category: "SSO")
        private var captureAttemptId: Int = 0

        init(
            state: Binding<SSOWebViewState>,
            onTokenCaptured: @escaping (String) -> Void,
            serverURL: String,
            provider: String?
        ) {
            _state = state
            self.onTokenCaptured = onTokenCaptured
            self.serverURL = serverURL
            self.provider = provider
        }

        /// Builds the login URL.
        /// - If a specific provider is set, loads `/oauth/{provider}/login` directly,
        ///   skipping the OpenWebUI auth page entirely.
        /// - Falls back to `/auth` for generic trusted-header SSO.
        func loadLoginPage() {
            let path: String
            if let provider, !provider.isEmpty {
                path = "/oauth/\(provider)/login"
            } else {
                path = "/auth"
            }

            guard let url = URL(string: "\(serverURL)\(path)") else {
                state.error = "Invalid server URL"
                return
            }

            logger.info("Loading SSO login page: \(url.absoluteString)")
            webView?.load(URLRequest(url: url))
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            captureAttemptId += 1
            state.isLoading = true
            state.error = nil
            logger.debug("SSO page started: \(webView.url?.absoluteString ?? "unknown")")
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            state.isLoading = false
            logger.debug("SSO page finished: \(webView.url?.absoluteString ?? "unknown")")

            guard !state.tokenCaptured else { return }
            guard let currentURL = webView.url else { return }

            // Check for error parameters in the URL
            if let components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false),
               let error = components.queryItems?.first(where: { $0.name == "error" })?.value,
               !error.isEmpty {
                state.error = error
                return
            }

            // Only attempt token capture once we're back on our server's pages
            // (after the OAuth provider has redirected back)
            guard isOurServer(currentURL) else { return }

            let attemptId = captureAttemptId
            Task { @MainActor in
                await attemptTokenCaptureWithRetry(attemptId: attemptId)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }

            state.isLoading = false
            state.error = error.localizedDescription
            logger.error("SSO navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }

            state.isLoading = false
            state.error = error.localizedDescription
            logger.error("SSO provisional navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Proactively detect when the OAuth callback lands back on our server.
            // This fires BEFORE didFinish, giving us an early trigger point to start
            // watching for the token cookie — particularly important for Microsoft which
            // may set the cookie during the redirect chain rather than after page load.
            if isOurServer(url) && !state.tokenCaptured {
                let path = url.path.lowercased()
                // Trigger early capture on the OAuth callback path or the root page
                // (OpenWebUI redirects to / after a successful OAuth callback).
                let isCallbackOrRoot = path.contains("/oauth/") || path == "/" || path.isEmpty
                if isCallbackOrRoot {
                    let attemptId = captureAttemptId
                    logger.debug("SSO: proactive capture trigger at \(url.path)")
                    Task { @MainActor in
                        // Brief wait for cookies to be written before trying to read them
                        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                        await attemptTokenCaptureWithRetry(attemptId: attemptId)
                    }
                }
            }

            decisionHandler(.allow)
        }

        /// Response policy — inspect HTTP response headers/cookies from the server
        /// callback before the page finishes rendering. This catches token cookies
        /// that are set in the HTTP response itself.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let httpResponse = navigationResponse.response as? HTTPURLResponse,
               let url = httpResponse.url,
               isOurServer(url),
               !state.tokenCaptured {

                // Check Set-Cookie headers from the HTTP response directly
                if let allHeaders = httpResponse.allHeaderFields as? [String: String] {
                    let cookieHeaders = HTTPCookie.cookies(
                        withResponseHeaderFields: allHeaders,
                        for: url
                    )
                    for cookie in cookieHeaders {
                        if isTokenCookie(cookie) && isValidJWT(cookie.value) {
                            let token = cookie.value
                            logger.info("SSO: found token in HTTP response Set-Cookie header")
                            let attemptId = captureAttemptId
                            Task { @MainActor in
                                guard !state.tokenCaptured, attemptId == captureAttemptId else { return }
                                await handleToken(token)
                            }
                            break
                        }
                    }
                }
            }
            decisionHandler(.allow)
        }

        // MARK: - WKUIDelegate

        /// Handles window.open() / target="_blank" navigation actions.
        ///
        /// Microsoft's OAuth flow (and some other providers) open the account picker,
        /// consent screen, or MFA prompts in a new window. Without this delegate
        /// method, WKWebView silently drops those requests and the login flow appears
        /// to hang. We load the new URL in the existing WebView instead.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Load the new window's URL in the existing WebView rather than opening
            // a separate window (which WKWebView doesn't support natively).
            if let url = navigationAction.request.url {
                logger.debug("SSO: handling window.open() for \(url.absoluteString)")
                webView.load(URLRequest(url: url))
            }
            // Returning nil tells WebKit not to create a new WebView — we handled it.
            return nil
        }

        // MARK: - Token Capture

        private func isOurServer(_ url: URL) -> Bool {
            guard let serverURL = URL(string: serverURL) else { return false }
            return url.host?.lowercased() == serverURL.host?.lowercased()
        }

        /// Returns true if a cookie is a known OpenWebUI session/token cookie.
        ///
        /// OpenWebUI has used several cookie names across versions:
        /// - `token` — the original JWT bearer token cookie
        /// - `oauth_session_id` — newer session-based cookie (recent OpenWebUI versions)
        private func isTokenCookie(_ cookie: HTTPCookie) -> Bool {
            let name = cookie.name.lowercased()
            return name == "token" || name == "oauth_session_id"
        }

        /// Attempts token capture with retries to handle timing issues.
        private func attemptTokenCaptureWithRetry(
            attemptId: Int,
            maxAttempts: Int = 5
        ) async {
            for attempt in 0..<maxAttempts {
                guard !state.tokenCaptured, attemptId == captureAttemptId else { return }

                if attempt > 0 {
                    // Increasing backoff: 300ms, 600ms, 1s, 1.5s
                    let delay: UInt64 = attempt == 1 ? 300_000_000
                                     : attempt == 2 ? 600_000_000
                                     : attempt == 3 ? 1_000_000_000
                                     : 1_500_000_000
                    try? await Task.sleep(nanoseconds: delay)
                    guard !state.tokenCaptured, attemptId == captureAttemptId else { return }
                }

                if await attemptTokenCapture(attemptId: attemptId) {
                    return
                }
            }

            logger.debug("SSO: no token found after \(maxAttempts) attempts")
        }

        /// Attempts to capture the JWT token using multiple strategies in order:
        ///
        /// 1. JavaScript `document.cookie` — works for non-HttpOnly cookies
        /// 2. JavaScript `localStorage.getItem('token')` — works for JS-stored tokens
        /// 3. Native `WKHTTPCookieStore` — works for HttpOnly cookies that JS can't read
        ///    (this is the primary strategy for Microsoft OAuth and newer OpenWebUI)
        @discardableResult
        private func attemptTokenCapture(attemptId: Int) async -> Bool {
            guard let webView, !state.tokenCaptured else { return false }
            guard attemptId == captureAttemptId else { return false }

            // Strategy 1: Check token cookie via JavaScript (non-HttpOnly cookies)
            if let token = await evaluateJS(
                webView: webView,
                script: """
                (function() {
                    var cookies = document.cookie.split(";");
                    for (var i = 0; i < cookies.length; i++) {
                        var cookie = cookies[i].trim();
                        if (cookie.startsWith("token=")) {
                            return cookie.substring(6);
                        }
                    }
                    return "";
                })()
                """
            ), isValidJWT(token) {
                logger.info("SSO: found valid token in JS-readable cookie")
                await handleToken(token)
                return true
            }

            guard attemptId == captureAttemptId else { return false }

            // Strategy 2: Check localStorage (older OpenWebUI versions)
            if let token = await evaluateJS(
                webView: webView,
                script: "localStorage.getItem('token') || ''"
            ), isValidJWT(token) {
                logger.info("SSO: found valid token in localStorage")
                await handleToken(token)
                return true
            }

            guard attemptId == captureAttemptId else { return false }

            // Strategy 3: Native WKHTTPCookieStore — reads HttpOnly cookies that
            // JavaScript cannot access. This is the critical path for Microsoft OAuth
            // and any provider where OpenWebUI sets the token as an HttpOnly cookie.
            if await attemptNativeCookieCapture(attemptId: attemptId) {
                return true
            }

            return false
        }

        /// Evaluates JavaScript in the webview and returns the string result.
        private func evaluateJS(webView: WKWebView, script: String) async -> String? {
            return await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { result, error in
                    if error != nil {
                        continuation.resume(returning: nil)
                        return
                    }
                    if let str = result as? String {
                        continuation.resume(returning: str)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        /// Checks if a string looks like a valid JWT token (3 dot-separated segments).
        private func isValidJWT(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed != "null",
                  trimmed != "undefined",
                  trimmed != "false"
            else { return false }

            var cleaned = trimmed
            if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
                cleaned = String(cleaned.dropFirst().dropLast())
            }

            let segments = cleaned.split(separator: ".")
            return segments.count == 3 && cleaned.count >= 50
        }

        /// Reads session/token cookies directly from WKHTTPCookieStore.
        ///
        /// This is the primary capture method for Microsoft OAuth (and any provider
        /// where OpenWebUI sets the auth token as an HttpOnly cookie — which JS cannot
        /// access via `document.cookie`).
        ///
        /// Checks for:
        /// - `token` — original OpenWebUI JWT bearer cookie
        /// - `oauth_session_id` — newer session cookie used in recent OpenWebUI versions
        private func attemptNativeCookieCapture(attemptId: Int) async -> Bool {
            guard let webView, !state.tokenCaptured, attemptId == captureAttemptId else { return false }

            return await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    guard !self.state.tokenCaptured, attemptId == self.captureAttemptId else {
                        continuation.resume(returning: false)
                        return
                    }

                    let serverHost = URL(string: self.serverURL)?.host ?? ""

                    // Find the first matching token cookie for our server
                    let tokenCookie = cookies.first { cookie in
                        self.isTokenCookie(cookie) &&
                        !cookie.value.isEmpty &&
                        (cookie.domain.contains(serverHost) ||
                         serverHost.contains(cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain) ||
                         self.serverURL.contains(cookie.domain))
                    }

                    guard let cookie = tokenCookie else {
                        self.logger.debug("SSO: native cookie store: no matching token cookie found (checked \(cookies.count) cookies)")
                        continuation.resume(returning: false)
                        return
                    }

                    // For oauth_session_id cookies, the value may not be a JWT — it's
                    // a session identifier. Still treat it as a valid token to pass to
                    // the server's /api/v1/auths/signin endpoint. The server will
                    // exchange it for a proper user session.
                    let value = cookie.value
                    let isJWT = self.isValidJWT(value)
                    let isSessionId = cookie.name.lowercased() == "oauth_session_id" && !value.isEmpty

                    guard isJWT || isSessionId else {
                        self.logger.debug("SSO: native cookie '\(cookie.name)' found but value not a valid token")
                        continuation.resume(returning: false)
                        return
                    }

                    self.logger.info("SSO: found valid token in native WKHTTPCookieStore cookie '\(cookie.name)'")
                    Task { @MainActor in
                        await self.handleToken(value)
                    }
                    continuation.resume(returning: true)
                }
            }
        }

        /// Handles a captured SSO token.
        @MainActor
        private func handleToken(_ rawToken: String) async {
            guard !state.tokenCaptured else { return }

            var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("\"") && token.hasSuffix("\"") {
                token = String(token.dropFirst().dropLast())
            }

            state.tokenCaptured = true
            state.isLoading = true

            logger.info("SSO: handling captured token")
            onTokenCaptured(token)
        }
    }
}
