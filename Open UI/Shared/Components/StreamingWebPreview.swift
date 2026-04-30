import SwiftUI
import WebKit

// MARK: - Render Mode

/// Determines how `StreamingWebPreview` interprets and renders partial content.
enum StreamingWebRenderMode {
    /// Raw HTML — incremental innerHTML during streaming, full replace + script exec on finalize.
    case html
    /// SVG markup — wrapped in a container div; browser renders SVG elements progressively.
    case svg
}

// MARK: - StreamingWebPreview

/// A `UIViewRepresentable` WKWebView that supports live incremental content updates
/// during token streaming, then finalizes (executes scripts, resolves layout) when
/// the code fence closes.
///
/// ## How it works
/// 1. `makeUIView` loads a lightweight shell HTML document once.
///    The shell contains CSS theme variables, a height reporter, and
///    `reconcileContent` / `finalizeContent` JavaScript functions.
/// 2. While `isStreaming == true`, each content change calls
///    `reconcileContent(escaped)` via `evaluateJavaScript` — this does a
///    safe-cut innerHTML set without a page reload, so the view updates
///    token-by-token with zero flicker.
/// 3. When `isStreaming` flips to `false` (closing ``` fence arrived),
///    `finalizeContent(escaped)` is called — full replace + inline script execution.
///
/// ## Backward compatibility
/// Callers that never set `isStreaming = true` behave identically to `HTMLWebView`:
/// `makeUIView` immediately calls `finalizeContent` via the shell's inline script.
struct StreamingWebPreview: UIViewRepresentable {
    let content: String
    let mode: StreamingWebRenderMode
    let isStreaming: Bool
    let isDark: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeUIView(context: Context) -> WKWebView {
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "heightHandler")

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
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false

        context.coordinator.currentWebView = webView
        context.coordinator.lastIsStreaming = isStreaming
        if !isStreaming {
            context.coordinator.finalized = true
        }

        let escaped = escape(content)
        let initialCall = isStreaming
            ? "reconcileContent(`\(escaped)`);"
            : "finalizeContent(`\(escaped)`);"

        context.coordinator.lastContent = content
        context.coordinator.lastIsDark = isDark

        // Use a non-null baseURL so localStorage / sessionStorage work correctly.
        // With baseURL:nil the WKWebView runs in a "null" origin, which causes
        // localStorage.setItem() to throw a SecurityError — breaking any app
        // that relies on it (e.g. a Kanban board persisting its layout).
        webView.loadHTMLString(buildShell(initialCall: initialCall), baseURL: URL(string: "https://localhost"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        let contentChanged = coord.lastContent != content
        let themeChanged = coord.lastIsDark != isDark
        let streamingJustEnded = coord.lastIsStreaming && !isStreaming
        coord.lastIsStreaming = isStreaming

        if themeChanged {
            coord.lastIsDark = isDark
            let theme = isDark ? "dark" : "light"
            webView.evaluateJavaScript(
                "document.documentElement.setAttribute('data-theme','\(theme)')",
                completionHandler: nil
            )
        }

        if contentChanged {
            coord.lastContent = content
            guard coord.shellLoaded else {
                coord.pendingContent = content
                coord.pendingIsStreaming = isStreaming
                return
            }
            let escaped = escape(content)
            if isStreaming {
                webView.evaluateJavaScript("reconcileContent(`\(escaped)`)", completionHandler: nil)
            } else {
                coord.finalized = true
                webView.evaluateJavaScript("finalizeContent(`\(escaped)`)", completionHandler: nil)
            }
        } else if !isStreaming, coord.shellLoaded, !coord.finalized || streamingJustEnded {
            coord.finalized = true
            let escaped = escape(content)
            webView.evaluateJavaScript("finalizeContent(`\(escaped)`)", completionHandler: nil)
        } else if streamingJustEnded, !coord.shellLoaded {
            coord.pendingIsStreaming = false
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        @Binding var height: CGFloat
        weak var currentWebView: WKWebView?
        var lastContent: String = ""
        var lastIsDark: Bool = false
        var lastIsStreaming: Bool = false
        var pendingContent: String? = nil
        var pendingIsStreaming: Bool = false
        var shellLoaded: Bool = false
        var finalized: Bool = false

        init(height: Binding<CGFloat>) {
            _height = height
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "heightHandler" else { return }
            let h: CGFloat
            if let v = message.body as? CGFloat, v > 0 { h = v }
            else if let v = message.body as? Int, v > 0 { h = CGFloat(v) }
            else if let v = message.body as? Double, v > 0 { h = CGFloat(v) }
            else { return }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.height = min(h, 3000)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.shellLoaded = true
                if let pending = self.pendingContent {
                    self.pendingContent = nil
                    let escaped = Self.escape(pending)
                    let js = self.pendingIsStreaming
                        ? "reconcileContent(`\(escaped)`)"
                        : "finalizeContent(`\(escaped)`)"
                    webView.evaluateJavaScript(js, completionHandler: nil)
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

        /// Static wrapper so `webView(_:didFinish:)` can call it without capturing `self`.
        static func escape(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")
                .replacingOccurrences(of: "</script", with: "<\\/script")
        }
    }

    // MARK: - Helpers

    private func escape(_ text: String) -> String {
        Coordinator.escape(text)
    }

    // MARK: - Shell HTML Builder

    private func buildShell(initialCall: String) -> String {
        let theme = isDark ? "dark" : "light"
        let bg    = isDark ? "#1c1c1e" : "#ffffff"
        let fg    = isDark ? "#e5e5e7" : "#1c1c1e"
        let link  = isDark ? "#64d2ff" : "#007aff"
        let border = isDark ? "#38383a" : "#d1d1d6"
        let surface = isDark ? "#2c2c2e" : "#f2f2f7"
        let muted  = isDark ? "#636366" : "#8e8e93"

        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0">
          <style>
            *, *::before, *::after { box-sizing: border-box; }
            html, body {
              margin: 0; padding: 4px 0;
              background: \(bg); color: \(fg);
              font-family: -apple-system, system-ui, sans-serif;
              font-size: 14px; line-height: 1.5;
              -webkit-text-size-adjust: 100%;
              overflow-x: auto; overflow-y: auto;
              word-wrap: break-word;
            }
            a { color: \(link); text-decoration: underline; }
            img { max-width: 100%; height: auto; border-radius: 8px; }
            table { border-collapse: collapse; width: 100%; margin: 8px 0; }
            th, td { border: 1px solid \(border); padding: 6px 10px; text-align: left; font-size: 13px; }
            th { background: \(surface); font-weight: 600; }
            pre, code {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              font-size: 12px; background: \(surface); border-radius: 4px;
            }
            pre { padding: 10px; overflow-x: auto; }
            code { padding: 1px 4px; }
            pre code { padding: 0; background: none; }
            hr { border: none; border-top: 1px solid \(border); margin: 12px 0; }
            blockquote {
              margin: 8px 0; padding: 4px 12px;
              border-left: 3px solid \(border); color: \(muted);
            }
            h1, h2, h3, h4, h5, h6 { margin: 12px 0 6px; }
            ul, ol { padding-left: 20px; }
            svg { max-width: 100%; }
            ::-webkit-scrollbar { width: 4px; }
            ::-webkit-scrollbar-track { background: transparent; }
            ::-webkit-scrollbar-thumb { background: \(border); border-radius: 2px; }
            [data-theme="dark"] {
              --bg: #1c1c1e; --fg: #e5e5e7; --muted: #636366;
              --surface: #2c2c2e; --border: #38383a; --link: #64d2ff;
            }
            [data-theme="light"] {
              --bg: #ffffff; --fg: #1c1c1e; --muted: #8e8e93;
              --surface: #f2f2f7; --border: #d1d1d6; --link: #007aff;
            }
            #render { min-height: 1px; }
          </style>
        </head>
        <body>
          <div id="render"></div>
          <script>
          // ── Height reporter ──
          var _rhLast = 0;
          function reportHeight() {
            var h = Math.ceil(document.body.scrollHeight);
            if (h > 0 && h !== _rhLast) {
              _rhLast = h;
              window.webkit.messageHandlers.heightHandler.postMessage(h);
            }
          }
          var _rhRaf = 0;
          function scheduleHeight() {
            cancelAnimationFrame(_rhRaf);
            _rhRaf = requestAnimationFrame(reportHeight);
          }
          new ResizeObserver(scheduleHeight).observe(document.body);
          window.addEventListener('load', scheduleHeight);

          // ── Safe HTML cut: returns longest prefix where parser is outside a tag ──
          function safeCutHTML(html) {
            var lastSafe = 0;
            var inTag = false;
            var tagStart = 0;
            for (var i = 0; i < html.length; i++) {
              var c = html.charCodeAt(i);
              if (c === 60 /* < */ && !inTag) {
                inTag = true; tagStart = i;
              } else if (c === 62 /* > */ && inTag) {
                inTag = false; lastSafe = i + 1;
              } else if (!inTag) {
                lastSafe = i + 1;
              }
            }
            return html.slice(0, inTag ? tagStart : lastSafe);
          }

          // ── Extract renderable body from a full HTML document ──
          // Preserves <style> and <script> blocks from <head> so user CSS and CDN
          // library imports (e.g. Chart.js, D3, Three.js) still apply.
          // Head scripts are placed before body content so CDN libs load first.
          function extractBody(html) {
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
            // No <body> tag — strip only outer doc-level wrapper tags, keep everything else
            return html.replace(/<!DOCTYPE[^>]*>|<\\/?(?:html|head|body)[^>]*>/gi, '');
          }

          // ── Reconcile: incremental update during streaming ──
          // Scripts are intentionally NOT executed — avoids repeat execution on every token.
          var _stripScriptPaired = /<script[\\s\\S]*?<\\/script>/gi;
          var _stripScriptOpen   = /<script[\\s\\S]*$/i;
          function reconcileContent(html) {
            html = extractBody(html);
            var safe = safeCutHTML(
              html.replace(_stripScriptPaired, '').replace(_stripScriptOpen, '')
            );
            if (!safe) return;
            document.getElementById('render').innerHTML = safe;
            scheduleHeight();
          }

          // ── Finalize: full replace + script execution ──
          function finalizeContent(html) {
            html = extractBody(html);
            var render = document.getElementById('render');
            render.innerHTML = html;

            // Monkey-patch listeners so DOMContentLoaded/load handlers in VIZ scripts fire now
            var _origDocAdd = document.addEventListener.bind(document);
            var _origWinAdd = window.addEventListener.bind(window);
            var _deferred = [];
            document.addEventListener = function(type, fn, opts) {
              if (type === 'DOMContentLoaded') { _deferred.push(fn); }
              else { _origDocAdd(type, fn, opts); }
            };
            window.addEventListener = function(type, fn, opts) {
              if (type === 'DOMContentLoaded' || type === 'load') { _deferred.push(fn); }
              else { _origWinAdd(type, fn, opts); }
            };

            // Re-execute inline / external scripts in order
            var scripts = render.querySelectorAll('script');
            var chain = Promise.resolve();
            scripts.forEach(function(old) {
              chain = chain.then(function() {
                return new Promise(function(resolve) {
                  var s = document.createElement('script');
                  if (old.src) {
                    s.src = old.src;
                    s.onload = resolve; s.onerror = resolve;
                  } else {
                    s.textContent = old.textContent;
                    resolve();
                  }
                  old.parentNode.replaceChild(s, old);
                });
              });
            });
            chain.then(function() {
              document.addEventListener = _origDocAdd;
              window.addEventListener = _origWinAdd;
              _deferred.forEach(function(fn) {
                try { fn({ type: 'DOMContentLoaded', target: document }); } catch(e) {}
              });
              scheduleHeight();
              setTimeout(scheduleHeight, 120);
            });
          }

          // ── Initial render ──
          \(initialCall)
          </script>
        </body>
        </html>
        """
    }
}
