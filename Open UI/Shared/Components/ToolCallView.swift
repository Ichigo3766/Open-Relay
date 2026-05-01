import SwiftUI
import WebKit
import os.log
import UniformTypeIdentifiers

private let vizLog = Logger(subsystem: "com.openui", category: "VizPipeline")

// MARK: - Tool Call Data

/// Represents a parsed tool call extracted from `<details>` HTML blocks
/// in assistant message content.
struct ToolCallData: Identifiable {
    let id: String
    let name: String
    let arguments: String?
    let result: String?
    let isDone: Bool
    /// Rich UI HTML embeds returned by the tool. Each string is a full HTML
    /// document to be rendered inline in the chat as an interactive webview.
    let embeds: [String]

    /// A display-friendly name (replaces underscores with spaces).
    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - Reasoning Data

/// Represents a parsed reasoning/thinking block extracted from
/// `<details type="reasoning">` HTML blocks in assistant content.
struct ReasoningData: Identifiable {
    /// Stable ID derived from the first 80 chars of content so SwiftUI
    /// preserves the `ReasoningView` identity across streaming re-parses.
    /// Using UUID() causes a new view to be created on every streaming tick,
    /// which resets `@State isExpanded` and makes the tap-to-expand unusable
    /// while streaming.
    let id: String
    let summary: String
    let content: String
    let duration: String?
    let isDone: Bool

    init(summary: String, content: String, duration: String?, isDone: Bool) {
        // Use the first 80 characters as a stable anchor — the beginning of
        // a reasoning block is fixed once streaming starts (only the tail grows).
        let prefix = String(content.prefix(80))
        self.id = "reason-\(prefix.hashValue)"
        self.summary = summary
        self.content = content
        self.duration = duration
        self.isDone = isDone
    }
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

    // MARK: - NSRegularExpression cache
    // Compiling an NSRegularExpression is ~10–50 µs. parseOrdered() is called
    // up to 60 times/sec during streaming so repeated compilation was a hot path.
    // This nonisolated(unsafe) static dictionary is read-only after warm-up and
    // safe to access from any thread via the `cachedRegex` helper below.
    private nonisolated(unsafe) static var _regexCache: [String: NSRegularExpression] = [:]
    private nonisolated(unsafe) static var _regexCacheLock = os_unfair_lock()

    /// Returns a cached (or freshly compiled) NSRegularExpression for `pattern`.
    /// Thread-safe via `os_unfair_lock` (non-recursive, no allocation).
    static func cachedRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = pattern + "\0\(options.rawValue)"
        os_unfair_lock_lock(&_regexCacheLock)
        if let cached = _regexCache[key] {
            os_unfair_lock_unlock(&_regexCacheLock)
            return cached
        }
        os_unfair_lock_unlock(&_regexCacheLock)
        guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        os_unfair_lock_lock(&_regexCacheLock)
        _regexCache[key] = rx
        os_unfair_lock_unlock(&_regexCacheLock)
        return rx
    }

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
        // Pre-process: convert raw <think>…</think> tags (sent by models
        // like Qwen, DeepSeek, etc.) into <details type="reasoning"> blocks
        // so the state-machine tokenizer picks them up and renders them as
        // collapsible ReasoningView instead of raw visible text.
        let content = preprocessThinkTags(content)

        // Use a quote-aware state-machine tokenizer instead of the old regex
        // `#"<details\s+[^>]*>[\s\S]*?</details>"#`.
        //
        // The regex used `[^>]*` to match opening-tag attributes — this breaks
        // whenever a quoted attribute value (e.g. `result="…"`) contains a `>`
        // character, which is common in tool results that include HTML snippets,
        // URLs with query strings, or angle-bracket operators. When that happens
        // the regex terminates the opening-tag match prematurely, causing the
        // rest of the block (including all the JSON tool-result content) to be
        // treated as surrounding text and rendered raw in the chat.
        //
        // The tokenizer below tracks quote state so it only treats `>` as the
        // end of the opening tag when it is NOT inside a quoted string, and it
        // tracks nesting depth to find the correct matching `</details>` even
        // when blocks are nested.
        let matches = findDetailsBlocks(in: content)

        guard !matches.isEmpty else {
            return OrderedParseResult(
                segments: [.text(content)],
                allToolCalls: []
            )
        }

        var segments: [ContentSegment] = []
        var allToolCalls: [ToolCallData] = []
        var currentPos = content.startIndex

        for match in matches {
            // Text before this details block
            if match.start > currentPos {
                let textBefore = String(content[currentPos..<match.start])
                    .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !textBefore.isEmpty {
                    segments.append(.text(textBefore))
                }
            }

            let block = match.block

            if block.contains("type=\"tool_calls\"") || block.contains("type='tool_calls'") {
                if let toolCall = parseToolCallBlock(block) {
                    segments.append(.toolCall(toolCall))
                    allToolCalls.append(toolCall)
                }
            } else if block.contains("type=\"reasoning\"") || block.contains("type='reasoning'") {
                if let parsed = parseReasoningBlock(block) {
                    segments.append(.reasoning(parsed.data))
                    // Spillover: content that was inside the <details> block AFTER
                    // a raw closing tag (e.g. </thinking>) — this is the real model
                    // reply that was accidentally captured inside the reasoning block.
                    if let spillover = parsed.spillover, !spillover.isEmpty {
                        segments.append(.text(spillover))
                    }
                }
            }

            currentPos = match.end
        }

        // Remaining text after the last details block
        if currentPos < content.endIndex {
            let remaining = String(content[currentPos...])
                .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                segments.append(.text(remaining))
            }
        }

        return OrderedParseResult(segments: segments, allToolCalls: allToolCalls)
    }

    // MARK: - State-machine <details> block tokenizer

    /// Represents a single `<details>…</details>` block found by the tokenizer.
    private struct DetailsMatch {
        /// Index of the `<` that opens the `<details` tag.
        let start: String.Index
        /// Index just past the `>` that closes the `</details>` tag.
        let end: String.Index
        /// The full text of the block from `<details` to `</details>`.
        let block: String
    }

    /// Scans `content` using a quote-aware state machine and returns every
    /// top-level `<details>…</details>` block it finds.
    ///
    /// Key properties:
    /// - Tracks whether the scanner is inside a double- or single-quoted
    ///   attribute value so that a `>` inside e.g. `result="…&gt;…"` does NOT
    ///   prematurely terminate the opening-tag scan.
    /// - Tracks nesting depth so nested `<details>` blocks are consumed as
    ///   part of the outer block rather than returning the outer block early.
    /// - Returns an incomplete (mid-stream) block only if it starts with a
    ///   valid `<details` open tag that has a fully-parsed opening tag (i.e. we
    ///   found the closing `>` of the opening tag) but whose `</details>` has
    ///   not yet arrived. In that case the block is skipped and left as
    ///   surrounding text so that streaming does not flash partial content.
    private static func findDetailsBlocks(in content: String) -> [DetailsMatch] {
        var results: [DetailsMatch] = []
        var i = content.startIndex

        while i < content.endIndex {
            // Fast-scan for the literal '<' that starts a potential tag
            guard let ltIdx = content[i...].firstIndex(of: "<") else { break }

            // Check if this is a <details opening (case-insensitive prefix check)
            let afterLt = content.index(after: ltIdx)
            guard afterLt < content.endIndex else { break }

            // We need at least "<details" (7 more chars after '<')
            let tagNameEnd = content.index(ltIdx, offsetBy: 8, limitedBy: content.endIndex) ?? content.endIndex
            let tagNameSlice = content[ltIdx..<tagNameEnd].lowercased()

            guard tagNameSlice.hasPrefix("<details") else {
                // Not a <details tag — advance past this '<' and keep scanning
                i = afterLt
                continue
            }

            // The character right after "<details" must be whitespace, '>', or end
            // to confirm this is the tag and not e.g. "<detailsview"
            let charAfterTagName = tagNameEnd < content.endIndex ? content[tagNameEnd] : ">"
            guard charAfterTagName.isWhitespace || charAfterTagName == ">" else {
                i = afterLt
                continue
            }

            let blockStart = ltIdx

            // --- Phase 1: scan the opening tag in quote-aware mode ---
            // We walk forward from `<details` until we find the `>` that closes
            // the opening tag, respecting quoted attribute values.
            var j = tagNameEnd
            var inQuote: Character? = nil
            var openingTagEnd: String.Index? = nil

            while j < content.endIndex {
                let ch = content[j]
                if let q = inQuote {
                    // Inside a quoted value — a backslash escapes the next char
                    // (handles \" inside double-quoted attribute values, which are
                    // common when tool results store JSON with escaped quotes like
                    // arguments="&quot;{\"query\": \"...\"}&quot;"). Without this,
                    // the `"` after `\` is mistaken for the closing quote, causing
                    // the scanner to exit quote mode prematurely and then find a
                    // false `>` end-of-opening-tag inside the attribute value.
                    if ch == "\\" {
                        // Skip the next character (the escaped character)
                        let next = content.index(after: j)
                        if next < content.endIndex {
                            j = content.index(after: next)
                            continue
                        }
                    } else if ch == q {
                        inQuote = nil
                    }
                } else {
                    if ch == "\"" || ch == "'" {
                        inQuote = ch
                    } else if ch == ">" {
                        // Found the real end of the opening tag
                        openingTagEnd = content.index(after: j)
                        break
                    }
                }
                j = content.index(after: j)
            }

            guard let bodyStart = openingTagEnd else {
                // Opening tag not yet closed — mid-stream, skip and stop scanning
                // (everything from here on is still arriving)
                break
            }

            // --- Phase 2: scan for the matching </details> tracking nesting ---
            var k = bodyStart
            var depth = 1   // we have one open <details> tag

            while k < content.endIndex && depth > 0 {
                guard let nextLt = content[k...].firstIndex(of: "<") else {
                    // No more '<' — closing tag hasn't arrived yet
                    depth = -1   // sentinel: incomplete block
                    break
                }

                let afterNextLt = content.index(after: nextLt)
                guard afterNextLt < content.endIndex else {
                    depth = -1
                    break
                }

                // Peek ahead for "/details" (closing) or "details" (opening)
                let peekEnd8 = content.index(nextLt, offsetBy: 9, limitedBy: content.endIndex) ?? content.endIndex
                let peekSlice = content[nextLt..<peekEnd8].lowercased()

                if peekSlice.hasPrefix("</details") {
                    // Possible closing tag — consume until its '>'
                    var m = content.index(nextLt, offsetBy: 9, limitedBy: content.endIndex) ?? content.endIndex
                    while m < content.endIndex && content[m] != ">" { m = content.index(after: m) }
                    if m < content.endIndex {
                        depth -= 1
                        k = content.index(after: m)
                    } else {
                        depth = -1   // mid-stream closing tag
                        break
                    }
                } else if peekSlice.hasPrefix("<details") {
                    // Nested opening tag — skip its opening tag quote-aware, then bump depth
                    let nestedNameEnd = content.index(nextLt, offsetBy: 8, limitedBy: content.endIndex) ?? content.endIndex
                    var m = nestedNameEnd
                    var nestedInQuote: Character? = nil
                    var foundClose = false
                    while m < content.endIndex {
                        let ch = content[m]
                        if let q = nestedInQuote {
                            if ch == q { nestedInQuote = nil }
                        } else {
                            if ch == "\"" || ch == "'" { nestedInQuote = ch }
                            else if ch == ">" { foundClose = true; m = content.index(after: m); break }
                        }
                        m = content.index(after: m)
                    }
                    if foundClose {
                        depth += 1
                        k = m
                    } else {
                        depth = -1
                        break
                    }
                } else {
                    // Some other tag — skip past it
                    k = afterNextLt
                }
            }

            if depth == 0 {
                // Successfully matched a complete block
                let blockEnd = k
                let block = String(content[blockStart..<blockEnd])
                results.append(DetailsMatch(start: blockStart, end: blockEnd, block: block))
                i = blockEnd
            } else {
                // Block is incomplete (still streaming) — stop; don't advance
                // so the caller treats everything from blockStart onward as text.
                break
            }
        }

        return results
    }

    /// Parses a `<details type="reasoning">` block.
    ///
    /// Returns a tuple of `(ReasoningData, spilloverText?)`:
    /// - `ReasoningData` is the collapsible thinking block.
    /// - `spilloverText` is any actual model reply that was inadvertently
    ///   swallowed into the reasoning block — caused by some models/servers
    ///   embedding a raw closing tag (e.g. `</thinking>`, `</details>`) inside
    ///   the `<details type="reasoning">` block content, with the real response
    ///   following it before the outer `</details>`.
    private static func parseReasoningBlock(_ block: String) -> (data: ReasoningData, spillover: String?)? {
        let doneStr = extractAttribute("done", from: block)
        let isDone = doneStr == "true"
        let duration = extractAttribute("duration", from: block)

        // Extract summary text from <summary>...</summary>
        let summary: String = {
            let summaryPattern = #"<summary>(.*?)</summary>"#
            if let regex = cachedRegex(summaryPattern, options: [.dotMatchesLineSeparators]),
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

        // Extract content between </summary> and </details>.
        // We use a lazy match so nested/model-emitted </details> tags stop
        // the capture at the right place (handled below for spillover).
        let rawContentText: String = {
            let contentPattern = #"</summary>([\s\S]*?)</details>"#
            if let regex = cachedRegex(contentPattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: (block as NSString).length)),
               match.numberOfRanges > 1 {
                return decodeHTMLEntities(
                    (block as NSString).substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                ) ?? ""
            }
            return ""
        }()

        guard !rawContentText.isEmpty else { return nil }

        // ── Spillover detection ──────────────────────────────────────────
        // Some models (e.g. Qwen3) skip the opening tag and the server
        // therefore wraps everything — including the raw close tag AND the
        // actual reply — inside the <details type="reasoning"> block:
        //
        //   <details type="reasoning"><summary>Thought for 2 seconds</summary>
        //   ...thinking text...
        //   </thinking>          ← model's own closing tag
        //   Oczywiście! 💕 ...   ← ACTUAL reply, must NOT be in thinking block
        //   </details>
        //
        // We detect any raw close tag inside the content, split there, and
        // surface the trailing text as `spillover` so the caller can emit it
        // as a normal text segment rather than burying it in the thinking view.
        var contentText = rawContentText
        var spillover: String? = nil

        for pair in defaultReasoningTagPairs {
            let closeTag = pair.close
            let escapedClose = NSRegularExpression.escapedPattern(for: closeTag)

            guard contentText.range(of: closeTag, options: .caseInsensitive) != nil else { continue }

            // Split at the first occurrence: before = reasoning, after = reply
            if let splitRegex = cachedRegex("^([\\s\\S]*?)\(escapedClose)([\\s\\S]*)$",
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) {
                let nsContent = contentText as NSString
                if let match = splitRegex.firstMatch(
                    in: contentText,
                    range: NSRange(location: 0, length: nsContent.length)
                ), match.numberOfRanges > 2 {
                    let before = nsContent.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let after = nsContent.substring(with: match.range(at: 2))
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    contentText = before
                    if !after.isEmpty {
                        spillover = after
                    }
                    break
                }
            }
        }

        guard !contentText.isEmpty else { return nil }

        let data = ReasoningData(
            summary: summary,
            content: contentText,
            duration: duration,
            isDone: isDone
        )
        return (data, spillover)
    }

    /// Parses a single tool call `<details>` block into a `ToolCallData`.
    private static func parseToolCallBlock(_ block: String) -> ToolCallData? {
        let name = extractAttribute("name", from: block) ?? "tool"
        let id = extractAttribute("id", from: block) ?? UUID().uuidString
        let doneStr = extractAttribute("done", from: block)
        let isDone = doneStr == "true"
        let arguments = extractAttribute("arguments", from: block)
        // Try the result="" attribute first. If absent (OpenWebUI stores the output
        // as the body between </summary> and </details>), fall back to body content.
        let resultAttr = extractAttribute("result", from: block)
        let result: String? = {
            if let r = resultAttr, !r.isEmpty { return r }
            // Body fallback: extract content between </summary> and </details>
            let bodyPattern = #"</summary>([\s\S]*?)</details>"#
            if let regex = cachedRegex(bodyPattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: block, range: NSRange(location: 0, length: (block as NSString).length)),
               match.numberOfRanges > 1 {
                let body = (block as NSString).substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? nil : body
            }
            return nil
        }()
        // Skip embed parsing for in-progress tool calls — embeds are only
        // rendered once isDone == true, so parsing the 30KB+ HTML-entity-encoded
        // iframe blob on every streaming frame is pure wasted CPU on the main thread.
        let embeds = isDone ? parseEmbedsAttribute(from: block) : []

        return ToolCallData(
            id: id,
            name: name,
            arguments: decodeHTMLEntities(arguments),
            result: decodeHTMLEntities(result),
            isDone: isDone,
            embeds: embeds
        )
    }

    /// Extracts and decodes the `embeds` attribute from a tool call block.
    ///
    /// The `embeds` attribute contains a JSON array of HTML strings, with HTML
    /// entities encoded on top of valid JSON. The raw attribute value looks like:
    ///   `[&quot;&lt;!DOCTYPE html&gt;\n&lt;html&gt;...&quot;]`
    ///
    /// Critical: we must ONLY decode HTML entities (&quot; &lt; &gt; &amp; &apos;)
    /// and must NOT convert `\n` → actual newline or `\"` → `"` before parsing.
    /// Those are JSON escape sequences that must remain intact so JSONSerialization
    /// can parse the array correctly. Raw newlines inside JSON string values make
    /// the JSON invalid and cause parse failure.
    private static func parseEmbedsAttribute(from block: String) -> [String] {
        guard let raw = extractAttribute("embeds", from: block),
              !raw.isEmpty else { return [] }

        // Fast bail: if the raw (still HTML-entity-encoded) attribute contains
        // "data-iv-build", every decoded embed will be filtered out downstream.
        // Skip the expensive ~30KB HTML entity decode + JSON parse that runs
        // 15-20x/sec during VIZ streaming on the main thread.
        if raw.contains("data-iv-build") { return [] }

        // Decode ONLY HTML entities — do NOT touch \n or \" (those are JSON escapes)
        let jsonStr = raw
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")

        // Parse as a JSON array of strings
        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }

        // Filter out data-iv-build embeds — these are the Inline Visualizer plugin's
        // HTMLResponse iframes that depend on parent.document DOM access (impossible in
        // a sandboxed WKWebView). The native InlineVisualizerView renders visualizations
        // instead, so these embeds must be suppressed unconditionally in BOTH the
        // message-level path (messageEmbeds filter in AssistantMessageContent.body) AND
        // here in the tool-call path so they never reach RichUIEmbedView.
        return array.filter { !$0.isEmpty && !$0.contains("data-iv-build") }
    }

    // MARK: - Raw Reasoning Tag Preprocessing

    /// All tag pairs that OpenWebUI recognises by default for reasoning content.
    /// Order matters: more specific / longer tags first to avoid partial matches.
    private static let defaultReasoningTagPairs: [(open: String, close: String)] = [
        ("<|begin_of_thought|>", "<|end_of_thought|>"),
        ("◁think▷", "◁/think▷"),
        ("<thinking>", "</thinking>"),
        ("<reasoning>", "</reasoning>"),
        ("<thought>", "</thought>"),
        ("<reason>", "</reason>"),
        ("<think>", "</think>"),
    ]

    /// Converts raw reasoning tags (from model output) and incomplete
    /// `<details type="reasoning">` blocks (mid-stream) into well-formed
    /// `<details type="reasoning">` blocks so the existing parser handles
    /// them uniformly.
    ///
    /// ## What this handles
    ///
    /// **Raw model tags** — Models like Qwen, DeepSeek R1, and others emit
    /// raw tags (`<think>`, `<thinking>`, `<reason>`, `<reasoning>`,
    /// `<thought>`, `<|begin_of_thought|>`) in their streaming output. The
    /// OpenWebUI server converts these to `<details type="reasoning">` blocks
    /// *after* streaming completes. During streaming the app receives the raw
    /// tags which would otherwise render as visible text.
    ///
    /// **Incomplete `<details>` blocks** — During streaming, the server may
    /// have started building a `<details type="reasoning">` block but the
    /// closing `</details>` hasn't arrived yet. Without this, the `<summary>`
    /// tag inside leaks as visible text.
    ///
    /// ## Cases
    /// 1. **Complete pair**: `<think>content</think>` → done reasoning block
    /// 2. **Unclosed tag**: `<think>content` (mid-stream) → in-progress block
    /// 3. **Incomplete details block**: `<details type="reasoning"><summary>…` → in-progress block
    /// 4. **No matching tags**: content returned unchanged
    private static func preprocessThinkTags(_ content: String) -> String {
        var result = content

        // ── Phase 1: Convert raw model reasoning tags ──
        for pair in defaultReasoningTagPairs {
            // Quick check: skip this pair entirely if the open tag isn't present
            guard result.contains(pair.open) else { continue }

            let escapedOpen = NSRegularExpression.escapedPattern(for: pair.open)
            let escapedClose = NSRegularExpression.escapedPattern(for: pair.close)

            // Case 1: Complete pairs (thinking finished)
            // Use .caseInsensitive so <Think>, <THINK>, <Thinking>, etc. all match
            if let completeRegex = cachedRegex("\(escapedOpen)([\\s\\S]*?)\(escapedClose)",
                options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                let nsResult = result as NSString
                let matches = completeRegex.matches(
                    in: result,
                    range: NSRange(location: 0, length: nsResult.length)
                )
                for match in matches.reversed() where match.numberOfRanges > 1 {
                    let thinkContent = nsResult.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let replacement = """
                    <details type="reasoning" done="true">\
                    <summary>Thinking</summary>\
                    \(thinkContent)\
                    </details>
                    """
                    result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                }
            }

            // Case 2: Unclosed tag (still streaming thinking content)
            // Case-insensitive check for the open tag
            if result.range(of: pair.open, options: .caseInsensitive) != nil {
                if let openRegex = cachedRegex("\(escapedOpen)([\\s\\S]*)$",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                    let nsResult = result as NSString
                    if let match = openRegex.firstMatch(
                        in: result,
                        range: NSRange(location: 0, length: nsResult.length)
                    ), match.numberOfRanges > 1 {
                        let thinkContent = nsResult.substring(with: match.range(at: 1))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let replacement = """
                        <details type="reasoning" done="false">\
                        <summary>Thinking</summary>\
                        \(thinkContent)\
                        </details>
                        """
                        result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                    }
                }
            }
        }

        // ── Phase 1b: Also handle case-insensitive open tags that the
        // case-sensitive .contains() quick-check above may have skipped ──
        // Re-run Phase 1 logic for tags present only in different casing.
        for pair in defaultReasoningTagPairs {
            // Skip Unicode/pipe variants — they're case-sensitive by nature
            if pair.open.hasPrefix("<|") || pair.open.hasPrefix("◁") { continue }

            // Already handled if exact-case was found. Check case-insensitive.
            guard result.range(of: pair.open, options: .caseInsensitive) != nil else { continue }
            // If exact case exists, Phase 1 already handled it
            guard !result.contains(pair.open) else { continue }

            let escapedOpen = NSRegularExpression.escapedPattern(for: pair.open)
            let escapedClose = NSRegularExpression.escapedPattern(for: pair.close)

            // Complete pairs (case-insensitive)
            if let completeRegex = cachedRegex("\(escapedOpen)([\\s\\S]*?)\(escapedClose)",
                options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                let nsResult = result as NSString
                let matches = completeRegex.matches(
                    in: result,
                    range: NSRange(location: 0, length: nsResult.length)
                )
                for match in matches.reversed() where match.numberOfRanges > 1 {
                    let thinkContent = nsResult.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let replacement = """
                    <details type="reasoning" done="true">\
                    <summary>Thinking</summary>\
                    \(thinkContent)\
                    </details>
                    """
                    result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                }
            }

            // Unclosed tag (case-insensitive)
            if result.range(of: pair.open, options: .caseInsensitive) != nil {
                if let openRegex = cachedRegex("\(escapedOpen)([\\s\\S]*)$",
                    options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                    let nsResult = result as NSString
                    if let match = openRegex.firstMatch(
                        in: result,
                        range: NSRange(location: 0, length: nsResult.length)
                    ), match.numberOfRanges > 1 {
                        let thinkContent = nsResult.substring(with: match.range(at: 1))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let replacement = """
                        <details type="reasoning" done="false">\
                        <summary>Thinking</summary>\
                        \(thinkContent)\
                        </details>
                        """
                        result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                    }
                }
            }
        }

        // ── Phase 2: Handle incomplete <details type="tool_calls"> blocks ──
        // During streaming the server emits tool call blocks incrementally.
        // The closing </details> may not have arrived yet, so the main regex
        // never matches and the partial block passes through as raw text.
        // We close the block so the parser can render it as an in-progress tool call.
        if result.contains("<details") && !result.isEmpty {
            if let incompleteToolRegex = cachedRegex(#"(<details\s+[^>]*type\s*=\s*["']tool_calls["'][^>]*>)([\s\S]*)$"#,
                options: [.dotMatchesLineSeparators]) {
                let nsResult = result as NSString
                let openToolCount = countOccurrences(of: #"<details\s+[^>]*type\s*=\s*["']tool_calls["']"#, in: result)
                let closeCount = countOccurrences(of: "</details>", in: result)

                if openToolCount > closeCount {
                    let allMatches = incompleteToolRegex.matches(
                        in: result,
                        range: NSRange(location: 0, length: nsResult.length)
                    )
                    if let match = allMatches.last, match.numberOfRanges > 1 {
                        let openTag = nsResult.substring(with: match.range(at: 1))
                        let innerContent = match.numberOfRanges > 2
                            ? nsResult.substring(with: match.range(at: 2))
                            : ""

                        // Inject done="false" if not already present so the
                        // ToolCallView shows an in-progress spinner.
                        let tagWithDone: String = {
                            if openTag.contains("done=") { return openTag }
                            return openTag.replacingOccurrences(of: ">", with: " done=\"false\">")
                        }()

                        let replacement = tagWithDone + innerContent + "</details>"
                        result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                    }
                }
            }
        }

        // ── Phase 3: Handle incomplete <details type="reasoning"> blocks ──
        // During streaming, the server may have started a <details> block but
        // </details> hasn't arrived yet. The main parser's regex requires the
        // closing tag, so the partial block passes through as raw text — with
        // <summary> tags visible to the user.
        // Detect an unclosed <details type="reasoning"...> and wrap it properly.
        if result.contains("<details") && !result.isEmpty {
            if let incompleteRegex = cachedRegex(#"(<details\s+[^>]*type\s*=\s*["']reasoning["'][^>]*>)([\s\S]*)$"#,
                options: [.dotMatchesLineSeparators]) {
                let nsResult = result as NSString
                // Only act if there's an opening <details> without a matching </details>
                // We check by counting opens vs closes for reasoning details
                let openCount = countOccurrences(of: #"<details\s+[^>]*type\s*=\s*["']reasoning["']"#, in: result)
                let closeCount = countOccurrences(of: "</details>", in: result)

                if openCount > closeCount {
                    // Find the LAST unclosed opening tag
                    let allMatches = incompleteRegex.matches(
                        in: result,
                        range: NSRange(location: 0, length: nsResult.length)
                    )
                    if let match = allMatches.last, match.numberOfRanges > 2 {
                        let innerContent = nsResult.substring(with: match.range(at: 2))

                        // Extract summary if present, strip it from content
                        var summary = "Thinking..."
                        var bodyContent = innerContent
                        if let summaryRegex = cachedRegex(#"<summary>([\s\S]*?)</summary>"#,
                            options: [.dotMatchesLineSeparators]) {
                            let nsInner = innerContent as NSString
                            if let sMatch = summaryRegex.firstMatch(
                                in: innerContent,
                                range: NSRange(location: 0, length: nsInner.length)
                            ), sMatch.numberOfRanges > 1 {
                                summary = nsInner.substring(with: sMatch.range(at: 1))
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                bodyContent = (innerContent as NSString)
                                    .replacingCharacters(in: sMatch.range, with: "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                            } else {
                                // Partial <summary> without closing — strip it
                                if let partialSummary = cachedRegex(#"<summary>([\s\S]*)$"#,
                                    options: [.dotMatchesLineSeparators]) {
                                    let nsInner2 = bodyContent as NSString
                                    if let psMatch = partialSummary.firstMatch(
                                        in: bodyContent,
                                        range: NSRange(location: 0, length: nsInner2.length)
                                    ), psMatch.numberOfRanges > 1 {
                                        summary = nsInner2.substring(with: psMatch.range(at: 1))
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                        if summary.isEmpty { summary = "Thinking..." }
                                        bodyContent = (bodyContent as NSString)
                                            .replacingCharacters(in: psMatch.range, with: "")
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }
                            }
                        }

                        // Rebuild as a complete details block (in-progress)
                        let replacement = """
                        <details type="reasoning" done="false">\
                        <summary>\(summary)</summary>\
                        \(bodyContent)\
                        </details>
                        """
                        result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                    }
                }
            }
        }

        // ── Phase 3: Clean up orphaned closing tags ──
        // This handles two scenarios:
        //
        // A) **Orphaned closer from split streaming**: The opening <think> was
        //    processed in an earlier chunk, and the closing </think> arrives
        //    alone in a later chunk with no matching opener. Without this,
        //    the bare </think> leaks as visible text / code block.
        //
        // B) **Qwen no-opener pattern**: Some Qwen models skip the opening
        //    <think> tag entirely and just start reasoning, then only emit
        //    </think> when done. Content before the closer is reasoning text.
        //
        // Strategy: For each closing tag, if it exists without a matching
        // opener, check if there's meaningful content before it. If so,
        // wrap that content as a reasoning block. If not, just strip the tag.
        for pair in defaultReasoningTagPairs {
            let closeTag = pair.close

            // Case-insensitive check for the closing tag
            guard result.range(of: closeTag, options: .caseInsensitive) != nil else { continue }

            // If the matching open tag is also present, this is a complete pair
            // that Phase 1 should have handled — skip.
            if result.range(of: pair.open, options: .caseInsensitive) != nil { continue }

            // Also skip if the closer is inside a <details> block (already converted)
            if result.contains("<details") && result.range(of: closeTag, options: .caseInsensitive) != nil {
                // Check if the close tag appears outside of any <details>...</details> block
                let stripped = result.replacingOccurrences(
                    of: #"<details\s+[^>]*>[\s\S]*?</details>"#,
                    with: "",
                    options: .regularExpression
                )
                guard stripped.range(of: closeTag, options: .caseInsensitive) != nil else { continue }
            }

            let escapedClose = NSRegularExpression.escapedPattern(for: closeTag)

            // Try to find: content</think> (Qwen no-opener pattern)
            // Match everything from start-of-string (or after last <details> block)
            // up to and including the closing tag
            if let orphanRegex = cachedRegex("^([\\s\\S]*?)\(escapedClose)",
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) {
                let nsResult = result as NSString
                if let match = orphanRegex.firstMatch(
                    in: result,
                    range: NSRange(location: 0, length: nsResult.length)
                ), match.numberOfRanges > 1 {
                    let beforeContent = nsResult.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !beforeContent.isEmpty &&
                       !beforeContent.hasPrefix("<details") &&
                       beforeContent.count > 20 {
                        // Meaningful content before the closer → treat as reasoning
                        // (Qwen no-opener pattern)
                        let replacement = """
                        <details type="reasoning" done="true">\
                        <summary>Thinking</summary>\
                        \(beforeContent)\
                        </details>
                        """
                        result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                    } else {
                        // No meaningful content (or just whitespace) → strip the tag
                        // This handles the orphaned closer from split streaming
                        result = (result as NSString).replacingCharacters(in: match.range, with: beforeContent)
                    }
                }
            }

            // Strip any remaining instances of the closing tag (there may be
            // multiple orphans, or the above only caught the first)
            if let stripRegex = cachedRegex("\\s*\(escapedClose)\\s*",
                options: [.caseInsensitive]
            ) {
                result = stripRegex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(location: 0, length: (result as NSString).length),
                    withTemplate: "\n"
                )
            }
        }

        // Also strip orphaned Unicode triangle closers and pipe closers
        // that might not have been caught above
        let additionalOrphanClosers = ["◁/think▷", "<|end_of_thought|>"]
        for closer in additionalOrphanClosers {
            if result.contains(closer) {
                result = result.replacingOccurrences(of: closer, with: "")
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Counts regex occurrences in a string.
    private static func countOccurrences(of pattern: String, in text: String) -> Int {
        guard let regex = cachedRegex(pattern, options: [.dotMatchesLineSeparators]) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// Extracts an HTML attribute value from a tag string.
    private static func extractAttribute(_ name: String, from html: String) -> String? {
        // Match attribute="value" with double or single quotes
        let patterns = [
            name + #"\s*=\s*"([^"]*)""#,
            name + #"\s*=\s*'([^']*)'"#
        ]

        for p in patterns {
            guard let regex = cachedRegex(p, options: [.dotMatchesLineSeparators]) else { continue }
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
            if let urlRegex = cachedRegex(urlPattern) {
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
            if let jsonRegex = cachedRegex(jsonFieldPattern) {
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
                if let uuidRegex = cachedRegex(uuidPattern) {
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

// MARK: - Rich UI Embed View

/// Renders a Rich UI embed — a full HTML document returned by a tool call —
/// inside a sandboxed WKWebView. This brings Open WebUI's "Rich UI" feature
/// to the iOS app: tools can return interactive HTML (cards, dashboards, charts,
/// forms, SMS composers, etc.) that render inline in the chat.
struct RichUIEmbedView: View {
    let html: String
    /// The tool call arguments JSON string, injected as `window.args`.
    let toolArgs: String?
    /// The server's auth JWT token injected into the webview's localStorage.
    /// Allows embeds that call `/api/` endpoints to authenticate correctly.
    var authToken: String? = nil
    /// The server base URL used as the WKWebView's baseURL so relative `/api/`
    /// paths resolve correctly and localStorage is accessible (not null-origin).
    var serverBaseURL: String? = nil

    /// Starts at 1 so the webview renders at minimal size until the embed
    /// reports its own height via postMessage or the didFinish fallback fires.
    @State private var webViewHeight: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    /// Maximum height before the embed gets internal scroll.
    /// Tall embeds (weather dashboards, etc.) can scroll within this frame.
    private let maxHeight: CGFloat = 600

    var body: some View {
        RichUIWebView(
            html: instrumentedHTML,
            height: $webViewHeight,
            authToken: authToken,
            serverBaseURL: serverBaseURL
        )
        .frame(height: min(max(webViewHeight, 1), maxHeight))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.2), value: webViewHeight)
    }

    /// The HTML with our bridge script injected just before `</body>` (or appended).
    /// The bridge:
    ///   1. Overrides `parent.postMessage` so the embed's height-reporting script works.
    ///   2. Injects `window.args` for tool argument access.
    ///
    /// Also injects a `<meta name="viewport">` tag so WKWebView renders at device
    /// width (not the default 980px desktop viewport). Without this the embed content
    /// appears tiny because a 420px card is only ~43% of the 980px default viewport.
    private var instrumentedHTML: String {
        let argsJSON: String
        if let args = toolArgs, !args.isEmpty {
            // Escape backticks and backslashes for safe inline JS string literal
            let escaped = args
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
            argsJSON = escaped
        } else {
            argsJSON = "null"
        }

        let viewportMeta = #"<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0">"#

        // Inject viewport meta tag into <head> so WKWebView uses device width.
        // Try <head> first, then <html>, then prepend to the whole document.
        func injectViewport(_ source: String) -> String {
            if let range = source.range(of: "<head>", options: .caseInsensitive) {
                // After opening <head>
                return source.replacingCharacters(in: range, with: "<head>\(viewportMeta)")
            } else if let range = source.range(of: "<head/>", options: .caseInsensitive) {
                // Self-closing <head/> → replace with a proper head
                return source.replacingCharacters(in: range, with: "<head>\(viewportMeta)</head>")
            } else if let range = source.range(of: "<html", options: .caseInsensitive),
                      let closeRange = source.range(of: ">", range: range.upperBound..<source.endIndex) {
                // After the closing > of the <html ...> opening tag
                return source.replacingCharacters(in: closeRange, with: "><head>\(viewportMeta)</head>")
            } else {
                // No HTML structure — prepend the meta tag
                return "\(viewportMeta)\n\(source)"
            }
        }

        let htmlWithViewport = injectViewport(html)

        let bridge = """
        <script>
        (function() {
          // ── 1. Tool args injection ──────────────────────────────────────────
          try {
            window.args = JSON.parse(`\(argsJSON)`);
          } catch(e) {
            window.args = null;
          }

          // ── 2. Console.log forwarding to native logger ──────────────────────
          // Forwards console.log/warn/error to the native richUIBridge so we can
          // see JS output in the Xcode log (or Console.app) as "RichUIWebView: JS console: ..."
          var _nativeLog = function(level, args) {
            try {
              var msg = Array.prototype.slice.call(args).map(function(a) {
                try { return typeof a === 'object' ? JSON.stringify(a) : String(a); } catch(e) { return String(a); }
              }).join(' ');
              window.webkit.messageHandlers.richUIBridge.postMessage({ type: 'log', level: level, msg: msg });
            } catch(e) {}
          };
          var _origConsoleLog   = console.log.bind(console);
          var _origConsoleWarn  = console.warn.bind(console);
          var _origConsoleError = console.error.bind(console);
          console.log   = function() { _nativeLog('log',   arguments); _origConsoleLog.apply(console, arguments);   };
          console.warn  = function() { _nativeLog('warn',  arguments); _origConsoleWarn.apply(console, arguments);  };
          console.error = function() { _nativeLog('error', arguments); _origConsoleError.apply(console, arguments); };

          // ── 3. Download interception ────────────────────────────────────────
          // Ace Step (and similar tools) use:
          //   fetch(url) → blob → URL.createObjectURL(blob) → a.href = blobURL → a.click()
          // WKWebView cannot handle blob-URL downloads natively, so we intercept
          // this pattern at two levels:

          // Level A: Track blob URLs → original fetch URL mapping.
          // When fetch() is called for a URL that looks like a file endpoint,
          // we record it so we can resolve the original URL when a.click() fires.
          var _blobUrlToOriginal = {};  // blobURL → { url, filename }
          var _origFetch = window.fetch.bind(window);
          window.fetch = function(input, init) {
            var url = (typeof input === 'string') ? input : (input && input.url) || '';
            var p = _origFetch.apply(this, arguments);
            // Track the promise → original URL so we can intercept createObjectURL below
            p._richUISourceURL = url;
            return p;
          };

          // Level B: Override URL.createObjectURL to tag blob URLs with their MIME type.
          // Also override Response.prototype.blob() to carry the fetch source URL
          // through the response chain so we can resolve blob: URLs to their origin.
          var _origResponseBlob = Response.prototype.blob;
          Response.prototype.blob = function() {
            var self = this;
            var sourceURL = (self.url) || '';
            return _origResponseBlob.apply(this, arguments).then(function(blob) {
              // Tag the blob with its HTTP origin URL for later resolution
              try { blob._richUISourceURL = sourceURL; } catch(e) {}
              return blob;
            });
          };

          var _origCreateObjectURL = URL.createObjectURL.bind(URL);
          URL.createObjectURL = function(obj) {
            var blobURL = _origCreateObjectURL(obj);
            // Capture MIME type from the Blob/File object itself (e.g. 'audio/mpeg',
            // 'video/mp4', 'image/png') — this lets us derive the correct file
            // extension later without hardcoding any specific format.
            var mimeType = (obj && obj.type) ? obj.type : '';
            var sourceURL = (obj && obj._richUISourceURL) ? obj._richUISourceURL : '';
            _blobUrlToOriginal[blobURL] = { url: sourceURL || blobURL, mimeType: mimeType };
            console.log('[RichUI] createObjectURL: blobURL=' + blobURL.substring(0, 60) + ' mime=' + mimeType + ' source=' + sourceURL.substring(0, 80));
            return blobURL;
          };

          // Level C: Intercept all anchor clicks at the document level.
          // IMPORTANT: Skip placeholder hrefs (href="#", empty, javascript:) so
          // the embed's own JS click handler can run first (e.g. Ace Step's Save
          // button uses <a href="#" download> as a placeholder and handles the
          // real download asynchronously via fetch→blob→createObjectURL→a.click()).
          // The real download anchor (with blob: or https: href) is caught by Level D.
          document.addEventListener('click', function(e) {
            var el = e.target;
            // Walk up the DOM in case the click target is a child of <a>
            while (el && el.tagName !== 'A') { el = el.parentElement; }
            if (!el) return;
            var a = el;
            var href = a.href || '';
            var dlAttr = a.getAttribute('download');
            if (dlAttr === null) return;  // not a download link — ignore

            // Skip placeholder hrefs — let the embed's own JS handler run.
            // The real download will be a blob: or https: URL caught by Level D.
            var rawHref = a.getAttribute('href') || '';
            if (!href ||
                rawHref === '#' ||
                rawHref === '' ||
                rawHref.toLowerCase().startsWith('javascript:') ||
                href === window.location.href ||
                href === window.location.href + '#') {
              console.log('[RichUI] Level C: skipping placeholder href="' + rawHref + '" — letting embed handle it');
              return;
            }

            var filename = dlAttr || href.split('/').pop() || 'download';
            var mimeType = '';
            console.log('[RichUI] Level C anchor click: href=' + href.substring(0, 80) + ' download=' + dlAttr);

            e.preventDefault();
            e.stopImmediatePropagation();

            // If it's a blob: URL, resolve to the original fetch URL and MIME type
            var resolvedURL = href;
            if (href.startsWith('blob:')) {
              var tracked = _blobUrlToOriginal[href];
              if (tracked) {
                mimeType = tracked.mimeType || '';
                if (tracked.url && !tracked.url.startsWith('blob:')) {
                  resolvedURL = tracked.url;
                  console.log('[RichUI] Level C resolved blob to: ' + resolvedURL + ' mime=' + mimeType);
                }
              }
            }

            // Send to native
            try {
              window.webkit.messageHandlers.richUIBridge.postMessage({
                type: 'download',
                url: resolvedURL,
                filename: filename,
                mimeType: mimeType
              });
            } catch(err) {
              console.error('[RichUI] download bridge postMessage failed: ' + err);
            }
          }, true);

          // Level D: Also intercept programmatic a.click() by monkey-patching
          // HTMLAnchorElement.prototype.click. Some embeds create a detached <a>
          // (not in DOM), set href + download, then call .click() — the DOM
          // listener above won't fire for detached elements.
          // This is the primary catch for the Ace Step pattern:
          //   fetch(url) → resp.blob() → URL.createObjectURL(blob) → a.href=blobURL → a.click()
          var _origAnchorClick = HTMLAnchorElement.prototype.click;
          HTMLAnchorElement.prototype.click = function() {
            var a = this;
            var href = a.href || '';
            var dlAttr = a.getAttribute('download');
            if (dlAttr !== null && href) {
              var filename = dlAttr || href.split('/').pop() || 'download';
              var mimeType = '';
              console.log('[RichUI] Level D anchor.click(): href=' + href.substring(0, 80) + ' download=' + dlAttr);

              var resolvedURL = href;
              if (href.startsWith('blob:')) {
                var tracked = _blobUrlToOriginal[href];
                if (tracked) {
                  mimeType = tracked.mimeType || '';
                  if (tracked.url && !tracked.url.startsWith('blob:')) {
                    resolvedURL = tracked.url;
                    console.log('[RichUI] Level D resolved blob to: ' + resolvedURL + ' mime=' + mimeType);
                  }
                }
              }

              try {
                window.webkit.messageHandlers.richUIBridge.postMessage({
                  type: 'download',
                  url: resolvedURL,
                  filename: filename,
                  mimeType: mimeType
                });
              } catch(err) {
                console.error('[RichUI] download bridge postMessage (Level D) failed: ' + err);
              }
              return;  // Don't call original .click()
            }
            return _origAnchorClick.apply(this, arguments);
          };

          // ── 4. parent.postMessage bridge ────────────────────────────────────
          // The embed HTML calls parent.postMessage({ type: 'iframe:height', height: h }, '*')
          // for auto-sizing. In a WKWebView there is no real parent frame, so we
          // intercept this and forward it to our WKScriptMessageHandler.
          var _nativePost = function(msg) {
            try {
              if (msg && msg.type === 'iframe:height' && typeof msg.height === 'number') {
                window.webkit.messageHandlers.richUIBridge.postMessage({ type: 'height', value: msg.height });
              } else if (msg && msg.type === 'open-url' && msg.url) {
                window.webkit.messageHandlers.richUIBridge.postMessage({ type: 'openUrl', url: msg.url });
              }
            } catch(e) {}
          };

          // Override parent.postMessage
          try {
            Object.defineProperty(window, 'parent', {
              get: function() {
                return {
                  postMessage: _nativePost
                };
              }
            });
          } catch(e) {
            // Fallback: assign directly if defineProperty fails
            window.parent = { postMessage: _nativePost };
          }

          // Also handle window.postMessage calls that some embeds use
          var _origPost = window.postMessage.bind(window);
          window.postMessage = function(msg, targetOrigin) {
            _nativePost(msg);
            try { _origPost(msg, targetOrigin || '*'); } catch(e) {}
          };

          console.log('[RichUI] bridge installed');
        })();
        </script>
        """

        // Inject bridge before </body> if present, otherwise append.
        // Use htmlWithViewport (not the original html) so both injections apply.
        if let range = htmlWithViewport.range(of: "</body>", options: .caseInsensitive) {
            return htmlWithViewport.replacingCharacters(in: range, with: bridge + "</body>")
        }
        return htmlWithViewport + bridge
    }
}

// MARK: - Rich UI WKWebView Wrapper

private let richUILog = Logger(subsystem: "com.openui", category: "RichUIWebView")

/// UIViewRepresentable wrapping a WKWebView for Rich UI embeds.
/// Handles height reporting, URL scheme routing, slider gestures, and downloads.
private struct RichUIWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    /// Auth JWT token injected into localStorage so the embed's authFetch()
    /// can authenticate `/api/` calls. Nil when no token is available.
    var authToken: String? = nil
    /// The server base URL used as the WKWebView baseURL so:
    /// 1. Relative `/api/` paths resolve against the correct origin.
    /// 2. `localStorage` is not null-origin (which blocks access).
    var serverBaseURL: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, authToken: authToken, serverBaseURL: serverBaseURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "richUIBridge")

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Allow inline media playback (useful for media-rich embeds)
        config.allowsInlineMediaPlayback = true

        // Remove ALL gesture-to-play restrictions so JS .play() from embed
        // buttons works exactly like a browser (no direct-gesture requirement).
        config.mediaTypesRequiringUserActionForPlayback = []

        // Allow JS to open windows (window.open / target="_blank")
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear

        // ── Scroll / gesture setup ────────────────────────────────────────────
        // Disable the scroll view entirely so it has NO gesture recognizers that
        // compete with HTML interactive elements.
        //
        // Background: WKWebView's internal scroll view owns a UIScrollViewPanGestureRecognizer
        // that has higher UIKit priority than WebKit's touch-handling. When the user
        // drags an <input type="range"> slider, the pan recognizer fires first and
        // claims the touch sequence — the slider thumb never moves.
        //
        // Setting isScrollEnabled = false removes the pan recognizer from the
        // responder chain, giving touches directly to WebKit. The SwiftUI .frame()
        // already constrains the webview height to content size (via postMessage /
        // scrollHeight fallback), so vertical scrolling inside the webview is not
        // needed — the parent chat ScrollView handles page-level scroll.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.delaysContentTouches = false
        // Belt-and-suspenders: also set cancelsTouchesInView = false so any
        // residual recognizer still in the tree doesn't swallow horizontal drags.
        webView.scrollView.panGestureRecognizer.cancelsTouchesInView = false

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false

        context.coordinator.webView = webView

        richUILog.debug("makeUIView: loading HTML (\(html.count) bytes), baseURL=\(serverBaseURL ?? "nil")")
        webView.loadHTMLString(html, baseURL: resolvedBaseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload if the HTML actually changed (e.g. args updated)
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            context.coordinator.authToken = authToken
            context.coordinator.serverBaseURL = serverBaseURL
            webView.loadHTMLString(html, baseURL: resolvedBaseURL)
        }
    }

    /// The base URL passed to WKWebView for origin-based security.
    private var resolvedBaseURL: URL? {
        guard let base = serverBaseURL, !base.isEmpty else { return nil }
        return URL(string: base)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        @Binding var height: CGFloat
        var loadedHTML: String?
        weak var webView: WKWebView?
        var authToken: String?
        var serverBaseURL: String?
        private var pendingDownloadURL: URL?

        init(height: Binding<CGFloat>, authToken: String?, serverBaseURL: String?) {
            _height = height
            self.authToken = authToken
            self.serverBaseURL = serverBaseURL
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "richUIBridge",
                  let body = message.body as? [String: Any] else { return }

            let msgType = body["type"] as? String ?? "unknown"
            richUILog.debug("JS→native message: type=\(msgType) body=\(body as NSDictionary)")

            switch msgType {
            case "height":
                let h: CGFloat? = {
                    if let v = body["value"] as? Double { return CGFloat(v) }
                    if let v = body["value"] as? CGFloat { return v }
                    return nil
                }()
                if let h, h > 1 {
                    richUILog.debug("height update: \(h)pt")
                    DispatchQueue.main.async { [weak self] in self?.height = h }
                }

            case "openUrl":
                if let urlString = body["url"] as? String, let url = URL(string: urlString) {
                    richUILog.debug("openUrl: \(urlString)")
                    DispatchQueue.main.async { UIApplication.shared.open(url) }
                }

            case "download":
                // JS download bridge: embed intercepted a fetch+blob download
                // and forwarded the file URL + suggested filename to us.
                // mimeType is passed from the Blob object's .type property so we
                // can derive the correct file extension without hardcoding any format.
                let urlString = body["url"] as? String ?? ""
                let filename   = body["filename"] as? String ?? "download"
                let mimeType   = body["mimeType"] as? String ?? ""
                richUILog.debug("download bridge: url=\(urlString) filename=\(filename) mime=\(mimeType)")
                fetchAndShare(urlString: urlString, filename: filename, hintMimeType: mimeType)

            case "log":
                // JS console.log forwarding
                let logMsg = body["msg"] as? String ?? "(empty)"
                richUILog.debug("JS console: \(logMsg)")

            default:
                richUILog.warning("unhandled JS message type: \(msgType)")
            }
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                richUILog.debug("navigationAction: no URL → allow")
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""
            let navType = navigationAction.navigationType.rawValue
            richUILog.debug("navigationAction: type=\(navType) scheme=\(scheme) url=\(url.absoluteString.prefix(120))")

            // ── Always allow in-context navigations ──────────────────────────
            // .other covers: initial load, fetch/XHR, JS-triggered src changes,
            // blob navigations. These are in-page requests, never page-leaving.
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            // In-document schemes — never navigate away.
            if scheme == "blob" || scheme == "data" || scheme == "javascript" || scheme == "about" {
                decisionHandler(.allow)
                return
            }

            // Same-origin API calls (relative /api/ paths).
            if let baseHost = webView.url?.host, let urlHost = url.host, baseHost == urlHost {
                richUILog.debug("navigationAction: same-origin → allow")
                decisionHandler(.allow)
                return
            }

            // External links — open in Safari, cancel webview navigation.
            if scheme == "http" || scheme == "https" {
                richUILog.debug("navigationAction: external link → open in Safari")
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
                return
            }

            // System URL schemes (tel:, mailto:, etc.)
            if UIApplication.shared.canOpenURL(url) {
                richUILog.debug("navigationAction: system URL → open")
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            }
            decisionHandler(.cancel)
        }

        // MARK: WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                richUILog.debug("window.open: \(url.absoluteString.prefix(120))")
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            richUILog.debug("didFinish: injecting auth token and measuring height")

            // Inject auth token into localStorage for authenticated API calls.
            if let token = authToken, !token.isEmpty {
                let safeToken = token.replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript("localStorage.setItem('token', '\(safeToken)')") { _, err in
                    if let err {
                        richUILog.warning("localStorage inject error: \(err.localizedDescription)")
                    } else {
                        richUILog.debug("auth token injected into localStorage")
                    }
                }
            } else {
                richUILog.debug("no auth token to inject")
            }

            // Measure content height as fallback when postMessage hasn't fired.
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, err in
                guard let self else { return }
                if let err {
                    richUILog.warning("scrollHeight eval error: \(err.localizedDescription)")
                    return
                }
                let h: CGFloat? = {
                    if let v = result as? Double { return CGFloat(v) }
                    if let v = result as? CGFloat { return v }
                    return nil
                }()
                guard let h, h > 1 else { return }
                richUILog.debug("scrollHeight fallback: \(h)pt (current=\(self.height)pt)")
                DispatchQueue.main.async {
                    if self.height <= 1 { self.height = h }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            richUILog.error("didFail navigation: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            richUILog.error("didFailProvisional: \(error.localizedDescription)")
        }

        /// Intercept navigation responses with `Content-Disposition: attachment`.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let response = navigationResponse.response as? HTTPURLResponse
            let statusCode   = response?.statusCode ?? 0
            let disposition  = response?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            let mimeType     = response?.mimeType ?? navigationResponse.response.mimeType ?? ""
            let canShow      = navigationResponse.canShowMIMEType
            richUILog.debug("navigationResponse: status=\(statusCode) mime=\(mimeType) disposition='\(disposition)' canShow=\(canShow) url=\(navigationResponse.response.url?.absoluteString.prefix(120) ?? "nil")")

            let isDownload = disposition.lowercased().contains("attachment") ||
                             (!mimeType.hasPrefix("text/") &&
                              !mimeType.hasPrefix("image/") &&
                              !mimeType.contains("html") &&
                              !mimeType.contains("javascript") &&
                              !mimeType.isEmpty &&
                              !canShow)

            if isDownload {
                richUILog.debug("navigationResponse: routing to WKDownloadDelegate")
                decisionHandler(.download)
            } else {
                richUILog.debug("navigationResponse: allowing display")
                decisionHandler(.allow)
            }
        }

        // MARK: WKDownloadDelegate

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            richUILog.debug("WKDownload: navigationResponse became download")
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            richUILog.debug("WKDownload: navigationAction became download")
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String
        ) async -> URL? {
            let tmp  = FileManager.default.temporaryDirectory
            let dest = tmp.appendingPathComponent(suggestedFilename)
            try? FileManager.default.removeItem(at: dest)
            pendingDownloadURL = dest
            richUILog.debug("WKDownload: destination=\(dest.path) suggestedFilename=\(suggestedFilename)")
            return dest
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let fileURL = pendingDownloadURL else {
                richUILog.error("WKDownload: finished but pendingDownloadURL is nil")
                return
            }
            pendingDownloadURL = nil
            richUILog.debug("WKDownload: finished at \(fileURL.path)")
            presentShareSheet(for: fileURL)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            richUILog.error("WKDownload: failed — \(error.localizedDescription)")
            pendingDownloadURL = nil
        }

        // MARK: - Native download fetch (JS bridge path)

        /// Fetches a file URL with auth token via URLSession and presents the share sheet.
        /// Called when the JS download bridge intercepts a fetch+blob download.
        ///
        /// - Parameters:
        ///   - urlString: The URL to fetch (absolute or relative to serverBaseURL).
        ///   - filename: Suggested filename from the `download` attribute or URL path.
        ///   - hintMimeType: MIME type reported by the Blob object (e.g. `audio/mpeg`,
        ///     `video/mp4`). Used as a fallback if the HTTP response doesn't include a
        ///     meaningful Content-Type. Never hardcoded to a specific format.
        private func fetchAndShare(urlString: String, filename: String, hintMimeType: String = "") {
            guard !urlString.isEmpty else {
                richUILog.error("fetchAndShare: empty URL string")
                return
            }

            // Resolve relative URLs against the server base URL
            let resolvedURL: URL? = {
                if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                    return URL(string: urlString)
                }
                guard let base = serverBaseURL, let baseURL = URL(string: base) else { return nil }
                return URL(string: urlString, relativeTo: baseURL)?.absoluteURL
            }()

            guard let url = resolvedURL else {
                richUILog.error("fetchAndShare: could not resolve URL '\(urlString)'")
                return
            }

            richUILog.debug("fetchAndShare: fetching \(url.absoluteString) as '\(filename)' hint-mime=\(hintMimeType)")

            var request = URLRequest(url: url)
            if let token = authToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                richUILog.debug("fetchAndShare: added Authorization header")
            }

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }

                if let error {
                    richUILog.error("fetchAndShare: URLSession error — \(error.localizedDescription)")
                    return
                }

                let httpResp = response as? HTTPURLResponse
                let statusCode = httpResp?.statusCode ?? 0
                richUILog.debug("fetchAndShare: response status=\(statusCode) bytes=\(data?.count ?? 0)")

                guard let data, !data.isEmpty else {
                    richUILog.error("fetchAndShare: no data received (status=\(statusCode))")
                    return
                }

                // ── Determine the correct file extension ────────────────────────
                // Priority: (1) URL path has extension, (2) Content-Type header,
                // (3) JS-passed mimeType hint, (4) keep filename as-is.
                // This is fully generic — no hardcoded format names.
                let finalFilename = Self.resolveFilename(
                    suggestedName: filename,
                    responseContentType: httpResp?.value(forHTTPHeaderField: "Content-Type"),
                    hintMimeType: hintMimeType
                )

                // Write to temp file then present share sheet
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(finalFilename)
                do {
                    try data.write(to: dest, options: .atomic)
                    richUILog.debug("fetchAndShare: wrote \(data.count) bytes to \(dest.path)")
                    DispatchQueue.main.async { self.presentShareSheet(for: dest) }
                } catch {
                    richUILog.error("fetchAndShare: write failed — \(error.localizedDescription)")
                }
            }.resume()
        }

        /// Resolves the best filename for a downloaded file.
        ///
        /// Strategy (in order of priority):
        /// 1. If `suggestedName` already has a file extension → use it unchanged.
        /// 2. Derive extension from `responseContentType` (HTTP `Content-Type` header).
        /// 3. Derive extension from `hintMimeType` (JS Blob.type from the webview).
        /// 4. Fallback: keep `suggestedName` as-is (no extension appended).
        ///
        /// Uses `UTType` (UniformTypeIdentifiers) for MIME→extension mapping so
        /// it works correctly for any media type (audio, video, image, document…)
        /// without hardcoding format names.
        private static func resolveFilename(
            suggestedName: String,
            responseContentType: String?,
            hintMimeType: String
        ) -> String {
            // Strip query parameters and fragments from the name
            let baseName = suggestedName
                .components(separatedBy: "?").first?
                .components(separatedBy: "#").first ?? suggestedName

            // If the name already has a meaningful extension, keep it.
            let existingExt = (baseName as NSString).pathExtension
            if !existingExt.isEmpty && existingExt.count <= 5 {
                richUILog.debug("resolveFilename: using existing extension '\(existingExt)' from '\(baseName)'")
                return baseName
            }

            // Try to derive extension from MIME type.
            // Use Content-Type header first, fall back to JS hint.
            let mimeToTry: [String] = [
                // Content-Type may be "audio/mpeg; charset=utf-8" — strip params
                (responseContentType ?? "").components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? "",
                hintMimeType.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
            ]

            for mime in mimeToTry where !mime.isEmpty && mime != "application/octet-stream" {
                if let utType = UTType(mimeType: mime),
                   let ext = utType.preferredFilenameExtension,
                   !ext.isEmpty {
                    let resolved = baseName.isEmpty ? "download.\(ext)" : "\(baseName).\(ext)"
                    richUILog.debug("resolveFilename: derived extension '\(ext)' from MIME '\(mime)' → '\(resolved)'")
                    return resolved
                }
            }

            // Last resort: no extension available — keep baseName (or fallback)
            let fallback = baseName.isEmpty ? "download" : baseName
            richUILog.debug("resolveFilename: no extension derived, using '\(fallback)'")
            return fallback
        }

        // MARK: - Share Sheet

        private func presentShareSheet(for fileURL: URL) {
            richUILog.debug("presentShareSheet: \(fileURL.lastPathComponent)")
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                  let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                richUILog.error("presentShareSheet: no key window / rootViewController found")
                return
            }

            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }

            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView  = topVC.view
                popover.sourceRect  = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            topVC.present(activityVC, animated: true) {
                richUILog.debug("presentShareSheet: share sheet presented")
            }
        }
    }
}

// MARK: - Tool Call Result Block View

/// Renders the OUTPUT section as plain scrollable text with lightweight JSON
/// pretty-printing and character-based truncation to prevent UI freezes on
/// large results (e.g. web search returning full HTML pages).
private struct ToolCallResultBlockView: View {
    let content: String

    /// Characters shown before the "Show full output" button appears.
    private static let truncationThreshold = 2_000

    @State private var showFull: Bool = false
    @Environment(\.theme) private var theme

    /// Lightweight JSON pretty-print — no syntax highlighting, no AttributedString.
    /// Falls back to the raw string if content is not valid JSON.
    private var formattedContent: String {
        // Try direct JSON parse
        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
           let pretty = String(data: prettyData, encoding: .utf8) {
            return pretty
        }
        // Try unwrapping a double-encoded JSON string (e.g. "\"{ ... }\"")
        let stripped = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("\"") && stripped.hasSuffix("\"") {
            let inner = String(stripped.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
            if let data = inner.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
               let pretty = String(data: prettyData, encoding: .utf8) {
                return pretty
            }
            return inner
        }
        return content
    }

    private var isTruncated: Bool {
        !showFull && formattedContent.count > Self.truncationThreshold
    }

    private var displayContent: String {
        guard isTruncated else { return formattedContent }
        return String(formattedContent.prefix(Self.truncationThreshold))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                // LazyVStack renders one Text per line so SwiftUI only lays out
                // the lines currently visible — prevents the main-thread stall
                // that occurs when the entire large string is measured at once.
                LazyVStack(alignment: .leading, spacing: 0) {
                    let lines = displayContent.components(separatedBy: "\n")
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .scaledFont(size: 12, design: .monospaced)
                            .foregroundStyle(theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 320)

            // Show full / collapse toggle
            if formattedContent.count > Self.truncationThreshold {
                Divider()
                    .overlay(theme.cardBorder.opacity(0.2))
                Button {
                    showFull.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showFull ? "chevron.up" : "chevron.down")
                            .scaledFont(size: 10, weight: .semibold)
                        Text(showFull
                             ? "Collapse"
                             : "Show full output (\(formattedContent.count.formatted()) chars)")
                            .scaledFont(size: 11, weight: .medium)
                    }
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(theme.surfaceContainer.opacity(theme.isDark ? 0.4 : 0.2))
            }
        }
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.35 : 0.25))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.35), lineWidth: 0.5)
        )
    }
}

// MARK: - Tool Call Arguments View

/// Renders the INPUT section as clean key-value rows (web UI style).
private struct ToolCallArgumentsView: View {
    let arguments: String
    @Environment(\.theme) private var theme

    /// Parsed key-value pairs. Falls back to raw display if not a JSON object.
    private var kvPairs: [(key: String, value: String)]? {
        guard let data = arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return dict.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: formatValue($0.value)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pairs = kvPairs {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 12) {
                        Text(pair.key)
                            .scaledFont(size: 12, design: .monospaced)
                            .foregroundStyle(theme.textTertiary)
                            .frame(minWidth: 70, alignment: .leading)
                            .lineLimit(1)

                        Text(pair.value)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)

                    if pair.key != pairs.last?.key {
                        Divider()
                            .padding(.leading, 12)
                            .overlay(theme.cardBorder.opacity(0.2))
                    }
                }
            } else {
                // Fallback: raw text
                Text(arguments)
                    .scaledFont(size: 12, design: .monospaced)
                    .foregroundStyle(theme.textSecondary)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.35 : 0.25))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.35), lineWidth: 0.5)
        )
    }

    private func formatValue(_ value: Any) -> String {
        switch value {
        case let str as String: return str
        case let num as NSNumber:
            // Bool check (NSNumber wraps booleans in Swift)
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        case is NSNull: return "null"
        case let arr as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "\(arr)"
        case let dict as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "\(dict)"
        default:
            return "\(value)"
        }
    }
}

// MARK: - Tool Call View

/// Displays a single tool call styled like the Open WebUI web interface:
/// - Header: checkmark/spinner + tool name + chevron (tappable to expand)
/// - When expanded: INPUT (key-value pairs) + OUTPUT (syntax-highlighted scrollable JSON)
/// - Rich UI HTML embeds always shown inline when present
struct ToolCallView: View {
    let toolCall: ToolCallData
    var authToken: String? = nil
    var serverBaseURL: String? = nil

    @State private var isExpanded: Bool = false
    @Environment(\.theme) private var theme

    /// Whether this tool call has rich HTML embeds to display.
    private var hasEmbeds: Bool { !toolCall.embeds.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header (tappable to expand/collapse) ─────────────────────
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    // Status indicator
                    if toolCall.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.success)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(theme.brandPrimary)
                    }

                    // "View Result from tool_name" — matches Open WebUI web UI pattern
                    (Text("View Result from ")
                        .foregroundStyle(theme.textTertiary)
                     + Text(toolCall.name)
                        .foregroundStyle(theme.textPrimary)
                        .fontWeight(.semibold))
                        .scaledFont(size: 13, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── Body ─────────────────────────────────────────────────────
            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // Arguments (INPUT)
                    if let args = toolCall.arguments, !args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("INPUT")
                                .scaledFont(size: 10, weight: .semibold)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 2)
                            ToolCallArgumentsView(arguments: args)
                        }
                    }

                    // Result (OUTPUT)
                    if let result = toolCall.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OUTPUT")
                                .scaledFont(size: 10, weight: .semibold)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 2)
                            ToolCallResultBlockView(content: result)
                        }
                    }

                    // Rich UI embeds — always visible when expanded
                    if hasEmbeds && toolCall.isDone {
                        ForEach(Array(toolCall.embeds.enumerated()), id: \.offset) { _, embedHTML in
                            RichUIEmbedView(
                                html: embedHTML,
                                toolArgs: toolCall.arguments,
                                authToken: authToken,
                                serverBaseURL: serverBaseURL
                            )
                        }
                    }
                }
                .padding(.bottom, Spacing.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if hasEmbeds && toolCall.isDone {
                // Rich UI embeds always visible even when collapsed
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(Array(toolCall.embeds.enumerated()), id: \.offset) { _, embedHTML in
                        RichUIEmbedView(
                            html: embedHTML,
                            toolArgs: toolCall.arguments,
                            authToken: authToken,
                            serverBaseURL: serverBaseURL
                        )
                    }
                }
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.sm)
            }
        }
    }
}

// MARK: - Collapsed Tool Call Group

/// Renders a group of consecutive tool calls from the same MCP server as a
/// collapsible summary row — "Explored N server-name ˅" — matching the Open
/// WebUI web UI. Tapping the header expands to reveal individual ToolCallViews.
private struct CollapsedToolCallGroup: View {
    let calls: [ToolCallData]
    var authToken: String? = nil
    var serverBaseURL: String? = nil

    @State private var isExpanded: Bool = false
    @Environment(\.theme) private var theme

    private var allDone: Bool { calls.allSatisfy(\.isDone) }

    /// The group label: a comma-separated list of unique tool names (with
    /// underscores replaced by spaces), preserving order of first appearance.
    /// E.g. "web_search, web_search, fetch_page" → "web_search, fetch_page"
    private var groupLabel: String {
        var seen = Set<String>()
        var unique: [String] = []
        for call in calls {
            if seen.insert(call.name).inserted {
                unique.append(call.name)
            }
        }
        return unique.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary header (tappable to expand/collapse)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if allDone {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.success)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(theme.brandPrimary)
                    }

                    (Text("Explored ")
                        .foregroundStyle(theme.textTertiary)
                     + Text("\(calls.count) ")
                        .foregroundStyle(theme.textPrimary)
                        .fontWeight(.semibold)
                     + Text(groupLabel)
                        .foregroundStyle(theme.textPrimary)
                        .fontWeight(.semibold))
                        .scaledFont(size: 13, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded: individual tool calls
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(calls.enumerated()), id: \.offset) { index, call in
                        if index > 0 {
                            Divider()
                                .overlay(Color.primary.opacity(0.07))
                        }
                        ToolCallView(
                            toolCall: call,
                            authToken: authToken,
                            serverBaseURL: serverBaseURL
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Tool Calls Container

/// Renders a list of tool calls extracted from message content.
/// Consecutive calls sharing the same MCP server prefix (the part before `__`)
/// are collapsed into a single expandable summary row, matching the Open WebUI
/// web UI. Plain tool names with no prefix are grouped by exact name.
struct ToolCallsContainer: View {
    let toolCalls: [ToolCallData]
    var authToken: String? = nil
    var serverBaseURL: String? = nil

    /// Returns the server prefix for a tool name.
    /// MCP tool names use `serverName__toolFunction` — we extract `serverName`.
    /// Plain tool names (no `__`) return the full name unchanged.
    static func serverPrefix(for name: String) -> String {
        guard let separatorRange = name.range(of: "__") else { return name }
        return String(name[name.startIndex..<separatorRange.lowerBound])
    }

    /// Groups all consecutive tool calls into a single group.
    /// All tool calls in a single `ToolCallsContainer` are already consecutive
    /// (they come from the same position in the message content), so we treat
    /// them all as one group — matching the Open WebUI web UI behavior where
    /// any mix of consecutive tools (e.g. web_search + fetch_page) collapses
    /// into a single "Explored N tool_a, tool_b" row.
    private static func subGroupByName(_ calls: [ToolCallData]) -> [[ToolCallData]] {
        guard !calls.isEmpty else { return [] }
        return [calls]
    }

    var body: some View {
        if !toolCalls.isEmpty {
            let subGroups = Self.subGroupByName(toolCalls)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(subGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Divider()
                            .overlay(Color.primary.opacity(0.07))
                            .padding(.horizontal, 12)
                    }

                    if group.count == 1 {
                        // Single call — render flat as before
                        ToolCallView(
                            toolCall: group[0],
                            authToken: authToken,
                            serverBaseURL: serverBaseURL
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    } else {
                        // Multiple same-name calls — collapsible group
                        CollapsedToolCallGroup(calls: group, authToken: authToken, serverBaseURL: serverBaseURL)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
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
        // Expanded while thinking is in progress, collapsed once done.
        // ReasoningData.id is a stable hash so SwiftUI reuses this view across
        // streaming ticks — @State persists, so user taps are preserved mid-stream.
        // Auto-collapse when isDone flips is handled by .onChange below.
        let autoExpand = UserDefaults.standard.object(forKey: "expandThinkingWhileStreaming") as? Bool ?? true
        self._isExpanded = State(initialValue: !reasoning.isDone && autoExpand)
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
                        .scaledFont(size: 9, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 12)

                    Image(systemName: "brain.head.profile")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.brandPrimary.opacity(0.7))

                    Text(reasoning.summary)
                        .scaledFont(size: 12, weight: .medium)
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
                    .scaledFont(size: 12, weight: .regular)
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
        .onChange(of: reasoning.isDone) { _, done in
            guard done else { return }
            let autoExpand = UserDefaults.standard.object(forKey: "expandThinkingWhileStreaming") as? Bool ?? true
            guard autoExpand else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded = false
            }
        }
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
///
/// ## Message-level embeds
/// OpenWebUI may store Rich UI HTML in the message object's `embeds` array
/// rather than inside the tool call `<details>` block (the `embeds=""` attribute
/// is empty in those cases). When `messageEmbeds` is non-empty, the embeds are
/// injected into the last tool call that has empty embeds — matching web UI
/// behavior where the player appears inline with the tool call that produced it.
/// If there are no tool calls, embeds are rendered as standalone blocks after
/// the text content.
struct AssistantMessageContent: View {
    let content: String
    let isStreaming: Bool
    var messageEmbeds: [String] = []
    /// Passed down to Rich UI embeds for auth token injection and base URL resolution.
    var authToken: String? = nil
    var serverBaseURL: String? = nil
    /// APIClient for rendering inline images via AuthenticatedImageView.
    var apiClient: APIClient? = nil

    @State private var parseCache = ParseCache()

    /// Reference-type cache for ToolCallParser results. Mutating a class
    /// property during body evaluation is safe because SwiftUI only tracks
    /// `@State`/`@Observable` value changes, not internal class mutations.
    private final class ParseCache {
        var lastLength: Int = -1
        var lastResult: ToolCallParser.OrderedParseResult?
    }

    var body: some View {
        // Cache key uses content hash so any change — including attribute
        // value changes like done="false" → done="true" that leave the byte
        // count identical — triggers a fresh parse. Previously using
        // content.utf8.count caused stale isDone=false results to be returned
        // after streaming completed, keeping the spinner running indefinitely
        // and blocking embed rendering (which is guarded by isDone == true).
        let cacheKey = content.hashValue
        let ordered: ToolCallParser.OrderedParseResult = {
            if cacheKey == parseCache.lastLength, let cached = parseCache.lastResult {
                return cached
            }
            let result = ToolCallParser.parseOrdered(content)
            parseCache.lastLength = cacheKey
            parseCache.lastResult = result
            // Log segment count and VIZ presence once per parse
            let hasViz = content.contains("@@@VIZ-START")
            if hasViz {
                let segTypes = result.segments.map { seg -> String in
                    switch seg {
                    case .text(let s): return "text(\(s.count))"
                    case .toolCall(let tc): return "toolCall(\(tc.name))"
                    case .reasoning: return "reasoning"
                    }
                }.joined(separator: ", ")
                vizLog.debug("AssistantMessageContent VIZ segments: \(segTypes)")
            }
            return result
        }()

        let groups: [SegmentGroup] = {
            let rawBase = Self.groupSegments(ordered.segments)

            // Phase 5: When @@@VIZ-START markers are present, suppress the entire
            // `render_visualization` tool call row. The native InlineVisualizerView
            // already renders the visualization — the tool call header and its giant
            // result/embed payload are redundant and cause lag as the large HTML blob
            // is parsed and laid out on every streaming tick.
            let hasVizMarkers = content.contains("@@@VIZ-START")
            let base: [SegmentGroup] = hasVizMarkers ? rawBase.compactMap { group in
                if case .toolCalls(let calls) = group {
                    let filtered = calls.filter { $0.name != "render_visualization" }
                    return filtered.isEmpty ? nil : .toolCalls(filtered)
                }
                return group
            } : rawBase

            // Phase 4: Always suppress data-iv-build embeds on iOS.
            // The inline-visualizer plugin's HTMLResponse embed uses a JS DOM observer
            // that calls parent.document — which is sandboxed/impossible in WKWebView.
            // Suppressing unconditionally (not gated on @@@VIZ-START being present yet)
            // eliminates the race-condition flash where the broken embed briefly appears
            // before the VIZ markers arrive in displayContent.
            // The native InlineVisualizerView handles all visualization rendering instead.
            let filteredEmbeds: [String] = messageEmbeds.filter { !$0.contains("data-iv-build") }
            guard !filteredEmbeds.isEmpty else { return base }
            let messageEmbeds = filteredEmbeds
            vizLog.debug("AssistantMessageContent embed inject: filteredEmbeds=\(filteredEmbeds.count), rawMessageEmbeds=\(self.messageEmbeds.count)")

            // Search from the end for the last toolCalls group
            var mutableGroups = base
            for i in stride(from: mutableGroups.count - 1, through: 0, by: -1) {
                if case .toolCalls(var calls) = mutableGroups[i] {
                    // Find the last call in this group that has no embeds
                    for j in stride(from: calls.count - 1, through: 0, by: -1) {
                        if calls[j].embeds.isEmpty {
                            let tc = calls[j]
                            calls[j] = ToolCallData(
                                id: tc.id,
                                name: tc.name,
                                arguments: tc.arguments,
                                result: tc.result,
                                isDone: tc.isDone,
                                embeds: messageEmbeds
                            )
                            mutableGroups[i] = .toolCalls(calls)
                            return mutableGroups
                        }
                    }
                }
            }
            // No tool call with empty embeds found — append a sentinel group
            // so the embeds are still rendered (handled below as .standaloneEmbeds).
            return mutableGroups + [.standaloneEmbeds(messageEmbeds)]
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
                let lastTextIndex = groups.lastIndex(where: {
                    if case .text = $0 { return true }
                    return false
                })

                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    switch group {
                    case .text(let str):
                        // Only the last text segment gets the streaming cursor
                        let isLastText = index == lastTextIndex && isStreaming
                        // The inline-visualizer plugin emits an iframe/JS block for the web UI
                        // between the </details> close and the @@@VIZ-START marker. On iOS this
                        // block has no purpose — InlineVisualizerView renders from the VIZ markers.
                        // Strip anything before @@@VIZ-START so it never reaches MarkdownView.
                        let effectiveStr: String = {
                            guard str.contains("@@@VIZ-START"),
                                  let r = str.range(of: "@@@VIZ-START") else { return str }
                            return String(str[r.lowerBound...])
                        }()
                        // Extract inline images from markdown ![alt](url) syntax.
                        // MarkdownView renders images as plain text links — we need
                        // to intercept server file URLs and render them as actual images.
                        let imageSegments = Self.splitInlineImages(effectiveStr)
                        if !effectiveStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if imageSegments.count <= 1 {
                            // No inline images — render normally
                            MarkdownWithLoading(
                                content: effectiveStr,
                                isLoading: isLastText
                            )
                        } else {
                            // Interleave text and images
                            ForEach(Array(imageSegments.enumerated()), id: \.offset) { segIdx, seg in
                                switch seg {
                                case .text(let text):
                                    let isLast = isLastText && segIdx == imageSegments.count - 1
                                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        MarkdownWithLoading(
                                            content: text,
                                            isLoading: isLast
                                        )
                                    }
                                case .image(let fileId, _):
                                    if let apiClient {
                                        AuthenticatedImageView(fileId: fileId, apiClient: apiClient)
                                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                                    }
                                }
                            }
                        }
                        } // end if !effectiveStr.isEmpty

                    case .toolCalls(let calls):
                        ToolCallsContainer(
                            toolCalls: calls,
                            authToken: authToken,
                            serverBaseURL: serverBaseURL
                        )

                    case .reasoningBlocks(let blocks):
                        ReasoningContainer(blocks: blocks)

                    case .standaloneEmbeds(let embeds):
                        // Standalone embeds: no tool call to attach to.
                        // Render the Rich UI webviews directly.
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            ForEach(Array(embeds.enumerated()), id: \.offset) { _, embedHTML in
                                RichUIEmbedView(
                                    html: embedHTML,
                                    toolArgs: nil,
                                    authToken: authToken,
                                    serverBaseURL: serverBaseURL
                                )
                            }
                        }
                        .padding(.top, Spacing.xs)
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
        /// Message-level embeds with no associated tool call to attach to.
        case standaloneEmbeds([String])
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

    // MARK: - Inline Image Extraction

    /// Segments produced by splitting markdown content at `![alt](url)` boundaries.
    enum InlineImageSegment {
        case text(String)
        /// An inline image with the extracted file ID and alt text.
        case image(fileId: String, altText: String)
    }

    /// Splits markdown text at `![alt](url)` patterns where the URL points to
    /// a server file (`/api/v1/files/{id}/content`). The URL can be relative
    /// (`/api/v1/files/...`) or absolute (`https://host/api/v1/files/...`).
    ///
    /// Returns a single `.text` segment if no server images are found, so the
    /// caller can short-circuit and render normally.
    static func splitInlineImages(_ text: String) -> [InlineImageSegment] {
        // Match ![alt text](url) where url contains /api/v1/files/{uuid}/content
        // The URL may be relative (/api/...) or absolute (https://host/api/...)
        let pattern = #"!\[([^\]]*)\]\(((?:https?://[^\s\)]+)?/api/v1/files/([a-f0-9\-]{36})/content)\)"#
        guard let regex = ToolCallParser.cachedRegex(pattern, options: []) else {
            return [.text(text)]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [.text(text)] }

        var segments: [InlineImageSegment] = []
        var currentIndex = 0

        for match in matches {
            // Text before this image
            if match.range.location > currentIndex {
                let beforeRange = NSRange(location: currentIndex, length: match.range.location - currentIndex)
                let before = nsText.substring(with: beforeRange)
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(before))
                }
            }

            // Extract the file ID (capture group 3)
            if match.numberOfRanges > 3 {
                let altText = nsText.substring(with: match.range(at: 1))
                let fileId = nsText.substring(with: match.range(at: 3))
                segments.append(.image(fileId: fileId, altText: altText))
            }

            currentIndex = match.range.location + match.range.length
        }

        // Remaining text after last image
        if currentIndex < nsText.length {
            let remaining = nsText.substring(from: currentIndex)
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(remaining))
            }
        }

        return segments.isEmpty ? [.text(text)] : segments
    }
}
