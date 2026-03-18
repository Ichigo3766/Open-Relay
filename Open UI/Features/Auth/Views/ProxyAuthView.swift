import SwiftUI
import WebKit
import os.log

// MARK: - Proxy Auth WebView

/// A WKWebView that loads the server URL and detects when the user has successfully
/// authenticated through an upstream auth proxy (Authelia, Authentik, Keycloak,
/// oauth2-proxy, Pangolin, etc.).
///
/// The view works by:
/// 1. Loading the server URL — the proxy will redirect to its login portal
/// 2. The user authenticates through whatever UI the proxy shows
/// 3. The proxy redirects back to the app's server URL
/// 4. We detect arrival back on the server domain and immediately capture cookies
///    (no health polling needed — redirect back = auth complete)
struct ProxyAuthWebView: UIViewRepresentable {
    let serverURL: String
    /// Called with all captured cookies (name→value) and the webView's User-Agent
    /// once the proxy auth is detected as complete.
    let onSuccess: ([String: String], String) -> Void
    let onFailed: () -> Void

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

        if let url = URL(string: serverURL) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        let serverURL: String
        let onSuccess: ([String: String], String) -> Void
        let onFailed: () -> Void
        weak var webView: WKWebView?

        private var timeoutTimer: Timer?
        private var didSucceed = false

        /// Tracks whether the WebView has navigated away from the server domain
        /// to the auth portal. We only trigger success detection AFTER the user
        /// has been to the proxy login page and come back.
        private var hasLeftServerDomain = false

        private let logger = Logger(subsystem: "com.openui", category: "ProxyAuth")

        init(
            serverURL: String,
            onSuccess: @escaping ([String: String], String) -> Void,
            onFailed: @escaping () -> Void
        ) {
            self.serverURL = serverURL
            self.onSuccess = onSuccess
            self.onFailed = onFailed
        }

        deinit {
            timeoutTimer?.invalidate()
        }

        // MARK: - Navigation Delegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Block all navigation once we've succeeded
            if didSucceed {
                decisionHandler(.cancel)
                return
            }

            if let url = navigationAction.request.url {
                if !isOnServerDomain(url) {
                    // We're navigating to the auth portal (Authelia, etc.)
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

            // Success condition: we previously left the server domain (went to auth portal)
            // and have now returned to the server domain. The proxy has set auth cookies.
            if hasLeftServerDomain && isOnServerDomain(currentURL) {
                logger.info("ProxyAuth: returned to server domain after auth portal — capturing cookies immediately")
                captureSessionAndSucceed()
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard !didSucceed else { return }

            // Start the 3-minute timeout on the very first navigation
            if timeoutTimer == nil {
                timeoutTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
                    guard let self, !self.didSucceed else { return }
                    self.logger.warning("ProxyAuth: timed out after 3 minutes")
                    DispatchQueue.main.async { self.onFailed() }
                }
            }

            // Also check on provisional navigation starts — this catches redirects
            // back to the server domain before the page fully loads, enabling
            // even faster dismissal.
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

            // This fires when the server sends a redirect header.
            // If we're being redirected back to the server domain, grab cookies now.
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

        // MARK: - Domain Check

        private func isOnServerDomain(_ url: URL) -> Bool {
            guard let serverHost = URL(string: serverURL)?.host?.lowercased(),
                  let currentHost = url.host?.lowercased() else { return false }
            // Match exact host or same base domain (e.g. sub.example.com vs example.com)
            return currentHost == serverHost || currentHost.hasSuffix(".\(serverHost)")
        }

        // MARK: - Cookie Capture

        private func captureSessionAndSucceed() {
            guard !didSucceed, let webView else { return }
            didSucceed = true
            timeoutTimer?.invalidate()
            timeoutTimer = nil

            logger.info("ProxyAuth: capturing cookies and completing auth")

            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
                guard let self else { return }

                // Build name→value dictionary of ALL cookies
                var cookieDict: [String: String] = [:]
                for cookie in cookies {
                    cookieDict[cookie.name] = cookie.value
                }

                self.logger.info("ProxyAuth: captured \(cookieDict.count) cookies")

                // Get the WebView User-Agent
                webView?.evaluateJavaScript("navigator.userAgent") { [weak self] ua, _ in
                    let userAgent = (ua as? String) ?? ""
                    DispatchQueue.main.async {
                        self?.onSuccess(cookieDict, userAgent)
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
/// and resumes the connection automatically.
struct ProxyAuthView: View {
    let serverURL: String
    /// Called with all captured cookies and the webView's User-Agent on success.
    let onSuccess: ([String: String], String) -> Void
    let onDismiss: () -> Void

    @State private var isWaiting = true
    @State private var didFail = false
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ProxyAuthWebView(
                    serverURL: serverURL,
                    onSuccess: { cookies, userAgent in
                        isWaiting = false
                        onSuccess(cookies, userAgent)
                    },
                    onFailed: {
                        isWaiting = false
                        didFail = true
                    }
                )
                .ignoresSafeArea(edges: .bottom)

                if isWaiting {
                    VStack(spacing: Spacing.sm) {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                                .tint(theme.brandPrimary)
                            Text("Sign in to continue — your login will be detected automatically.")
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
            .navigationTitle("Sign In")
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
