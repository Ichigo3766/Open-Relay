import SwiftUI
import WebKit
import os.log

private let vizLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.openui", category: "VizPipeline")

// MARK: - Notification

extension Notification.Name {
    /// Posted by `InlineVisualizerView` when the user taps "Send prompt".
    /// userInfo key `"text"` contains the prompt string.
    static let vizSendPrompt = Notification.Name("vizSendPrompt")
}

// MARK: - InlineVisualizerView

/// Renders HTML/SVG visualization content extracted from `@@@VIZ-START` / `@@@VIZ-END` markers.
///
/// Wraps the visualization HTML in a design-system shell document with:
/// - Light/dark theme variables driven by SwiftUI `colorScheme`
/// - CDN script loading for Chart.js, D3, Vega-Lite
/// - Native bridge handlers: `sendPrompt`, `openLink`, `copyText`, `toast`, `saveState`/`loadState`
/// - Auto-height reporting (same pattern as `RichUIEmbedView`)
/// - Fullscreen expand and HTML copy buttons
///
/// ## Streaming Mode
/// When `isStreaming = true`, the view accepts repeated `content` updates and
/// calls `reconcileContent(html)` via `evaluateJavaScript` to incrementally update
/// the live DOM. Full replacement happens when `isStreaming` transitions to `false`.
struct InlineVisualizerView: View {
    /// The raw HTML/SVG content to render (between the VIZ markers).
    let content: String
    /// Whether the content is still being streamed (partial content).
    var isStreaming: Bool = false
    /// Unique identifier for state persistence (message ID).
    var stateKey: String = ""

    @State private var webViewHeight: CGFloat = 1
    @State private var showFullscreen = false
    @State private var codeCopied = false
    @State private var toastMessage: String? = nil
    /// Tracks when streaming started so the timeout can fire after 30 seconds.
    @State private var streamingStartedAt: Date? = nil
    /// True once the timeout has fired — forces finalized rendering.
    @State private var timeoutFinalized: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    private let maxHeight: CGFloat = 600

    /// Effective streaming state: false once the 30-second timeout fires.
    private var effectivelyStreaming: Bool { isStreaming && !timeoutFinalized }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            vizWebView
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        )
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                toastOverlay(msg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage != nil)
        .fullScreenCover(isPresented: $showFullscreen) {
            VizFullscreenView(content: content, stateKey: stateKey, colorScheme: colorScheme)
        }
        .onAppear {
            vizLog.debug("InlineVisualizerView.onAppear: contentLen=\(content.count), isStreaming=\(isStreaming), preview=\(String(content.prefix(80)))")
            if isStreaming && streamingStartedAt == nil {
                streamingStartedAt = Date()
            }
        }
        .onChange(of: isStreaming) { _, newValue in
            if newValue {
                // Streaming (re-)started — record the start time
                streamingStartedAt = Date()
                timeoutFinalized = false
            } else {
                // Streaming ended normally — clear state
                streamingStartedAt = nil
            }
        }
        .task(id: streamingStartedAt) {
            // 30-second timeout: if still streaming after 30s, force-finalize
            // so the user isn't stuck with "processing forever".
            guard let startedAt = streamingStartedAt else { return }
            let deadline = startedAt.addingTimeInterval(30)
            let now = Date()
            let delay = deadline.timeIntervalSince(now)
            guard delay > 0 else {
                timeoutFinalized = true
                return
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if isStreaming && !timeoutFinalized {
                    timeoutFinalized = true
                }
            } catch {
                // Task cancelled (streaming ended before timeout) — no-op
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Label("Visualization", systemImage: "chart.xyaxis.line")
                .font(.system(.caption, design: .default))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Spacer()

            if effectivelyStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.secondary)
            }

            // Copy button
            Button {
                UIPasteboard.general.string = content
                Haptics.notify(.success)
                withAnimation(.spring()) { codeCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation(.spring()) { codeCopied = false }
                }
            } label: {
                Image(systemName: codeCopied ? "checkmark" : "square.on.square")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy visualization HTML")

            // Fullscreen button
            Button {
                showFullscreen = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View fullscreen")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.3))
    }

    // MARK: - Web View

    private var vizWebView: some View {
        VizWebViewRepresentable(
            content: content,
            isStreaming: effectivelyStreaming,
            isDark: colorScheme == .dark,
            stateKey: stateKey,
            height: $webViewHeight,
            onToast: { msg in
                withAnimation { toastMessage = msg }
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation { toastMessage = nil }
                }
            }
        )
        .frame(height: min(max(webViewHeight, 1), maxHeight))
    }

    // MARK: - Toast Overlay

    private func toastOverlay(_ message: String) -> some View {
        Text(message)
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.72), in: Capsule())
    }
}

// MARK: - UIViewRepresentable

private struct VizWebViewRepresentable: UIViewRepresentable {
    let content: String
    let isStreaming: Bool
    let isDark: Bool
    let stateKey: String
    @Binding var height: CGFloat
    let onToast: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, onToast: onToast)
    }

    func makeUIView(context: Context) -> WKWebView {
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "heightHandler")
        userController.add(context.coordinator, name: "vizBridge")

        let config = WKWebViewConfiguration()
        config.userContentController = userController
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.showsHorizontalScrollIndicator = true
        webView.scrollView.alwaysBounceHorizontal = true
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false

        context.coordinator.currentWebView = webView
        context.coordinator.stateKey = stateKey

        // Pre-populate state from UserDefaults before loading the shell
        let savedState = loadStateDict(for: stateKey)
        let shellHTML = buildShellHTML(
            content: content,
            isDark: isDark,
            isStreaming: isStreaming,
            savedState: savedState
        )
        context.coordinator.lastContent = content
        context.coordinator.lastIsDark = isDark
        context.coordinator.lastIsStreaming = isStreaming
        // If non-streaming, the shell already calls finalizeContent inline.
        // Mark finalized now so updateUIView doesn't call it a second time
        // after DOMContentLoaded has already fired (which would destroy working state).
        if !isStreaming {
            context.coordinator.finalized = true
        }
        webView.loadHTMLString(shellHTML, baseURL: URL(string: "https://localhost"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        let contentChanged = coord.lastContent != content
        let themeChanged  = coord.lastIsDark != isDark
        // Detect the exact frame when streaming transitions to finished.
        // This is used as a reliable trigger to call finalizeContent() regardless
        // of whether the VIZ HTML content string itself changed in this update cycle.
        let streamingJustEnded = coord.lastIsStreaming && !isStreaming
        coord.lastIsStreaming = isStreaming

        if themeChanged {
            coord.lastIsDark = isDark
            let theme = isDark ? "dark" : "light"
            webView.evaluateJavaScript("document.documentElement.setAttribute('data-theme','\(theme)')", completionHandler: nil)
        }

        if contentChanged {
            coord.lastContent = content
            if !coord.shellLoaded {
                // Shell not yet loaded — queue the update, remembering whether we're streaming.
                // If streaming just ended in this same cycle, queue as non-streaming so the
                // shell-load handler will call finalizeContent (not reconcileContent).
                coord.pendingContent = content
                coord.pendingIsStreaming = isStreaming
                vizLog.debug("InlineVisualizerView.updateUIView: shell not loaded, queuing pending (isStreaming=\(isStreaming), contentLen=\(content.count))")
                return
            }
            if isStreaming {
                // Incremental streaming update — no throttle, update immediately on every
                // content change so the visualization renders as fast as tokens arrive.
                let escaped = content
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "${", with: "\\${")
                    .replacingOccurrences(of: "</script", with: "<\\/script")
                webView.evaluateJavaScript("reconcileContent(`\(escaped)`)", completionHandler: nil)
            } else {
                // Final content — full replace with script execution.
                coord.finalized = true
                let escaped = content
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "${", with: "\\${")
                    .replacingOccurrences(of: "</script", with: "<\\/script")
                webView.evaluateJavaScript("finalizeContent(`\(escaped)`)", completionHandler: nil)
            }
        } else if !isStreaming, coord.shellLoaded, !coord.finalized || streamingJustEnded {
            // Either: content unchanged but we haven't finalized yet (e.g. shell loaded late),
            // OR: streaming just ended this frame — always re-finalize to execute scripts even
            // if the VIZ HTML bytes didn't change in this exact update cycle.
            coord.finalized = true
            let escaped = content
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")
                .replacingOccurrences(of: "</script", with: "<\\/script")
            vizLog.debug("InlineVisualizerView.updateUIView: finalizeContent via fallback (streamingJustEnded=\(streamingJustEnded), finalized=\(coord.finalized))")
            webView.evaluateJavaScript("finalizeContent(`\(escaped)`)", completionHandler: nil)
        } else if streamingJustEnded, !coord.shellLoaded {
            // Shell hasn't loaded yet but streaming just ended — make sure any pending
            // content will use finalizeContent when the shell finishes loading.
            coord.pendingIsStreaming = false
            vizLog.debug("InlineVisualizerView.updateUIView: streamingJustEnded but shell not loaded — set pendingIsStreaming=false")
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        @Binding var height: CGFloat
        let onToast: (String) -> Void
        weak var currentWebView: WKWebView?
        var lastContent: String = ""
        var lastIsDark: Bool = false
        var lastIsStreaming: Bool = true
        var pendingContent: String? = nil
        var shellLoaded: Bool = false
        var finalized: Bool = false
        var stateKey: String = ""
        /// Tracks whether pending content should be reconciled (streaming) or finalized.
        var pendingIsStreaming: Bool = false

        init(height: Binding<CGFloat>, onToast: @escaping (String) -> Void) {
            _height = height
            self.onToast = onToast
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "heightHandler" {
                if let h = message.body as? CGFloat, h > 0 {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) { self.height = min(h, 3000) }
                    }
                } else if let h = message.body as? Int {
                    if h > 0 {
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) { self.height = min(CGFloat(h), 3000) }
                        }
                    }
                }
            } else if message.name == "vizBridge" {
                handleBridge(message.body)
            }
        }

        private func handleBridge(_ body: Any) {
            guard let dict = body as? [String: Any],
                  let type = dict["type"] as? String else { return }

            switch type {
            case "sendPrompt":
                guard let text = dict["text"] as? String, !text.isEmpty else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .vizSendPrompt,
                        object: nil,
                        userInfo: ["text": text]
                    )
                }

            case "openLink":
                guard let urlString = dict["url"] as? String,
                      let url = URL(string: urlString),
                      url.scheme == "http" || url.scheme == "https" else { return }
                DispatchQueue.main.async {
                    UIApplication.shared.open(url)
                }

            case "copyText":
                guard let text = dict["text"] as? String else { return }
                DispatchQueue.main.async {
                    UIPasteboard.general.string = text
                    Haptics.notify(.success)
                    self.onToast("Copied!")
                }

            case "toast":
                guard let msg = dict["msg"] as? String else { return }
                DispatchQueue.main.async { self.onToast(msg) }

            case "saveState":
                guard let key = dict["key"] as? String else { return }
                let value = dict["value"]
                let storeKey = "viz_state_\(stateKey)_\(key)"
                if let v = value as? String {
                    UserDefaults.standard.set(v, forKey: storeKey)
                } else if let v = value as? Bool {
                    UserDefaults.standard.set(v, forKey: storeKey)
                } else if let v = value as? Double {
                    UserDefaults.standard.set(v, forKey: storeKey)
                } else if let v = value,
                          JSONSerialization.isValidJSONObject(v),
                          let data = try? JSONSerialization.data(withJSONObject: v),
                          let jsonStr = String(data: data, encoding: .utf8) {
                    // Objects/arrays arrive as JSON string (serialized by JS before postMessage)
                    // but defensively also handle if they arrive as native objects.
                    UserDefaults.standard.set(jsonStr, forKey: storeKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: storeKey)
                }

            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.shellLoaded = true
                vizLog.debug("InlineVisualizerView: shell didFinish — pendingContent=\(self.pendingContent != nil), pendingIsStreaming=\(self.pendingIsStreaming)")
                if let pending = self.pendingContent {
                    self.pendingContent = nil
                    let escaped = pending
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "`", with: "\\`")
                        .replacingOccurrences(of: "${", with: "\\${")
                        .replacingOccurrences(of: "</script", with: "<\\/script")
                    // Use reconcileContent for streaming pending content, finalizeContent otherwise.
                    // Previously this always called finalizeContent — which meant streaming content
                    // was immediately finalized (scripts run, layout locked) even before @@@VIZ-END
                    // arrived, preventing incremental reconcileContent calls from updating the DOM.
                    let jsCall = self.pendingIsStreaming
                        ? "reconcileContent(`\(escaped)`)"
                        : "finalizeContent(`\(escaped)`)"
                    vizLog.debug("InlineVisualizerView: executing pending \(self.pendingIsStreaming ? "reconcileContent" : "finalizeContent"), contentLen=\(pending.count)")
                    webView.evaluateJavaScript(jsCall, completionHandler: nil)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                if let url = navigationAction.request.url,
                   url.scheme == "http" || url.scheme == "https" {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }
    }

    // MARK: - State Helpers

    private func loadStateDict(for key: String) -> [String: String] {
        guard !key.isEmpty else { return [:] }
        let prefix = "viz_state_\(key)_"
        var result: [String: String] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                let shortKey = String(k.dropFirst(prefix.count))
                if let str = v as? String {
                    result[shortKey] = str
                } else if let num = v as? Double {
                    result[shortKey] = String(num)
                } else if let b = v as? Bool {
                    result[shortKey] = b ? "true" : "false"
                }
            }
        }
        return result
    }

    // MARK: - Shell HTML Builder

    private func buildShellHTML(
        content: String,
        isDark: Bool,
        isStreaming: Bool,
        savedState: [String: String]
    ) -> String {
        let theme = isDark ? "dark" : "light"
        let bg    = isDark ? "#1c1c1e" : "#ffffff"
        let fg    = isDark ? "#e5e5e7" : "#1c1c1e"
        let link  = isDark ? "#64d2ff" : "#007aff"
        let muted = isDark ? "#636366" : "#8e8e93"
        let border = isDark ? "#38383a" : "#d1d1d6"
        let surface = isDark ? "#2c2c2e" : "#f2f2f7"

        // Build preloaded state JS
        let stateEntries = savedState.map { k, v -> String in
            let ek = k.replacingOccurrences(of: "\"", with: "\\\"")
            let ev = v.replacingOccurrences(of: "\"", with: "\\\"")
            return "    \"\(ek)\": \"\(ev)\""
        }.joined(separator: ",\n")
        let stateJS = stateEntries.isEmpty ? "window._ivState = {};" : "window._ivState = {\n\(stateEntries)\n};"

        // Escape content for injection into JS template literal.
        // </script> must be escaped as <\/script to prevent the HTML parser from
        // closing the enclosing <script> block prematurely when VIZ content
        // contains inline <script> tags (e.g. Kanban boards, interactive charts).
        let escapedContent = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
            .replacingOccurrences(of: "</script", with: "<\\/script")

        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0">
          <style>
            /* ── Reset ── */
            *, *::before, *::after { box-sizing: border-box; }
            html, body {
              margin: 0;
              padding: 0;
              background: \(bg);
              color: \(fg);
              font-family: -apple-system, system-ui, sans-serif;
              font-size: 14px;
              line-height: 1.5;
              -webkit-text-size-adjust: 100%;
              overflow-x: auto;
              overflow-y: auto;
              word-wrap: break-word;
            }
            a { color: \(link); text-decoration: underline; }
            img { max-width: 100%; height: auto; border-radius: 8px; }
            table { border-collapse: collapse; width: 100%; margin: 8px 0; }
            th, td { border: 1px solid \(border); padding: 6px 10px; text-align: left; font-size: 13px; }
            th { background: \(surface); font-weight: 600; }
            pre, code {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              font-size: 12px;
              background: \(surface);
              border-radius: 4px;
            }
            pre { padding: 10px; overflow-x: auto; }
            code { padding: 1px 4px; }
            pre code { padding: 0; background: none; }
            hr { border: none; border-top: 1px solid \(border); margin: 12px 0; }
            blockquote { margin: 8px 0; padding: 4px 12px; border-left: 3px solid \(border); color: \(muted); }
            h1, h2, h3, h4, h5, h6 { margin: 12px 0 6px; }
            ul, ol { padding-left: 20px; }
            input[type="checkbox"] { margin-right: 6px; }
            svg { max-width: 100%; }
            ::-webkit-scrollbar { width: 4px; }
            ::-webkit-scrollbar-track { background: transparent; }
            ::-webkit-scrollbar-thumb { background: \(border); border-radius: 2px; }

            /* ── Theme variables (for visualization CSS that references var(--bg)) ── */
            [data-theme="dark"] {
              --bg: #1c1c1e; --fg: #e5e5e7; --muted: #636366;
              --surface: #2c2c2e; --border: #38383a; --link: #64d2ff;
              --brand: #0a84ff; --success: #34c759; --warning: #ff9f0a; --error: #ff453a;
            }
            [data-theme="light"] {
              --bg: #ffffff; --fg: #1c1c1e; --muted: #8e8e93;
              --surface: #f2f2f7; --border: #d1d1d6; --link: #007aff;
              --brand: #007aff; --success: #34c759; --warning: #ff9500; --error: #ff3b30;
            }

            /* ── Render container ── */
            #iv-render { min-height: 1px; padding: 12px; }
          </style>
        </head>
        <body>
          <div id="iv-render"></div>

          <script>
          // ── Preloaded state ──
          \(stateJS)

          // ── Height reporter ──
          function reportHeight() {
            var h = Math.ceil(document.body.scrollHeight);
            if (h > 0) window.webkit.messageHandlers.heightHandler.postMessage(h);
          }
          var _reportFrame = null;
          function scheduleReport() {
            if (_reportFrame) cancelAnimationFrame(_reportFrame);
            _reportFrame = requestAnimationFrame(reportHeight);
          }
          new ResizeObserver(scheduleReport).observe(document.body);
          window.addEventListener('load', scheduleReport);

          // ── Native bridge ──
          window.vizBridge = {
            sendPrompt: function(text) {
              window.webkit.messageHandlers.vizBridge.postMessage({ type: 'sendPrompt', text: text });
            },
            openLink: function(url) {
              window.webkit.messageHandlers.vizBridge.postMessage({ type: 'openLink', url: url });
            },
            copyText: function(text) {
              window.webkit.messageHandlers.vizBridge.postMessage({ type: 'copyText', text: text });
            },
            toast: function(msg, kind) {
              window.webkit.messageHandlers.vizBridge.postMessage({ type: 'toast', msg: msg, kind: kind || 'info' });
            },
            saveState: function(key, value) {
              // Serialize objects/arrays to JSON string so the Swift handler can store them
              var v = (value !== null && typeof value === 'object') ? JSON.stringify(value) : value;
              window.webkit.messageHandlers.vizBridge.postMessage({ type: 'saveState', key: key, value: v });
            },
            loadState: function(key, fallback) {
              if (!window._ivState.hasOwnProperty(key)) return fallback !== undefined ? fallback : null;
              var raw = window._ivState[key];
              // Attempt to deserialize JSON objects/arrays that were saved as strings
              try { return JSON.parse(raw); } catch(e) { return raw; }
            }
          };

          // ── Global aliases so VIZ content can call bridge functions without the vizBridge prefix ──
          var sendPrompt = function(text) { window.vizBridge.sendPrompt(text); };
          var openLink   = function(url)  { window.vizBridge.openLink(url); };
          var copyText   = function(text) { window.vizBridge.copyText(text); };
          var toast      = function(msg, kind) { window.vizBridge.toast(msg, kind); };
          var saveState  = function(key, value) { window.vizBridge.saveState(key, value); };
          var loadState  = function(key, fallback) { return window.vizBridge.loadState(key, fallback); };

          // ── Safe-cut: return the longest valid HTML prefix ──
          function safeCutHTML(html) {
            // Walk backwards to find the last complete tag or text boundary
            var stack = 0;
            var lastSafe = 0;
            var inTag = false;
            for (var i = 0; i < html.length; i++) {
              var c = html[i];
              if (c === '<') { inTag = true; stack = i; }
              else if (c === '>' && inTag) { inTag = false; lastSafe = i + 1; }
              else if (!inTag) { lastSafe = i + 1; }
            }
            return html.slice(0, inTag ? stack : lastSafe);
          }

          // ── Extract body content from a full HTML document (strips <!DOCTYPE>, <html>, <head>, <body> wrappers) ──
          // Preserves <style> and <script> blocks from <head> so user CSS and CDN
          // library imports (e.g. Chart.js, D3, Three.js) still apply.
          // Head scripts are placed before body content so CDN libs load first.
          function extractVizBody(html) {
            var styles = '';
            var headScripts = '';
            var headMatch = html.match(/<head[^>]*>([\\s\\S]*?)<\\/head>/i);
            if (headMatch) {
              var styleMatches = headMatch[1].match(/<style[\\s\\S]*?<\\/style>/gi);
              if (styleMatches) styles = styleMatches.join('\\n');
              var scriptMatches = headMatch[1].match(/<script[\\s\\S]*?<\\/script>/gi);
              if (scriptMatches) headScripts = scriptMatches.join('\\n');
            }
            var bodyMatch = html.match(/<body[^>]*>([\\s\\S]*)<\\/body>/i);
            if (bodyMatch) return styles + headScripts + bodyMatch[1];
            // No <body> tag — return as-is (plain fragment)
            return html;
          }

          // ── Reconcile: incremental DOM update during streaming ──
          function reconcileContent(html) {
            var safe = safeCutHTML(html);
            if (!safe) return;
            var render = document.getElementById('iv-render');
            // Simple approach: set innerHTML for streaming (content is partial)
            render.innerHTML = extractVizBody(safe);
            scheduleReport();
          }

          // ── Finalize: full content replacement + script execution ──
          function finalizeContent(html) {
            html = extractVizBody(html);
            var render = document.getElementById('iv-render');
            render.innerHTML = html;

            // Monkey-patch addEventListener before re-executing scripts so that VIZ code
            // registering 'DOMContentLoaded' or 'load' listeners gets called immediately —
            // those events already fired on the shell document before finalizeContent runs.
            var _origDocAdd = document.addEventListener.bind(document);
            var _origWinAdd = window.addEventListener.bind(window);
            var _deferredCallbacks = [];
            document.addEventListener = function(type, fn, opts) {
              if (type === 'DOMContentLoaded') { _deferredCallbacks.push(fn); }
              else { _origDocAdd(type, fn, opts); }
            };
            window.addEventListener = function(type, fn, opts) {
              if (type === 'DOMContentLoaded' || type === 'load') { _deferredCallbacks.push(fn); }
              else { _origWinAdd(type, fn, opts); }
            };

            // Re-execute any inline scripts
            var scripts = render.querySelectorAll('script');
            var chain = Promise.resolve();
            scripts.forEach(function(oldScript) {
              chain = chain.then(function() {
                return new Promise(function(resolve) {
                  var newScript = document.createElement('script');
                  if (oldScript.src) {
                    newScript.src = oldScript.src;
                    newScript.onload = resolve;
                    newScript.onerror = resolve;
                  } else {
                    newScript.textContent = oldScript.textContent;
                    resolve();
                  }
                  oldScript.parentNode.replaceChild(newScript, oldScript);
                });
              });
            });
            chain.then(function() {
              // Restore original addEventListener before firing deferred callbacks
              document.addEventListener = _origDocAdd;
              window.addEventListener = _origWinAdd;
              // Invoke all deferred DOMContentLoaded/load handlers now
              _deferredCallbacks.forEach(function(fn) {
                try { fn({ type: 'DOMContentLoaded', target: document }); } catch(e) {}
              });
              scheduleReport();
            });
          }

          // ── Initial load ──
          \(isStreaming ? "reconcileContent(`\(escapedContent)`);" : "finalizeContent(`\(escapedContent)`);")
          </script>
        </body>
        </html>
        """
    }
}

// MARK: - Fullscreen Visualizer

private struct VizFullscreenView: View {
    let content: String
    let stateKey: String
    let colorScheme: ColorScheme

    @State private var webViewHeight: CGFloat = 1000
    @State private var codeCopied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VizWebViewRepresentable(
                content: content,
                isStreaming: false,
                isDark: colorScheme == .dark,
                stateKey: stateKey,
                height: $webViewHeight,
                onToast: { _ in }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Visualization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = content
                        Haptics.notify(.success)
                        withAnimation(.spring()) { codeCopied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation(.spring()) { codeCopied = false }
                        }
                    } label: {
                        Image(systemName: codeCopied ? "checkmark" : "square.on.square")
                    }
                }
            }
        }
    }
}
