import Foundation
import WebKit
import OSLog

// MARK: - Result

struct ActionJSDownload {
    let filename: String
    let data: Data
    let mimeType: String
}

// MARK: - ActionJSExecutor

/// Lazily creates a hidden 1×1 WKWebView to execute action-button JavaScript.
/// A download-interception shim overrides `URL.createObjectURL`, `saveAs`,
/// `window.open`, and `<a>.click()` so any file download the JS tries to
/// trigger is captured and returned to Swift instead of opening in a browser.
@MainActor
final class ActionJSExecutor: NSObject {

    // MARK: - Singleton

    static let shared = ActionJSExecutor()

    // MARK: - State

    private var webView: WKWebView?
    private var messageHandlerProxy: WeakActionHandlerProxy?
    private var pendingContinuation: CheckedContinuation<ActionJSDownload?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.openui", category: "ActionJSExecutor")

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Executes `code` inside a hidden WKWebView loaded at `baseURL`.
    /// Returns the first file download the JS triggers, or `nil` on timeout.
    func execute(code: String, baseURL: URL, timeout: TimeInterval = 30) async -> ActionJSDownload? {
        let wv = webViewReady()
        logger.info("🟢 [ActionJS] execute: baseURL=\(baseURL, privacy: .public) codeLen=\(code.count, privacy: .public)")

        // Load a blank page at the server origin so fetch/XHR same-origin rules are satisfied
        let blankHTML = "<!DOCTYPE html><html><body></body></html>"
        wv.loadHTMLString(blankHTML, baseURL: baseURL)

        // Small settle delay so the page and shim are fully loaded before running code
        try? await Task.sleep(nanoseconds: 200_000_000)

        return await withCheckedContinuation { continuation in
            self.pendingContinuation = continuation

            // Timeout guard
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.logger.warning("⏱ [ActionJS] timeout after \(timeout, privacy: .public)s")
                self.resolve(nil)
            }

            // Inject shim + user code together
            let fullScript = self.shimJS + "\n" + code
            wv.evaluateJavaScript(fullScript) { [weak self] _, error in
                if let error {
                    self?.logger.error("❌ [ActionJS] evaluateJavaScript error: \(error.localizedDescription, privacy: .public)")
                    self?.resolve(nil)
                }
                // Success result arrives via postMessage → userContentController
            }
        }
    }

    // MARK: - Lazy Setup

    private func webViewReady() -> WKWebView {
        if let existing = webView { return existing }
        logger.info("🟢 [ActionJS] creating hidden WKWebView (lazy)")

        let proxy = WeakActionHandlerProxy(target: self)
        messageHandlerProxy = proxy

        let controller = WKUserContentController()
        controller.add(proxy, name: "actionDownload")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.isHidden = true
        wv.navigationDelegate = self
        self.webView = wv

        attachToWindow(wv)
        return wv
    }

    private func attachToWindow(_ wv: WKWebView) {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        let window = windowScene?.windows.first(where: { $0.isKeyWindow }) ?? windowScene?.windows.first
        window?.addSubview(wv)
        window?.sendSubviewToBack(wv)
    }

    // MARK: - Resolution

    fileprivate func resolve(_ result: ActionJSDownload?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let c = pendingContinuation
        pendingContinuation = nil
        c?.resume(returning: result)
    }

    // MARK: - Download Interception Shim

    /// Injected before user code runs. Overrides all common browser download
    /// mechanisms and posts the captured data to Swift via the message handler.
    private var shimJS: String {
        """
        (function() {
          if (window.__actionShimInstalled) return;
          window.__actionShimInstalled = true;

          function postDownload(filename, base64, mimeType) {
            window.webkit.messageHandlers.actionDownload.postMessage({
              filename: filename || 'download',
              base64: base64,
              mimeType: mimeType || 'application/octet-stream'
            });
          }

          // 1. Intercept <a download> clicks (covers FileSaver.js saveAs)
          var _origCreateObjURL = URL.createObjectURL.bind(URL);
          var _blobMap = {};
          URL.createObjectURL = function(blob) {
            var fakeURL = 'blob:intercepted/' + Math.random().toString(36).slice(2);
            _blobMap[fakeURL] = blob;
            return fakeURL;
          };

          var _origClick = HTMLAnchorElement.prototype.click;
          HTMLAnchorElement.prototype.click = function() {
            var href = this.href || '';
            var download = this.download || 'download';
            var blob = _blobMap[href];
            if (blob) {
              var reader = new FileReader();
              reader.onloadend = function() {
                var b64 = reader.result.split(',')[1] || '';
                postDownload(download, b64, blob.type);
              };
              reader.readAsDataURL(blob);
              return;
            }
            _origClick.call(this);
          };

          // Also intercept document.createElement('a') + .click() flow
          var _origCreateElement = document.createElement.bind(document);
          document.createElement = function(tag) {
            var el = _origCreateElement(tag);
            if (tag.toLowerCase() === 'a') {
              var _elClick = el.click.bind(el);
              el.click = function() {
                var href = el.href || '';
                var download = el.download || 'download';
                var blob = _blobMap[href];
                if (blob) {
                  var reader = new FileReader();
                  reader.onloadend = function() {
                    var b64 = reader.result.split(',')[1] || '';
                    postDownload(download, b64, blob.type);
                  };
                  reader.readAsDataURL(blob);
                  return;
                }
                _elClick();
              };
            }
            return el;
          };

          // 2. FileSaver saveAs global override
          window.saveAs = function(blob, filename) {
            var reader = new FileReader();
            reader.onloadend = function() {
              var b64 = reader.result.split(',')[1] || '';
              postDownload(filename || 'download', b64, blob.type);
            };
            reader.readAsDataURL(blob);
          };

          // 3. window.open override (some scripts open a data: URI)
          var _origWindowOpen = window.open.bind(window);
          window.open = function(url, target, features) {
            if (typeof url === 'string' && url.startsWith('data:')) {
              var parts = url.match(/^data:([^;]+);base64,(.+)$/s);
              if (parts) {
                var mime = parts[1];
                var b64 = parts[2];
                var ext = mime.split('/')[1] || 'bin';
                postDownload('download.' + ext, b64, mime);
                return null;
              }
            }
            return _origWindowOpen(url, target, features);
          };

          // 4. Direct base64 variable pattern:
          //    If code sets `const base64 = "..."` and later does nothing with it,
          //    we wrap the whole script result check at the end.
          //    This is handled via a MutationObserver-free sentinel approach:
          //    after a tick we check window.__base64Result.
          setTimeout(function() {
            var b64 = window.base64 || window.__base64;
            var fname = window.fileName || window.filename || 'export';
            if (b64 && typeof b64 === 'string' && b64.length > 0) {
              var ext = fname.includes('.') ? '' : '.pdf';
              postDownload(fname + ext, b64, 'application/pdf');
            }
          }, 500);
        })();
        """
    }
}

// MARK: - WKScriptMessageHandler

extension ActionJSExecutor: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor [weak self] in
            let messageName = message.name
            let messageBody = message.body
            guard messageName == "actionDownload",
                  let body = messageBody as? [String: Any],
                  let filename = body["filename"] as? String,
                  let base64 = body["base64"] as? String,
                  let data = Data(base64Encoded: base64)
            else {
                self?.logger.warning("⚠️ [ActionJS] malformed message from JS: \(String(describing: message.body), privacy: .public)")
                return
            }
            let mime = body["mimeType"] as? String ?? "application/octet-stream"
            let download = ActionJSDownload(filename: filename, data: data, mimeType: mime)
            self?.logger.info("✅ [ActionJS] download intercepted: \(filename, privacy: .public) \(data.count, privacy: .public) bytes")
            self?.resolve(download)
        }
    }
}

// MARK: - WKNavigationDelegate

extension ActionJSExecutor: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.logger.error("❌ [ActionJS] navigation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.logger.error("❌ [ActionJS] provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Weak Proxy

private final class WeakActionHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var target: ActionJSExecutor?
    init(target: ActionJSExecutor) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
