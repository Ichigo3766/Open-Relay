import SwiftUI
import WebKit
import AVFoundation

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
        // Ensure the shared audio session is active so the WebContent process inherits
        // the global baseline (.playAndRecord + .defaultToSpeaker + .mixWithOthers) set
        // at app launch. No category change here — the JS audioSessionHandler re-asserts
        // it at the moment audio actually starts.
        try? AVAudioSession.sharedInstance().setPreferredSampleRate(48000)
        try? AVAudioSession.sharedInstance().setActive(true)

        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "heightHandler")
        userController.add(context.coordinator, name: "audioSessionHandler")

        let config = WKWebViewConfiguration()
        config.userContentController = userController
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Allow inline media playback and remove gesture requirement so
        // JS-triggered audio (Web Audio API, <audio>.play()) works like a browser.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

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
            if isStreaming {
                // Reset finalized flag when streaming restarts (e.g. regeneration).
                // Without this, height updates during re-streaming fire with easeOut
                // animation because `isFinalized` was left `true` from the prior generation,
                // causing 10 animated height jumps/sec competing with the render process.
                if coord.finalized {
                    coord.finalized = false
                }
                // Throttle reconcileContent to at most once per 100ms.
                // Without this, every streamed character fires a JS bridge call
                // serializing 300+ lines of HTML into WKWebView at 60fps — the
                // dominant lag source when streaming portfolio/HTML code blocks.
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - coord.lastReconcileTime
                if elapsed >= Coordinator.reconcileThrottleInterval {
                    // Enough time has passed — fire immediately.
                    // Fix C: escape off main thread to avoid blocking the UI thread
                    // with 4× replacingOccurrences on potentially 10k+ char strings.
                    coord.lastReconcileTime = now
                    coord.pendingReconcileWorkItem?.cancel()
                    coord.pendingReconcileWorkItem = nil
                    let capturedContent = content
                    Task { @MainActor [weak webView] in
                        let escaped = await Task.detached(priority: .userInitiated) {
                            Coordinator.escape(capturedContent)
                        }.value
                        _ = try? await webView?.evaluateJavaScript("reconcileContent(`\(escaped)`)")
                    }
                } else {
                    // Too soon — buffer the latest content and schedule a flush
                    // at the throttle boundary. Any previous pending flush is
                    // cancelled so only one is ever queued at a time.
                    coord.pendingReconcileWorkItem?.cancel()
                    let capturedContent = content
                    let delay = Coordinator.reconcileThrottleInterval - elapsed
                    let workItem = DispatchWorkItem { [weak coord, weak webView] in
                        guard let coord, let webView else { return }
                        coord.lastReconcileTime = CFAbsoluteTimeGetCurrent()
                        coord.pendingReconcileWorkItem = nil
                        // Fix C: escape on this background queue item (not main thread).
                        let escaped = Coordinator.escape(capturedContent)
                        DispatchQueue.main.async {
                            webView.evaluateJavaScript("reconcileContent(`\(escaped)`)", completionHandler: nil)
                        }
                    }
                    coord.pendingReconcileWorkItem = workItem
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: workItem)
                }
            } else {
                // Streaming ended — cancel any pending throttled update and
                // finalize immediately with the complete content.
                coord.pendingReconcileWorkItem?.cancel()
                coord.pendingReconcileWorkItem = nil
                coord.finalized = true
                let escaped = escape(content)
                webView.evaluateJavaScript("finalizeContent(`\(escaped)`)", completionHandler: nil)
            }
        } else if !isStreaming, coord.shellLoaded, !coord.finalized || streamingJustEnded {
            coord.pendingReconcileWorkItem?.cancel()
            coord.pendingReconcileWorkItem = nil
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

        /// Minimum interval (seconds) between reconcileContent JS calls during streaming.
        /// 100ms = at most 10 WKWebView re-renders/sec instead of 60fps.
        static let reconcileThrottleInterval: CFAbsoluteTime = 0.1

        /// Timestamp of the last reconcileContent call (CFAbsoluteTime).
        var lastReconcileTime: CFAbsoluteTime = 0

        /// Pending throttled reconcile work item. Cancelled and replaced on every
        /// new update tick so only one deferred flush is ever queued at a time.
        var pendingReconcileWorkItem: DispatchWorkItem? = nil

        init(height: Binding<CGFloat>) {
            _height = height
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "audioSessionHandler" {
                // JS is about to create an AudioContext or play an <audio> element.
                // Re-assert the global baseline (.playAndRecord + .defaultToSpeaker + .mixWithOthers)
                // so audio plays through the silent switch, regardless of what any prior TTS/call
                // session left the category as.
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playAndRecord, mode: .default,
                                         options: [.defaultToSpeaker, .allowBluetoothHFP,
                                                   .allowBluetoothA2DP, .mixWithOthers])
                try? session.setActive(true)
                return
            }
            guard message.name == "heightHandler" else { return }
            let h: CGFloat
            if let v = message.body as? CGFloat, v > 0 { h = v }
            else if let v = message.body as? Int, v > 0 { h = CGFloat(v) }
            else if let v = message.body as? Double, v > 0 { h = CGFloat(v) }
            else { return }
            // Animate height only when content is finalized — during streaming,
            // overlapping 200ms animations at 10fps created continuous main-thread
            // animation frames competing with the WebContent render process.
            // On finalize, a single easeOut animates the settle from streaming height
            // to the final rendered height (script execution may expand the content).
            let isFinalized = self.finalized
            DispatchQueue.main.async {
                if isFinalized {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.height = min(h, 3000)
                    }
                } else {
                    self.height = min(h, 3000)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Ensure the session is active — don't change category here, rely on the
            // global baseline (.playAndRecord + .defaultToSpeaker + .mixWithOthers) set
            // at app launch. The JS audioSessionHandler re-asserts it when audio starts.
            try? AVAudioSession.sharedInstance().setActive(true)

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
            // Only intercept explicit link taps that navigate to an external http/https URL.
            // All other navigation types (reload, form submit, back/forward, JS-initiated,
            // hash fragments) are allowed so in-page interactions like "Play Again" work.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        /// Static wrapper so `webView(_:didFinish:)` can call it without capturing `self`.
        nonisolated static func escape(_ text: String) -> String {
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
          // ── navigator.audioSession: bypass hardware silent switch for WebAudio ──
          // WebKit's WebContent process manages its own internal audio pipeline that
          // does NOT inherit the host app's AVAudioSession category. Since iOS 16.3,
          // AudioContext audio is muted by the silent switch regardless of what the
          // native AVAudioSession is set to. Setting navigator.audioSession.type to
          // 'playback' is the ONLY reliable way to make WebAudio ignore the silent
          // switch inside WKWebView. (Confirmed fix per WebKit bug #251532 comment 6.)
          (function() {
            try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch(e) {}
          })();

          // ── Web Audio API quality polyfill ──
          // Forces 48kHz sample rate and adds gain envelope smoothing to
          // OscillatorNode start/stop to eliminate click/pop artifacts that
          // sound like static on small phone speakers.
          (function() {
            var _OrigAudioCtx = window.AudioContext || window.webkitAudioContext;
            if (!_OrigAudioCtx) return;

            // Patch constructor to force 48kHz sample rate and re-activate native
            // AVAudioSession(.playback) so audio plays even when silent switch is on.
            // TTS/voice-call may have left the session as .playAndRecord which respects
            // the silent switch — this message handler flips it back immediately.
            function PatchedAudioContext(opts) {
              opts = opts || {};
              if (!opts.sampleRate) opts.sampleRate = 48000;
              try { window.webkit.messageHandlers.audioSessionHandler.postMessage(1); } catch(e) {}
              return new _OrigAudioCtx(opts);
            }
            PatchedAudioContext.prototype = _OrigAudioCtx.prototype;
            Object.defineProperty(PatchedAudioContext, 'name', { value: 'AudioContext' });
            window.AudioContext = PatchedAudioContext;
            if (window.webkitAudioContext) window.webkitAudioContext = PatchedAudioContext;

            // Patch OscillatorNode.stop() to ramp gain down over 5ms before stopping
            var _origStop = OscillatorNode.prototype.stop;
            OscillatorNode.prototype.stop = function(when) {
              var ctx = this.context;
              var now = ctx.currentTime;
              var stopTime = (when && when > now) ? when : now;
              // Insert a gain node if not already wrapped
              if (!this._envGain) {
                this._envGain = ctx.createGain();
                this._envGain.gain.value = 1.0;
                // Rewire: disconnect from current destination, route through gain
                try {
                  this.disconnect();
                  this.connect(this._envGain);
                  this._envGain.connect(ctx.destination);
                } catch(e) {
                  // Already disconnected or complex routing — just stop directly
                  return _origStop.call(this, when);
                }
              }
              // Smooth ramp down over 5ms
              this._envGain.gain.setValueAtTime(1.0, stopTime);
              this._envGain.gain.linearRampToValueAtTime(0.0, stopTime + 0.005);
              _origStop.call(this, stopTime + 0.006);
            };
          })();

          // ── <audio> element silent-mode fix ──
          // Patch HTMLAudioElement.play() to re-activate native .playback session
          // so <audio> tags also play through the silent switch.
          (function() {
            var _origPlay = HTMLAudioElement.prototype.play;
            HTMLAudioElement.prototype.play = function() {
              try { window.webkit.messageHandlers.audioSessionHandler.postMessage(1); } catch(e) {}
              return _origPlay.apply(this, arguments);
            };
          })();

          // ── Height reporter ──
          // _rhFloor: minimum height that reportHeight will ever send.
          // Set to the current height before a DOM swap so the ResizeObserver
          // can't report a collapsed (near-zero) height while innerHTML is empty.
          // Cleared to 0 after the new DOM has fully painted.
          var _rhLast = 0;
          var _rhFloor = 0;
          function reportHeight() {
            var h = Math.ceil(document.body.scrollHeight);
            // Never send a height smaller than the floor set during finalization.
            if (_rhFloor > 0 && h < _rhFloor) h = _rhFloor;
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
          // Scripts are NOT executed during streaming to avoid repeat execution per token.
          // Fully-closed script pairs are stripped; if an unclosed opening tag remains,
          // content is cut before it so preceding HTML stays visible mid-stream.
          var _stripScriptPaired = /<script[\\s\\S]*?<\\/script>/gi;
          function reconcileContent(html) {
            html = extractBody(html);
            var cleaned = html.replace(_stripScriptPaired, '');
            var openIdx = cleaned.search(/<script/i);
            var trimmed = openIdx >= 0 ? cleaned.slice(0, openIdx) : cleaned;
            var safe = safeCutHTML(trimmed);
            if (!safe) return;
            document.getElementById('render').innerHTML = safe;
            scheduleHeight();
          }

          // ── Finalize: full replace + script execution ──
          // The key insight: when innerHTML is set to a new value, the browser
          // briefly empties the DOM before painting the new content. The
          // ResizeObserver fires during this gap and reports scrollHeight ≈ 0,
          // which causes Swift to shrink the WKWebView frame — producing the
          // visible "collapse and re-expand" flash.
          //
          // Fix: set _rhFloor to the current height before touching the DOM,
          // so reportHeight() clamps any transient near-zero readings to the
          // last known good height. After scripts have run and the final layout
          // is painted, _rhFloor is cleared so height can grow freely.
          function finalizeContent(html) {
            html = extractBody(html);
            var render = document.getElementById('render');

            // ── Freeze height: prevent ResizeObserver collapse flash ──
            // Capture the last-reported height as a floor. Any height report
            // while the DOM is being swapped will be clamped to this value,
            // so Swift never sees a near-zero height during the transition.
            _rhFloor = _rhLast > 0 ? _rhLast : Math.ceil(document.body.scrollHeight);

            // Patch event listeners BEFORE swapping DOM so any scripts that
            // register DOMContentLoaded/load during innerHTML assignment are caught.
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

            // Swap the DOM and re-execute scripts.
            render.innerHTML = html;

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
              // ── Unfreeze height ──
              // New DOM is fully painted. Allow _rhFloor to drop so the height
              // can shrink (e.g. final content shorter than streaming preview)
              // or grow. Use a rAF to ensure one paint has occurred first.
              requestAnimationFrame(function() {
                _rhFloor = 0;
                scheduleHeight();
                setTimeout(scheduleHeight, 120);
              });
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

// MARK: - Lazy Wrapper

/// Wraps `StreamingWebPreview` with deferred WKWebView creation.
///
/// The underlying WKWebView — and its WebContent process — is not initialized
/// until the view actually appears on screen. This prevents the main-thread
/// "stampede" that occurs when opening a chat with multiple HTML/SVG/viz blocks:
/// without this guard every WKWebView in the initial render window initializes
/// simultaneously, blocking the main thread for several hundred milliseconds.
///
/// Use `LazyStreamingWebPreview` everywhere a `StreamingWebPreview` appears
/// inside a scroll view. The caller controls the visible frame via the `height`
/// binding exactly as before — the placeholder just keeps the space reserved.
struct LazyStreamingWebPreview: View {
    let content: String
    let mode: StreamingWebRenderMode
    let isStreaming: Bool
    let isDark: Bool
    @Binding var height: CGFloat

    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible {
                StreamingWebPreview(
                    content: content,
                    mode: mode,
                    isStreaming: isStreaming,
                    isDark: isDark,
                    height: $height
                )
            } else {
                // Transparent placeholder — frame is always applied by the
                // caller using the `height` binding, so layout is stable.
                // Use .task instead of .onAppear: .task is re-triggered by
                // SwiftUI identity changes whereas .onAppear can be skipped
                // on re-insertion, which would leave the WebView permanently
                // hidden after a parent view identity change.
                Color.clear
                    .task { isVisible = true }
            }
        }
    }
}
