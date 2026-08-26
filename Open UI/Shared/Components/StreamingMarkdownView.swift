import UIKit
import SwiftUI
import MarkdownView
import Charts
import Photos
import os.log

private let vizLog = Logger(subsystem: "com.openui", category: "VizPipeline")

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
    ///
    /// Also caches the opening fence location for `resolveStreamingCodeBlock()`.
    /// Once the fence is found (Phase 1 or Phase 2 of that function), subsequent
    /// ticks only scan the *new* suffix for a closing fence — O(delta) instead of
    /// the previous O(N) × 4 full re-scan on every drain tick.
    private final class SegmentCache {
        // parseSpecialBlocks cache
        var content: String = ""
        var isStreaming: Bool = false
        var segments: [ContentSegment] = []

        // Fence location cache for resolveStreamingCodeBlock fast path.
        //
        // `fenceContentStart` is the String.Index of the first character of the
        // code block body (i.e. the char just after the opening fence's \n).
        // It is stable for the entire life of an open code block because content
        // only grows by appending — the fence never moves.
        //
        // `fenceBaseByteCount` is the utf8.count of `content` when the fence was
        // found. On each new tick we verify content.utf8.count > fenceBaseByteCount
        // (always true for an append) and that content[..<fenceContentStart] still
        // matches (implicit — Swift indices are stable under appends).
        var fenceContentStart: String.Index? = nil
        var fenceBaseByteCount: Int = 0
        var fenceLanguage: String = ""
        // true → Phase 1 (html/svg live-preview); false → Phase 2 (generic .streamingCode)
        var fenceIsLivePreview: Bool = false
        // Phase 1 only: the makeSeg closure cached so we don't re-allocate the array literal
        var fenceMakeSegTag: String = ""   // "html" or "svg"
        // Phase 1 only: text before the opening fence (stable once fence is found)
        var fenceBeforeText: String = ""
    }


    init(content: String, isStreaming: Bool, textColor: SwiftUI.Color? = nil) {
        self.content = content
        self.isStreaming = isStreaming
        self.textColor = textColor
    }

    var body: some View {
        unifiedBody
            // Animate layout changes only when streaming ends (isStreaming flips false→true
            // is intentionally excluded — animating during streaming would create per-token
            // animations at 60fps and re-introduce the old AttributeGraph cycle).
            // The `.value:` key ensures this animation fires exactly once per stream end,
            // smoothing the height settle when the final parse delivers its result.
            .animation(.easeOut(duration: 0.18), value: isStreaming)
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
    // InlineVisualizerView keeps a stable identity in the SwiftUI view tree
    // across the streaming→final transition, so the WKWebView is never
    // destroyed and recreated (which was the cause of the visible flash).

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
        let _ = maxContentWidth  // suppress unused-variable warning when not used in fast path
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            // Always re-parse on every tick during streaming so VIZ segments
            // appear on the same frame the @@@VIZ-START marker arrives.
            // resolveSegments() is cheap (a few .range(of:) calls on a short
            // string — the big <details> blob is stripped upstream before it
            // ever reaches StreamingMarkdownView).
            let segments: [ContentSegment] = resolveSegments()
            if segments.isEmpty {
                EmptyView()
            } else if !isStreaming, segments.count == 1, case .markdown(let text) = segments[0].kind {
                // Fast path: plain markdown only — no viz, no ForEach overhead.
                // Only used when NOT streaming so the container type never changes
                // mid-stream. If we allowed this during streaming, the view would
                // swap from bare MarkdownView → VStack{ForEach} the moment a code
                // fence appears, destroying the prose view for one frame (blank flash).
                MarkdownView(text, theme: cachedTheme)
                    .codeAutoScroll(isStreaming)
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

    /// Resolves the current content into renderable segments.
    ///
    /// During streaming, we use `streamingParse` to get a partial segment list
    /// so that `InlineVisualizerView` appears at the same `ForEach` offset it will
    /// occupy once streaming ends. This prevents SwiftUI from rebuilding the view
    /// tree when `isStreaming` flips to `false`.
    ///
    /// ## Performance: VIZ streaming optimisation
    /// The `<details type="tool_calls">` block that used to appear before VIZ
    /// markers is now stripped upstream by `ToolCallParser.parseOrdered()` inside
    /// `AssistantMessageContent` before the text ever reaches `StreamingMarkdownView`.
    /// By the time we see the content, the pre-VIZ prose is just a short settled
    /// string (e.g. "Here's a cute little pig for you! 🐷") — safe to pass to
    /// MarkdownView on every tick with negligible cost.
    ///
    /// We therefore pass the real pre-VIZ prose through rather than an empty
    /// placeholder. This fixes the visible flash where the prose text disappeared
    /// during VIZ streaming and only reappeared once the stream finished.
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

    private func resolveSegments() -> [ContentSegment] {
        // When streaming, hide any Base64 data URI that hasn't fully arrived yet.
        // The raw base64 payload is stripped from display until the closing `)` lands
        // and `findMarkdownImages` can decode + render the complete image.
        let content = isStreaming ? Self.stripIncompleteDataURIs(self.content) : self.content

        if isStreaming {
            // ── VIZ marker path ───────────────────────────────────────────────
            let vizState = VizMarkerParser.streamingParse(content)
            switch vizState {
            case .noMarkers:
                break   // fall through to streaming code-block detection below

            case .streaming(let proseBeforeMarker, let vizContent):
                let _ = vizLog.debug("StreamingMarkdownView: .streaming — proseLen=\(proseBeforeMarker.count), vizLen=\(vizContent.count)")
                return [.markdown(proseBeforeMarker, index: 0), .visualization(vizContent, index: 0)]

            case .complete:
                let preViz = extractPreVizText(content)
                let postViz = extractPostVizText(content)
                let _ = vizLog.debug("StreamingMarkdownView: .complete during streaming — preVizLen=\(preViz.count), postVizLen=\(postViz.count)")
                var result: [ContentSegment] = []
                result.append(.markdown(preViz, index: 0))
                let vizContent = extractVizContent(content)
                result.append(.visualization(vizContent, index: 0))
                if !postViz.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(postViz, index: 1))
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
            //
            // CACHE: parseSpecialBlocks / parseCodeBlocks is O(N) and was previously
            // called on every drain tick (~60fps) once a code block's closing fence
            // arrived. The content string only grows by ~7 chars per tick (maxRatePerFrame),
            // so consecutive ticks with identical content are pure wasted work.
            // Cache the result and return it directly on a hit (O(1) COW pointer check).
            return cachedParseSpecialBlocks(content, isStreaming: true)

        } else {
            // Non-streaming: content never changes after first render — cache ensures
            // parseSpecialBlocks runs exactly once per message lifetime.
            return cachedParseSpecialBlocks(content, isStreaming: false)
        }
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

    /// Detects an incomplete (unclosed) fenced code block in `text` during streaming.
    ///
    /// **Priority order:**
    /// 1. `html` / `svg` → live preview via `HTMLPreviewView` / `SVGPreviewView`
    /// 2. Any other language → `StreamingCodeBlockView` (O(delta) append + O(viewport) windowed render)
    ///
    /// Returns `nil` when no incomplete fenced code block is found, letting the
    /// caller fall back to plain markdown rendering via `MarkdownView`.
    ///
    /// ## Performance
    /// After the opening fence is located on the first call, the fence position is
    /// cached in `segmentCache`. Subsequent ticks (where `text` is always an append
    /// of the previous `text`) skip all four O(N) `range(of:)` scans and only scan
    /// the *new* suffix for a closing fence — reducing per-tick cost to O(delta).
    private func resolveStreamingCodeBlock(_ text: String) -> [ContentSegment]? {
        let textByteCount = text.utf8.count

        // ── FAST PATH: fence already located and text is a streaming append ──
        // `fenceContentStart` is valid when we previously found an open fence and
        // the content has only grown (utf8 count is strictly larger than when found).
        if let cachedStart = segmentCache.fenceContentStart,
           textByteCount > segmentCache.fenceBaseByteCount {
            // Only scan the suffix *after* the known fence start for a closing fence.
            // This is O(delta) — proportional only to newly-appended characters.
            let afterOpen = text[cachedStart...]
            if afterOpen.range(of: "\n```") != nil {
                // Closing fence just arrived — invalidate and fall through to slow path
                // so parseSpecialBlocks (caller's fallback) handles the complete block.
                segmentCache.fenceContentStart = nil
                return nil
            }
            // Still open — build result from cached metadata + growing suffix.
            let partialContent = String(afterOpen)
            if segmentCache.fenceIsLivePreview {
                let tag = segmentCache.fenceMakeSegTag
                let makeSeg: (String) -> ContentSegment = { content in
                    switch tag {
                    case "html":    return .html(content, isStreaming: true, index: 0)
                    case "svg":     return .svg(content, isStreaming: true, index: 0)
                    case "mermaid": return .mermaid(content, isStreaming: true, index: 0)
                    default:        return .chart(content, isStreaming: true, index: 0)
                    }
                }
                let before = segmentCache.fenceBeforeText
                var result: [ContentSegment] = []
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(before, index: 0))
                }
                if !partialContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(makeSeg(partialContent))
                }
                return result.isEmpty ? nil : result
            } else {
                // Phase 2 generic code block
                let before = segmentCache.fenceBeforeText
                var result: [ContentSegment] = []
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(before, index: 0))
                }
                result.append(.streamingCode(partialContent, language: segmentCache.fenceLanguage, index: 0))
                return result
            }
        }

        // ── SLOW PATH: first call or content replaced — locate fence via full scan ──
        // Runs at most once per code block (until closing fence arrives).

        // ── Phase 1: Live-preview languages (html/svg/mermaid/chart) ───────
        let livePreviewCandidates: [(tag: String, langKey: String)] = [
            ("```html\n",      "html"),
            ("```svg\n",       "svg"),
            ("```mermaid\n",   "mermaid"),
            ("```chart\n",     "chart"),
            ("```chartjs\n",   "chart"),
            ("```echarts\n",   "chart"),
            ("```highcharts\n","chart"),
            ("```plotly\n",    "chart"),
            ("```vega-lite\n", "chart"),
            ("```vegalite\n",  "chart"),
        ]
        for (tag, langKey) in livePreviewCandidates {
            guard let openRange = text.range(of: tag, options: .caseInsensitive) else { continue }
            let contentStart = openRange.upperBound
            let afterOpen = text[contentStart...]
            if afterOpen.range(of: "\n```") != nil { continue }  // complete — skip

            let partialContent = String(afterOpen)
            let before = String(text[text.startIndex..<openRange.lowerBound])

            // Cache fence location for fast path on next tick.
            segmentCache.fenceContentStart = contentStart
            segmentCache.fenceBaseByteCount = textByteCount
            segmentCache.fenceIsLivePreview = true
            segmentCache.fenceMakeSegTag = langKey
            segmentCache.fenceLanguage = langKey
            segmentCache.fenceBeforeText = before

            let makeSeg: (String) -> ContentSegment = { content in
                switch langKey {
                case "html":    return .html(content, isStreaming: true, index: 0)
                case "svg":     return .svg(content, isStreaming: true, index: 0)
                case "mermaid": return .mermaid(content, isStreaming: true, index: 0)
                default:        return .chart(content, isStreaming: true, index: 0)
                }
            }
            var result: [ContentSegment] = []
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(before, index: 0))
            }
            if !partialContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(makeSeg(partialContent))
            }
            return result.isEmpty ? nil : result
        }

        // ── Phase 2: Generic unclosed fence → StreamingCodeBlockView ───────
        guard let fenceStart = text.range(of: "```") else { return nil }
        let afterTicks = text[fenceStart.upperBound...]

        let language: String
        let partialContent: String

        if let newlineAfterFence = afterTicks.firstIndex(of: "\n") {
            language = String(afterTicks[afterTicks.startIndex..<newlineAfterFence])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let contentStart = text.index(after: newlineAfterFence)
            let afterOpen = text[contentStart...]
            if afterOpen.range(of: "\n```") != nil { return nil }  // complete block
            partialContent = String(afterOpen)

            let before = String(text[text.startIndex..<fenceStart.lowerBound])

            // Cache fence location only once the fence line is complete (has \n).
            // Do NOT cache when the fence line is still arriving — the endIndex of
            // the partial text would become a mid-string index in the next tick's
            // longer string, corrupting the language label and first content line.
            segmentCache.fenceContentStart = contentStart
            segmentCache.fenceBaseByteCount = textByteCount
            segmentCache.fenceIsLivePreview = false
            segmentCache.fenceLanguage = language
            segmentCache.fenceBeforeText = before

            var result: [ContentSegment] = []
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(before, index: 0))
            }
            result.append(.streamingCode(partialContent, language: language, index: 0))
            return result
        } else {
            // Fence line still arriving (e.g. "```python" with no \n yet).
            // Do NOT cache — the index would be invalid in the next tick's longer string.
            language = String(afterTicks).trimmingCharacters(in: .whitespaces).lowercased()
            partialContent = ""
            let before = String(text[text.startIndex..<fenceStart.lowerBound])
            var result: [ContentSegment] = []
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(before, index: 0))
            }
            // Still emit .streamingCode with empty content to stabilise view identity.
            result.append(.streamingCode(partialContent, language: language, index: 0))
            return result
        }
    }

    /// Extracts the text that appears before `@@@VIZ-START` in the content.
    /// Returns the full text if the start marker is not present.
    private func extractPreVizText(_ text: String) -> String {
        guard let startRange = VizMarkerParser.findRealStartMarkerRange(in: text) else { return text }
        return String(text[text.startIndex..<startRange.lowerBound])
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
        let endMarker = "\n@@@VIZ-END"
        guard let startRange = VizMarkerParser.findRealStartMarkerRange(in: text) else { return "" }
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
        switch segment.kind {
        case .markdown(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownView(text, theme: cachedTheme)
                    .codeAutoScroll(isStreaming)
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
        case .streamingCode(let code, let language):
            StreamingCodeBlockView(
                language: language,
                content: code,
                isStreaming: true,
                theme: cachedTheme
            )
        case .code(let code, let language):
            // Finalized large code block — rendered via StreamingCodeBlockView(isStreaming:false)
            // to avoid the O(n) CommonMark parse spike MarkdownView triggers on transition.
            StreamingCodeBlockView(
                language: language,
                content: code,
                isStreaming: false,
                theme: cachedTheme
            )
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
            /// A code block being actively streamed (unclosed fence). Rendered via
            /// `StreamingCodeBlockView` which uses O(delta) incremental appends and
            /// O(viewport) virtual line windowing — bypasses IncrementalStreamingParser
            /// entirely to avoid O(n²) re-parse lag on large blocks.
            case streamingCode(String, language: String)
            /// A finalized (closed fence) large plain code block (>50 lines). Rendered
            /// via `StreamingCodeBlockView(isStreaming: false)` to bypass the O(n)
            /// CommonMark full-parse spike ("Frame of Doom") that MarkdownView triggers
            /// the moment a big code block transitions from streaming → done.
            case code(String, language: String)
            case markdownImage(imageURL: URL, altText: String, linkURL: URL?)
            case visualization(String)

            /// Short type tag used in the stable `id`.
            var typeTag: String {
                switch self {
                case .markdown:      return "md"
                case .chart:         return "chart"
                case .html:          return "html"
                case .mermaid:       return "mermaid"
                case .svg:           return "svg"
                case .python:        return "python"
                case .streamingCode: return "scode"
                case .code:          return "code"
                case .markdownImage: return "img"
                case .visualization: return "viz"
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
        static func streamingCode(_ code: String, language: String, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "scode-\(index)", kind: .streamingCode(code, language: language))
        }
        static func code(_ code: String, language: String, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "code-\(index)", kind: .code(code, language: language))
        }
        static func markdownImage(imageURL: URL, altText: String, linkURL: URL?, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "img-\(index)", kind: .markdownImage(imageURL: imageURL, altText: altText, linkURL: linkURL))
        }
        static func visualization(_ html: String, index: Int = 0) -> ContentSegment {
            ContentSegment(id: "viz-\(index)", kind: .visualization(html))
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
        // 0) First check for VIZ markers and expand them into segments.
        //    Each text chunk from the VIZ parse is then processed for images + code blocks.
        let vizSegments = VizMarkerParser.parse(text)
        let hasViz = vizSegments.contains { if case .visualization = $0 { return true }; return false }
        if hasViz {
            var result: [ContentSegment] = []
            for seg in vizSegments {
                switch seg {
                case .text(let chunk):
                    result.append(contentsOf: parseImagesAndCodeBlocks(chunk, baseOffset: result.count))
                case .visualization(let html):
                    let vizIdx = result.filter { if case .visualization = $0.kind { return true }; return false }.count
                    result.append(.visualization(html, index: vizIdx))
                }
            }
            return result.isEmpty ? [.markdown(text, index: 0)] : result
        }

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

    /// Convenience combining markdown-image extraction and code-block parsing.
    /// Used by `parseSpecialBlocks` when splitting text chunks from VIZ segments.
    private func parseImagesAndCodeBlocks(_ text: String, baseOffset: Int = 0) -> [ContentSegment] {
        let images = findMarkdownImages(in: text)
        guard !images.isEmpty else { return parseCodeBlocks(text, baseOffset: baseOffset) }

        var segments: [ContentSegment] = []
        var cursor = text.startIndex
        for img in images {
            if cursor < img.range.lowerBound {
                segments.append(contentsOf: parseCodeBlocks(String(text[cursor..<img.range.lowerBound]), baseOffset: baseOffset + segments.count))
            }
            let imgIdx = segments.filter { if case .markdownImage = $0.kind { return true }; return false }.count
            segments.append(.markdownImage(imageURL: img.imageURL, altText: img.altText, linkURL: img.linkURL, index: imgIdx))
            cursor = img.range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(contentsOf: parseCodeBlocks(String(text[cursor..<text.endIndex]), baseOffset: baseOffset + segments.count))
        }
        return segments.isEmpty ? [.markdown(text, index: baseOffset)] : segments
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

        // Split into lines for fence detection. We work line-by-line so we can
        // apply the CommonMark closer rules precisely.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var segments: [ContentSegment] = []
        var i = 0
        var proseLinesStart = 0   // first line of the current prose run

        while i < lines.count {
            guard let fence = Self.parseFenceLine(lines[i]) else {
                i += 1
                continue
            }
            // lines[i] is a fence opener. Find its matching closer.
            let openerTickCount = fence.backtickCount
            let lang = fence.info.lowercased()

            guard let closerIdx = Self.findClosingFence(in: lines, from: i + 1, minTickCount: openerTickCount) else {
                // No matching closer found — unclosed block (or streaming). Treat
                // everything from here to end as plain markdown (MarkdownView handles it).
                i += 1
                continue
            }

            // Flush preceding prose lines as a .markdown segment.
            if proseLinesStart < i {
                let proseText = lines[proseLinesStart..<i].joined(separator: "\n")
                if !proseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let mdIdx = baseOffset + segments.filter { if case .markdown = $0.kind { return true }; return false }.count
                    segments.append(.markdown(proseText, index: mdIdx))
                }
            }

            // Extract code content (lines between opener and closer).
            let codeContent = lines[(i + 1)..<closerIdx].joined(separator: "\n")

            // Determine segment type based on language tag.
            let isChart = chartLanguageTags.contains(lang) && looksLikeChartJSON(codeContent)
            let isHTML = lang == "html" && codeContent.contains("<") && codeContent.contains(">") && codeContent.count >= 10
            let isMermaid = lang == "mermaid" && codeContent.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
            let isSVG = lang == "svg" && looksLikeSVG(codeContent)
            let isPython = pythonLanguageTags.contains(lang) && codeContent.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2

            // Per-type index for stable segment identity within this parse.
            let typeIdx = baseOffset + segments.count
            if isChart {
                segments.append(.chart(codeContent, isStreaming: false, index: typeIdx))
            } else if isMermaid {
                segments.append(.mermaid(codeContent, isStreaming: false, index: typeIdx))
            } else if isSVG {
                segments.append(.svg(codeContent, isStreaming: false, index: typeIdx))
            } else if isPython {
                segments.append(.python(codeContent, index: typeIdx))
            } else if isHTML {
                segments.append(.html(codeContent, isStreaming: false, index: typeIdx))
            } else {
                // Plain code block. For large blocks (>50 lines) use StreamingCodeBlockView
                // with isStreaming:false to avoid the O(n) CommonMark full-parse spike
                // ("Frame of Doom") that MarkdownView triggers on the streaming→done transition.
                let lineCount = codeContent.components(separatedBy: "\n").count
                if lineCount > 50 {
                    segments.append(.code(codeContent, language: lang, index: typeIdx))
                } else {
                    // Small block — reconstruct fenced markdown so MarkdownView renders it
                    // with syntax highlighting. Any literal ``` inside the code content
                    // (e.g. from nested blocks) are preserved as-is.
                    let fenceStr = String(repeating: "`", count: openerTickCount)
                    let fencedBlock = "\(fenceStr)\(lang)\n\(codeContent)\n\(fenceStr)"
                    let mdIdx = baseOffset + segments.filter { if case .markdown = $0.kind { return true }; return false }.count
                    segments.append(.markdown(fencedBlock, index: mdIdx))
                }
            }

            i = closerIdx + 1
            proseLinesStart = i
        }

        // Flush any trailing prose after the last code block.
        if proseLinesStart < lines.count {
            let trailingText = lines[proseLinesStart...].joined(separator: "\n")
            if !trailingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let mdIdx = baseOffset + segments.filter { if case .markdown = $0.kind { return true }; return false }.count
                segments.append(.markdown(trailingText, index: mdIdx))
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
private struct MarkdownInlineImageView: View {
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
                                guard let dataURI = await store.resolve(urlString: tokenString) else {
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
            guard let (data, _) = try? await URLSession.shared.data(from: imageURL) else { return }
            if let img = UIImage(data: data) {
                await MainActor.run { loadedRemoteImage = img }
            }
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
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                        .fontWeight(.semibold)
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
