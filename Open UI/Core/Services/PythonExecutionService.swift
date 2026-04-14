import Foundation
import WebKit
import os.log

// MARK: - Python Execution Result

struct PythonExecutionResult {
    enum Status {
        case success
        case error
    }
    let status: Status
    let stdout: String
    let stderr: String
    /// Base64-encoded PNG images captured from matplotlib/plt.show()
    let images: [String]
}

// MARK: - Python Execution Service

/// Runs Python code locally on-device using Pyodide (CPython compiled to WebAssembly),
/// executing inside a hidden WKWebView sandbox.
///
/// ## Architecture
/// A single hidden WKWebView is kept alive for the app's lifetime. On first use,
/// Pyodide is loaded from CDN (~10MB, cached by WebKit's HTTP cache after the first
/// download). Subsequent runs reuse the warm interpreter — fast, stateful.
///
/// ## Security
/// - Runs in WebKit's sandboxed JS engine — no access to the file system or device APIs
/// - App Store safe: WebAssembly is explicitly allowed by Apple (WKWebView)
///
/// ## What works
/// - Pure Python: math, dataclasses, itertools, functools, collections, re, json, etc.
/// - Numeric: numpy, pandas, sympy, scipy (pre-compiled WASM in Pyodide)
/// - Plotting: matplotlib — `plt.show()` is intercepted and returns a base64 PNG
///
/// ## What doesn't work
/// - C extensions not included in Pyodide's wheel set
/// - `open()` / file I/O (sandboxed)
@MainActor
final class PythonExecutionService: NSObject {

    // MARK: - Singleton

    static let shared = PythonExecutionService()

    // MARK: - State

    enum EngineState {
        case notLoaded
        case loading
        case ready
        case error(String)
    }

    private(set) var engineState: EngineState = .notLoaded
    private var webView: WKWebView?
    /// Weak message handler proxy to break the WKUserContentController retain cycle.
    private var messageHandlerProxy: WeakMessageHandlerProxy?
    private var pendingExecutions: [(code: String, completion: (PythonExecutionResult) -> Void)] = []
    private var runCompletion: ((PythonExecutionResult) -> Void)?
    private var isRunning = false
    private let logger = Logger(subsystem: "com.openui", category: "PythonExecution")

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Pre-warms the Pyodide engine in the background. Call this when the user
    /// opens a chat that has Python code blocks so the first "Run" is instant.
    func prewarm() {
        guard case .notLoaded = engineState else { return }
        setupWebView()
    }

    /// Executes the given Python code string and returns the result via completion.
    /// Thread-safe: always called on MainActor.
    func execute(code: String, completion: @escaping (PythonExecutionResult) -> Void) {
        // Ensure engine is loaded
        if case .notLoaded = engineState {
            setupWebView()
        }

        switch engineState {
        case .ready:
            runCode(code, completion: completion)
        case .loading:
            // Queue until ready
            pendingExecutions.append((code: code, completion: completion))
        case .error(let msg):
            completion(PythonExecutionResult(
                status: .error,
                stdout: "",
                stderr: "Pyodide failed to load: \(msg)",
                images: []
            ))
        case .notLoaded:
            // setupWebView was just called, now loading
            pendingExecutions.append((code: code, completion: completion))
        }
    }

    // MARK: - Engine Setup

    private func setupWebView() {
        engineState = .loading

        // Use a weak proxy to break WKUserContentController's strong retain cycle
        let proxy = WeakMessageHandlerProxy(target: self)
        self.messageHandlerProxy = proxy

        let controller = WKUserContentController()
        controller.add(proxy, name: "pyodideBridge")

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.isHidden = true
        wv.navigationDelegate = self
        self.webView = wv

        // CRITICAL: WKWebView must be attached to a window to execute JS reliably on iOS.
        // We attach it to the key window as a 1×1 hidden subview.
        attachToWindow(wv)

        // Load Pyodide bootstrap HTML
        wv.loadHTMLString(bootstrapHTML, baseURL: URL(string: "https://localhost"))
    }

    /// Attaches the WKWebView to the app's key window so JS execution works reliably.
    private func attachToWindow(_ wv: WKWebView) {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        let window = windowScene?.windows.first(where: { $0.isKeyWindow })
            ?? windowScene?.windows.first
        window?.addSubview(wv)
        window?.sendSubviewToBack(wv)
    }

    // MARK: - Code Execution

    private func runCode(_ code: String, completion: @escaping (PythonExecutionResult) -> Void) {
        guard !isRunning else {
            // Serial queue — retry after a short delay
            pendingExecutions.append((code: code, completion: completion))
            return
        }

        isRunning = true
        runCompletion = completion

        // Escape the code safely via JSON encoding
        let jsonEncoded: String
        if let data = try? JSONEncoder().encode(code),
           let str = String(data: data, encoding: .utf8) {
            jsonEncoded = str
        } else {
            // Fallback: manual escape
            jsonEncoded = "\"" + code
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                + "\""
        }

        let js = "runPython(\(jsonEncoded)); undefined;"
        webView?.evaluateJavaScript(js) { [weak self] _, error in
            if let error {
                guard let self else { return }
                self.isRunning = false
                let completion = self.runCompletion
                self.runCompletion = nil
                completion?(PythonExecutionResult(
                    status: .error,
                    stdout: "",
                    stderr: error.localizedDescription,
                    images: []
                ))
                self.drainPending()
            }
            // Success result will arrive via postMessage bridge
        }
    }

    /// Drains the next pending execution if any.
    private func drainPending() {
        guard !isRunning, !pendingExecutions.isEmpty else { return }
        let next = pendingExecutions.removeFirst()
        if case .ready = engineState {
            runCode(next.code, completion: next.completion)
        } else if case .error(let msg) = engineState {
            next.completion(PythonExecutionResult(
                status: .error, stdout: "", stderr: "Pyodide failed to load: \(msg)", images: []
            ))
            drainPending()
        }
    }

    // MARK: - Bootstrap HTML

    /// The HTML page that loads Pyodide and sets up the execution bridge.
    private var bootstrapHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <script>
            // ── Pyodide load ──────────────────────────────────────────────────
            async function loadPyodideEngine() {
              try {
                const script = document.createElement('script');
                script.src = 'https://cdn.jsdelivr.net/pyodide/v0.27.0/full/pyodide.js';
                document.head.appendChild(script);
                await new Promise((resolve, reject) => {
                  script.onload = resolve;
                  script.onerror = () => reject(new Error('Failed to load Pyodide script'));
                });

                window._pyodide = await loadPyodide({
                  indexURL: 'https://cdn.jsdelivr.net/pyodide/v0.27.0/full/',
                });

                // Pre-load common scientific packages (they're bundled in Pyodide)
                await window._pyodide.loadPackagesFromImports(`
        import numpy
        import pandas
        import matplotlib
        import sympy
        `).catch(() => {}); // ignore if not available

                // Set up matplotlib backend to capture figures as base64 PNG
                window._pyodide.runPython(`
        import matplotlib
        matplotlib.use('AGG')
        import matplotlib.pyplot as plt
        import io, base64, json, sys
        _captured_images = []
        _orig_show = plt.show

        def _intercept_show(*args, **kwargs):
            buf = io.BytesIO()
            plt.savefig(buf, format='png', bbox_inches='tight', dpi=100)
            buf.seek(0)
            img_b64 = base64.b64encode(buf.read()).decode('utf-8')
            _captured_images.append(img_b64)
            buf.close()
            plt.close()

        plt.show = _intercept_show
        `);

                window.webkit.messageHandlers.pyodideBridge.postMessage({
                  type: 'ready'
                });
              } catch (e) {
                window.webkit.messageHandlers.pyodideBridge.postMessage({
                  type: 'loadError',
                  error: e.message || String(e)
                });
              }
            }

            // ── Run Python ────────────────────────────────────────────────────
            async function runPython(code) {
              const py = window._pyodide;
              if (!py) {
                window.webkit.messageHandlers.pyodideBridge.postMessage({
                  type: 'result',
                  status: 'error',
                  stdout: '',
                  stderr: 'Pyodide not loaded yet',
                  images: []
                });
                return;
              }

              // Capture stdout/stderr
              let stdoutBuf = '';
              let stderrBuf = '';

              py.runPython(`
        import sys, io
        _stdout_capture = io.StringIO()
        _stderr_capture = io.StringIO()
        sys.stdout = _stdout_capture
        sys.stderr = _stderr_capture
        _captured_images.clear()
        `);

              let status = 'success';
              try {
                await py.runPythonAsync(code);
              } catch (e) {
                status = 'error';
                // Append JS-side error to stderr capture
                try {
                  py.runPython(`
        import sys
        sys.stderr.write(${JSON.stringify(e.message || String(e))})
        `);
                } catch (_) {}
              }

              try {
                stdoutBuf = py.runPython('_stdout_capture.getvalue()') || '';
                stderrBuf = py.runPython('_stderr_capture.getvalue()') || '';
                const imagesJson = py.runPython('json.dumps(_captured_images)') || '[]';
                const images = JSON.parse(imagesJson);

                // Restore real stdout/stderr
                py.runPython(`
        sys.stdout = sys.__stdout__
        sys.stderr = sys.__stderr__
        `);

                window.webkit.messageHandlers.pyodideBridge.postMessage({
                  type: 'result',
                  status: status,
                  stdout: stdoutBuf,
                  stderr: stderrBuf,
                  images: images
                });
              } catch (e) {
                window.webkit.messageHandlers.pyodideBridge.postMessage({
                  type: 'result',
                  status: 'error',
                  stdout: stdoutBuf,
                  stderr: e.message || String(e),
                  images: []
                });
              }
            }

            // Start loading immediately when DOM is ready
            window.addEventListener('DOMContentLoaded', loadPyodideEngine);
          </script>
        </head>
        <body></body>
        </html>
        """
    }
}

// MARK: - Weak Proxy (breaks WKUserContentController retain cycle)

/// WKUserContentController retains its message handlers strongly.
/// This proxy holds a weak reference to the actual handler, breaking the cycle
/// so the WKWebView and PythonExecutionService can be deallocated normally.
private final class WeakMessageHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var target: (NSObject & WKScriptMessageHandler)?

    init(target: NSObject & WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - WKScriptMessageHandler

extension PythonExecutionService: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "pyodideBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }

        switch type {
        case "ready":
            logger.info("Pyodide engine ready")
            engineState = .ready
            // Drain all pending executions
            let pending = pendingExecutions
            pendingExecutions.removeAll()
            for item in pending {
                runCode(item.code, completion: item.completion)
            }

        case "loadError":
            let errMsg = body["error"] as? String ?? "Unknown error"
            logger.error("Pyodide load error: \(errMsg)")
            engineState = .error(errMsg)
            // Fail all pending
            let pending = pendingExecutions
            pendingExecutions.removeAll()
            for item in pending {
                item.completion(PythonExecutionResult(
                    status: .error, stdout: "", stderr: "Pyodide failed to load: \(errMsg)", images: []
                ))
            }
            // Fail current run if any
            if let completion = runCompletion {
                isRunning = false
                runCompletion = nil
                completion(PythonExecutionResult(
                    status: .error, stdout: "", stderr: "Pyodide failed to load: \(errMsg)", images: []
                ))
            }

        case "result":
            isRunning = false
            let statusStr = body["status"] as? String ?? "error"
            let stdout = body["stdout"] as? String ?? ""
            let stderr = body["stderr"] as? String ?? ""
            let images = body["images"] as? [String] ?? []

            let result = PythonExecutionResult(
                status: statusStr == "success" ? .success : .error,
                stdout: stdout,
                stderr: stderr,
                images: images
            )

            let completion = runCompletion
            runCompletion = nil
            completion?(result)

            // Run next queued execution if any
            drainPending()

        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension PythonExecutionService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.logger.error("WebView navigation failed: \(error.localizedDescription)")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.logger.error("WebView provisional navigation failed: \(error.localizedDescription)")
        }
    }
}
