import Foundation

/// Single source of truth for locating `<details>…</details>` blocks in
/// assistant content. The message parser, the streaming pipeline and every
/// "strip hidden blocks" path (copy, share, Shortcuts, notifications, TTS)
/// use it so they all agree on where a block starts and ends.
///
/// Rules (Open WebUI's `marked` details extension, hardened):
/// - Tags match case-insensitively with any attributes. Quoted attribute
///   values (including `\"` escapes and `>`) never end a tag.
/// - Nesting is depth-tracked at any depth.
/// - Structural blocks (`type` = `tool_calls`, `reasoning`, `code_interpreter`)
///   are recognised anywhere and close by plain depth counting, like the server.
/// - Every other `<details>` (filter/outlet output, model-written sections)
///   is recognised outside fenced and inline code, so a code sample *about*
///   `<details>` stays a code sample.
/// - Unclosed blocks are reported (`isClosed == false`) when structural or
///   starting a line; a mid-line unclosed `<details>` stays prose.
/// - An opening tag still arriving at the very end is a `.partialTag`.
/// - Orphan `</details>` tags outside code are dropped so they never leak.
/// - Zero-width characters (U+200B/C/D, U+2060, U+FEFF) count as blank.
nonisolated enum DetailsBlockScanner {

    /// `type` values the Open WebUI server emits for structured blocks.
    static let structuralTypes: Set<String> = ["tool_calls", "reasoning", "code_interpreter"]

    struct Block: Sendable {
        /// UTF-8 byte range of the whole block within the scanned text.
        let byteRange: Range<Int>
        /// The full opening tag, e.g. `<details type="reasoning" done="true">`.
        let openTag: String
        /// Raw text between the opening tag and its matching close tag
        /// (or the end of the text when unclosed).
        let body: String
        /// The literal closing tag (`""` when unclosed).
        let closeTag: String
        let isClosed: Bool
        /// Parsed attributes of the opening tag (lowercased names).
        let attributes: [String: String]

        /// Lowercased `type` attribute, if any.
        var type: String? { attributes["type"]?.lowercased() }
        var isStructural: Bool { type.map { DetailsBlockScanner.structuralTypes.contains($0) } ?? false }
        var raw: String { openTag + body + closeTag }
    }

    enum Piece: Sendable {
        case text(String, byteRange: Range<Int>)
        case block(Block)
        /// A `<details` opening tag whose `>` has not arrived yet (always last).
        case partialTag(byteRange: Range<Int>)
    }

    /// Removes details blocks (all by default), a trailing partial tag and
    /// orphan close tags, keeping every other character intact.
    static func strip(_ text: String, where shouldStrip: (Block) -> Bool = { _ in true }) -> String {
        guard mayContainDetails(text) else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for piece in scan(text) {
            switch piece {
            case .text(let t, _): out += t
            case .block(let b): if !shouldStrip(b) { out += b.raw }
            case .partialTag: break
            }
        }
        return out
    }

    /// True when the text contains an unclosed block or a partially-arrived tag.
    static func hasUnclosedBlock(_ text: String) -> Bool {
        guard mayContainDetails(text) else { return false }
        return scan(text).contains { piece in
            switch piece {
            case .text: return false
            case .block(let b): return !b.isClosed
            case .partialTag: return true
            }
        }
    }

    /// Cheap pre-check before running a full scan.
    static func mayContainDetails(_ text: String) -> Bool {
        text.range(of: "<details", options: .caseInsensitive) != nil
            || text.range(of: "</details", options: .caseInsensitive) != nil
    }

    /// Splits a block body into its leading `<summary>` and the remainder.
    /// A `<summary>` still streaming (no close yet) yields the partial title
    /// and an empty remainder.
    static func splitSummary(_ body: String) -> (summary: String?, rest: String) {
        let t = trimmed(body)
        guard t.range(of: "<summary", options: [.caseInsensitive, .anchored]) != nil else { return (nil, body) }
        let nameEnd = t.index(t.startIndex, offsetBy: 8)
        if nameEnd < t.endIndex, t[nameEnd] != ">", !t[nameEnd].isWhitespace { return (nil, body) }
        guard let openEnd = t[nameEnd...].firstIndex(of: ">") else { return ("", "") }
        let afterOpen = t.index(after: openEnd)
        guard let close = t.range(of: "</summary>", options: .caseInsensitive, range: afterOpen..<t.endIndex) else {
            return (String(t[afterOpen...]), "")
        }
        return (String(t[afterOpen..<close.lowerBound]), String(t[close.upperBound...]))
    }

    /// Whitespace, newlines and invisible zero-width characters.
    static let invisibleCharacters: CharacterSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}"))

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: invisibleCharacters)
    }

    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { invisibleCharacters.contains($0) }
    }
}
