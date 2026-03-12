import SwiftUI

// MARK: - Tool Call Data

/// Represents a parsed tool call extracted from `<details>` HTML blocks
/// in assistant message content.
struct ToolCallData: Identifiable {
    let id: String
    let name: String
    let arguments: String?
    let result: String?
    let isDone: Bool

    /// A display-friendly name (replaces underscores with spaces).
    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - Reasoning Data

/// Represents a parsed reasoning/thinking block extracted from
/// `<details type="reasoning">` HTML blocks in assistant content.
struct ReasoningData: Identifiable {
    let id = UUID().uuidString
    let summary: String
    let content: String
    let duration: String?
    let isDone: Bool
}

// MARK: - Content Segment

/// Represents a segment of assistant message content in the order it appears.
/// Used to interleave tool calls and reasoning blocks with text, matching
/// the web UI's rendering where tool calls appear inline where they were
/// performed rather than being grouped at the top.
enum ContentSegment: Identifiable {
    case text(String)
    case toolCall(ToolCallData)
    case reasoning(ReasoningData)

    var id: String {
        switch self {
        case .text(let str): return "text-\(str.hashValue)"
        case .toolCall(let tc): return "tool-\(tc.id)"
        case .reasoning(let r): return "reason-\(r.id)"
        }
    }
}

// MARK: - Tool Call Parser

/// Parses `<details>` blocks from OpenWebUI assistant message content,
/// including both tool calls and reasoning/thinking blocks.
enum ToolCallParser {

    /// Result of parsing assistant content.
    struct ParseResult {
        let toolCalls: [ToolCallData]
        let reasoning: [ReasoningData]
        let cleanedContent: String
    }

    /// Ordered parse result that preserves the position of each block
    /// relative to the surrounding text content.
    struct OrderedParseResult {
        let segments: [ContentSegment]
        /// All tool calls for backward compatibility (e.g. file extraction).
        let allToolCalls: [ToolCallData]
    }

    /// Extracts all details blocks from the content string.
    /// Returns parsed tool calls, reasoning blocks, and remaining content.
    static func parse(_ content: String) -> (toolCalls: [ToolCallData], cleanedContent: String) {
        let result = parseAll(content)
        return (result.toolCalls, result.cleanedContent)
    }

    /// Full parse that also extracts reasoning blocks.
    /// NOTE: This groups all tool calls and reasoning together — use
    /// `parseOrdered` for interleaved (inline) rendering.
    static func parseAll(_ content: String) -> ParseResult {
        let ordered = parseOrdered(content)

        var toolCalls: [ToolCallData] = []
        var reasoning: [ReasoningData] = []
        var textParts: [String] = []

        for segment in ordered.segments {
            switch segment {
            case .text(let str): textParts.append(str)
            case .toolCall(let tc): toolCalls.append(tc)
            case .reasoning(let r): reasoning.append(r)
            }
        }

        let cleaned = textParts.joined(separator: "\n\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParseResult(toolCalls: toolCalls, reasoning: reasoning, cleanedContent: cleaned)
    }

    /// Parses the content into ordered segments preserving the original
    /// position of each `<details>` block relative to surrounding text.
    /// This is the core parser that all other methods delegate to.
    static func parseOrdered(_ content: String) -> OrderedParseResult {
        let pattern = #"<details\s+[^>]*>[\s\S]*?</details>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return OrderedParseResult(
                segments: [.text(content)],
                allToolCalls: []
            )
        }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        guard !matches.isEmpty else {
            return OrderedParseResult(
                segments: [.text(content)],
                allToolCalls: []
            )
        }

        var segments: [ContentSegment] = []
        var allToolCalls: [ToolCallData] = []
        var currentIndex = 0

        for match in matches {
            // Text before this details block
            if match.range.location > currentIndex {
                let textRange = NSRange(location: currentIndex, length: match.range.location - currentIndex)
                let textBefore = nsContent.substring(with: textRange)
                    .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !textBefore.isEmpty {
                    segments.append(.text(textBefore))
                }
            }

            let block = nsContent.substring(with: match.range)

            if block.contains("type=\"tool_calls\"") || block.contains("type='tool_calls'") {
                if let toolCall = parseToolCallBlock(block) {
                    segments.append(.toolCall(toolCall))
                    allToolCalls.append(toolCall)
                }
            } else if block.contains("type=\"reasoning\"") || block.contains("type='reasoning'") {
                if let reason = parseReasoningBlock(block) {
                    segments.append(.reasoning(reason))
                }
            }

            currentIndex = match.range.location + match.range.length
        }

        // Remaining text after the last details block
        if currentIndex < nsContent.length {
            let remaining = nsContent.substring(from: currentIndex)
                .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                segments.append(.text(remaining))
            }
        }

        return OrderedParseResult(segments: segments, allToolCalls: allToolCalls)
    }

    /// Parses a `<details type="reasoning">` block.
    private static func parseReasoningBlock(_ block: String) -> ReasoningData? {
        let doneStr = extractAttribute("done", from: block)
        let isDone = doneStr == "true"
        let duration = extractAttribute("duration", from: block)

        // Extract summary text from <summary>...</summary>
        let summary: String = {
            let summaryPattern = #"<summary>(.*?)</summary>"#
            if let regex = try? NSRegularExpression(pattern: summaryPattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: (block as NSString).length)),
               match.numberOfRanges > 1 {
                return (block as NSString).substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let dur = duration {
                return "Thought for \(dur) seconds"
            }
            return "Reasoning"
        }()

        // Extract content between </summary> and </details>
        let contentText: String = {
            let contentPattern = #"</summary>([\s\S]*?)</details>"#
            if let regex = try? NSRegularExpression(pattern: contentPattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: (block as NSString).length)),
               match.numberOfRanges > 1 {
                return decodeHTMLEntities(
                    (block as NSString).substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                ) ?? ""
            }
            return ""
        }()

        guard !contentText.isEmpty else { return nil }

        return ReasoningData(
            summary: summary,
            content: contentText,
            duration: duration,
            isDone: isDone
        )
    }

    /// Parses a single tool call `<details>` block into a `ToolCallData`.
    private static func parseToolCallBlock(_ block: String) -> ToolCallData? {
        let name = extractAttribute("name", from: block) ?? "tool"
        let id = extractAttribute("id", from: block) ?? UUID().uuidString
        let doneStr = extractAttribute("done", from: block)
        let isDone = doneStr == "true"
        let arguments = extractAttribute("arguments", from: block)
        let result = extractAttribute("result", from: block)

        return ToolCallData(
            id: id,
            name: name,
            arguments: decodeHTMLEntities(arguments),
            result: decodeHTMLEntities(result),
            isDone: isDone
        )
    }

    /// Extracts an HTML attribute value from a tag string.
    private static func extractAttribute(_ name: String, from html: String) -> String? {
        // Match attribute="value" with double or single quotes
        let patterns = [
            name + #"\s*=\s*"([^"]*)""#,
            name + #"\s*=\s*'([^']*)'"#
        ]

        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) else { continue }
            let nsHTML = html as NSString
            if let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)),
               match.numberOfRanges > 1 {
                return nsHTML.substring(with: match.range(at: 1))
            }
        }
        return nil
    }

    /// Decodes common HTML entities in attribute values.
    private static func decodeHTMLEntities(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return string }
        return string
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    // MARK: - File ID Extraction from Tool Results

    /// Extracts file IDs from tool call results embedded in assistant message content.
    ///
    /// When tools like image generation complete, their results (stored in the
    /// `result` attribute of `<details>` blocks) often contain file references
    /// as JSON. This method scans the tool results for patterns that look like
    /// OpenWebUI file IDs and returns them as `ChatMessageFile` objects.
    ///
    /// This is a safety net: normally the server populates `message.files`, but
    /// if the app was backgrounded or had connectivity issues, the files array
    /// may be empty even though the tool result clearly references generated files.
    ///
    /// Recognized patterns:
    /// - `/api/v1/files/{id}/content` URLs
    /// - `"file_id": "..."` or `"id": "..."` JSON fields
    /// - Bare UUIDs in image-related tool results
    static func extractFileReferences(from content: String) -> [ChatMessageFile] {
        let parsed = parse(content)
        var files: [ChatMessageFile] = []
        var seenIds = Set<String>()

        // Tool names that are known to produce images — only these should
        // have their file references treated as images.
        let imageToolNames = ["image_gen", "image_generation", "generate_image",
                              "dall_e", "dalle", "stable_diffusion", "flux",
                              "text_to_image", "create_image", "comfyui"]

        for toolCall in parsed.toolCalls where toolCall.isDone {
            guard let result = toolCall.result, !result.isEmpty else { continue }

            let isImageTool = imageToolNames.contains(where: {
                toolCall.name.lowercased().contains($0)
            })

            // Only extract file references from image-generation tools.
            // Other tools (e.g. knowledge base, web search) may return file
            // paths or IDs in their results but those are NOT images and
            // should not be rendered as such.
            guard isImageTool else { continue }

            // Strategy 1: Extract file IDs from /api/v1/files/{id}/content URLs
            let urlPattern = #"/api/v1/files/([a-f0-9\-]{36})/content"#
            if let urlRegex = try? NSRegularExpression(pattern: urlPattern) {
                let nsResult = result as NSString
                let matches = urlRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
                for match in matches where match.numberOfRanges > 1 {
                    let fileId = nsResult.substring(with: match.range(at: 1))
                    if !seenIds.contains(fileId) {
                        seenIds.insert(fileId)
                        files.append(ChatMessageFile(type: "image", url: fileId, name: nil, contentType: nil))
                    }
                }
            }

            // Strategy 2: Extract from JSON fields like "file_id", "id", "url" containing UUIDs
            let jsonFieldPattern = #"(?:"file_id"|"id"|"url")\s*:\s*"([a-f0-9\-]{36})""#
            if let jsonRegex = try? NSRegularExpression(pattern: jsonFieldPattern) {
                let nsResult = result as NSString
                let matches = jsonRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
                for match in matches where match.numberOfRanges > 1 {
                    let fileId = nsResult.substring(with: match.range(at: 1))
                    if !seenIds.contains(fileId) {
                        seenIds.insert(fileId)
                        files.append(ChatMessageFile(type: "image", url: fileId, name: nil, contentType: nil))
                    }
                }
            }

            // Strategy 3: Last resort — look for any bare UUID in the result
            if files.isEmpty {
                let uuidPattern = #"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"#
                if let uuidRegex = try? NSRegularExpression(pattern: uuidPattern) {
                    let nsResult = result as NSString
                    let matches = uuidRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
                    for match in matches {
                        let fileId = nsResult.substring(with: match.range)
                        if !seenIds.contains(fileId) {
                            seenIds.insert(fileId)
                            files.append(ChatMessageFile(type: "image", url: fileId, name: nil, contentType: nil))
                        }
                    }
                }
            }
        }

        return files
    }
}

// MARK: - Tool Call View

/// Displays a single tool call as a collapsible disclosure group,
/// matching the Flutter app's presentation.
struct ToolCallView: View {
    let toolCall: ToolCallData
    @State private var isExpanded: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 14)

                    if toolCall.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Text("Used \(toolCall.displayName)")
                        .font(AppTypography.labelSmallFont)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textSecondary)

                    Spacer()
                }
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if let args = toolCall.arguments, !args.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Arguments")
                                .font(AppTypography.captionFont)
                                .fontWeight(.semibold)
                                .foregroundStyle(theme.textTertiary)

                            Text(formatJSON(args))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(10)
                                .padding(Spacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.surfaceContainer.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                        }
                    }

                    if let result = toolCall.result, !result.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Result")
                                .font(AppTypography.captionFont)
                                .fontWeight(.semibold)
                                .foregroundStyle(theme.textTertiary)

                            Text(formatJSON(result))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(20)
                                .padding(Spacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.surfaceContainer.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.bottom, Spacing.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Tries to pretty-print JSON strings, falls back to raw display.
    private func formatJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return text
        }
        return pretty
    }
}

// MARK: - Tool Calls Container

/// Renders a list of tool calls extracted from message content.
struct ToolCallsContainer: View {
    let toolCalls: [ToolCallData]

    var body: some View {
        if !toolCalls.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(toolCalls) { toolCall in
                    ToolCallView(toolCall: toolCall)
                    if toolCall.id != toolCalls.last?.id {
                        Divider()
                            .padding(.leading, 24)
                    }
                }
            }
        }
    }
}

// MARK: - Reasoning View

/// Displays a reasoning/thinking block as a collapsible section with
/// a brain icon, similar to how ChatGPT shows "Thought for X seconds".
/// Expanded while thinking is in progress so the user can follow along,
/// then collapses automatically once thinking completes.
struct ReasoningView: View {
    let reasoning: ReasoningData
    @State private var isExpanded: Bool
    @Environment(\.theme) private var theme

    init(reasoning: ReasoningData) {
        self.reasoning = reasoning
        // Expanded while thinking is still in progress, collapsed once done.
        // Because ReasoningData.id is a fresh UUID on each re-parse, SwiftUI
        // treats each streaming update as a new view — so `@State` re-inits
        // each time, giving us the desired auto-collapse on completion.
        self._isExpanded = State(initialValue: !reasoning.isDone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — tappable to expand/collapse
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 12)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.brandPrimary.opacity(0.7))

                    Text(reasoning.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.vertical, Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded reasoning content
            if isExpanded {
                Text(reasoning.content)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.textTertiary)
                    .lineSpacing(3)
                    .padding(.leading, 22)
                    .padding(.trailing, Spacing.sm)
                    .padding(.bottom, Spacing.sm)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .fill(theme.surfaceContainer.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .strokeBorder(theme.brandPrimary.opacity(0.1), lineWidth: 0.5)
        )
    }
}

// MARK: - Reasoning Container

/// Renders a list of reasoning blocks.
struct ReasoningContainer: View {
    let blocks: [ReasoningData]

    var body: some View {
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(blocks) { block in
                    ReasoningView(reasoning: block)
                }
            }
        }
    }
}

// MARK: - Message Content with Tool Calls

/// Renders assistant message content, extracting and displaying tool call
/// and reasoning blocks as proper UI components instead of raw HTML.
///
/// ## Inline Ordering
/// Tool calls and reasoning blocks are rendered **in the order they appear**
/// in the raw content string, interleaved with surrounding text. This matches
/// the web UI behavior where you can see which tool call was made at which
/// point during the response — providing important context about *why* a
/// tool was invoked and what came after.
struct AssistantMessageContent: View {
    let content: String
    let isStreaming: Bool

    /// ## OPT 3: Reference-type parse cache (fixes 1-frame stale race)
    ///
    /// ### Problem (before)
    /// The cache used `@State` properties updated via `DispatchQueue.main.async`
    /// to avoid the "setting value during view update" warning. But this created
    /// a 1-frame race: the async update doesn't land until the NEXT run loop
    /// iteration, so the very next body evaluation sees stale cache and re-runs
    /// the expensive O(n) regex parse — defeating the cache entirely during
    /// streaming where body is called at ~7-15fps.
    ///
    /// ### Fix
    /// Use a reference-type (`class`) cache that mutates synchronously during
    /// body evaluation. Since it's a class (not a value type), mutating it
    /// doesn't trigger SwiftUI state changes or "setting value during update"
    /// warnings. The cache hit is immediate — same run loop, same body call.
    @State private var parseCache = ParseCache()

    /// Reference-type cache for ToolCallParser results. Mutating a class
    /// property during body evaluation is safe because SwiftUI only tracks
    /// `@State`/`@Observable` value changes, not internal class mutations.
    private final class ParseCache {
        var lastLength: Int = -1
        var lastResult: ToolCallParser.OrderedParseResult?
    }

    var body: some View {
        // OPT 3: Synchronous cache lookup — no 1-frame stale race.
        // The class mutation happens inline during body, so the next
        // body call in the same layout pass sees the updated cache.
        let contentLength = content.utf8.count
        let ordered: ToolCallParser.OrderedParseResult = {
            if contentLength == parseCache.lastLength, let cached = parseCache.lastResult {
                return cached
            }
            let result = ToolCallParser.parseOrdered(content)
            parseCache.lastLength = contentLength
            parseCache.lastResult = result
            return result
        }()

        VStack(alignment: .leading, spacing: Spacing.xs) {
            if ordered.segments.isEmpty && isStreaming {
                // Show typing indicator when streaming with no content yet
                HStack {
                    TypingIndicator()
                    Spacer()
                }
            } else {
                // Render each segment in the order it appears in the content.
                // Adjacent tool calls are grouped together with dividers
                // for a cleaner look, matching the web UI.
                let groups = Self.groupSegments(ordered.segments)
                let lastTextIndex = groups.lastIndex(where: {
                    if case .text = $0 { return true }
                    return false
                })

                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    switch group {
                    case .text(let str):
                        // Only the last text segment gets the streaming cursor
                        let isLastText = index == lastTextIndex && isStreaming
                        MarkdownWithLoading(
                            content: str,
                            isLoading: isLastText
                        )

                    case .toolCalls(let calls):
                        ToolCallsContainer(toolCalls: calls)

                    case .reasoningBlocks(let blocks):
                        ReasoningContainer(blocks: blocks)
                    }
                }

                // If streaming and the last segment is NOT text (e.g. a tool call
                // just finished, text hasn't started yet), show a typing indicator.
                if isStreaming {
                    let lastIsNonText: Bool = {
                        guard let last = ordered.segments.last else { return true }
                        if case .text = last { return false }
                        return true
                    }()
                    if lastIsNonText {
                        HStack {
                            TypingIndicator()
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    /// Groups adjacent segments of the same type for cleaner rendering.
    /// Adjacent tool calls become a single `toolCalls` group with dividers.
    /// Adjacent reasoning blocks become a single `reasoningBlocks` group.
    /// Text segments remain individual.
    private enum SegmentGroup {
        case text(String)
        case toolCalls([ToolCallData])
        case reasoningBlocks([ReasoningData])
    }

    private static func groupSegments(_ segments: [ContentSegment]) -> [SegmentGroup] {
        var groups: [SegmentGroup] = []

        for segment in segments {
            switch segment {
            case .text(let str):
                groups.append(.text(str))

            case .toolCall(let tc):
                // Merge with previous group if it's also tool calls
                if case .toolCalls(var existing) = groups.last {
                    groups.removeLast()
                    existing.append(tc)
                    groups.append(.toolCalls(existing))
                } else {
                    groups.append(.toolCalls([tc]))
                }

            case .reasoning(let r):
                // Merge with previous group if it's also reasoning
                if case .reasoningBlocks(var existing) = groups.last {
                    groups.removeLast()
                    existing.append(r)
                    groups.append(.reasoningBlocks(existing))
                } else {
                    groups.append(.reasoningBlocks([r]))
                }
            }
        }

        return groups
    }
}
