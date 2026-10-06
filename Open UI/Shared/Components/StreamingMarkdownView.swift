import UIKit
import SwiftUI
import MarkdownView
import MarkdownParser
import Charts
import Photos
import os.log

// MARK: - Photos Permission Helper

/// Requests `.addOnly` Photos authorization if needed, then saves the image.
/// On first call the system permission prompt appears automatically.
/// If the user previously denied access, `onDenied` is called on the main thread
/// so the caller can show an alert directing them to Settings.
func saveImageWithPermission(_ image: UIImage, onDenied: @escaping () -> Void) {
    let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    switch current {
    case .authorized, .limited:
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    case .notDetermined:
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                if status == .authorized || status == .limited {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                } else {
                    onDenied()
                }
            }
        }
    case .denied, .restricted:
        DispatchQueue.main.async { onDenied() }
    @unknown default:
        DispatchQueue.main.async { onDenied() }
    }
}

/// Opens the app's page in the iOS Settings app so the user can grant Photos access.
func openPhotosSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}

// MARK: - Streaming Markdown View

/// Renders markdown using MarkdownView (UIKit-backed).
///
/// Streaming and completed content use the same segment hierarchy so the
/// existing text view survives completion.
struct StreamingMarkdownView: View {
    let content: String
    let isStreaming: Bool
    let textColor: SwiftUI.Color?

    @Environment(\.accessibilityScale) private var accessibilityScale

    /// Base body font size used by MarkdownTheme.default (UIFont.preferredFont(.body)).
    /// We scale relative to this so the user's content text scale applies correctly.
    private static let baseBodyFontSize: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize

    // Bug 16: scaledTheme was recomputed on every render (N times per frame for N segments).
    // Cache it as @State and only rebuild when accessibilityScale or textColor changes.
    @State private var cachedTheme: MarkdownTheme = MarkdownTheme.default

    // B4 fix: Cache resolveSegments / parseSpecialBlocks output via a
    // reference-type cache. Mutating a class property during body evaluation
    // is safe — SwiftUI only tracks @State/@Observable value changes, not
    // internal class mutations. This eliminates the O(N) parseCodeBlocks()
    // call that was firing on every drain tick (60fps) once a code block's
    // closing fence had arrived in the displayed content.
    @State private var segmentCache = SegmentCache()

    /// Reference-type segment parse cache. Keyed by (content, isStreaming).
    /// A cache miss triggers parseSpecialBlocks(); a hit returns the stored
    /// result in O(1) via Swift COW pointer equality on the content string.
    private final class SegmentCache {
        // parseSpecialBlocks cache
        var content: String = ""
        var isStreaming: Bool = false
        var segments: [ContentSegment] = []
    }


    init(content: String, isStreaming: Bool, textColor: SwiftUI.Color? = nil) {
        self.content = content
        self.isStreaming = isStreaming
        self.textColor = textColor
    }

    var body: some View {
        unifiedBody
            .transaction { $0.animation = nil }
            .onAppear {
                rebuildThemeIfNeeded()
            }
            .onChange(of: accessibilityScale.scale(for: .content)) { _, _ in rebuildThemeIfNeeded() }
            .onChange(of: textColor) { _, _ in rebuildThemeIfNeeded() }
    }

    // Bug 16: builds a MarkdownTheme only when the inputs actually change.
    private func rebuildThemeIfNeeded() {
        let scale = accessibilityScale.scale(for: .content)
        var theme = MarkdownTheme.default
        if abs(scale - 1.0) > 0.01 {
            theme.align(to: Self.baseBodyFontSize * scale)
        }
        if let swiftUIColor = textColor {
            let uiColor = UIColor(swiftUIColor)
            theme.colors.body = uiColor
            theme.colors.code = uiColor
        }
        cachedTheme = theme
    }

    // MARK: - Unified Body
    //
    // A single render path is used for both streaming and final states.
    // Keeping the same VStack+ForEach structure throughout ensures that
    // WKWebView-backed previews (HTML, SVG, Mermaid) keep a stable identity in
    // the SwiftUI view tree across the streaming→final transition, so the web
    // view is never destroyed and recreated (which caused a visible flash).

    @ViewBuilder
    private var unifiedBody: some View {
        // Cap the entire content area to prevent WKWebView-backed blocks (SVG, HTML, code)
        // from reporting a wider intrinsic size than the visible viewport. Without this cap,
        // a wide SVG or code block causes the ScrollView content to be wider than the screen,
        // which stretches the entire chat layout (navbar, messages, input bar) on smaller
        // devices such as iPhone 12 Pro. UIViewRepresentable views ignore SwiftUI's .frame()
        // from parent containers, but respect it when applied to their own output — so this
        // constraint here is what actually propagates the width budget into WKWebView.
        //
        // The value matches ChatMessageBubble.assistantContent's maxContentWidth so the
        // two caps are in sync and neither exceeds the screen width.
        let maxContentWidth = UIScreen.main.bounds.width - (Spacing.screenPadding * 2)
        if content.isBlank {
            EmptyView()
        } else {
            // resolveSegments() is cheap: plain prose short-circuits, and
            // <details> blocks are split out upstream by ToolCallParser.
            let segments: [ContentSegment] = resolveSegments()
            if segments.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Use stable type-based IDs so SwiftUI updates each segment
                    // in-place rather than destroying and recreating it when the
                    // segments array grows (e.g. prose → prose + streamingCode).
                    // With offset-based IDs, every new segment insertion shifts
                    // all subsequent offsets, invalidating @State measuredHeight
                    // in each nested MarkdownView and causing a frame-of-collapse.
                    ForEach(segments) { segment in
                        segmentView(for: segment)
                    }
                }
                // Cap the multi-segment VStack so WKWebView-backed blocks (SVG, HTML,
                // code) can never report a width wider than the visible viewport.
                // UIViewRepresentable width constraints are honoured when the .frame
                // is applied at this level — they propagate down into the UIKit layout.
                .frame(maxWidth: maxContentWidth)
            }
        }
    }

    /// During streaming, strips any incomplete `![alt](data:image/...` data URI from
    /// the display string so raw Base64 characters never appear in the chat.
    ///
    /// Handles all image formats (`png`, `jpeg`, `gif`, `webp`, `svg+xml`, etc.) because
    /// the match prefix is `data:image/` — format-agnostic.
    ///
    /// **Rules:**
    /// - Incomplete URI (opening `![` found, no matching closing `)` yet) → strip
    ///   everything from that `![` to end of string so nothing appears until the
    ///   full URI has arrived.
    /// - Complete URI → leave intact; `findMarkdownImages` decodes + renders it.
    private static func stripIncompleteDataURIs(_ text: String) -> String {
        // Fast-exit: if no data URI marker exists, nothing to do.
        guard let dataRange = text.range(of: "](data:image/") else { return text }

        // Walk backwards from the `](data:image/` to find the corresponding `![`.
        // We need the `![` that immediately precedes this `](`.
        let beforeBracket = text[text.startIndex..<dataRange.lowerBound]
        guard let imgOpenRange = beforeBracket.range(of: "![", options: .backwards) else { return text }

        // Now scan forward from the data URI opening to find the closing `)`.
        let afterDataStart = text[dataRange.lowerBound...]
        if afterDataStart.last == ")" || afterDataStart.contains(")") {
            // Closing `)` exists — the URI is complete. Leave it alone.
            return text
        }

        // No closing `)` yet — the URI is still streaming in. Strip from `![` to end.
        let cleanedUpToHere = String(text[text.startIndex..<imgOpenRange.lowerBound])
        return cleanedUpToHere.trimmingCharacters(in: .newlines)
    }

    /// Resolves the current content into renderable segments (cached per
    /// content + streaming state).
    private func resolveSegments() -> [ContentSegment] {
        // Plain prose (the common case while streaming) has no image or fence
        // syntax; every parser below would return one markdown segment.
        // Skip the regexes and line splits run on each update.
        if !Self.mayContainSpecialBlocks(content) {
            return [.markdown(content, index: 0)]
        }
        // When streaming, hide any Base64 data URI that hasn't fully arrived yet.
        // The raw base64 payload is stripped from display until the closing `)` lands
        // and `findMarkdownImages` can decode + render the complete image.
        let content = isStreaming ? Self.stripIncompleteDataURIs(self.content) : self.content
        // Non-streaming content never changes after first render — the cache
        // ensures parseSpecialBlocks runs exactly once per message lifetime.
        return cachedParseSpecialBlocks(content, isStreaming: isStreaming)
    }

    /// One allocation-free pass: true if `text` contains `![` (image) or a
    /// backtick pair (code fence). False means the text is plain
    /// Markdown that `parseSpecialBlocks` would return unchanged as one segment.
    private static func mayContainSpecialBlocks(_ text: String) -> Bool {
        var previous: UInt8 = 0
        for byte in text.utf8 {
            switch (previous, byte) {
            case (0x21, 0x5B), (0x60, 0x60): return true // "![", "``"
            default: previous = byte
            }
        }
        return false
    }

    /// Returns cached parseSpecialBlocks result when content+isStreaming unchanged,
    /// otherwise re-parses and stores the result. O(1) on cache hit.
    private func cachedParseSpecialBlocks(_ content: String, isStreaming: Bool) -> [ContentSegment] {
        if segmentCache.content == content && segmentCache.isStreaming == isStreaming {
            return segmentCache.segments
        }
        let result = parseSpecialBlocks(content)
        segmentCache.content = content
        segmentCache.isStreaming = isStreaming
        segmentCache.segments = result
        return result
    }

    /// Returns the SwiftUI view for a single content segment.
    @ViewBuilder
    private func segmentView(for segment: ContentSegment) -> some View {
        switch segment.kind {
        case .markdown(let text):
            if !text.isBlank {
                StableStreamingMarkdown(text: text, isStreaming: isStreaming, theme: cachedTheme)
            }
        case .chart(let code, let streaming):
            ChartPreviewView(
                spec: tryParseChart(code: code),
                rawCode: code,
                language: "json",
                isStreaming: streaming
            )
        case .html(let code, let streaming):
            HTMLPreviewView(html: code, isStreaming: streaming)
        case .mermaid(let code, let streaming):
            MermaidPreviewView(code: code, isStreaming: streaming)
        case .svg(let code, let streaming):
            SVGPreviewView(code: code, isStreaming: streaming)
        case .python(let code):
            PythonCodeBlockView(code: code)
        case .markdownImage(let imageURL, let altText, let linkURL):
            MarkdownInlineImageView(imageURL: imageURL, altText: altText, linkURL: linkURL)
        }
    }

    // MARK: - Special Block Detection (final render only)

    private let chartLanguageTags: Set<String> = [
        "json", "chart", "chartjs", "echarts", "highcharts",
        "vega-lite", "vegalite", "plotly"
    ]

    private let pythonLanguageTags: Set<String> = ["python", "python3", "py"]

    /// A single renderable slice of message content.
    ///
    /// ## Stable Identity
    /// `id` is a type-qualified position string (e.g. `"markdown-0"`, `"code-1"`,
    /// `"html-0"`). This keeps SwiftUI's ForEach identity stable when the last
    /// segment grows (streaming append) or when a new segment is appended at the
    /// end — existing views are updated in-place rather than destroyed/recreated.
    /// Offset-only IDs (`id: \.offset`) caused @State measuredHeight resets in
    /// nested MarkdownView instances on every segment-count change, producing
    /// a frame-of-collapsed-height visual glitch.
    private struct ContentSegment: Identifiable {
        enum Kind {
            case markdown(String)
            /// `isStreaming` — true while the closing ``` fence has not yet arrived.
            case chart(String, isStreaming: Bool)
            /// `isStreaming` — true while the closing ``` fence has not yet arrived.
            case html(String, isStreaming: Bool)
            /// `isStreaming` — true while the closing ``` fence has not yet arrived.
            case mermaid(String, isStreaming: Bool)
            /// `isStreaming` — true while the closing ``` fence has not yet arrived.
            case svg(String, isStreaming: Bool)
            case python(String)
            case markdownImage(imageURL: URL, altText: String, linkURL: URL?)

            /// Short type tag used in the stable `id`.
            var typeTag: String {
                switch self {
                case .markdown:      return "md"
                case .chart:         return "chart"
                case .html:          return "html"
                case .mermaid:       return "mermaid"
                case .svg:           return "svg"
                case .python:        return "python"
                case .markdownImage: return "img"
                }
            }
        }

        let id: String
        let kind: Kind

        // Convenience factory methods mirror the old enum cases for minimal call-site changes.
        static func markdown(_ text: String, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "md-\(index)", kind: .markdown(text))
        }
        static func chart(_ code: String, isStreaming: Bool, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "chart-\(index)", kind: .chart(code, isStreaming: isStreaming))
        }
        static func html(_ code: String, isStreaming: Bool, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "html-\(index)", kind: .html(code, isStreaming: isStreaming))
        }
        static func mermaid(_ code: String, isStreaming: Bool, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "mermaid-\(index)", kind: .mermaid(code, isStreaming: isStreaming))
        }
        static func svg(_ code: String, isStreaming: Bool, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "svg-\(index)", kind: .svg(code, isStreaming: isStreaming))
        }
        static func python(_ code: String, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "python-\(index)", kind: .python(code))
        }
        static func markdownImage(imageURL: URL, altText: String, linkURL: URL?, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "img-\(index)", kind: .markdownImage(imageURL: imageURL, altText: altText, linkURL: linkURL))
        }
    }

    // MARK: - Markdown Image Regex Patterns

    /// Matches linked images: [![alt](imageUrl)](linkUrl)
    /// Group 1: alt text, Group 2: image URL, Group 3: link URL
    private static let linkedImagePattern: NSRegularExpression? = {
        // [![...](...)](#...)  — the link wraps the image
        try? NSRegularExpression(
            pattern: #"\[!\[([^\]]*)\]\(([^)]+)\)\]\(([^)]+)\)"#,
            options: []
        )
    }()

    /// Matches standalone images: ![alt](imageUrl)
    /// Group 1: alt text, Group 2: image URL
    /// Negative lookbehind ensures we don't match images already captured as linked images.
    private static let standaloneImagePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?<!\[)!\[([^\]]*)\]\(([^)]+)\)"#,
            options: []
        )
    }()

    /// Data model for a parsed markdown image occurrence.
    private struct ParsedImage {
        let range: Range<String.Index>
        let imageURL: URL
        let altText: String
        let linkURL: URL?
    }

    /// Returns true for image URLs that can be rendered inline:
    /// - `http` / `https` remote URLs
    /// - `data:image/` Base64 data URIs
    /// - `imgcache://` compact tokens (base64 payloads extracted at parse time)
    private static func isRenderableImageURL(_ url: URL) -> Bool {
        switch url.scheme {
        case "http", "https": return true
        case "data":          return url.absoluteString.hasPrefix("data:image/")
        case "imgcache":      return true
        default:              return false
        }
    }

    /// Scans `text` for markdown image syntax and returns all occurrences with their ranges.
    private func findMarkdownImages(in text: String) -> [ParsedImage] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var results: [ParsedImage] = []

        // 1) Find linked images first  [![alt](img)](link)
        if let pattern = Self.linkedImagePattern {
            let matches = pattern.matches(in: text, options: [], range: fullRange)
            for match in matches {
                guard match.numberOfRanges >= 4,
                      let swiftRange = Range(match.range, in: text),
                      let altRange = Range(match.range(at: 1), in: text),
                      let imgRange = Range(match.range(at: 2), in: text),
                      let linkRange = Range(match.range(at: 3), in: text),
                      let imgURL = URL(string: String(text[imgRange])),
                      Self.isRenderableImageURL(imgURL)
                else { continue }

                let linkURLStr = String(text[linkRange])
                let linkURL = URL(string: linkURLStr)

                results.append(ParsedImage(
                    range: swiftRange,
                    imageURL: imgURL,
                    altText: String(text[altRange]),
                    linkURL: linkURL
                ))
            }
        }

        // 2) Find standalone images  ![alt](img)  — skip any that overlap with linked images
        if let pattern = Self.standaloneImagePattern {
            let matches = pattern.matches(in: text, options: [], range: fullRange)
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let swiftRange = Range(match.range, in: text),
                      let altRange = Range(match.range(at: 1), in: text),
                      let imgRange = Range(match.range(at: 2), in: text),
                      let imgURL = URL(string: String(text[imgRange])),
                      Self.isRenderableImageURL(imgURL)
                else { continue }

                // Skip if this overlaps with any linked image already found
                let overlaps = results.contains { $0.range.overlaps(swiftRange) }
                if overlaps { continue }

                results.append(ParsedImage(
                    range: swiftRange,
                    imageURL: imgURL,
                    altText: String(text[altRange]),
                    linkURL: nil
                ))
            }
        }

        // Sort by position in the string (earliest first)
        results.sort { $0.range.lowerBound < $1.range.lowerBound }
        return results
    }

    private func parseSpecialBlocks(_ text: String) -> [ContentSegment] {
        // 1) Extract markdown images first, splitting the text around them.
        //    This runs before code-block detection so images inside prose are found.
        let images = findMarkdownImages(in: text)

        if images.isEmpty {
            // No images — fall through to code-block parsing directly.
            return parseCodeBlocks(text, baseOffset: 0)
        }

        var segments: [ContentSegment] = []
        var cursor = text.startIndex

        for img in images {
            // Text before this image
            if cursor < img.range.lowerBound {
                let preceding = String(text[cursor..<img.range.lowerBound])
                // Parse code blocks within the preceding text chunk
                segments.append(contentsOf: parseCodeBlocks(preceding, baseOffset: segments.count))
            }
            // The image itself
            let imgIdx = segments.filter { if case .markdownImage = $0.kind { return true }; return false }.count
            segments.append(.markdownImage(imageURL: img.imageURL, altText: img.altText, linkURL: img.linkURL, index: imgIdx))
            cursor = img.range.upperBound
        }

        // Remaining text after the last image
        if cursor < text.endIndex {
            let remaining = String(text[cursor..<text.endIndex])
            segments.append(contentsOf: parseCodeBlocks(remaining, baseOffset: segments.count))
        }

        return segments.isEmpty ? [.markdown(text, index: 0)] : segments
    }

    // MARK: - CommonMark fence helpers
    //
    // Per the CommonMark spec, a fenced code block closer must:
    //   1. Have ≥ as many backticks as the opener (e.g. opener ``` → closer needs ≥ 3)
    //   2. Have NO info string (only optional trailing whitespace after the backticks)
    //   3. Have ≤ 3 spaces of leading indent
    //
    // These rules mean that when a model writes:
    //
    //   ```                ← opener (3 backticks, no lang)
    //   ```bash            ← NOT a closer (has info string "bash") → treated as inner opener
    //   aws elbv2 …
    //   ```                ← closes the bash block
    //   …more content…
    //   ```                ← closes the outer block
    //
    // Our old naïve `range(of: "\n```")` matched the first ``` it found, eating
    // everything after as prose. This helper finds the *correct* closer.

    /// Returns how many leading backtick characters a fence line starts with,
    /// and the info string (language tag) if any. Returns nil if the line is
    /// not a fence line (fewer than 3 backticks, or > 3 leading spaces).
    private static func parseFenceLine(_ line: Substring) -> (backtickCount: Int, info: String)? {
        // Allow ≤ 3 leading spaces.
        var idx = line.startIndex
        var leadingSpaces = 0
        while idx < line.endIndex, line[idx] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            idx = line.index(after: idx)
        }
        guard leadingSpaces < 4, idx < line.endIndex, line[idx] == "`" else { return nil }
        var tickCount = 0
        while idx < line.endIndex, line[idx] == "`" {
            tickCount += 1
            idx = line.index(after: idx)
        }
        guard tickCount >= 3 else { return nil }
        let info = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return (tickCount, info)
    }

    /// Finds the index of the closing fence line in `lines` starting from `startIdx`.
    /// The closer must have ≥ `minTickCount` backticks and an EMPTY info string.
    /// Returns the line index of the closer, or nil if not found (unclosed/streaming block).
    private static func findClosingFence(in lines: [Substring], from startIdx: Int, minTickCount: Int) -> Int? {
        for i in startIdx..<lines.count {
            if let fence = parseFenceLine(lines[i]),
               fence.backtickCount >= minTickCount,
               fence.info.isEmpty {
                return i
            }
        }
        return nil
    }

    /// Parses code blocks (chart/html/mermaid/svg/python) from a text chunk that
    /// has already had markdown images extracted.
    ///
    /// Uses CommonMark-compliant fence matching: the closing fence must have
    /// ≥ as many backticks as the opener AND no info string. This correctly
    /// handles nested code blocks (e.g. a ``` outer block containing ```bash inner
    /// blocks — the inner ```bash lines are NOT mistaken for closers because they
    /// have an info string).
    private func parseCodeBlocks(_ text: String, baseOffset: Int = 0) -> [ContentSegment] {
        guard text.contains("```") else { return [.markdown(text, index: baseOffset)] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var segments: [ContentSegment] = []
        var i = 0
        var proseStart = 0

        func nextIndex(_ prefix: String) -> Int {
            segments.filter { $0.id.hasPrefix(prefix) }.count + baseOffset
        }

        while i < lines.count {
            guard let fence = Self.parseFenceLine(lines[i]) else { i += 1; continue }
            let closer = Self.findClosingFence(in: lines, from: i + 1, minTickCount: fence.backtickCount)
            let codeEnd = closer ?? lines.count
            let code = lines[(i + 1)..<codeEnd].joined(separator: "\n")
            let language = fence.info.lowercased()
            let live = closer == nil && isStreaming
            let chart = chartLanguageTags.contains(language) &&
                (looksLikeChartJSON(code) || (live && language != "json"))
            let html = language == "html" && (live || (code.contains("<") && code.contains(">") && code.count >= 10))
            let svg = language == "svg" && (live || looksLikeSVG(code))
            let mermaid = language == "mermaid" && (live || code.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5)
            let python = !live && pythonLanguageTags.contains(language) &&
                code.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            guard (closer != nil || live), chart || html || svg || mermaid || python else {
                // Ordinary fences remain in ONE Markdown document, whether open
                // or closed. Closing a fence must not move code to a new parent.
                i = codeEnd + 1
                continue
            }
            if proseStart < i {
                let prose = lines[proseStart..<i].joined(separator: "\n")
                if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.markdown(prose, index: nextIndex("md-")))
                }
            }
            if chart { segments.append(.chart(code, isStreaming: live, index: nextIndex("chart-"))) }
            else if html { segments.append(.html(code, isStreaming: live, index: nextIndex("html-"))) }
            else if svg { segments.append(.svg(code, isStreaming: live, index: nextIndex("svg-"))) }
            else if mermaid { segments.append(.mermaid(code, isStreaming: live, index: nextIndex("mermaid-"))) }
            else { segments.append(.python(code, index: nextIndex("python-"))) }
            i = codeEnd + 1
            proseStart = i
        }
        if proseStart < lines.count {
            let prose = lines[proseStart...].joined(separator: "\n")
            if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(prose, index: nextIndex("md-")))
            }
        }
        return segments.isEmpty ? [.markdown(text, index: baseOffset)] : segments
    }

    private func looksLikeChartJSON(_ code: String) -> Bool {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") && t.hasSuffix("}")
            && (t.contains("\"data\"") || t.contains("\"datasets\"")
                || t.contains("\"series\"") || t.contains("\"values\"")
                || t.contains("\"labels\"") || t.contains("\"type\""))
    }

    private func looksLikeSVG(_ code: String) -> Bool {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("<svg") || t.contains("<svg ")
            || t.contains("xmlns=\"http://www.w3.org/2000/svg\"")
    }

    private func tryParseChart(code: String) -> USpec? {
        guard let data = code.data(using: .utf8) else { return nil }
        return try? parseUSpec(from: data)
    }
}

// MARK: - Markdown Inline Image View

/// Renders a markdown image as a native SwiftUI async image with caching.
/// Supports optional link wrapping — tapping opens the link URL in Safari.
///
/// ## Interactions
/// - **Tap** → fullscreen viewer with pinch-to-zoom
/// - **Long-press** → context menu with Save to Photos and Share options
///
/// ## Data URI support
/// When the image URL is a `data:image/...;base64,...` URI, the Base64 payload
/// is decoded directly into a `UIImage` — no network call is made.
/// Remote `http`/`https` images go through `CachedAsyncImage` as before.
struct MarkdownInlineImageView: View {
    let imageURL: URL
    let altText: String
    let linkURL: URL?

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    // Fullscreen sheet state (shared by both Base64 and remote paths).
    @State private var showFullscreen = false
    // For remote images: cache the downloaded UIImage so we can save/share it.
    @State private var loadedRemoteImage: UIImage? = nil
    // Feedback toast for save-to-photos action.
    @State private var savedToPhotos = false
    // Alert shown when Photos access was previously denied.
    @State private var showPhotosDeniedAlert = false

    // ── Base64 async decode state ──────────────────────────────────────────
    // The decode (base64 + UIImage decompress) runs off the main thread so it
    // never blocks the SwiftUI layout pass when opening a chat with images.
    @State private var decodedBase64Image: UIImage? = nil
    @State private var base64DecodeError = false

    /// Process-lifetime cache for decoded base64 UIImages.
    /// Keyed by a cheap surrogate (total length + first 80 chars) so the full
    /// multi-MB absoluteString is never copied just to form a cache key.
    /// On a cache hit the image appears synchronously on the first render —
    /// no placeholder flash when scrolling back through a chat.
    private static let base64ImageCache = NSCache<NSString, UIImage>()

    /// Cheap cache key derived from the URI without copying the full payload.
    private static func base64CacheKey(for url: URL) -> NSString {
        let s = url.absoluteString
        return "\(s.count)_\(s.prefix(80))" as NSString
    }

    /// Attempts to decode a `data:image/...;base64,<payload>` URI into a UIImage.
    /// Returns `nil` for any other scheme or malformed URI.
    /// Safe to call from a background thread — no UIKit main-thread APIs used.
    private nonisolated static func decodeDataURI(_ url: URL) -> UIImage? {
        decodeDataURIString(url.absoluteString)
    }

    /// Variant that accepts the raw data URI string directly, avoiding the cost
    /// of constructing a `URL` from a potentially 500 KB base64 string.
    /// Safe to call from a background thread — no UIKit main-thread APIs used.
    private nonisolated static func decodeDataURIString(_ raw: String) -> UIImage? {
        guard raw.hasPrefix("data:image/") else { return nil }
        // Find the comma that separates the header from the payload.
        guard let commaIdx = raw.firstIndex(of: ",") else { return nil }
        let header = raw[raw.startIndex..<commaIdx]
        guard header.hasSuffix(";base64") else { return nil }
        let base64 = String(raw[raw.index(after: commaIdx)...])
        // Base64 strings from some models contain whitespace/newlines — strip them.
        let cleaned = base64.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        if imageURL.scheme == "data" || imageURL.scheme == "imgcache" {
            // ── Inline Base64 data URI ────────────────────────────────────────
            // Decoding happens off the main thread to prevent the freeze that
            // occurs when opening a chat with multiple base64 images — each
            // Data(base64Encoded:) + UIImage(data:) call blocks the main thread
            // for 50–200ms on older devices.
            if let uiImage = decodedBase64Image {
                base64ImageView(uiImage: uiImage)
            } else if base64DecodeError {
                dataURIErrorPlaceholder
            } else {
                // Stable-height loading placeholder — same height as the remote
                // image placeholder so there's no layout shift on decode completion.
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.surfaceContainer.opacity(0.5))
                    .frame(height: 160)
                    .overlay {
                        VStack(spacing: 6) {
                            ProgressView()
                            if !altText.isEmpty {
                                Text(altText)
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .task(id: imageURL) {
                        let key = Self.base64CacheKey(for: imageURL)
                        // Check process-level cache first — instant on scroll-back.
                        if let cached = Self.base64ImageCache.object(forKey: key) {
                            withAnimation(.none) { decodedBase64Image = cached }
                            return
                        }
                        // Decode on a background thread — base64 + image decompression
                        // can be 50–200ms; must not run on the main thread.
                        let decoded: UIImage?
                        if imageURL.scheme == "imgcache" {
                            // Resolve the compact token back to the actual data URI string.
                            // We pass the raw string directly to avoid the cost of constructing
                            // a URL from a potentially 500 KB base64 URI.
                            let tokenString = imageURL.absoluteString
                            let store = InlineImageStore.shared
                            decoded = await Task.detached(priority: .userInitiated) {
                                guard let dataURI = store.resolve(urlString: tokenString) else {
                                    return nil
                                }
                                return Self.decodeDataURIString(dataURI)
                            }.value
                        } else {
                            let url = imageURL
                            decoded = await Task.detached(priority: .userInitiated) {
                                Self.decodeDataURI(url)
                            }.value
                        }
                        if let image = decoded {
                            Self.base64ImageCache.setObject(image, forKey: key)
                            // Suppress implicit animation so the layout change from
                            // placeholder → image does not cause a scroll jump.
                            withAnimation(.none) { decodedBase64Image = image }
                        } else {
                            base64DecodeError = true
                        }
                    }
            }
        } else {
            // ── Remote http/https image ───────────────────────────────────────
            remoteImageView
        }
    }

    /// Displays a decoded UIImage (from a data URI) with fullscreen + context menu.
    @ViewBuilder
    private func base64ImageView(uiImage: UIImage) -> some View {
        Image(uiImage: uiImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { showFullscreen = true }
            .contextMenu { imageContextMenu(for: uiImage) }
            .accessibilityLabel(altText.isEmpty ? "Image" : altText)
            .accessibilityAddTraits(.isImage)
            .sheet(isPresented: $showFullscreen) {
                FullscreenImageViewer(image: uiImage, altText: altText)
            }
    }

    /// Small placeholder shown when a data URI fails to decode.
    private var dataURIErrorPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(theme.surfaceContainer.opacity(0.5))
            .frame(height: 80)
            .overlay {
                Label("Image could not be decoded", systemImage: "photo")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
            }
    }

    /// Remote-image view via CachedAsyncImage (http / https).
    private var remoteImageView: some View {
        CachedAsyncImage(url: imageURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } placeholder: {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.surfaceContainer.opacity(0.5))
                .frame(height: 160)
                .overlay {
                    VStack(spacing: 6) {
                        ProgressView()
                        if !altText.isEmpty {
                            Text(altText)
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { showFullscreen = true }
        .contextMenu {
            if let img = loadedRemoteImage {
                imageContextMenu(for: img)
            }
        }
        .accessibilityLabel(altText.isEmpty ? "Image" : altText)
        .accessibilityAddTraits(.isImage)
        .sheet(isPresented: $showFullscreen) {
            // Use cached UIImage if available, otherwise fall back to URL-based viewer.
            if let img = loadedRemoteImage {
                FullscreenImageViewer(image: img, altText: altText)
            } else {
                FullscreenImageViewer(imageURL: imageURL, altText: altText)
            }
        }
        .task(id: imageURL) {
            // Download a UIImage copy in the background so save/share work without
            // needing to render the SwiftUI Image back to a bitmap.
            guard loadedRemoteImage == nil else { return }
            let image = await ImageCacheService.shared.loadImage(from: imageURL)
            guard !Task.isCancelled else { return }
            loadedRemoteImage = image
        }
    }

    /// Context menu items shared by both image types.
    @ViewBuilder
    private func imageContextMenu(for image: UIImage) -> some View {
        Button {
            saveImageWithPermission(image, onDenied: { showPhotosDeniedAlert = true })
        } label: {
            Label("Save to Photos", systemImage: "square.and.arrow.down")
        }

        Button {
            shareImage(image)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        if let linkURL {
            Button {
                openURL(linkURL)
            } label: {
                Label("Open Link", systemImage: "link")
            }
        }
        // Note: openURL here is @Environment(\.openURL) used for the Share sheet context menu.
        // The in-app browser routing is handled via the global openURL(_:) helper for tap actions.
    }

    /// Presents a `UIActivityViewController` for sharing the given image.
    private func shareImage(_ image: UIImage) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        // iPad needs a source view for the popover.
        vc.popoverPresentationController?.sourceView = rootVC.view
        vc.popoverPresentationController?.sourceRect = CGRect(
            x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
        vc.popoverPresentationController?.permittedArrowDirections = []
        rootVC.present(vc, animated: true)
    }
}

// MARK: - Fullscreen Image Viewer

/// Full-screen image viewer with pinch-to-zoom, Save, and Share toolbar actions.
/// Accepts either a pre-decoded `UIImage` (Base64 path) or a remote `URL` (http/https path
/// where the async download is still in progress).
private struct FullscreenImageViewer: View {

    // Exactly one of these will be non-nil.
    var image: UIImage?
    var imageURL: URL?
    var altText: String

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var savedConfirmation = false

    init(image: UIImage, altText: String) {
        self.image = image
        self.imageURL = nil
        self.altText = altText
    }

    init(imageURL: URL, altText: String) {
        self.image = nil
        self.imageURL = imageURL
        self.altText = altText
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black.ignoresSafeArea()

                    if let uiImage = image {
                        zoomableImage(Image(uiImage: uiImage), size: geo.size)
                    } else if let url = imageURL {
                        CachedAsyncImage(url: url) { img in
                            zoomableImage(img, size: geo.size)
                        } placeholder: {
                            ProgressView().tint(.white)
                        }
                    }

                    // "Saved!" confirmation toast.
                    if savedConfirmation {
                        VStack {
                            Spacer()
                            Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.bottom, 32)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let uiImage = image {
                        Button {
                            saveToPhotos(uiImage)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .foregroundStyle(.white)

                        Button {
                            shareImage(uiImage)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func zoomableImage(_ img: Image, size: CGSize) -> some View {
        img
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(1.0, min(lastScale * value, 6.0))
                    }
                    .onEnded { _ in
                        lastScale = scale
                        // Snap back if zoomed out below 1×.
                        if scale < 1.0 {
                            withAnimation(.spring()) {
                                scale = 1.0
                                offset = .zero
                            }
                            lastScale = 1.0
                            lastOffset = .zero
                        }
                    }
                    .simultaneously(with:
                        DragGesture()
                            .onChanged { value in
                                // Only allow panning when zoomed in.
                                guard scale > 1.0 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring()) {
                    if scale > 1.0 {
                        scale = 1.0
                        offset = .zero
                        lastScale = 1.0
                        lastOffset = .zero
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                    }
                }
            }
    }

    private func saveToPhotos(_ uiImage: UIImage) {
        saveImageWithPermission(uiImage) {
            // Permission denied — open Settings so the user can enable it.
            openPhotosSettings()
        }
        withAnimation(.spring()) { savedConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { savedConfirmation = false }
        }
    }

    private func shareImage(_ uiImage: UIImage) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: [uiImage], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = rootVC.view
        vc.popoverPresentationController?.sourceRect = CGRect(
            x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
        vc.popoverPresentationController?.permittedArrowDirections = []
        rootVC.present(vc, animated: true)
    }
}

// MARK: - Full Code View (Fullscreen)

struct FullCodeView: View {
    let code: String
    let language: String

    @State private var codeCopied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HighlightedSourceView(code: code, language: language, truncate: false, maxHeight: .infinity)
                .navigationTitle(language)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .tint(.secondary)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = code
                            Haptics.notify(.success)
                            withAnimation(.spring()) { codeCopied = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                withAnimation(.spring()) { codeCopied = false }
                            }
                        } label: {
                            Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                                .scaledFont(size: 14, weight: .medium)
                        }
                    }
                }
        }
    }
}

// MARK: - Markdown With Loading

struct MarkdownWithLoading: View {
    let content: String?
    let isLoading: Bool

    var body: some View {
        let text = content ?? ""
        if isLoading && text.isBlank {
            HStack {
                BlinkingCursorIndicator()
                Spacer()
            }
        } else {
            StreamingMarkdownView(content: text, isStreaming: isLoading)
        }
    }
}

// MARK: - Preview

#Preview("Streaming Markdown") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
            StreamingMarkdownView(
                content: """
                ## Hello World

                This is a **bold** statement with `inline code`.

                ```python
                def fibonacci(n):
                    if n <= 1:
                        return n
                    return fibonacci(n-1) + fibonacci(n-2)

                for i in range(20):
                    print(fibonacci(i))
                ```

                > A blockquote for good measure.

                Here is an image:

                ![Cat](https://ts3.mm.bing.net/th?id=OIP.aSMukwrEsjGt9XxJFvxdxQHaEo&pid=15.1)
                """,
                isStreaming: false
            )
        }
        .padding()
    }
    .themed()
}

/// Keeps the same parsed-chunk views during streaming and completion. Parsing a
/// complete Markdown document preserves container context (lists, fences, links);
/// only changed chunks receive new render objects.
private struct StableStreamingMarkdown: View {
    let text: String
    let isStreaming: Bool
    let theme: MarkdownTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.streamRateMeter) private var streamRateMeter
    @State private var reveal = StreamingTextReveal()
    @State private var parser = StreamingMarkdownParser()
    @State private var pump = ParsePump()

    /// Drives streaming parses so that every finished parse is used.
    ///
    /// A `.task(id:)` keyed on the text cancels the running parse on every server
    /// update and discards its result. With a fast model, updates arrive faster
    /// than a parse takes, so almost nothing reached the typewriter until a pause
    /// let one parse through — and then a large block appeared at once. The pump
    /// instead runs one parse at a time and always parses the newest text next.
    /// Each result is a prefix of the latest text, so it is always usable.
    @MainActor private final class ParsePump {
        var latest: (text: String, reduceMotion: Bool)?
        var task: Task<Void, Never>?
    }

    private struct Request: Equatable {
        let isStreaming: Bool
        let theme: MarkdownTheme
        let reduceMotion: Bool
        /// Settled content only: live text goes through the pump.
        let settledText: String?
    }

    var body: some View {
        let request = Request(isStreaming: isStreaming, theme: theme, reduceMotion: reduceMotion,
                              settledText: isStreaming ? nil : text)
        let cached = isStreaming ? nil : MarkdownBlockRenderCache.shared.lookup(content: text, theme: theme)
        let live = isStreaming || reveal.isAnimating
        Group {
            if let pieces = reveal.pieces(live: live, spacings: theme.spacings)
                ?? cached.map({ StreamingTextReveal.wholePieces($0, spacings: theme.spacings) }) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pieces) { piece in
                        pieceView(piece.content, live: live, reveals: piece.reveals)
                            .padding(.top, piece.topSpacing)
                    }
                }
            } else if isStreaming {
                // First packet: keep the typing cursor on screen until the first
                // parse lands, instead of an empty frame between cursor and text.
                HStack(spacing: 0) {
                    BlinkingCursorIndicator()
                    Spacer()
                }
            } else {
                Color.clear
                    .frame(height: CGFloat(max(1, text.utf8.count / 55)) * theme.fonts.body.lineHeight)
                    .accessibilityHidden(true)
            }
        }
        .onAppear { reveal.rateMeter = streamRateMeter }
        .onDisappear {
            pump.task?.cancel()
            pump.task = nil
            pump.latest = nil
            reveal.finish()
        }
        // Live text: hand the newest version to the pump on every update.
        .onChange(of: text, initial: true) { _, newText in
            guard isStreaming else { return }
            enqueueLiveParse(newText)
        }
        // Settled text, theme and motion changes keep the existing task path.
        .task(id: request) {
            reveal.rateMeter = streamRateMeter
            if isStreaming {
                enqueueLiveParse(text)
                return
            }
            // A live parse still in flight must not land after the final content.
            pump.task?.cancel()
            pump.task = nil
            pump.latest = nil
            if let cached {
                reveal.receive(cached, source: text, streaming: false, reduceMotion: reduceMotion)
                return
            }
            if reveal.hasContent {
                let parsed = await parser.parse(text)
                guard !Task.isCancelled else { return }
                reveal.receive(parsed, source: text, streaming: false, reduceMotion: reduceMotion)
            }
            // Reuse the existing finished-message cache, including its math
            // rendering. Keep the visible text while that work completes.
            let finished = await withCheckedContinuation { continuation in
                MarkdownBlockRenderCache.shared.build(content: text, theme: theme) {
                    continuation.resume(returning: $0)
                }
            }
            guard !Task.isCancelled else { return }
            reveal.receive(finished, source: text, streaming: false, reduceMotion: reduceMotion)
        }
    }

    /// Queues `newText` for parsing; starts the single parse loop if idle.
    private func enqueueLiveParse(_ newText: String) {
        let work = pump
        work.latest = (newText, reduceMotion)
        guard work.task == nil else { return }
        let parser = parser
        let reveal = reveal
        work.task = Task { @MainActor in
            while let next = work.latest, !Task.isCancelled {
                work.latest = nil
                let parsed = await parser.parse(next.text)
                guard !Task.isCancelled else { break }
                reveal.receive(parsed, source: next.text, streaming: true, reduceMotion: next.reduceMotion)
            }
            work.task = nil
        }
    }

    @ViewBuilder
    private func pieceView(_ content: MarkdownView.PreprocessedContent, live: Bool, reveals: Bool) -> some View {
        if content.blocks.count == 1, case let .codeBlock(language, code) = content.blocks[0] {
            // cmark adds a terminal newline even to partial lines.
            // Omit it so the native code view can append new tokens.
            let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
            StreamingCodeBlockView(language: language ?? "", content: trimmed, isStreaming: live, theme: theme)
        } else {
            MarkdownView(content, theme: theme)
                .codeAutoScroll(live)
                .revealing(reveals ? reveal.controller : nil)
        }
    }
}

/// Animation changes only a prefix of the already-parsed active chunk. Completed
/// chunks keep their render objects; Markdown parsing is driven by server updates,
/// never by the display clock. Non-text attachments are revealed atomically.
///
/// While a reply is live, the block being typed is split into its own view. Every
/// revealed character then re-lays out and redraws one paragraph instead of the
/// whole 1,800-character chunk, so the per-frame cost no longer grows with the
/// chunk or the screen width. When the reply settles, the pieces merge back into
/// the chunk; `blockGap` reproduces the paragraph spacing the merged text view
/// applies between those two blocks, so the merge does not move anything.
@MainActor @Observable
final class StreamingTextReveal {
    struct Piece: Identifiable {
        let id: String
        let content: MarkdownView.PreprocessedContent
        let topSpacing: CGFloat
        /// The active block, whose text view the reveal controller drives.
        var reveals = false
    }

    private var target: [MarkdownView.PreprocessedContent]?
    @ObservationIgnored private var lengths: [Int] = []
    /// Reveal-unit length of every block, per chunk.
    @ObservationIgnored private var blockLengths: [[Int]] = []
    /// Fully revealed leading blocks of the live chunk, kept stable between frames.
    /// Holds the chunk itself (compared by identity) so a freed chunk's address
    /// can never be mistaken for a new one.
    @ObservationIgnored private var frozenCache: (chunk: MarkdownView.PreprocessedContent, count: Int,
                                                  content: MarkdownView.PreprocessedContent)?

    /// The block being typed. Changes only when typing moves to the next block,
    /// so SwiftUI re-renders once per block instead of once per character.
    struct Cursor: Equatable {
        let chunk: Int
        let block: Int
    }
    private(set) var cursor: Cursor?
    /// Characters shown of the active block, published only for code blocks,
    /// which are drawn by their own view and cannot use the draw-time reveal.
    private(set) var codePrefix = 0
    /// The active block's node, to tell a grown block from an unchanged one.
    @ObservationIgnored private var cursorNode: MarkdownBlockNode?

    /// Drives the per-frame reveal of the active block's text view directly,
    /// without re-evaluating any SwiftUI body.
    let controller = MarkdownRevealController()
    private static let fadeCharacters: CGFloat = 6

    private let progress = StreamingTypewriter(publishesCount: false)
    var isAnimating: Bool { progress.isAnimating }
    /// Whether any parsed content has been received yet.
    var hasContent: Bool { target != nil }

    init() {
        progress.onShown = { [weak self] shown in self?.reveal(at: shown) }
    }

    /// Gap to place above chunk `index` so separately rendered chunks line up
    /// exactly as one continuous text view would. Each chunk is its own text view,
    /// and CoreText drops a paragraph's trailing spacing at a view's bottom edge, so
    /// without this, paragraphs on either side of a chunk boundary touched.
    static func chunkGap(before next: [MarkdownBlockNode], after previous: [MarkdownBlockNode],
                         spacings: MarkdownTheme.Spacings) -> CGFloat {
        guard let last = previous.last, let first = next.first else { return 0 }
        // The splitter cuts an oversized paragraph after a space; the two halves are
        // one paragraph, so only ordinary line spacing separates them.
        if case let .paragraph(content) = last, case .paragraph = first,
           case let .text(text)? = content.last, text.last?.isWhitespace == true {
            return spacings.lineSpacing
        }
        return blockGap(after: last, before: first, spacings: spacings)
    }

    /// Finished content: one piece per chunk, exactly as the settled message renders.
    static func wholePieces(_ chunks: [MarkdownView.PreprocessedContent],
                            spacings: MarkdownTheme.Spacings) -> [Piece] {
        chunks.enumerated().map { index, chunk in
            Piece(id: "\(index)", content: chunk,
                  topSpacing: index == 0 ? 0 : chunkGap(before: chunk.blocks, after: chunks[index - 1].blocks,
                                                        spacings: spacings))
        }
    }

    func pieces(live: Bool, spacings: MarkdownTheme.Spacings) -> [Piece]? {
        guard let target else { return nil }
        guard live, let cursor, cursor.chunk < target.count,
              cursor.block < target[cursor.chunk].blocks.count
        else { return Self.wholePieces(target, spacings: spacings) }
        var result: [Piece] = []
        // Chunks before the active one are complete and unchanged.
        for index in 0 ..< cursor.chunk {
            result.append(Piece(
                id: "\(index)", content: target[index],
                topSpacing: index == 0 ? 0 : Self.chunkGap(before: target[index].blocks,
                                                           after: target[index - 1].blocks, spacings: spacings)
            ))
        }
        let chunk = target[cursor.chunk]
        let node = chunk.blocks[cursor.block]
        let chunkTop = cursor.chunk == 0 ? 0 : Self.chunkGap(before: chunk.blocks,
                                                             after: target[cursor.chunk - 1].blocks,
                                                             spacings: spacings)
        // Blocks of the active chunk before the active block are complete.
        if cursor.block > 0 {
            let frozen: MarkdownView.PreprocessedContent
            if let cache = frozenCache, cache.chunk === chunk, cache.count == cursor.block {
                frozen = cache.content
            } else {
                frozen = .init(blocks: Array(chunk.blocks.prefix(cursor.block)),
                               rendered: chunk.rendered, highlightMaps: chunk.highlightMaps)
                frozenCache = (chunk, cursor.block, frozen)
            }
            result.append(Piece(id: "\(cursor.chunk)", content: frozen, topSpacing: chunkTop))
        }
        // The active block is laid out in full once; its text view reveals it at
        // draw time. Code blocks have their own view and are prefixed instead.
        let liveContent: MarkdownView.PreprocessedContent
        let reveals: Bool
        if case let .codeBlock(info, code) = node {
            liveContent = .init(blocks: [.codeBlock(fenceInfo: info, content: String(code.prefix(codePrefix)))],
                                rendered: chunk.rendered, highlightMaps: chunk.highlightMaps)
            reveals = false
        } else if let cache = liveCache, cache.cursor == cursor, cache.chunk === chunk, cache.node == node {
            liveContent = cache.content
            reveals = true
        } else {
            liveContent = .init(blocks: [node], rendered: chunk.rendered, highlightMaps: chunk.highlightMaps)
            liveCache = (cursor, chunk, node, liveContent)
            reveals = true
        }
        result.append(Piece(
            id: "\(cursor.chunk)-live", content: liveContent,
            topSpacing: cursor.block == 0 ? chunkTop
                : Self.blockGap(after: chunk.blocks[cursor.block - 1], before: node, spacings: spacings),
            reveals: reveals
        ))
        return result
    }

    @ObservationIgnored private var liveCache: (cursor: Cursor, chunk: MarkdownView.PreprocessedContent,
                                                node: MarkdownBlockNode, content: MarkdownView.PreprocessedContent)?

    /// Maps the typewriter position to the active block and its revealed share.
    /// Runs every display frame; it only touches SwiftUI state when typing moves
    /// to another block (or into a code block, which is revealed by prefix).
    private func reveal(at shown: Double) {
        guard let target, !blockLengths.isEmpty else {
            if cursor != nil { cursor = nil }
            return
        }
        var start = 0.0
        var found: (cursor: Cursor, node: MarkdownBlockNode, length: Int, local: Double)?
        search: for (chunkIndex, blocks) in blockLengths.enumerated() where chunkIndex < target.count {
            let isLastChunk = chunkIndex == blockLengths.count - 1
            let chunkLength = Double(lengths[chunkIndex])
            if !isLastChunk, start + chunkLength <= shown {
                start += chunkLength
                continue
            }
            for (blockIndex, length) in blocks.enumerated() where blockIndex < target[chunkIndex].blocks.count {
                let isLastBlock = isLastChunk && blockIndex == blocks.count - 1
                if start + Double(length) > shown || isLastBlock {
                    found = (Cursor(chunk: chunkIndex, block: blockIndex),
                             target[chunkIndex].blocks[blockIndex], length, shown - start)
                    break search
                }
                start += Double(length)
            }
        }
        guard let found else {
            if cursor != nil { cursor = nil }
            return
        }
        let fraction = found.length > 0 ? min(1, max(0, found.local / Double(found.length))) : 1
        let moved = found.cursor != cursor || found.node != cursorNode
        if case .codeBlock = found.node {
            let prefix = max(0, Int(found.local))
            if prefix != codePrefix { codePrefix = prefix }
        }
        if moved {
            // Finish the block that was being typed, then hold the new value
            // until SwiftUI hands the new block to the text view.
            if found.cursor != cursor { controller.update(progress: 1, fadeCharacters: 0) }
            controller.stage(progress: fraction, fadeCharacters: Self.fadeCharacters)
            if found.cursor != cursor { cursor = found.cursor }
            cursorNode = found.node
        } else {
            controller.update(progress: fraction, fadeCharacters: Self.fadeCharacters)
        }
    }

    /// The vertical gap one text view leaves between two consecutive blocks. It
    /// matches MarkdownView's paragraph styles: the previous block's
    /// paragraphSpacing plus its lineSpacing, plus the next block's
    /// paragraphSpacingBefore. CoreText drops these at a text view's edges, so
    /// split views must add the gap back to line up with the merged view.
    static func blockGap(after previous: MarkdownBlockNode, before next: MarkdownBlockNode,
                         spacings: MarkdownTheme.Spacings) -> CGFloat {
        let after: CGFloat
        switch previous {
        case .heading: after = spacings.headingSpacing
        case .thematicBreak: after = 0
        default: after = spacings.paragraphSpacing
        }
        let before: CGFloat
        if case .heading = next { before = spacings.headingSpacing } else { before = 0 }
        return after + spacings.lineSpacing + before
    }

    /// Shared delivery rate for the reply this text belongs to.
    var rateMeter: StreamRateMeter? {
        get { progress.rateMeter }
        set { progress.rateMeter = newValue }
    }

    func receive(_ next: [MarkdownView.PreprocessedContent], source: String,
                 streaming: Bool, reduceMotion: Bool = false) {
        let previous = target ?? []
        let previousBlocks = blockLengths
        blockLengths = next.enumerated().map { index, chunk in
            index < previous.count && previous[index] === chunk && index < previousBlocks.count
                ? previousBlocks[index] : chunk.blocks.map { RevealPrefix.length($0) }
        }
        lengths = blockLengths.map { $0.reduce(0, +) }
        target = next
        progress.receive(source, count: lengths.reduce(0, +), streaming: streaming, reduceMotion: reduceMotion)
    }

    func advance(by seconds: Double) { progress.advance(by: seconds) }
    func finish() { progress.finish() }
}

/// Both formatted answers and plain reasoning use this clock.
///
/// While a reply is live the reveal holds a short, steady lag behind the newest
/// text, so there is always something left to type and packet gaps never show.
/// Speed follows the reply's measured delivery rate (shared per reply via
/// `StreamRateMeter`) and a gentle correction toward the target lag. It changes
/// only through bounded acceleration: a burst of new text raises the speed over a
/// fraction of a second instead of sprinting, and a gap slows it gradually.
///
/// Very fast models: the reveal soft-caps near `softCap` characters per second so
/// it stays letter-by-letter. The cap rises only while the lag stays beyond
/// `maxLag`, so a slower-than-server reveal cannot fall further and further behind.
@MainActor @Observable
final class StreamingTypewriter {
    /// Whole visible characters. Published only when `publishesCount` is set, so
    /// views that drive a draw-time reveal are not re-evaluated per character.
    private(set) var visibleCount = 0
    private(set) var hasStreamed = false
    /// Whether the reveal is still behind the newest text; changes rarely.
    private(set) var isAnimating = false
    /// Called with the fractional reveal position whenever it moves.
    @ObservationIgnored var onShown: ((Double) -> Void)?
    @ObservationIgnored private let publishesCount: Bool
    @ObservationIgnored private var source = ""
    @ObservationIgnored private var shown = 0.0
    @ObservationIgnored private var total = 0
    @ObservationIgnored private var isLive = false
    @ObservationIgnored private var speed = 0.0
    /// Local arrival estimate, used when no shared meter is available.
    @ObservationIgnored private var localRate = ArrivalRateEstimator()
    @ObservationIgnored private var link: CADisplayLink?
    /// Shared delivery rate for this reply; set by the owning view.
    @ObservationIgnored weak var rateMeter: StreamRateMeter?

    /// Typical model output before any arrival has been measured.
    private static let initialRate = 240.0
    /// Target distance behind the newest text while live, in seconds of text.
    private static let targetLag = 0.45
    /// Lag bounds in characters (tiny packets, very fast models).
    private static let minLagChars = 16.0
    private static let maxLagChars = 400.0
    /// How quickly a lag error is corrected, in seconds.
    private static let lagCorrection = 1.0
    /// Letter-by-letter ceiling for fast models (about 10 characters per frame).
    private static let softCap = 1_200.0
    /// Past this much lag the cap gives way so the reveal keeps up with the server.
    private static let maxLag = 1.5
    /// Bounded acceleration and deceleration, as a fraction of speed per second.
    private static let accelerationPerSecond = 2.2
    private static let decelerationPerSecond = 3.5
    /// Speed change is at least this many characters per second per second.
    private static let minimumAcceleration = 600.0
    /// After the stream ends, a large backlog drains within about this long.
    private static let finishSeconds = 1.0
    /// A frame longer than this (a hitch or backgrounding) is not caught up on:
    /// the text pauses for that moment instead of leaping forward.
    private static let maxFrameStep = 1.0 / 40
    /// A view that first sees more than this much text joined a reply already in
    /// progress (opened mid-stream) and starts near the live edge instead of
    /// retyping it. Shorter first packets are a new reply and type from the start.
    private static let joinThreshold = 600

    /// Answers reveal at the full ProMotion rate — smaller, more even steps — since
    /// only their live block re-renders per step. Thinking text re-lays out its
    /// whole block per step, so it stays at 60 Hz.
    private let maxFrameRate: Float

    init(maxFrameRate: Float = 120, publishesCount: Bool = true) {
        self.maxFrameRate = maxFrameRate
        self.publishesCount = publishesCount
    }

    deinit { link?.invalidate() }

    /// The reply's delivery rate: the shared meter when present, else local.
    private func deliveryRate(now: Double) -> Double {
        rateMeter?.rate(now: now) ?? localRate.rate(now: now) ?? Self.initialRate
    }

    /// How far behind the newest text the reveal aims to be, in characters.
    private func targetLagChars(rate: Double) -> Double {
        min(Self.maxLagChars, max(Self.minLagChars, rate * Self.targetLag))
    }

    func receive(_ source: String, count: Int, streaming: Bool, reduceMotion: Bool = false,
                 now: Double = ProcessInfo.processInfo.systemUptime) {
        let append = source.hasPrefix(self.source)
        let added = count - total
        total = count
        self.source = source
        isLive = streaming
        hasStreamed = hasStreamed || streaming
        guard hasStreamed, !reduceMotion, append else {
            localRate = ArrivalRateEstimator()
            speed = 0
            finish()
            return
        }
        if added > 0 { localRate.record(added, now: now) }
        shown = min(shown, Double(total))
        if shown == 0, total > Self.joinThreshold {
            shown = Double(total) - targetLagChars(rate: deliveryRate(now: now))
        }
        setVisible()
        if shown < Double(total) {
            startLinkIfNeeded(now: now)
        } else if !streaming {
            finish()
        }
    }

    /// The speed the reveal is steering toward right now.
    ///
    /// Live: the delivery rate, plus a correction that removes a lag error over
    /// `lagCorrection` seconds — so the lag, not each packet, sets the pace. When
    /// the reveal runs out of backlog it slows smoothly instead of stopping dead.
    private func targetSpeed(lead: Double, now: Double) -> Double {
        let rate = deliveryRate(now: now)
        guard isLive else {
            // Keep typing at the reply's pace; only a large backlog speeds up.
            return max(speed, rate, lead / Self.finishSeconds)
        }
        let lagTarget = targetLagChars(rate: rate)
        let desired = max(0, rate + (lead - lagTarget) / Self.lagCorrection)
        // Soft cap: letter-by-letter for fast models, until the lag grows past
        // maxLag seconds — then let the pace rise just enough to keep up.
        let lagSeconds = lead / max(rate, 1)
        let cap = lagSeconds > Self.maxLag
            ? max(Self.softCap, rate + (lead - rate * Self.maxLag) / Self.lagCorrection)
            : Self.softCap
        return min(desired, cap)
    }

    func advance(by seconds: Double, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard seconds > 0, seconds.isFinite else { return }
        // A long frame (hitch or backgrounding) is not caught up on in one go.
        let dt = min(seconds, Self.maxFrameStep)
        let lead = Double(total) - shown
        guard lead > 0 else {
            // Caught up: idle until the next packet restarts the clock.
            if isLive { stopLink() } else { finish() }
            return
        }
        let target = targetSpeed(lead: lead, now: now)
        // Bounded acceleration: speed moves toward the target at a limited rate,
        // so a burst of new text never turns into a visible sprint.
        let limit = (target > speed ? Self.accelerationPerSecond : Self.decelerationPerSecond)
            * max(speed, Self.minimumAcceleration) * dt
        speed += max(-limit, min(limit, target - speed))
        shown = min(Double(total), shown + max(0, speed) * dt)
        setVisible()
        if shown >= Double(total) {
            if isLive { stopLink() } else { finish() }
        }
    }

    func finish() {
        shown = Double(total)
        setVisible()
        stopLink()
    }

    /// Publish only whole-character changes, so observers re-render at most once
    /// per newly visible character rather than on every display frame. The
    /// fractional position goes to `onShown` every frame for draw-time reveals.
    private func setVisible() {
        let next = Int(shown)
        if publishesCount, next != visibleCount { visibleCount = next }
        let animating = shown < Double(total)
        if animating != isAnimating { isAnimating = animating }
        onShown?(shown)
    }

    private func startLinkIfNeeded(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard link == nil else { return }
        // Starting from rest: begin at the reply's pace rather than easing up from
        // zero, which reads as a slow start followed by a rush.
        if speed <= 0 { speed = min(deliveryRate(now: now), Self.softCap) }
        let clock = Clock(self)
        let displayLink = CADisplayLink(target: clock, selector: #selector(Clock.tick(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maxFrameRate), maximum: maxFrameRate, preferred: maxFrameRate)
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @MainActor private final class Clock: NSObject {
        weak var owner: StreamingTypewriter?
        private var previous: CFTimeInterval?
        init(_ owner: StreamingTypewriter) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            let elapsed = previous.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
            previous = link.timestamp
            owner?.advance(by: elapsed)
        }
    }
}

/// Prefixes formatted nodes, not Markdown source: a closing fence or emphasis
/// delimiter cannot disappear merely because the animation has not reached it.
enum RevealPrefix {
    static func length(_ node: MarkdownBlockNode) -> Int {
        switch node {
        case let .paragraph(content), let .heading(_, content): return inlineLength(content)
        case let .codeBlock(_, content): return content.count
        case let .blockquote(children), let .callout(_, children): return children.reduce(0) { $0 + length($1) }
        case let .bulletedList(_, items), let .numberedList(_, _, items):
            return items.reduce(0) { $0 + $1.children.reduce(0) { $0 + length($1) } }
        case let .taskList(_, items):
            return items.reduce(0) { $0 + $1.children.reduce(0) { $0 + length($1) } }
        case .table, .thematicBreak: return 1
        }
    }

    private static func inlineLength(_ nodes: [MarkdownInlineNode]) -> Int {
        nodes.reduce(0) { result, node in
            switch node {
            case let .text(text), let .code(text), let .html(text): return result + text.count
            case .emphasis, .strong, .strikethrough, .link: return result + inlineLength(node.children)
            case .softBreak, .lineBreak, .image, .math: return result + 1
            }
        }
    }

    static func blocks(_ nodes: [MarkdownBlockNode], budget: inout Int) -> [MarkdownBlockNode] {
        var result: [MarkdownBlockNode] = []
        for node in nodes {
            let count = length(node)
            if budget >= count { result.append(node); budget -= count; continue }
            guard budget > 0 else { break }
            switch node {
            case let .paragraph(content): result.append(.paragraph(content: inlines(content, budget: &budget)))
            case let .heading(level, content): result.append(.heading(level: level, content: inlines(content, budget: &budget)))
            case let .codeBlock(info, content):
                result.append(.codeBlock(fenceInfo: info, content: String(content.prefix(budget)))); budget = 0
            case let .blockquote(children): result.append(.blockquote(children: blocks(children, budget: &budget)))
            case let .callout(kind, children): result.append(.callout(kind: kind, children: blocks(children, budget: &budget)))
            case let .bulletedList(tight, items):
                result.append(.bulletedList(isTight: tight, items: list(items, budget: &budget)))
            case let .numberedList(tight, start, items):
                result.append(.numberedList(isTight: tight, start: start, items: list(items, budget: &budget)))
            case let .taskList(tight, items):
                var visible: [RawTaskListItem] = []
                for item in items where budget > 0 {
                    visible.append(.init(isCompleted: item.isCompleted, children: blocks(item.children, budget: &budget)))
                }
                result.append(.taskList(isTight: tight, items: visible))
            case .table, .thematicBreak: break // Atomic nodes were handled above.
            }
        }
        return result
    }

    private static func list(_ items: [RawListItem], budget: inout Int) -> [RawListItem] {
        var result: [RawListItem] = []
        for item in items where budget > 0 { result.append(.init(children: blocks(item.children, budget: &budget))) }
        return result
    }

    private static func inlines(_ nodes: [MarkdownInlineNode], budget: inout Int) -> [MarkdownInlineNode] {
        var result: [MarkdownInlineNode] = []
        for var node in nodes {
            let count = inlineLength([node])
            if budget >= count { result.append(node); budget -= count; continue }
            guard budget > 0 else { break }
            switch node {
            case let .text(text): node = .text(String(text.prefix(budget))); budget = 0
            case let .code(text): node = .code(String(text.prefix(budget))); budget = 0
            case let .html(text): node = .html(String(text.prefix(budget))); budget = 0
            case .emphasis, .strong, .strikethrough, .link: node.children = inlines(node.children, budget: &budget)
            case .softBreak, .lineBreak, .image, .math: break
            }
            result.append(node)
        }
        return result
    }
}

actor StreamingMarkdownParser {
    private var chunks: [MarkdownView.PreprocessedContent] = []

    func parse(_ text: String) -> [MarkdownView.PreprocessedContent] {
        guard !Task.isCancelled else { return chunks }
        let result = MarkdownParser().parse(text)
        let next = MarkdownView.PreprocessedContent(parserResultNoMath: result).split()
        guard !Task.isCancelled else { return chunks }
        chunks = next.enumerated().map { index, chunk in
            if index < chunks.count, chunks[index].blocks == chunk.blocks {
                return chunks[index]
            }
            return chunk
        }
        return chunks
    }
}
