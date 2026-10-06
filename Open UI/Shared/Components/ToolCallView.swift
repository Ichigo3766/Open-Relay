import SwiftUI
import WebKit
import os.log
import UniformTypeIdentifiers
import MarkdownView

// MARK: - Global Off-Main Parse Cache

/// Process-lifetime, content-keyed cache for `ToolCallParser.parseOrdered` results.
///
/// ## Why global instead of per-instance @State
/// Each `AssistantMessageContent` view instance carries its own `@State parseCache`
/// which is destroyed when the sliding window recycles the row. Re-visiting a
/// scrolled-away row forces a full re-parse on the main thread (the hot path for
/// 80k-token chats). This actor replaces that per-instance cache with a single
/// process-wide store keyed by a content hash, so the parse result is available
/// instantly even after the row has been recycled and re-mounted.
///
/// ## Thread safety
/// All writes and reads happen on a dedicated background executor (actor isolation).
/// `AssistantMessageContent.body` reads the cache synchronously via a nonisolated
/// helper that checks an `NSCache` (itself thread-safe), then fires an async Task on
/// a background priority queue for cache misses.
///
/// ## Memory
/// Advisory entry and byte-cost limits reduce retention of long streaming
/// snapshots. `NSCache` may also evict entries under memory pressure.
actor MessageParseCache {
    static let shared = MessageParseCache()

    /// Lightweight value cached per content string.
    struct Entry {
        let result: ToolCallParser.OrderedParseResult
        /// utf8 byte count of the content that produced this entry — used
        /// as a fast pre-check before an O(N) equality test.
        let byteCount: Int
        /// The exact content string so we can detect hash collisions.
        let content: String
    }

    // NSCache is thread-safe and auto-evicts under memory pressure.
    // We wrap it in the actor so all mutations go through the actor's executor,
    // but the *read* path below (via `lookup`) is also actor-isolated.
    // `nonisolated(unsafe)` lets the synchronous `lookupSync` helper read
    // this property without hopping to the actor executor — safe because
    // NSCache's own locking guarantees atomicity for object reads/writes.
    nonisolated(unsafe) private let cache = NSCache<NSString, NSObject>()

    init() {
        // Allow ~200 entries (typical chat has far fewer assistant messages).
        cache.countLimit = 200
        // Long streaming snapshots also need a byte budget, not just an entry count.
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    // MARK: - Actor-isolated interface

    /// Returns a cached entry for `content` if present, otherwise `nil`.
    func lookup(content: String) -> ToolCallParser.OrderedParseResult? {
        let key = cacheKey(content)
        guard let obj = cache.object(forKey: key as NSString) as? EntryBox else { return nil }
        // Guard against hash collisions: verify exact content match.
        guard obj.entry.content == content else { return nil }
        return obj.entry.result
    }

    // MARK: - Nonisolated synchronous read (for SwiftUI body)

    /// Synchronous, non-actor-isolated cache lookup for use inside SwiftUI `body`.
    ///
    /// `NSCache` is internally thread-safe, so we can read it from any context
    /// without hopping to the actor's executor. This avoids the `await` that
    /// would be required for an actor-isolated call, which cannot be used in a
    /// synchronous `body` function.
    ///
    /// The trade-off: we bypass actor isolation for the *read* path only.
    /// Writes still go through `parseAndStore` (actor-isolated) which serialises
    /// all mutations. A concurrent read of a partially-written entry is impossible
    /// because `NSCache.setObject` is atomic and `EntryBox` is immutable after
    /// construction — once visible, it is fully formed.
    nonisolated func lookupSync(_ content: String) -> ToolCallParser.OrderedParseResult? {
        let key = cacheKey(content)
        guard let obj = cache.object(forKey: key as NSString) as? EntryBox else { return nil }
        guard obj.entry.content == content else { return nil }
        return obj.entry.result
    }

    /// Parses `content` (off the main thread, inside the actor) and stores the result.
    /// Returns the result so callers can chain without a second lookup.
    @discardableResult
    func parseAndStore(content: String) -> ToolCallParser.OrderedParseResult {
        // Check again — another Task may have already done this.
        let key = cacheKey(content)
        if let existing = cache.object(forKey: key as NSString) as? EntryBox,
           existing.entry.content == content {
            return existing.entry.result
        }
        let result = ToolCallParser.parseOrdered(content)
        let entry = Entry(result: result, byteCount: content.utf8.count, content: content)
        cache.setObject(EntryBox(entry), forKey: key as NSString, cost: entry.byteCount * 2)
        return result
    }

    /// Warms the cache for all provided content strings concurrently.
    /// Safe to call from background tasks — actor isolation handles serialisation.
    func warmBatch(_ contents: [String]) async {
        for (i, content) in contents.enumerated() {
            // Skip already-cached entries to avoid re-work.
            let key = cacheKey(content)
            if let existing = cache.object(forKey: key as NSString) as? EntryBox,
               existing.entry.content == content {
                continue
            }
            let result = ToolCallParser.parseOrdered(content)
            let entry = Entry(result: result, byteCount: content.utf8.count, content: content)
            cache.setObject(EntryBox(entry), forKey: key as NSString, cost: entry.byteCount * 2)
            // Yield to the cooperative thread pool every 4 items so the actor
            // doesn't monopolise a thread and starve the main-thread render loop.
            if i % 4 == 3 { await Task.yield() }
        }
    }

    // MARK: - Helpers

    /// Hash the full content so equal-length messages with a common prefix can
    /// coexist. Lookups still verify the exact content against hash collisions.
    nonisolated private func cacheKey(_ content: String) -> String {
        String(content.hashValue)
    }

    /// NSCache requires AnyObject values.
    private final class EntryBox: NSObject {
        let entry: Entry
        init(_ entry: Entry) { self.entry = entry }
    }
}

// MARK: - Tool Call Data

/// Represents a parsed tool call extracted from `<details>` HTML blocks
/// in assistant message content.
struct ToolCallData: Identifiable {
    let id: String
    let name: String
    let arguments: String?
    let result: String?
    let isDone: Bool
    /// The raw `status` attribute from the output item, e.g. `"pending"`, `"completed"`,
    /// `"rejected"`, `"failed"`. `nil` for older content that has no status attribute.
    let status: String?
    /// Rich UI HTML embeds returned by the tool. Each string is a full HTML
    /// document to be rendered inline in the chat as an interactive webview.
    let embeds: [String]
    var terminalFile: TerminalFileAttachment? = nil

    /// A display-friendly name (replaces underscores with spaces).
    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    /// True when this is an `ask_user` call awaiting the user's answers.
    var needsUserInput: Bool {
        name == "ask_user" && status == "pending"
    }

    /// Whether this tool call resulted in an error.
    ///
    /// OpenWebUI marks failed tool calls by embedding an error indicator in the result.
    /// Checks for common patterns: top-level `"error"` JSON key, `Error:` prefix,
    /// `"status": "error"`, or an explicit `"success": false` field.
    var isError: Bool {
        guard isDone, let result, !result.isEmpty else { return false }
        // Fast string checks before attempting JSON parse
        let lower = result.lowercased()
        // JSON error key: {"error": ...} or {"error":...}
        if lower.contains("\"error\"") { return true }
        // Explicit error prefix from Python exceptions
        if result.hasPrefix("Error:") || result.hasPrefix("error:") { return true }
        // Status field
        if lower.contains("\"status\": \"error\"") || lower.contains("\"status\":\"error\"") { return true }
        // Explicit failure flag
        if lower.contains("\"success\": false") || lower.contains("\"success\":false") { return true }
        return false
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
    // Count once per parsed snapshot; reveal can then trim from the short tail.
    let characterCount: Int
    let duration: String?
    let isDone: Bool

    nonisolated init(summary: String, content: String, duration: String?, isDone: Bool) {
        // Use the first 80 characters as a stable anchor — the beginning of
        // a reasoning block is fixed once streaming starts (only the tail grows).
        let prefix = String(content.prefix(80))
        self.id = "reason-\(prefix.hashValue)"
        self.summary = summary
        self.content = content
        self.characterCount = content.count
        self.duration = duration
        self.isDone = isDone
    }
}

// MARK: - Details Data

/// A generic collapsible `<details>` section — anything that isn't a tool call
/// or a reasoning block: filter/outlet output (e.g. LLMTrace), model-written
/// `<details>` sections, and `type="code_interpreter"` blocks.
struct DetailsData: Identifiable {
    let id: String
    /// Header title (may contain inline markdown such as `**bold**`).
    let summary: String
    /// Raw body markdown; rendered recursively so nested details work.
    let body: String
    /// Lowercased `type` attribute (`nil` for plain `<details>`).
    let type: String?
    let isDone: Bool
    /// `<details open>` — start expanded.
    let startsOpen: Bool

    nonisolated init(summary: String, body: String, type: String?, isDone: Bool, startsOpen: Bool, ordinal: Int) {
        // Summary + ordinal are fixed once the block starts streaming, so the
        // view keeps its expanded state while the body grows.
        self.id = "details-\(ordinal)-\(summary.hashValue)"
        self.summary = summary
        self.body = body
        self.type = type
        self.isDone = isDone
        self.startsOpen = startsOpen
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
    case details(DetailsData)

    var id: String {
        switch self {
        case .text(let str): return "text-\(str.hashValue)"
        case .toolCall(let tc): return "tool-\(tc.id)"
        case .reasoning(let r): return "reason-\(r.id)"
        case .details(let d): return d.id
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
    nonisolated static func cachedRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
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

    /// Quickly reject absent tags via a cached literal regex (avoids scanning every Character
    /// in a long response), but preserve Swift's grapheme-boundary behavior when
    /// the regex finds a possible match (e.g. combining marks).
    private nonisolated static func containsTag(_ tag: String, in text: String,
                                               options: String.CompareOptions = .caseInsensitive) -> Bool {
        guard let regex = cachedRegex(NSRegularExpression.escapedPattern(for: tag),
                                      options: options.contains(.caseInsensitive) ? .caseInsensitive : []),
              regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
        return text.range(of: tag, options: options) != nil
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
            case .details: break   // hidden sections are not spoken/plain text
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
    nonisolated static func parseOrdered(_ content: String) -> OrderedParseResult {
        guard content.contains("<") || content.contains("◁") else {
            return OrderedParseResult(
                segments: [.text(content.trimmingCharacters(in: .whitespacesAndNewlines))],
                allToolCalls: []
            )
        }
        // Pre-process: convert raw <think>…</think> tags (sent by models
        // like Qwen, DeepSeek, etc.) into <details type="reasoning"> blocks
        // so the state-machine tokenizer picks them up and renders them as
        // collapsible ReasoningView instead of raw visible text.
        let content = preprocessThinkTags(content)

        // Tokenize with the shared DetailsBlockScanner — the same rules the
        // streaming pipeline and every strip path use. It is quote-aware
        // (`>` / `\"` inside attribute values never end a tag), nesting-aware,
        // code-aware for plain blocks, and recognises EVERY `<details>`:
        // tool calls, reasoning, code interpreter and plain sections
        // (filter/outlet output such as LLMTrace, model-written sections).
        guard DetailsBlockScanner.mayContainDetails(content) else {
            return OrderedParseResult(segments: [.text(content)], allToolCalls: [])
        }

        var segments: [ContentSegment] = []
        var allToolCalls: [ToolCallData] = []
        var detailsOrdinal = 0

        func appendText(_ raw: String) {
            let text = DetailsBlockScanner.trimmed(
                raw.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            )
            if !text.isEmpty { segments.append(.text(text)) }
        }

        for piece in DetailsBlockScanner.scan(content) {
            switch piece {
            case .text(let text, _):
                appendText(text)
            case .partialTag:
                // An opening/closing tag still arriving — never show it raw.
                continue
            case .block(let block):
                switch block.type {
                case "tool_calls":
                    if let toolCall = parseToolCallBlock(block) {
                        segments.append(.toolCall(toolCall))
                        allToolCalls.append(toolCall)
                    }
                case "reasoning":
                    if let parsed = parseReasoningBlock(block) {
                        segments.append(.reasoning(parsed.data))
                        // Spillover: content that was inside the <details> block AFTER
                        // a raw closing tag (e.g. </thinking>) — this is the real model
                        // reply that was accidentally captured inside the reasoning block.
                        if let spillover = parsed.spillover, !spillover.isEmpty {
                            segments.append(.text(spillover))
                        }
                    }
                default:
                    segments.append(.details(parseGenericDetails(block, ordinal: detailsOrdinal)))
                    detailsOrdinal += 1
                }
            }
        }

        return OrderedParseResult(segments: segments, allToolCalls: allToolCalls)
    }

    /// Builds a generic collapsible section from any non tool/reasoning block.
    private nonisolated static func parseGenericDetails(_ block: DetailsBlockScanner.Block, ordinal: Int) -> DetailsData {
        let split = DetailsBlockScanner.splitSummary(block.body)
        let isDone: Bool = {
            if let done = block.attributes["done"]?.lowercased() { return done == "true" }
            return block.isClosed
        }()
        let summary: String = {
            if block.type == "code_interpreter" { return isDone ? "Analyzed" : "Analyzing..." }
            let title = DetailsBlockScanner.trimmed(decodeHTMLEntities(split.summary) ?? "")
            return title.isEmpty ? "Details" : title
        }()
        let body = DetailsBlockScanner.trimmed(decodeHTMLEntities(split.rest) ?? "")
        return DetailsData(
            summary: summary,
            body: body,
            type: block.type,
            isDone: isDone,
            startsOpen: block.attributes["open"] != nil,
            ordinal: ordinal
        )
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
    private nonisolated static func parseReasoningBlock(_ block: DetailsBlockScanner.Block) -> (data: ReasoningData, spillover: String?)? {
        let isDone = block.attributes["done"]?.lowercased() == "true"
        let duration = block.attributes["duration"]

        // Summary + body come from the shared scanner, so nested `<details>`
        // inside a thinking block no longer truncate it at the first
        // `</details>` (the old lazy regex stopped there).
        let split = DetailsBlockScanner.splitSummary(block.body)
        let summary: String = {
            let title = DetailsBlockScanner.trimmed(split.summary ?? "")
            if !title.isEmpty { return title }
            if let dur = duration { return "Thought for \(dur) seconds" }
            return isDone ? "Thought" : "Thinking..."
        }()

        let rawContentText = DetailsBlockScanner.trimmed(decodeHTMLEntities(split.rest) ?? "")

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

            guard containsTag(closeTag, in: contentText) else { continue }

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

        // An empty (or in-progress) thinking block keeps its header, matching
        // the web client, instead of silently disappearing.
        let data = ReasoningData(
            summary: summary,
            content: contentText,
            duration: duration,
            isDone: isDone
        )
        return (data, spillover)
    }

    /// Parses a single tool call `<details>` block into a `ToolCallData`.
    /// Attributes come from the scanner's quote-aware parser, so an attribute
    /// name appearing inside another value (e.g. `name=` inside `arguments`)
    /// can never be picked up by mistake.
    private nonisolated static func parseToolCallBlock(_ block: DetailsBlockScanner.Block) -> ToolCallData? {
        let attrs = block.attributes
        let name = attrs["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "tool"
        let id = attrs["id"].flatMap { $0.isEmpty ? nil : $0 } ?? "tool-\(name)-\(block.byteRange.lowerBound)"
        let isDone = attrs["done"]?.lowercased() == "true"
        let status = attrs["status"]
        let arguments = attrs["arguments"]
        // Try the result="" attribute first. If absent (OpenWebUI stores the output
        // as the body between </summary> and </details>), fall back to body content.
        let result: String? = {
            if let r = attrs["result"], !r.isEmpty { return r }
            let body = DetailsBlockScanner.trimmed(DetailsBlockScanner.splitSummary(block.body).rest)
            return body.isEmpty ? nil : body
        }()
        // Skip embed parsing for in-progress tool calls — embeds are only
        // rendered once isDone == true, so parsing the 30KB+ HTML-entity-encoded
        // iframe blob on every streaming frame is pure wasted CPU on the main thread.
        let embeds = isDone ? parseEmbedsAttribute(attrs["embeds"]) : []

        return ToolCallData(
            id: id,
            name: name,
            arguments: decodeHTMLEntities(arguments),
            result: decodeHTMLEntities(result),
            isDone: isDone,
            status: status,
            embeds: embeds,
            terminalFile: isDone && name == "display_file"
                ? TerminalFileAttachment(result: decodeHTMLEntities(result), arguments: decodeHTMLEntities(arguments)) : nil
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
    private nonisolated static func parseEmbedsAttribute(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }

        // Fast bail: the legacy Inline Visualizer plugin's embeds (data-iv-build)
        // need parent.document DOM access, impossible in a sandboxed WKWebView.
        // Skip the expensive ~30KB HTML entity decode + JSON parse for them.
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

        // Filter out data-iv-build embeds (legacy Inline Visualizer plugin
        // iframes that cannot run in a sandboxed WKWebView). Suppressed here and
        // in the message-level embeds path so they never reach RichUIEmbedView.
        return array.filter { !$0.isEmpty && !$0.contains("data-iv-build") }
    }

    // MARK: - Raw Reasoning Tag Preprocessing

    /// All tag pairs that OpenWebUI recognises by default for reasoning content.
    /// Order matters: more specific / longer tags first to avoid partial matches.
    private nonisolated static let defaultReasoningTagPairs: [(open: String, close: String)] = [
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
    private nonisolated static func preprocessThinkTags(_ content: String) -> String {
        var result = content

        // ── Phase 1: Convert raw model reasoning tags ──
        for pair in defaultReasoningTagPairs {
            guard containsTag(pair.open, in: result, options: []) else { continue }
            result = convertReasoningTag(pair, in: result)
        }
        // Keep the existing second-pass ordering for mixed-case nested input.
        for pair in defaultReasoningTagPairs {
            guard !pair.open.hasPrefix("<|"), !pair.open.hasPrefix("◁"),
                  containsTag(pair.open, in: result), !containsTag(pair.open, in: result, options: []) else { continue }
            result = convertReasoningTag(pair, in: result)
        }

        // Unclosed <details type="tool_calls" | "reasoning"> blocks (mid-stream)
        // need no patching here: DetailsBlockScanner reports them as unclosed
        // blocks that run to the end of the content, and the block parsers
        // treat a missing done="true" as in-progress.

        // ── Phase 2: Clean up orphaned closing tags ──
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
            guard containsTag(closeTag, in: result) else { continue }

            // If the matching open tag is also present, this is a complete pair
            // that Phase 1 should have handled — skip.
            if containsTag(pair.open, in: result) { continue }

            // Also skip if the closer is inside a <details> block (already converted)
            if result.contains("<details") {
                // Check if the close tag appears outside of any <details>...</details> block
                let stripped = DetailsBlockScanner.strip(result)
                guard containsTag(closeTag, in: stripped) else { continue }
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
            if containsTag(closer, in: result, options: []) {
                result = result.replacingOccurrences(of: closer, with: "")
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convert complete pairs, then any remaining unfinished opening tag.
    private nonisolated static func convertReasoningTag(_ pair: (open: String, close: String), in content: String) -> String {
        var result = content
        let escapedOpen = NSRegularExpression.escapedPattern(for: pair.open)
        let escapedClose = NSRegularExpression.escapedPattern(for: pair.close)
        if let regex = cachedRegex("\(escapedOpen)([\\s\\S]*?)\(escapedClose)",
                                   options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let source = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)).reversed()
                where match.numberOfRanges > 1 {
                let text = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = "<details type=\"reasoning\" done=\"true\"><summary>Thinking</summary>\(text)</details>"
                result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
        if containsTag(pair.open, in: result),
           let regex = cachedRegex("\(escapedOpen)([\\s\\S]*)$", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let source = result as NSString
            if let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: source.length)),
               match.numberOfRanges > 1 {
                let text = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = "<details type=\"reasoning\" done=\"false\"><summary>Thinking</summary>\(text)</details>"
                result = source.replacingCharacters(in: match.range, with: replacement)
            }
        }
        return result
    }

    /// Decodes common HTML entities in attribute values.
    private nonisolated static func decodeHTMLEntities(_ string: String?) -> String? {
        guard let string, string.utf8.contains(0x26) else { return string }
        return string
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
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
    /// Closure set by RichUIWebView once its coordinator is ready.
    /// Calling it triggers a WKWebView snapshot + share sheet.
    @State private var snapshotTrigger: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// Maximum height before the embed gets internal scroll.
    /// Tall embeds (weather dashboards, etc.) can scroll within this frame.
    private let maxHeight: CGFloat = 600

    var body: some View {
        RichUIWebView(
            html: instrumentedHTML,
            height: $webViewHeight,
            snapshotTrigger: $snapshotTrigger,
            authToken: authToken,
            serverBaseURL: serverBaseURL
        )
        .frame(height: min(max(webViewHeight, 1), maxHeight))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            // Share / save button — lets the user share the embed as an image
            // (useful for QR codes, charts, etc. that have no built-in download)
            if snapshotTrigger != nil {
                Button {
                    snapshotTrigger?()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
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
    /// When non-nil, calling this closure triggers a webview snapshot + share sheet.
    /// Set by makeUIView so the parent SwiftUI view can drive it via a @State closure.
    @Binding var snapshotTrigger: (() -> Void)?
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
        // Enable native scroll so 1-finger drag works inside the embed when its
        // content is taller than the capped frame height (maxHeight = 600pt).
        // When the content fits within the frame SwiftUI sizes the webview to its
        // exact content height, so there is nothing to scroll and the gesture falls
        // through naturally to the parent chat ScrollView — identical behaviour to
        // StreamingWebPreview (HTML code block previews) which uses the same pattern.
        //
        // cancelsTouchesInView = false is kept so any pan recognizer still in the
        // tree doesn't swallow horizontal drags (e.g. sliders inside embeds).
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.delaysContentTouches = false
        webView.scrollView.panGestureRecognizer.cancelsTouchesInView = false

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false

        context.coordinator.webView = webView

        richUILog.debug("makeUIView: loading HTML (\(html.count) bytes), baseURL=\(serverBaseURL ?? "nil")")
        webView.loadHTMLString(html, baseURL: resolvedBaseURL)

        // Expose the snapshot trigger to the parent SwiftUI view.
        // We set it after creating the coordinator so the closure captures
        // the coordinator (and its weak webView reference) correctly.
        DispatchQueue.main.async {
            self.snapshotTrigger = { [weak coord = context.coordinator] in
                coord?.takeSnapshot()
            }
        }

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

            ClientCertificateSession.shared.dataTask(with: request) { [weak self] data, response, error in
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

        // MARK: - Snapshot (native share button)

        /// Takes a WKWebView snapshot and presents the iOS share sheet with the resulting image.
        /// Called when the user taps the share button overlay on the embed.
        func takeSnapshot() {
            guard let webView else {
                richUILog.error("takeSnapshot: webView is nil")
                return
            }
            let config = WKSnapshotConfiguration()
            webView.takeSnapshot(with: config) { [weak self] image, error in
                guard let self else { return }
                if let error {
                    richUILog.error("takeSnapshot: failed — \(error.localizedDescription)")
                    return
                }
                guard let image else {
                    richUILog.error("takeSnapshot: image is nil")
                    return
                }
                richUILog.debug("takeSnapshot: success, size=\(image.size.width)x\(image.size.height)")
                DispatchQueue.main.async { self.presentShareSheet(for: image) }
            }
        }

        // MARK: - Share Sheet

        private func presentShareSheet(for image: UIImage) {
            richUILog.debug("presentShareSheet(image): size=\(image.size.width)x\(image.size.height)")
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                  let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                richUILog.error("presentShareSheet(image): no key window / rootViewController found")
                return
            }
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            topVC.present(activityVC, animated: true) {
                richUILog.debug("presentShareSheet(image): share sheet presented")
            }
        }

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

/// Renders the OUTPUT section as a plain monospaced text block.
/// JSON results are pretty-printed. Uses a simple ScrollView+Text instead of
/// MarkdownView to avoid async WKWebView zero-height collapse on first render.
private struct ToolCallResultBlockView: View {
    let content: String

    @Environment(\.theme) private var theme
    @State private var showFullPreview = false

    /// Pretty-prints the content if it is JSON, otherwise returns the raw string.
    /// Also handles double-encoded JSON strings (e.g. `"\"{ ... }\""` ).
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                Text(formattedContent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.35 : 0.25))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.35), lineWidth: 0.5)
            )

            // Eye / preview button
            Button {
                showFullPreview = true
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .padding(6)
                    .background(theme.surfaceContainer.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(6)
        }
        .sheet(isPresented: $showFullPreview) {
            ToolCallResultFullPreviewSheet(content: formattedContent)
        }
    }
}

// MARK: - Full-screen preview sheet for tool call output

private struct ToolCallResultFullPreviewSheet: View {
    let content: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationView {
            ScrollView {
                Text(content)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(theme.background)
            .navigationTitle("Output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.secondary)
                }
            }
        }
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
            // ── Header (tappable to expand/collapse, unless awaiting user input) ────
            if toolCall.needsUserInput {
                // ask_user pending — non-interactive pill: spinner + "Input needed"
                // The actual question card lives above the chat input (AskUserCard).
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(theme.brandPrimary)

                    Text("Input needed")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.vertical, 10)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        // Status indicator
                        if toolCall.isDone {
                            Image(systemName: toolCall.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .scaledFont(size: 14)
                                .foregroundStyle(toolCall.isError ? theme.error : theme.success)
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
            }

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
            }

            if !isExpanded && hasEmbeds && toolCall.isDone {
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

// MARK: - Mixed Tool Call Group (with interleaved reasoning)

/// Renders a mixed group of tool calls and interleaved reasoning blocks.
/// Collapsed header: "Explored N tool_a, tool_b ˅" (tools only in the count/label).
/// Expanded body: renders items in order — tool calls and reasoning blocks inline.
private struct MixedToolCallGroup: View {
    let items: [AssistantMessageContent.GroupedItem]
    var authToken: String? = nil
    var serverBaseURL: String? = nil
    var isStreaming = false

    @State private var isExpanded: Bool = false
    @Environment(\.theme) private var theme

    /// Only the .tool items — used for the count and label in the header.
    private var toolItems: [ToolCallData] {
        items.compactMap { if case .tool(let tc) = $0 { return tc }; return nil }
    }

    private var allDone: Bool {
        // Done when all tool calls are done (reasoning isDone is separate)
        toolItems.allSatisfy(\.isDone)
    }

    /// True when ANY tool item in the group is an ask_user awaiting input.
    private var hasNeedsInput: Bool {
        toolItems.contains { $0.needsUserInput }
    }

    /// Comma-separated unique tool names (order of first appearance).
    private var groupLabel: String {
        var seen = Set<String>()
        var unique: [String] = []
        for tc in toolItems {
            if seen.insert(tc.name).inserted { unique.append(tc.name) }
        }
        return unique.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed summary header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
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

                    if hasNeedsInput && !allDone {
                        // Show "Input needed" as the summary when ask_user is pending
                        Text("Input needed")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    } else {
                        (Text("Explored ")
                            .foregroundStyle(theme.textTertiary)
                         + Text("\(toolItems.count) ")
                            .foregroundStyle(theme.textPrimary)
                            .fontWeight(.semibold)
                         + Text(groupLabel)
                            .foregroundStyle(theme.textPrimary)
                            .fontWeight(.semibold))
                            .scaledFont(size: 13, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded: render items in order (tool calls + inline reasoning)
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        switch item {
                        case .tool(let tc):
                            if idx > 0 {
                                Divider().overlay(Color.primary.opacity(0.07))
                            }
                            ToolCallView(toolCall: tc, authToken: authToken, serverBaseURL: serverBaseURL)
                        case .reasoning(let r):
                            Divider().overlay(Color.primary.opacity(0.07))
                            ReasoningView(reasoning: r, isStreaming: isStreaming)
                                .padding(.vertical, Spacing.xs)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Tool Calls Container

/// Renders a mixed list of tool calls (and optionally interleaved reasoning blocks)
/// extracted from message content.  All items in one container come from the
/// same consecutive run in the message — they are collapsed into a single
/// "Explored N" row matching the Open WebUI web UI behaviour.
struct ToolCallsContainer: View {
    /// Mixed items — tool calls and sandwiched reasoning blocks in order.
    let toolCalls: [AssistantMessageContent.GroupedItem]
    var authToken: String? = nil
    var serverBaseURL: String? = nil
    var isStreaming = false

    /// Returns the server prefix for a tool name (for external callers).
    static func serverPrefix(for name: String) -> String {
        guard let separatorRange = name.range(of: "__") else { return name }
        return String(name[name.startIndex..<separatorRange.lowerBound])
    }

    /// All pure tool-call items (for single-item fast path detection).
    private var toolOnlyItems: [ToolCallData] {
        toolCalls.compactMap { if case .tool(let tc) = $0 { return tc }; return nil }
    }

    var body: some View {
        // Empty — nothing to render
        if toolCalls.isEmpty { return AnyView(EmptyView()) }

        // Single tool call with no embedded reasoning → flat (no collapse header)
        if toolCalls.count == 1, case .tool(let tc) = toolCalls[0] {
            return AnyView(
                ToolCallView(toolCall: tc, authToken: authToken, serverBaseURL: serverBaseURL)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            )
        }

        // Multiple items (or single reasoning-only edge case) → collapsed group
        return AnyView(
            MixedToolCallGroup(items: toolCalls, authToken: authToken, serverBaseURL: serverBaseURL,
                              isStreaming: isStreaming)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        )
    }
}

// MARK: - Reasoning View

/// Observe per-character progress only in the text leaf, not the disclosure/header.
private struct StreamingReasoningText: View {
    let reasoning: ReasoningData
    let progress: StreamingTypewriter
    let streaming: Bool
    let fontSize: CGFloat
    let color: UIColor

    var body: some View {
        ReasoningText(
            text: streaming || progress.hasStreamed
                ? String(reasoning.content.dropLast(max(0, reasoning.characterCount - progress.visibleCount)))
                : reasoning.content,
            fontSize: fontSize, color: color
        )
    }
}

/// Displays a reasoning/thinking block as a collapsible section with
/// a brain icon, similar to how ChatGPT shows "Thought for X seconds".
/// Expanded while thinking is in progress so the user can follow along,
/// then collapses automatically once thinking completes.
struct ReasoningView: View {
    let reasoning: ReasoningData
    let isStreaming: Bool
    @State private var isExpanded: Bool
    @State private var progress = StreamingTypewriter(maxFrameRate: 60)
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityScale) private var accessibilityScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.streamRateMeter) private var streamRateMeter

    private struct RevealRequest: Equatable {
        let text: String
        let streaming: Bool
        let skipAnimation: Bool
    }

    init(reasoning: ReasoningData, isStreaming: Bool = true) {
        self.reasoning = reasoning
        self.isStreaming = isStreaming
        // Expanded while thinking is in progress, collapsed once done.
        // Containers use the block's position rather than its growing content
        // as identity, preserving user taps and reveal state between tokens.
        // Auto-collapse when isDone flips is handled by .onChange below.
        let autoExpand = UserDefaults.standard.object(forKey: "expandThinkingWhileStreaming") as? Bool ?? true
        self._isExpanded = State(initialValue: !reasoning.isDone && autoExpand)
    }

    var body: some View {
        let streaming = isStreaming && !reasoning.isDone
        let request = RevealRequest(text: reasoning.content, streaming: streaming,
                                    skipAnimation: reduceMotion || !isExpanded)
        // An empty thinking block keeps its header but can't be expanded (web parity).
        let hasContent = !reasoning.content.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            // Header — tappable to expand/collapse
            Button {
                guard hasContent else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: isExpanded && hasContent ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 9, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 12)
                        .opacity(hasContent ? 1 : 0.35)

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
            // NOTE: AnimatedPresence is intentionally NOT used here.
            // The reasoning text grows live during streaming — AnimatedPresence's
            // GeometryReader-background measures the constrained height, not the
            // natural height, so it locks the frame too early and truncates the text.
            if isExpanded && hasContent {
                StreamingReasoningText(
                    reasoning: reasoning, progress: progress, streaming: streaming,
                    fontSize: round(12 * accessibilityScale.uiScale * 10) / 10,
                    color: UIColor(theme.textTertiary)
                )
                .padding(.leading, 22)
                .padding(.trailing, Spacing.sm)
                .padding(.bottom, Spacing.sm)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.xs)
        // Keep reveal state outside the conditional text view. Collapsed
        // thinking catches up without animating, so reopening does not replay it.
        .onChange(of: request, initial: true) { _, request in
            progress.rateMeter = streamRateMeter
            progress.receive(request.text, count: reasoning.characterCount, streaming: request.streaming,
                             reduceMotion: request.skipAnimation)
        }
        .onDisappear { progress.finish() }
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
    var isStreaming = false

    var body: some View {
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // A content-derived ID changes while the first tokens arrive.
                // Reasoning blocks are append-ordered within this message group.
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    ReasoningView(reasoning: block, isStreaming: isStreaming)
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
    var streamingTail: String? = nil
    var messageEmbeds: [String] = []
    /// Passed down to Rich UI embeds for auth token injection and base URL resolution.
    var authToken: String? = nil
    var serverBaseURL: String? = nil
    /// APIClient for rendering inline images via AuthenticatedImageView.
    var apiClient: APIClient? = nil
    var terminalSessionId: String? = nil
    var terminalMessageId: String = ""
    var liveTerminalFiles: [TerminalFileAttachment] = []

    @State private var resolvedResult: ToolCallParser.OrderedParseResult?
    @State private var resolvedContent = ""
    @State private var presentation = Presentation()

    /// Retains the ENTIRE displayed answer while a new structural parse runs,
    /// including the live tail. The prefix and tail always share one view tree.
    private final class Presentation {
        var result: ToolCallParser.OrderedParseResult?
        var pendingContent: String?
        var parseTask: Task<Void, Never>?
    }

    private var isPlainText: Bool {
        !content.contains("<") && !content.contains("◁")
    }

    var body: some View {
        let ordered: ToolCallParser.OrderedParseResult = {
            let parsed: ToolCallParser.OrderedParseResult?
            if isPlainText {
                parsed = .init(segments: [.text(content)], allToolCalls: [])
            } else if resolvedContent == content {
                parsed = resolvedResult
            } else {
                // During a live structural stream, use the latest finished
                // parse while the next one runs. Requiring an exact match on
                // every packet starves rendering when delivery outruns parsing.
                parsed = MessageParseCache.shared.lookupSync(content)
                    ?? (isStreaming && (streamingTail?.isEmpty ?? true) ? resolvedResult : nil)
            }
            if let parsed {
                var segments = parsed.segments
                if let tail = streamingTail?.trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty {
                    if case .text(let previous) = segments.last {
                        segments[segments.count - 1] = .text(previous + "\n\n" + tail)
                    } else {
                        segments.append(.text(tail))
                    }
                }
                let result = ToolCallParser.OrderedParseResult(segments: segments, allToolCalls: parsed.allToolCalls)
                presentation.result = result
                return result
            }
            return presentation.result ?? .init(segments: [], allToolCalls: [])
        }()

        let groups: [SegmentGroup] = {
            let base = Self.groupSegments(ordered.segments)

            // Always suppress data-iv-build embeds on iOS: the legacy Inline
            // Visualizer plugin's HTMLResponse embed calls parent.document,
            // which is impossible in a sandboxed WKWebView.
            let filteredEmbeds: [String] = messageEmbeds.filter { !$0.contains("data-iv-build") }
            guard !filteredEmbeds.isEmpty else { return base }
            let messageEmbeds = filteredEmbeds

            // Search from the end for the last toolCalls group, and within it
            // find the last .tool item that has no embeds to attach the embed to.
            var mutableGroups = base
            for i in stride(from: mutableGroups.count - 1, through: 0, by: -1) {
                if case .toolCalls(var items) = mutableGroups[i] {
                    // Walk backwards through items, skipping .reasoning entries
                    for j in stride(from: items.count - 1, through: 0, by: -1) {
                        if case .tool(let tc) = items[j], tc.embeds.isEmpty {
                            items[j] = .tool(ToolCallData(
                                id: tc.id,
                                name: tc.name,
                                arguments: tc.arguments,
                                result: tc.result,
                                isDone: tc.isDone,
                                status: tc.status,
                                embeds: messageEmbeds,
                                terminalFile: tc.terminalFile
                            ))
                            mutableGroups[i] = .toolCalls(items)
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
                // Show typing indicator when streaming with no content yet.
                // Wrap in HStack+Spacer to pin the indicator to the leading edge.
                // Without this, the infinity-width VStack container can misplace
                // or stretch the 44×22pt fixed view.
                HStack(spacing: 0) {
                    BlinkingCursorIndicator()
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

                ForEach(identifiedGroups(groups), id: \.id) { item in
                    let index = item.index
                    let group = item.group
                    switch group {
                    case .text(let str):
                        // Only the last text segment gets the streaming cursor
                        let isLastText = index == lastTextIndex && isStreaming
                        let effectiveStr = str
                        // Extract inline images from markdown ![alt](url) syntax.
                        // MarkdownView renders images as plain text links — we need
                        // to intercept server file URLs and render them as actual images.
                        let imageSegments = Self.splitInlineImages(effectiveStr)
                        if !effectiveStr.isBlank {
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
                                    if !text.isBlank {
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
                            serverBaseURL: serverBaseURL,
                            isStreaming: isStreaming
                        )

                    case .reasoningBlocks(let blocks):
                        ReasoningContainer(blocks: blocks, isStreaming: isStreaming)

                    case .details(let details):
                        DetailsSectionView(
                            details: details,
                            isStreaming: isStreaming,
                            authToken: authToken,
                            serverBaseURL: serverBaseURL,
                            apiClient: apiClient
                        )

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
                        // Wrap in HStack+Spacer to pin the indicator to the leading edge.
                        // Without this, the infinity-width VStack container can misplace
                        // or stretch the 44×22pt fixed view.
                        HStack(spacing: 0) {
                            BlinkingCursorIndicator()
                            Spacer()
                        }
                    }
                }
            }
            if let apiClient {
                ForEach(TerminalFileAttachment.merged(
                    ordered.allToolCalls.compactMap(\.terminalFile) + liveTerminalFiles,
                    sessionId: terminalSessionId
                )) { file in
                    TerminalFileAttachmentView(file: file, messageId: terminalMessageId, apiClient: apiClient)
                }
            }
        }
        .onAppear(perform: parseLatestContent)
        .onChange(of: content) { _, _ in parseLatestContent() }
        .onDisappear {
            presentation.parseTask?.cancel()
            presentation.parseTask = nil
            presentation.pendingContent = nil
        }
    }

    private func parseLatestContent() {
        let work = presentation
        work.pendingContent = isPlainText ? nil : content
        guard work.parseTask == nil, work.pendingContent != nil else { return }
        work.parseTask = Task {
            // Cumulative snapshots need only one in-flight parse and the latest
            // pending input. Never queue a parse for every arriving token.
            while let source = work.pendingContent {
                work.pendingContent = nil
                if resolvedContent == source { continue }
                let result = await MessageParseCache.shared.parseAndStore(content: source)
                guard !Task.isCancelled else { return }
                resolvedResult = result
                resolvedContent = source
            }
            work.parseTask = nil
        }
    }

    private func identifiedGroups(_ groups: [SegmentGroup]) -> [(id: String, index: Int, group: SegmentGroup)] {
        var counts: [String: Int] = [:]
        return groups.enumerated().map { index, group in
            let kind: String
            switch group {
            case .text: kind = "text"
            case .toolCalls: kind = "tools"
            case .reasoningBlocks: kind = "reasoning"
            case .details: kind = "details"
            case .standaloneEmbeds: kind = "embeds"
            }
            let ordinal = counts[kind, default: 0]
            counts[kind] = ordinal + 1
            return ("\(kind)-\(ordinal)", index, group)
        }
    }

    /// An item inside a mixed tool-call group.
    /// A single "Explored N" container can hold interleaved tool calls and
    /// reasoning blocks — matching the OpenWebUI web UI where thinking blocks
    /// that appear between tool calls are collapsed inside the same group.
    enum GroupedItem {
        case tool(ToolCallData)
        case reasoning(ReasoningData)
    }

    /// Groups adjacent segments of the same type for cleaner rendering.
    /// Adjacent tool calls become a single `toolCalls` group.
    /// A reasoning block that appears *between* tool calls is folded into the
    /// surrounding tool group rather than breaking it into separate rows.
    /// A reasoning block that is NOT sandwiched between tool calls (e.g. a
    /// leading think before any tools, or a trailing think after the last tool
    /// followed by text) stays as its own `reasoningBlocks` group.
    /// Text segments and generic `<details>` sections remain individual and
    /// always break a tool group.
    private enum SegmentGroup {
        case text(String)
        case toolCalls([GroupedItem])
        case reasoningBlocks([ReasoningData])
        /// A generic collapsible `<details>` section (filter output, model-written, code interpreter).
        case details(DetailsData)
        /// Message-level embeds with no associated tool call to attach to.
        case standaloneEmbeds([String])
    }

    private static func groupSegments(_ segments: [ContentSegment]) -> [SegmentGroup] {
        var groups: [SegmentGroup] = []

        // Helper: does a reasoning block at index `i` have a tool call after it
        // (before any intervening text / details section)? Used to decide whether
        // to fold the reasoning block into a tool group or emit it as standalone.
        func nextNonReasoningIsToolCall(from i: Int) -> Bool {
            var j = i + 1
            while j < segments.count {
                switch segments[j] {
                case .toolCall: return true
                case .reasoning: j += 1   // skip consecutive reasoning blocks
                case .text, .details: return false
                }
            }
            return false
        }

        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let str):
                groups.append(.text(str))

            case .details(let d):
                groups.append(.details(d))

            case .toolCall(let tc):
                // Merge with previous group if it is already a toolCalls group
                if case .toolCalls(var existing) = groups.last {
                    groups.removeLast()
                    existing.append(.tool(tc))
                    groups.append(.toolCalls(existing))
                } else {
                    groups.append(.toolCalls([.tool(tc)]))
                }

            case .reasoning(let r):
                // If the previous group is already a toolCalls group AND the
                // next non-reasoning segment is another tool call, fold this
                // reasoning block inside that group (it is "sandwiched").
                if case .toolCalls(var existing) = groups.last,
                   nextNonReasoningIsToolCall(from: index) {
                    groups.removeLast()
                    existing.append(.reasoning(r))
                    groups.append(.toolCalls(existing))
                } else if case .reasoningBlocks(var existing) = groups.last {
                    // Merge consecutive standalone reasoning blocks
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
        // Every match contains this path; skip the regex (run on each streaming
        // update) when it cannot match.
        guard text.contains("/api/v1/files/") else { return [.text(text)] }
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
