import UIKit
import SwiftUI
import MarkdownView
import Charts
import os.log

private let vizLog = Logger(subsystem: "com.openui", category: "VizPipeline")

// MARK: - Streaming Markdown View

/// Renders markdown using MarkdownView (UIKit-backed).
///
/// During streaming, a single `MarkdownView` renders the `displayContent` string
/// which is smoothly drained from the raw server tokens by `StreamingContentStore`.
/// This gives a typewriter effect — characters flow in at a readable pace rather
/// than bursting in large chunks.
///
/// ## Parse Throttling
/// During streaming, the underlying MarkdownView (which runs a full CommonMark
/// parse + CoreText layout pass on every update) is throttled via the MarkdownView
/// library's built-in `lastHeightMeasureTime` coordinator — updated at most once
/// per frame (16ms). On top of that, SwiftUI's own coalescing means view updates
/// are already capped at display refresh rate.
///
/// ## Animated Height
/// The container height is animated with a spring so content grows smoothly
/// instead of jumping as new lines appear.
///
/// When streaming ends, `finalBody` takes over for special block detection
/// (charts, HTML, Mermaid, SVG, images).
struct StreamingMarkdownView: View {
    let content: String
    let isStreaming: Bool
    let textColor: SwiftUI.Color?

    @Environment(\.accessibilityScale) private var accessibilityScale

    /// Base body font size used by MarkdownTheme.default (UIFont.preferredFont(.body)).
    /// We scale relative to this so the user's content text scale applies correctly.
    private static let baseBodyFontSize: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize

    init(content: String, isStreaming: Bool, textColor: SwiftUI.Color? = nil) {
        self.content = content
        self.isStreaming = isStreaming
        self.textColor = textColor
    }

    /// Returns a MarkdownTheme with fonts scaled by the user's accessibility content scale,
    /// and optionally with the body text color overridden (for rendering on coloured backgrounds
    /// like the blue "sent" bubble in channels — UIKit-backed MarkdownView ignores SwiftUI
    /// foregroundStyle, so we must set the color directly in the theme).
    private var scaledTheme: MarkdownTheme {
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
        return theme
    }

    var body: some View {
        unifiedBody
    }

    // MARK: - Unified Body
    //
    // A single render path is used for both streaming and final states.
    // Keeping the same VStack+ForEach structure throughout ensures that
    // InlineVisualizerView keeps a stable identity in the SwiftUI view tree
    // across the streaming→final transition, so the WKWebView is never
    // destroyed and recreated (which was the cause of the visible flash).

    @ViewBuilder
    private var unifiedBody: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            let segments = resolveSegments()
            if segments.isEmpty {
                EmptyView()
            } else if segments.count == 1, case .markdown(let text) = segments[0] {
                // Fast path: plain markdown only — no viz, no ForEach overhead.
                MarkdownView(text, theme: scaledTheme)
                    .codeAutoScroll(true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(for: segment)
                    }
                }
            }
        }
    }

    /// Resolves the current content into renderable segments.
    ///
    /// During streaming, we use `streamingParse` to get a partial segment list
    /// so that `InlineVisualizerView` appears at the same `ForEach` offset it will
    /// occupy once streaming ends. This prevents SwiftUI from rebuilding the view
    /// tree when `isStreaming` flips to `false`.
    ///
    /// ## Performance: VIZ streaming optimisation
    /// When `@@@VIZ-START` is present, the message content contains a large
    /// `<details type="tool_calls">` block (~20-30 KB of HTML-entity-encoded
    /// embed HTML) BEFORE the VIZ markers. Passing this entire string to
    /// MarkdownView on every display-link tick (60fps) forces a full CommonMark
    /// parse + CoreText layout on the whole thing every frame — that is the
    /// primary cause of 104% CPU during VIZ streaming.
    ///
    /// Fix: during streaming, **never pass the pre-VIZ prose to MarkdownView**.
    /// The `<details>` block is already rendered by `ToolCallView`; MarkdownView
    /// only needs the post-VIZ text (the prose written AFTER `@@@VIZ-END`).
    /// We keep an empty `.markdown("")` placeholder at segment index 0 so the
    /// view tree stays stable (same ForEach identity) when streaming ends and
    /// the real pre-VIZ prose is restored.
    private func resolveSegments() -> [ContentSegment] {
        if isStreaming {
            // ── VIZ marker path (existing behaviour, unchanged) ──────────────
            let vizState = VizMarkerParser.streamingParse(content)
            switch vizState {
            case .noMarkers:
                break   // fall through to streaming code-block detection below

            case .streaming(_, let vizContent):
                let _ = vizLog.debug("StreamingMarkdownView: .streaming — passing empty pre-viz prose, vizLen=\(vizContent.count)")
                return [.markdown(""), .visualization(vizContent)]

            case .complete:
                let postViz = extractPostVizText(content)
                let _ = vizLog.debug("StreamingMarkdownView: .complete during streaming — postVizLen=\(postViz.count)")
                var result: [ContentSegment] = []
                result.append(.markdown(""))
                let vizContent = extractVizContent(content)
                result.append(.visualization(vizContent))
                if !postViz.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(postViz))
                }
                return result
            }

            // ── Streaming code-block detection (html / svg) ───────────────────
            // If the model is mid-way through a ```html or ```svg block (opening
            // fence seen, closing fence not yet arrived), render a live preview
            // instead of raw monospace text. This is the streaming analogue of
            // parseCodeBlocks — it only fires when isStreaming=true and the block
            // is incomplete. Once the closing ``` arrives, resolveSegments() falls
            // through to parseSpecialBlocks() which handles the complete block.
            if let streamingSeg = resolveStreamingCodeBlock(content) {
                return streamingSeg
            }

            // No incomplete special block found — but there may be a *complete* block
            // (opening AND closing fence both arrived) while post-block prose is still
            // streaming. Use parseSpecialBlocks so HTML/SVG/chart blocks already closed
            // render as previews instead of flashing to raw code text until streaming ends.
            return parseSpecialBlocks(content)

        } else {
            return parseSpecialBlocks(content)
        }
    }

    /// Detects an incomplete (unclosed) ` ```html ` or ` ```svg ` code block
    /// in `text` during streaming and returns a segment list with a live preview.
    ///
    /// Returns `nil` when no incomplete special block is found, letting the caller
    /// fall back to plain markdown rendering.
    private func resolveStreamingCodeBlock(_ text: String) -> [ContentSegment]? {
        // We only care about html and svg — mermaid needs complete syntax to render.
        let candidates: [(tag: String, makeSeg: (String) -> ContentSegment)] = [
            ("```html\n",  { .html($0, isStreaming: true) }),
            ("```svg\n",   { .svg($0, isStreaming: true) }),
        ]

        for (tag, makeSeg) in candidates {
            guard let openRange = text.range(of: tag, options: .caseInsensitive) else { continue }

            let contentStart = openRange.upperBound
            let afterOpen = text[contentStart...]

            // If the closing fence is already present, this is a complete block —
            // parseSpecialBlocks (non-streaming path) handles it. Skip here.
            if afterOpen.range(of: "\n```") != nil { continue }

            // Incomplete block — extract partial content
            let partialContent = String(afterOpen)
            // Anything before the opening fence is plain markdown
            let before = String(text[text.startIndex..<openRange.lowerBound])

            var result: [ContentSegment] = []
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(before))
            }
            if !partialContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(makeSeg(partialContent))
            }
            return result.isEmpty ? nil : result
        }
        return nil
    }

    /// Extracts the text that appears after `\n@@@VIZ-END` in the content.
    /// Returns an empty string if the end marker is not present.
    private func extractPostVizText(_ text: String) -> String {
        let endMarker = "\n@@@VIZ-END"
        guard let endRange = text.range(of: endMarker) else { return "" }
        let afterEnd = String(text[endRange.upperBound...])
        // Strip leading newline that typically follows @@@VIZ-END
        if afterEnd.hasPrefix("\n") {
            return String(afterEnd.dropFirst())
        }
        return afterEnd
    }

    /// Extracts the HTML/SVG content between `@@@VIZ-START` and `\n@@@VIZ-END`.
    /// Returns an empty string if the start marker is not present.
    private func extractVizContent(_ text: String) -> String {
        let startMarker = "@@@VIZ-START"
        let endMarker = "\n@@@VIZ-END"
        guard let startRange = text.range(of: startMarker) else { return "" }
        var contentStart = startRange.upperBound
        if contentStart < text.endIndex, text[contentStart] == "\n" {
            contentStart = text.index(after: contentStart)
        }
        if let endRange = text.range(of: endMarker, range: contentStart..<text.endIndex) {
            return String(text[contentStart..<endRange.lowerBound])
        }
        return String(text[contentStart...])
    }

    /// Returns the SwiftUI view for a single content segment.
    /// `isStreaming` is forwarded to `InlineVisualizerView` so the existing WKWebView
    /// continues receiving `reconcileContent` / `finalizeContent` JS calls without
    /// being recreated.
    @ViewBuilder
    private func segmentView(for segment: ContentSegment) -> some View {
        switch segment {
        case .markdown(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownView(text, theme: scaledTheme)
                    .codeAutoScroll(true)
            }
        case .chart(let code):
            if let spec = tryParseChart(code: code) {
                ChartPreviewView(spec: spec, rawCode: code, language: "json")
            } else {
                MarkdownView("```json\n\(code)\n```", theme: scaledTheme)
            }
        case .html(let code, let streaming):
            HTMLPreviewView(html: code, isStreaming: streaming)
        case .mermaid(let code):
            MermaidPreviewView(code: code)
        case .svg(let code, let streaming):
            SVGPreviewView(code: code, isStreaming: streaming)
        case .python(let code):
            PythonCodeBlockView(code: code)
        case .markdownImage(let imageURL, let altText, let linkURL):
            MarkdownInlineImageView(imageURL: imageURL, altText: altText, linkURL: linkURL)
        case .visualization(let html):
            // Pass isStreaming only while the VIZ block itself is still open.
            // Once \n@@@VIZ-END has arrived in the content the visualization is
            // complete — pass false so InlineVisualizerView calls finalizeContent()
            // and stops the spinner, even if the overall message stream is still active
            // (e.g. post-VIZ prose is still draining character-by-character).
            let vizComplete = content.contains("\n@@@VIZ-END")
            let vizIsStreaming = isStreaming && !vizComplete
            let _ = vizLog.debug("StreamingMarkdownView: rendering InlineVisualizerView isStreaming=\(vizIsStreaming) (vizComplete=\(vizComplete)), htmlLen=\(html.count)")
            InlineVisualizerView(content: html, isStreaming: vizIsStreaming)
        }
    }

    // MARK: - Special Block Detection (final render only)

    private let chartLanguageTags: Set<String> = [
        "json", "chart", "chartjs", "echarts", "highcharts",
        "vega-lite", "vegalite", "plotly"
    ]

    private let pythonLanguageTags: Set<String> = ["python", "python3", "py"]

    private enum ContentSegment {
        case markdown(String)
        case chart(String)
        /// `isStreaming` — true while the closing ``` fence has not yet arrived.
        case html(String, isStreaming: Bool)
        case mermaid(String)
        /// `isStreaming` — true while the closing ``` fence has not yet arrived.
        case svg(String, isStreaming: Bool)
        case python(String)
        case markdownImage(imageURL: URL, altText: String, linkURL: URL?)
        case visualization(String)
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
                      imgURL.scheme == "http" || imgURL.scheme == "https"
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
                      imgURL.scheme == "http" || imgURL.scheme == "https"
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
        // 0) First check for VIZ markers and expand them into segments.
        //    Each text chunk from the VIZ parse is then processed for images + code blocks.
        let vizSegments = VizMarkerParser.parse(text)
        let hasViz = vizSegments.contains { if case .visualization = $0 { return true }; return false }
        if hasViz {
            var result: [ContentSegment] = []
            for seg in vizSegments {
                switch seg {
                case .text(let chunk):
                    result.append(contentsOf: parseImagesAndCodeBlocks(chunk))
                case .visualization(let html):
                    result.append(.visualization(html))
                }
            }
            return result.isEmpty ? [.markdown(text)] : result
        }

        // 1) Extract markdown images first, splitting the text around them.
        //    This runs before code-block detection so images inside prose are found.
        let images = findMarkdownImages(in: text)

        if images.isEmpty {
            // No images — fall through to code-block parsing directly.
            return parseCodeBlocks(text)
        }

        var segments: [ContentSegment] = []
        var cursor = text.startIndex

        for img in images {
            // Text before this image
            if cursor < img.range.lowerBound {
                let preceding = String(text[cursor..<img.range.lowerBound])
                // Parse code blocks within the preceding text chunk
                segments.append(contentsOf: parseCodeBlocks(preceding))
            }
            // The image itself
            segments.append(.markdownImage(imageURL: img.imageURL, altText: img.altText, linkURL: img.linkURL))
            cursor = img.range.upperBound
        }

        // Remaining text after the last image
        if cursor < text.endIndex {
            let remaining = String(text[cursor..<text.endIndex])
            segments.append(contentsOf: parseCodeBlocks(remaining))
        }

        return segments.isEmpty ? [.markdown(text)] : segments
    }

    /// Convenience combining markdown-image extraction and code-block parsing.
    /// Used by `parseSpecialBlocks` when splitting text chunks from VIZ segments.
    private func parseImagesAndCodeBlocks(_ text: String) -> [ContentSegment] {
        let images = findMarkdownImages(in: text)
        guard !images.isEmpty else { return parseCodeBlocks(text) }

        var segments: [ContentSegment] = []
        var cursor = text.startIndex
        for img in images {
            if cursor < img.range.lowerBound {
                segments.append(contentsOf: parseCodeBlocks(String(text[cursor..<img.range.lowerBound])))
            }
            segments.append(.markdownImage(imageURL: img.imageURL, altText: img.altText, linkURL: img.linkURL))
            cursor = img.range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(contentsOf: parseCodeBlocks(String(text[cursor..<text.endIndex])))
        }
        return segments.isEmpty ? [.markdown(text)] : segments
    }

    /// Parses code blocks (chart/html/mermaid/svg/python) from a text chunk that
    /// has already had markdown images extracted.
    private func parseCodeBlocks(_ text: String) -> [ContentSegment] {
        guard text.contains("```") else { return [.markdown(text)] }

        var segments: [ContentSegment] = []
        var remaining = text[text.startIndex...]

        while let openRange = remaining.range(of: "```") {
            let afterOpen = remaining[openRange.upperBound...]
            guard let newlineIdx = afterOpen.firstIndex(of: "\n") else {
                segments.append(.markdown(String(remaining)))
                return segments
            }
            let lang = afterOpen[afterOpen.startIndex..<newlineIdx]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let contentStart = afterOpen.index(after: newlineIdx)
            let searchArea = remaining[contentStart...]
            guard let closeRange = searchArea.range(of: "\n```") else {
                segments.append(.markdown(String(remaining)))
                return segments
            }
            let codeContent = String(remaining[contentStart..<closeRange.lowerBound])
            let isChart = chartLanguageTags.contains(lang) && looksLikeChartJSON(codeContent)
            let isHTML = lang == "html" && codeContent.contains("<") && codeContent.contains(">") && codeContent.count >= 10
            let isMermaid = lang == "mermaid" && codeContent.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
            let isSVG = lang == "svg" && looksLikeSVG(codeContent)
            let isPython = pythonLanguageTags.contains(lang) && codeContent.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2

            if isChart || isHTML || isMermaid || isSVG || isPython {
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.markdown(preceding))
                }
                if isChart { segments.append(.chart(codeContent)) }
                else if isMermaid { segments.append(.mermaid(codeContent)) }
                else if isSVG { segments.append(.svg(codeContent, isStreaming: false)) }
                else if isPython { segments.append(.python(codeContent)) }
                else { segments.append(.html(codeContent, isStreaming: false)) }
                remaining = remaining[closeRange.upperBound...]
            } else {
                let blockEnd = closeRange.upperBound
                segments.append(.markdown(String(remaining[remaining.startIndex..<blockEnd])))
                remaining = remaining[blockEnd...]
            }
        }

        if !remaining.isEmpty {
            let s = String(remaining)
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(s))
            }
        }

        return segments.isEmpty ? [.markdown(text)] : segments
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
private struct MarkdownInlineImageView: View {
    let imageURL: URL
    let altText: String
    let linkURL: URL?

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
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
        .onTapGesture {
            // If the image is wrapped in a link, open the link URL.
            // Otherwise, open the image URL directly.
            if let linkURL {
                openURL(linkURL)
            } else {
                openURL(imageURL)
            }
        }
        .accessibilityLabel(altText.isEmpty ? "Image" : altText)
        .accessibilityAddTraits(.isImage)
        .accessibilityAddTraits(.isLink)
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
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
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
        if isLoading && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            TypingIndicator()
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
