import UIKit
import SwiftUI
import MarkdownView
import Charts

// MARK: - Streaming Markdown View

/// Renders markdown using MarkdownView (UIKit-backed).
///
/// During streaming, a single `MarkdownView` renders the full content string.
/// Updates are throttled to at most every 300ms so cmark parses at most 3-4×/sec,
/// keeping CPU low regardless of how fast tokens arrive.
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
        if isStreaming {
            streamingBody
        } else {
            finalBody
        }
    }

    // MARK: - Streaming Body

    @ViewBuilder
    private var streamingBody: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            // Render content directly — no flush delay.
            // cmark parses at token rate; only IsolatedAssistantMessage re-evaluates per token.
            MarkdownView(content, theme: scaledTheme).codeAutoScroll(true)
        }
    }

    // MARK: - Final Body (special block detection)

    @ViewBuilder
    private var finalBody: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            let parsed = parseSpecialBlocks(content)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(parsed.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let text):
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownView(text, theme: scaledTheme)
                        }
                    case .chart(let code):
                        if let spec = tryParseChart(code: code) {
                            ChartPreviewView(spec: spec, rawCode: code, language: "json")
                        } else {
                            MarkdownView("```json\n\(code)\n```", theme: scaledTheme)
                        }
                    case .html(let code):
                        HTMLPreviewView(html: code)
                    case .mermaid(let code):
                        MermaidPreviewView(code: code)
                    case .svg(let code):
                        SVGPreviewView(code: code)
                    case .python(let code):
                        PythonCodeBlockView(code: code)
                    case .markdownImage(let imageURL, let altText, let linkURL):
                        MarkdownInlineImageView(imageURL: imageURL, altText: altText, linkURL: linkURL)
                    }
                }
            }
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
        case html(String)
        case mermaid(String)
        case svg(String)
        case python(String)
        case markdownImage(imageURL: URL, altText: String, linkURL: URL?)
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
            let isHTML = lang == "HTML" && codeContent.contains("<") && codeContent.contains(">") && codeContent.count >= 10
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
                else if isSVG { segments.append(.svg(codeContent)) }
                else if isPython { segments.append(.python(codeContent)) }
                else { segments.append(.html(codeContent)) }
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
