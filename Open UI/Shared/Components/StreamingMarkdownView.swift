import SwiftUI
import MarkdownView
import Charts

// MARK: - Streaming Markdown View

/// Renders markdown using MarkdownView (UIKit-backed).
///
/// Uses a three-layer throttle to keep streaming at 60fps:
/// 1. **ContentAccumulator** (upstream) — batches socket tokens to ~15/sec.
/// 2. **Render throttle** (this file) — passes content to MarkdownView at ~7fps.
/// 3. **Special block skip** — skips `parseSpecialBlocks()` during streaming.
struct StreamingMarkdownView: View {
    let content: String
    let isStreaming: Bool
    let textColor: SwiftUI.Color?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    // Throttled content: only updated at ~15fps during streaming to avoid
    // triggering expensive MarkdownView parse+layout on every token.
    @State private var renderedContent: String = ""
    @State private var lastRenderTime: CFAbsoluteTime = 0

    // 15fps ≈ 67ms per frame — smooth enough to feel like fast typing.
    private static let renderInterval: CFAbsoluteTime = 1.0 / 15.0

    init(content: String, isStreaming: Bool, textColor: SwiftUI.Color? = nil) {
        self.content = content
        self.isStreaming = isStreaming
        self.textColor = textColor
    }

    var body: some View {
        // Use throttled content during streaming; direct content after.
        let displayContent = isStreaming ? renderedContent : content

        Group {
            if displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyView()
            } else if isStreaming {
                // Skip parseSpecialBlocks during streaming — charts/HTML/mermaid
                // fall back to code blocks anyway and the scan wastes main-thread time.
                MarkdownView(displayContent)
            } else {
                // Full special block detection after streaming completes.
                let parsed = parseSpecialBlocks(displayContent)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(parsed.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .markdown(let text):
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                MarkdownView(text)
                            }

                        case .chart(let code):
                            if let spec = tryParseChart(code: code) {
                                ChartPreviewView(spec: spec, rawCode: code, language: "json")
                            } else {
                                MarkdownView("```json\n\(code)\n```")
                            }

                        case .html(let code):
                            HTMLPreviewView(html: code)

                        case .mermaid(let code):
                            MermaidPreviewView(code: code)

                        case .svg(let code):
                            SVGPreviewView(code: code)
                        }
                    }
                }
            }
        }
        .onAppear {
            renderedContent = content
            lastRenderTime = CFAbsoluteTimeGetCurrent()
        }
        // Throttle: update renderedContent at ~15fps during streaming.
        // Not streaming → update immediately (final content, version switch, etc.)
        .onChange(of: content) { _, newContent in
            guard isStreaming else {
                renderedContent = newContent
                return
            }
            let now = CFAbsoluteTimeGetCurrent()
            if renderedContent.isEmpty || now - lastRenderTime >= Self.renderInterval {
                renderedContent = newContent
                lastRenderTime = now
            }
        }
        // Flush any remaining buffered content when streaming ends.
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                renderedContent = content
            }
        }
    }

    // MARK: - Special Block Detection

    /// Language tags that trigger chart rendering.
    private let chartLanguageTags: Set<String> = [
        "json", "chart", "chartjs", "echarts", "highcharts",
        "vega-lite", "vegalite", "plotly"
    ]

    /// Content segment — either regular markdown or a special code block.
    private enum ContentSegment {
        case markdown(String)
        case chart(String)
        case html(String)
        case mermaid(String)
        case svg(String)
    }

    /// Scans the content for ```html and ```chart-type code blocks.
    /// Splits the content into segments so special blocks can be rendered
    /// with their own views while the rest goes to MarkdownView.
    ///
    /// NOTE: Only called when `isStreaming == false`. During streaming,
    /// this scan is skipped entirely (OPT 4) because charts, HTML, and
    /// mermaid all fall back to code blocks during streaming anyway.
    private func parseSpecialBlocks(_ text: String) -> [ContentSegment] {
        // Fast path: no code blocks at all
        guard text.contains("```") else {
            return [.markdown(text)]
        }

        var segments: [ContentSegment] = []
        var remaining = text[text.startIndex...]
        // Pattern: ```lang\n...content...\n```
        // We look for opening ``` with a language tag, then the matching closing ```
        while let openRange = remaining.range(of: "```") {
            let afterOpen = remaining[openRange.upperBound...]

            // Extract language tag (everything up to the next newline)
            guard let newlineIdx = afterOpen.firstIndex(of: "\n") else {
                // No newline after ``` — treat as regular markdown
                segments.append(.markdown(String(remaining)))
                return segments
            }

            let lang = afterOpen[afterOpen.startIndex..<newlineIdx]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let contentStart = afterOpen.index(after: newlineIdx)

            // Find closing ```
            let searchArea = remaining[contentStart...]
            guard let closeRange = searchArea.range(of: "\n```") else {
                // No closing ``` — treat everything as regular markdown
                segments.append(.markdown(String(remaining)))
                return segments
            }

            let codeContent = String(remaining[contentStart..<closeRange.lowerBound])

            // Check if this is a special block
            let isChart = chartLanguageTags.contains(lang) && looksLikeChartJSON(codeContent)
            let isHTML = lang == "html" && codeContent.contains("<") && codeContent.contains(">") && codeContent.count >= 10
            let isMermaid = lang == "mermaid" && codeContent.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
            let isSVG = lang == "svg" && looksLikeSVG(codeContent)

            if isChart || isHTML || isMermaid || isSVG {
                // Add preceding markdown (before the opening ```)
                let precedingText = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.markdown(precedingText))
                }

                if isChart {
                    segments.append(.chart(codeContent))
                } else if isMermaid {
                    segments.append(.mermaid(codeContent))
                } else if isSVG {
                    segments.append(.svg(codeContent))
                } else {
                    segments.append(.html(codeContent))
                }

                // Move past the closing ```
                remaining = remaining[closeRange.upperBound...]
            } else {
                // Not a special block — include the whole fenced block as markdown
                let blockEnd = closeRange.upperBound
                let chunk = String(remaining[remaining.startIndex..<blockEnd])
                segments.append(.markdown(chunk))
                remaining = remaining[blockEnd...]
            }
        }

        // Remaining text after all special blocks
        if !remaining.isEmpty {
            let remainingStr = String(remaining)
            if !remainingStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(remainingStr))
            }
        }

        // If no special blocks were found, return as single markdown segment
        if segments.isEmpty {
            return [.markdown(text)]
        }

        return segments
    }

    /// Quick heuristic: does this look like chart JSON?
    private func looksLikeChartJSON(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
            && (trimmed.contains("\"data\"") || trimmed.contains("\"datasets\"")
                || trimmed.contains("\"series\"") || trimmed.contains("\"values\"")
                || trimmed.contains("\"labels\"") || trimmed.contains("\"type\""))
    }

    /// Quick heuristic: does this look like SVG markup?
    private func looksLikeSVG(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("<svg") || trimmed.contains("<svg ")
            || trimmed.contains("xmlns=\"http://www.w3.org/2000/svg\"")
    }

    /// Attempts to parse chart JSON. Returns nil on failure.
    private func tryParseChart(code: String) -> USpec? {
        guard let data = code.data(using: .utf8) else { return nil }
        return try? parseUSpec(from: data)
    }
}

// MARK: - Streaming Content Environment Key

/// Environment key that tells code block views whether content is still streaming.
private struct IsStreamingContentKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isStreamingContent: Bool {
        get { self[IsStreamingContentKey.self] }
        set { self[IsStreamingContentKey.self] = newValue }
    }
}

// MARK: - Streaming HTML Code View

/// Simple plain text view for streaming HTML code blocks.
private struct StreamingHTMLCodeView: View {
    let code: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("html")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.quaternary.opacity(0.3))

            Divider()

            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(colorScheme == .dark ? Color(.systemGray) : Color(.darkGray))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        )
    }
}

// MARK: - Full Code View (Fullscreen)

/// A fullscreen view for viewing the complete source code of a truncated
/// code block. Shows the full highlighted code with copy and share buttons.
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
                        Button("Done") {
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // Copy
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
                                .font(.system(size: 14, weight: .medium))
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

                ```swift
                struct GreetingView: View {
                    var body: some View {
                        Text("Hello!")
                    }
                }
                ```

                > A blockquote for good measure.
                """,
                isStreaming: false
            )
        }
        .padding()
    }
    .themed()
}
