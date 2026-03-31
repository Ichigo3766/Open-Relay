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
/// (charts, HTML, Mermaid, SVG).
struct StreamingMarkdownView: View {
    let content: String
    let isStreaming: Bool
    let textColor: SwiftUI.Color?

    // The version of content currently shown during streaming.
    // Updated on the 300ms flush tick, not on every token.
    @State private var displayContent: String = ""
    @State private var flushTask: Task<Void, Never>? = nil

    @Environment(\.accessibilityScale) private var accessibilityScale

    private static let flushInterval: Double = 0.3

    /// Base body font size used by MarkdownTheme.default (UIFont.preferredFont(.body)).
    /// We scale relative to this so the user's content text scale applies correctly.
    private static let baseBodyFontSize: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize

    init(content: String, isStreaming: Bool, textColor: SwiftUI.Color? = nil) {
        self.content = content
        self.isStreaming = isStreaming
        self.textColor = textColor
    }

    /// Returns a MarkdownTheme with fonts scaled by the user's accessibility content scale.
    private var scaledTheme: MarkdownTheme {
        let scale = accessibilityScale.scale(for: .content)
        guard abs(scale - 1.0) > 0.01 else { return .default }
        var theme = MarkdownTheme.default
        theme.align(to: Self.baseBodyFontSize * scale)
        return theme
    }

    var body: some View {
        Group {
            if isStreaming {
                streamingBody
            } else {
                finalBody
            }
        }
        .onAppear {
            if isStreaming {
                displayContent = content
            }
        }
        .onChange(of: content) { _, newContent in
            guard isStreaming else { return }
            armFlush(newContent: newContent)
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                flushTask?.cancel()
                flushTask = nil
                displayContent = content
            }
        }
    }

    // MARK: - Streaming Body

    @ViewBuilder
    private var streamingBody: some View {
        if displayContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            // .codeAutoScroll(true) → CodeView auto-scrolls to bottom as new
            // lines arrive during streaming. User can scroll up manually and the
            // FAB appears to jump back to the bottom.
            MarkdownView(displayContent, theme: scaledTheme).codeAutoScroll(true)
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
                    }
                }
            }
        }
    }

    // MARK: - Throttled Flush

    private func armFlush(newContent: String) {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.flushInterval))
            guard !Task.isCancelled else { return }
            displayContent = newContent
            flushTask = nil
        }
    }

    // MARK: - Special Block Detection (final render only)

    private let chartLanguageTags: Set<String> = [
        "json", "chart", "chartjs", "echarts", "highcharts",
        "vega-lite", "vegalite", "plotly"
    ]

    private enum ContentSegment {
        case markdown(String)
        case chart(String)
        case html(String)
        case mermaid(String)
        case svg(String)
    }

    private func parseSpecialBlocks(_ text: String) -> [ContentSegment] {
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

            if isChart || isHTML || isMermaid || isSVG {
                let preceding = String(remaining[remaining.startIndex..<openRange.lowerBound])
                if !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.markdown(preceding))
                }
                if isChart { segments.append(.chart(codeContent)) }
                else if isMermaid { segments.append(.mermaid(codeContent)) }
                else if isSVG { segments.append(.svg(codeContent)) }
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
                """,
                isStreaming: false
            )
        }
        .padding()
    }
    .themed()
}
