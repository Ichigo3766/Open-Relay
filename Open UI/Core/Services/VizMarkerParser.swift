import Foundation

// MARK: - Viz Marker Parser

/// Parses `@@@VIZ-START` / `@@@VIZ-END` markers from a message string,
/// splitting the text into interleaved text and visualization segments.
///
/// Used by `StreamingMarkdownView` to detect inline visualizations
/// produced by the Inline Visualizer plugin.
enum VizMarkerParser {

    // MARK: - Types

    /// A segment of parsed content from a message containing VIZ markers.
    enum VizSegment {
        /// Plain text (markdown prose, no markers).
        case text(String)
        /// HTML/SVG content extracted between `@@@VIZ-START` and `@@@VIZ-END`.
        case visualization(String)
    }

    /// The streaming-parse state returned when content may still be arriving.
    enum StreamingState {
        /// No markers found — render everything as markdown (current behavior).
        case noMarkers
        /// `@@@VIZ-START` seen but `@@@VIZ-END` not yet received.
        /// - proseBeforeMarker: text that comes before the start marker
        /// - vizContent: partial HTML/SVG between the marker and the current cursor
        case streaming(proseBeforeMarker: String, vizContent: String)
        /// Both markers present — parse is complete.
        case complete([VizSegment])
    }

    // MARK: - Constants

    private static let startMarker = "@@@VIZ-START"
    // Use "\n@@@VIZ-END" (newline-prefixed) so we only match the standalone
    // end marker on its own line, never an embedded occurrence inside the VIZ
    // HTML/JS content (e.g. `var END_MARK = '@@@VIZ-END'`).
    private static let endMarker   = "\n@@@VIZ-END"

    // MARK: - Full Parse (post-streaming)

    /// Parses a fully-received message string into `[VizSegment]`.
    ///
    /// - Handles multiple VIZ blocks in a single message.
    /// - Unclosed `@@@VIZ-START` blocks are returned as plain `.text`.
    /// - Returns `[.text(text)]` when no markers are found.
    static func parse(_ text: String) -> [VizSegment] {
        guard text.contains(startMarker) else { return [.text(text)] }

        var segments: [VizSegment] = []
        var remaining = text[text.startIndex...]

        while let startRange = remaining.range(of: startMarker) {
            // Text before this VIZ block
            let before = String(remaining[remaining.startIndex..<startRange.lowerBound])
            if !before.isEmpty {
                segments.append(.text(before))
            }

            // Content after @@@VIZ-START (skip optional leading newline)
            var contentStart = startRange.upperBound
            if contentStart < remaining.endIndex, remaining[contentStart] == "\n" {
                contentStart = remaining.index(after: contentStart)
            }

            let searchArea = remaining[contentStart...]
            guard let endRange = searchArea.range(of: endMarker) else {
                // Unclosed block (stream stopped before @@@VIZ-END arrived).
                // Emit the partial VIZ payload as .visualization so InlineVisualizerView
                // handles it — avoids routing raw SVG/HTML through MarkdownView which
                // would render it as code blocks or literal text.
                let partialViz = String(remaining[contentStart...])
                if !partialViz.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.visualization(partialViz))
                }
                return segments
            }

            // Strip optional trailing newline before @@@VIZ-END
            var vizEnd = endRange.lowerBound
            if vizEnd > contentStart {
                let beforeEnd = remaining.index(before: vizEnd)
                if remaining[beforeEnd] == "\n" {
                    vizEnd = beforeEnd
                }
            }

            let vizContent = String(remaining[contentStart..<vizEnd])
            if !vizContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.visualization(vizContent))
            }

            remaining = remaining[endRange.upperBound...]
        }

        // Trailing text after the last @@@VIZ-END
        if !remaining.isEmpty {
            segments.append(.text(String(remaining)))
        }

        return segments.isEmpty ? [.text(text)] : segments
    }

    // MARK: - Streaming Parse (incremental)

    /// Fast incremental parse for use during streaming.
    ///
    /// O(1) amortized — only scans the string once. Returns a `StreamingState`
    /// so callers can decide how to render partial content without blocking.
    static func streamingParse(_ text: String) -> StreamingState {
        guard let startRange = text.range(of: startMarker) else {
            return .noMarkers
        }

        let proseBeforeMarker = String(text[text.startIndex..<startRange.lowerBound])

        // Content after @@@VIZ-START (skip optional leading newline)
        var contentStart = startRange.upperBound
        if contentStart < text.endIndex, text[contentStart] == "\n" {
            contentStart = text.index(after: contentStart)
        }

        guard text.range(of: endMarker, range: contentStart..<text.endIndex) != nil else {
            // @@@VIZ-START seen but @@@VIZ-END not yet arrived
            let vizContent = String(text[contentStart...])
            return .streaming(proseBeforeMarker: proseBeforeMarker, vizContent: vizContent)
        }

        // Both markers present — do full parse
        return .complete(parse(text))
    }
}
