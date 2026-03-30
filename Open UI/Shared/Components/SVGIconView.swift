import SwiftUI
import WebKit

/// Renders an inline SVG string as a small icon using a lightweight WKWebView.
/// Used for action button icons that come as SVG data URIs from the server.
///
/// The SVG is rendered at the native size with `currentColor` set to the
/// current theme's text tertiary color (via CSS `color` property).
struct SVGIconView: UIViewRepresentable {
    let svgString: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false

        // Wrap the SVG in minimal HTML that:
        // 1. Sets currentColor to match the app's text color
        // 2. Centers the SVG
        // 3. Uses the viewport meta tag for proper sizing
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        * { margin: 0; padding: 0; }
        body {
            display: flex;
            align-items: center;
            justify-content: center;
            width: 100vw;
            height: 100vh;
            background: transparent;
            color: rgba(255,255,255,0.5);
        }
        @media (prefers-color-scheme: light) {
            body { color: rgba(0,0,0,0.4); }
        }
        svg {
            width: 16px;
            height: 16px;
        }
        </style>
        </head>
        <body>\(svgString)</body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
