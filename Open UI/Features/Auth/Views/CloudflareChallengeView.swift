import SwiftUI
import WebKit

// MARK: - Cloudflare Challenge WebView

/// A WKWebView that loads the server URL so the user can complete the Cloudflare
/// Bot Fight Mode / Browser Integrity Check challenge. Once Cloudflare issues a
/// `cf_clearance` cookie the view detects it, extracts the cookie value AND the
/// browser's User-Agent (Cloudflare ties the clearance to the UA that solved it),
/// then calls `onClearance(cookieValue, userAgent)`.
struct CloudflareChallengeWebView: UIViewRepresentable {
    let serverURL: String
    /// Called with (cfClearanceValue, webViewUserAgent, expiryDate) when the challenge is solved.
    /// All three values must be forwarded to URLSession so Cloudflare accepts the cookie.
    /// `expiryDate` may be nil if the cookie has no explicit expiry.
    let onClearance: (String, String, Date?) -> Void
    let onFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClearance: onClearance, onFailed: onFailed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // Clear ALL existing WKWebView cookies before starting the challenge.
        // Stale/expired cf_clearance cookies from previous sessions would be
        // detected immediately and used without completing a fresh challenge,
        // resulting in 500 errors when Cloudflare rejects the expired token.
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            // After clearing, load the challenge page fresh
            if let url = URL(string: serverURL) {
                webView.load(URLRequest(url: url))
            }
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onClearance: (String, String, Date?) -> Void
        let onFailed: () -> Void
        weak var webView: WKWebView?

        private var pollTimer: Timer?
        private var timeoutTimer: Timer?
        private var didSucceed = false

        init(onClearance: @escaping (String, String, Date?) -> Void, onFailed: @escaping () -> Void) {
            self.onClearance = onClearance
            self.onFailed = onFailed
        }

        deinit {
            pollTimer?.invalidate()
            timeoutTimer?.invalidate()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkForClearanceCookie()
            startPolling()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
        }

        /// Block navigation once clearance is obtained so we don't load the full app in the sheet.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if didSucceed {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func startPolling() {
            guard !didSucceed else { return }
            pollTimer?.invalidate()

            if timeoutTimer == nil || !(timeoutTimer?.isValid ?? false) {
                timeoutTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
                    guard let self, !self.didSucceed else { return }
                    self.pollTimer?.invalidate()
                    DispatchQueue.main.async { self.onFailed() }
                }
            }

            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkForClearanceCookie()
            }
        }

        private func checkForClearanceCookie() {
            guard !didSucceed, let webView else { return }

            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
                guard let self, !self.didSucceed else { return }

                guard let clearanceCookie = cookies.first(where: { $0.name == "cf_clearance" }) else {
                    return
                }

                self.didSucceed = true
                self.pollTimer?.invalidate()
                self.timeoutTimer?.invalidate()

                let clearanceValue = clearanceCookie.value
                // Extract the expiry date so we can persist the cookie across app restarts.
                // Without an explicit expiry, HTTPCookieStorage treats it as a session cookie
                // that vanishes when the app is terminated.
                let expiryDate = clearanceCookie.expiresDate

                // Extract the WKWebView User-Agent via JavaScript.
                // Cloudflare BINDS cf_clearance to the User-Agent that solved the challenge.
                // If URLSession sends a different UA (e.g. CFNetwork/...), Cloudflare will
                // re-challenge. We must send the exact same UA with every subsequent request.
                webView?.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
                    let userAgent = (result as? String) ?? ""

                    // Clear other WKWebView session cookies so OpenWebUI login state
                    // from the WKWebView doesn't bleed into the app's URLSession.
                    let cookieStore = WKWebsiteDataStore.default().httpCookieStore
                    cookieStore.getAllCookies { allCookies in
                        for cookie in allCookies where cookie.name != "cf_clearance" {
                            cookieStore.delete(cookie)
                        }
                    }

                    DispatchQueue.main.async {
                        self?.onClearance(clearanceValue, userAgent, expiryDate)
                    }
                }
            }
        }
    }
}

// MARK: - Cloudflare Challenge Sheet View

/// Full-screen sheet shown when the server is behind a Cloudflare Bot Fight Mode check.
/// Presents a WKWebView so the user can complete the "Just a moment…" challenge,
/// then automatically dismisses when `cf_clearance` is obtained.
struct CloudflareChallengeView: View {
    let serverURL: String
    /// Called with (cfClearanceValue, userAgent, expiryDate).
    let onClearance: (String, String, Date?) -> Void
    let onDismiss: () -> Void

    @State private var isWaiting = true
    @State private var didFail = false
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                CloudflareChallengeWebView(
                    serverURL: serverURL,
                    onClearance: { cookie, userAgent, expiry in
                        isWaiting = false
                        onClearance(cookie, userAgent, expiry)
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
                            Text("Complete the security check to continue…")
                                .font(AppTypography.captionFont)
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
            .navigationTitle("Security Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
            .alert("Verification Timed Out", isPresented: $didFail) {
                Button("Try Again") {
                    didFail = false
                    isWaiting = true
                }
                Button("Cancel", role: .cancel) {
                    onDismiss()
                }
            } message: {
                Text("The Cloudflare security check took too long. Please try again or check your server settings.")
            }
        }
    }
}
