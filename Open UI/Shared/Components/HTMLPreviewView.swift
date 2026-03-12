import SwiftUI
import WebKit

// MARK: - HTML Preview View

/// Renders raw HTML content as a live preview using a sandboxed `WKWebView`.
///
/// Used by the smart code block style to replace ` ```html ` code blocks
/// with a rendered preview. Features:
/// - **Scrollable** — capped at 400pt with internal scrolling for tall content
/// - **Sandboxed** — no external network, link taps open Safari
/// - **Auto-height** — measures content and sizes up to the cap
/// - **Dark mode** — injects CSS that matches the current color scheme
/// - **Preview/Source toggle** — source view uses Highlightr syntax highlighting
/// - **Fullscreen mode** — expand to full screen for complex HTML
/// - **Copy button** — copies raw HTML to clipboard with haptic feedback
/// - **Loading indicator** — subtle spinner while the webview renders
struct HTMLPreviewView: View {
    let html: String

    /// Fixed height for all inline HTML previews. Using a consistent height
    /// prevents the jarring size variation where some previews are tiny and
    /// others are large. Content scrolls within this frame. Users can tap
    /// the fullscreen button for the complete view.
    private let previewHeight: CGFloat = 360

    @State private var showSource = false
    @State private var showFullscreen = false
    @State private var contentHeight: CGFloat = 360
    @State private var isLoading = true
    @State private var codeCopied = false

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // ── Header bar ──
            headerBar

            Divider()

            // ── Content area ──
            ZStack {
                if showSource {
                    sourceView
                        .transition(.opacity)
                } else {
                    previewView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSource)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        )
        .fullScreenCover(isPresented: $showFullscreen) {
            HTMLFullscreenView(
                html: html,
                wrappedHTML: wrappedHTML(scrollable: true),
                colorScheme: colorScheme,
                theme: theme
            )
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Language label
            Text("html")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Spacer()

            // Preview/Source toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSource.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11, weight: .medium))
                    Text(showSource ? "Preview" : "Source")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Copy button
            Button {
                UIPasteboard.general.string = html
                Haptics.notify(.success)
                withAnimation(.spring()) { codeCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation(.spring()) { codeCopied = false }
                }
            } label: {
                Group {
                    if codeCopied {
                        Label("Copied", systemImage: "checkmark")
                            .transition(.opacity.combined(with: .scale))
                    } else {
                        Label("Copy", systemImage: "square.on.square")
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)

            // Fullscreen button
            Button {
                showFullscreen = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.3))
    }

    // MARK: - Preview View (WebView)

    private var previewView: some View {
        ZStack(alignment: .center) {
            HTMLWebView(
                html: wrappedHTML(scrollable: true),
                contentHeight: $contentHeight,
                isLoading: $isLoading,
                scrollEnabled: true
            )
            .frame(height: previewHeight)

            // Loading indicator
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Source View (Syntax Highlighted)

    /// Renders the raw HTML source with Highlightr syntax highlighting.
    /// Uses `HighlightedSourceView` which is headerless — our parent
    /// view already provides the toolbar with Preview/Source/Copy/Fullscreen.
    /// Includes a footer with line count and fullscreen shortcut.
    private var sourceView: some View {
        let lineCount = html.components(separatedBy: "\n").count

        return VStack(spacing: 0) {
            HighlightedSourceView(code: html, language: "html")

            Divider()

            // Footer — line count + fullscreen shortcut
            Button {
                showFullscreen = true
                Haptics.play(.light)
            } label: {
                HStack(spacing: 6) {
                    Text("\(lineCount) lines")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Text("·")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.quaternary)

                    HStack(spacing: 3) {
                        Text("Open fullscreen")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(theme.brandPrimary)
                }
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.15))
        }
    }

    // MARK: - HTML Wrapper

    /// Wraps the user's HTML in a full document with viewport meta,
    /// dark mode CSS, and a height-reporting script.
    func wrappedHTML(scrollable: Bool) -> String {
        let isDark = colorScheme == .dark
        let bgColor = isDark ? "#1c1c1e" : "#ffffff"
        let textColor = isDark ? "#e5e5e7" : "#1c1c1e"
        let linkColor = isDark ? "#64d2ff" : "#007aff"
        let overflow = scrollable ? "auto" : "hidden"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { box-sizing: border-box; }
                html, body {
                    margin: 0;
                    padding: 4px 0;
                    background: \(bgColor);
                    color: \(textColor);
                    font-family: -apple-system, system-ui, sans-serif;
                    font-size: 14px;
                    line-height: 1.5;
                    -webkit-text-size-adjust: 100%;
                    overflow-x: auto;
                    overflow-y: \(overflow);
                    word-wrap: break-word;
                }
                a { color: \(linkColor); text-decoration: underline; }
                img { max-width: 100%; height: auto; border-radius: 8px; }
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin: 8px 0;
                }
                th, td {
                    border: 1px solid \(isDark ? "#38383a" : "#d1d1d6");
                    padding: 6px 10px;
                    text-align: left;
                    font-size: 13px;
                }
                th {
                    background: \(isDark ? "#2c2c2e" : "#f2f2f7");
                    font-weight: 600;
                }
                pre, code {
                    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                    font-size: 12px;
                    background: \(isDark ? "#2c2c2e" : "#f2f2f7");
                    border-radius: 4px;
                }
                pre {
                    padding: 10px;
                    overflow-x: auto;
                }
                code { padding: 1px 4px; }
                pre code { padding: 0; background: none; }
                hr {
                    border: none;
                    border-top: 1px solid \(isDark ? "#38383a" : "#d1d1d6");
                    margin: 12px 0;
                }
                blockquote {
                    margin: 8px 0;
                    padding: 4px 12px;
                    border-left: 3px solid \(isDark ? "#48484a" : "#c7c7cc");
                    color: \(isDark ? "#98989d" : "#8e8e93");
                }
                h1, h2, h3, h4, h5, h6 { margin: 12px 0 6px; }
                ul, ol { padding-left: 20px; }
                input[type="checkbox"] { margin-right: 6px; }
                /* Smooth scrollbar for dark mode */
                ::-webkit-scrollbar { width: 4px; }
                ::-webkit-scrollbar-track { background: transparent; }
                ::-webkit-scrollbar-thumb {
                    background: \(isDark ? "#48484a" : "#c7c7cc");
                    border-radius: 2px;
                }
            </style>
        </head>
        <body>
            \(html)
            <script>
                function reportHeight() {
                    var h = Math.ceil(document.body.scrollHeight);
                    window.webkit.messageHandlers.heightHandler.postMessage(h);
                }
                window.addEventListener('load', function() {
                    setTimeout(reportHeight, 50);
                    // Signal loading complete
                    window.webkit.messageHandlers.heightHandler.postMessage(-1);
                });
                setTimeout(reportHeight, 100);
                document.querySelectorAll('img').forEach(function(img) {
                    img.addEventListener('load', reportHeight);
                    img.addEventListener('error', reportHeight);
                });
            </script>
        </body>
        </html>
        """
    }
}

// MARK: - Fullscreen HTML View

/// A fullscreen presentation for viewing complex HTML content.
/// Provides a top toolbar with dismiss, copy, source toggle, and
/// open-in-Safari actions.
private struct HTMLFullscreenView: View {
    let html: String
    let wrappedHTML: String
    let colorScheme: ColorScheme
    let theme: AppTheme

    @State private var showSource = false
    @State private var codeCopied = false
    @State private var contentHeight: CGFloat = 1000
    @State private var isLoading = true
    @State private var shareFileURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                if showSource {
                    // Fullscreen source — full content, no truncation, fills screen
                    HighlightedSourceView(code: html, language: "html", truncate: false, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    // Fullscreen webview — scrolls freely
                    HTMLWebView(
                        html: wrappedHTML,
                        contentHeight: $contentHeight,
                        isLoading: $isLoading,
                        scrollEnabled: true
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSource)
            .navigationTitle("HTML Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Preview/Source toggle
                    Button {
                        withAnimation { showSource.toggle() }
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: showSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 14, weight: .medium))
                    }

                    // Copy
                    Button {
                        UIPasteboard.general.string = html
                        Haptics.notify(.success)
                        withAnimation(.spring()) { codeCopied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation(.spring()) { codeCopied = false }
                        }
                    } label: {
                        Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                    }

                    // Share / Open externally
                    Button {
                        shareHTML()
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
            }
            .sheet(item: $shareFileURL) { url in
                ShareSheetView(activityItems: [url])
            }
        }
    }

    /// Saves the HTML to a temp file and presents the iOS share sheet,
    /// which lets the user open in Safari, save to Files, AirDrop, etc.
    private func shareHTML() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("preview.html")
        do {
            try wrappedHTML.write(to: fileURL, atomically: true, encoding: .utf8)
            shareFileURL = fileURL
        } catch {
            UIPasteboard.general.string = html
        }
    }
}

// MARK: - WKWebView Wrapper

/// A `UIViewRepresentable` that renders HTML in a sandboxed `WKWebView`
/// and reports the content height back to SwiftUI for dynamic sizing.
private struct HTMLWebView: UIViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat
    @Binding var isLoading: Bool
    var scrollEnabled: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight, isLoading: $isLoading)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "heightHandler")

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = scrollEnabled
        webView.scrollView.bounces = scrollEnabled
        webView.scrollView.showsVerticalScrollIndicator = scrollEnabled
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false

        context.coordinator.currentWebView = webView
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.scrollView.isScrollEnabled = scrollEnabled
        webView.scrollView.bounces = scrollEnabled
        webView.scrollView.showsVerticalScrollIndicator = scrollEnabled
        // Only reload if HTML actually changed
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        @Binding var contentHeight: CGFloat
        @Binding var isLoading: Bool
        var lastHTML: String?
        weak var currentWebView: WKWebView?

        init(contentHeight: Binding<CGFloat>, isLoading: Binding<Bool>) {
            _contentHeight = contentHeight
            _isLoading = isLoading
        }

        // Receive height (or loading-complete signal) from JavaScript
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if let value = message.body as? Int {
                DispatchQueue.main.async {
                    if value == -1 {
                        // Loading complete signal
                        withAnimation(.easeOut(duration: 0.2)) {
                            self.isLoading = false
                        }
                    } else if value > 0 {
                        self.contentHeight = min(CGFloat(value), 3000)
                    }
                }
            } else if let height = message.body as? CGFloat, height > 0 {
                DispatchQueue.main.async {
                    self.contentHeight = min(height, 3000)
                }
            }
        }

        // Navigation started
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = true
            }
        }

        // Navigation finished
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // JS will send -1 signal; this is a fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if self.isLoading {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.isLoading = false
                    }
                }
            }
        }

        // Block navigation — sandboxed
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .other {
                // Allow initial HTML load
                decisionHandler(.allow)
            } else {
                // Link taps → open in Safari
                if let url = navigationAction.request.url,
                   url.scheme == "http" || url.scheme == "https" {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }
    }
}

// MARK: - Syntax-Highlighted HTML Source View

/// Renders HTML source code with Highlightr syntax highlighting.
/// Styled to match the default MarkdownView code block appearance
/// with a header bar, horizontal scroll, and copy button.
struct HTMLSourceCodeView: View {
    let code: String
    let lightTheme: String
    let darkTheme: String

    @State private var highlightedCode: AttributedString?
    @State private var codeCopied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("html")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Haptics.notify(.success)
                    withAnimation(.spring()) { codeCopied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation(.spring()) { codeCopied = false }
                    }
                } label: {
                    Group {
                        if codeCopied {
                            Label("Copied", systemImage: "checkmark")
                                .transition(.opacity.combined(with: .scale))
                        } else {
                            Label("Copy", systemImage: "square.on.square")
                                .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.quaternary.opacity(0.3))

            Divider()

            // Highlighted code
            ScrollView(.horizontal) {
                Group {
                    if let highlighted = highlightedCode {
                        Text(highlighted)
                    } else {
                        Text(code)
                            .foregroundStyle(.primary)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(4)
                .padding(16)
                .textSelection(.enabled)
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        )
        .task(id: colorScheme) {
            highlight()
        }
    }

    /// Plain text display — Highlightr removed, HTML source renders as-is.
    /// The HTML gets rendered in the WKWebView preview anyway.
    private func highlight() {
        // No syntax highlighting — just show plain monospaced text
        highlightedCode = nil
    }
}

/// Renders an `NSAttributedString` as a SwiftUI `Text` by converting
/// color attributes into `Text` segments concatenated together.
private struct HighlightedTextView: View {
    let attributedString: NSAttributedString

    var body: some View {
        textFromAttributed(attributedString)
    }

    private func textFromAttributed(_ attrStr: NSAttributedString) -> Text {
        var result = Text("")
        attrStr.enumerateAttributes(in: NSRange(location: 0, length: attrStr.length)) { attrs, range, _ in
            let substring = attrStr.attributedSubstring(from: range).string
            var segment = Text(substring)
            if let uiColor = attrs[.foregroundColor] as? UIColor {
                segment = segment.foregroundColor(Color(uiColor))
            }
            result = result + segment
        }
        return result
    }
}
