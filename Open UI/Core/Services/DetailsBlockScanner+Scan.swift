import Foundation

// MARK: - Top-level scan

extension DetailsBlockScanner {

    /// Splits `text` into ordered prose pieces and top-level details blocks.
    nonisolated static func scan(_ text: String) -> [Piece] {
        let s = Array(text.utf8)
        let n = s.count
        var pieces: [Piece] = []
        var textStart = 0
        var i = 0
        var lineHasContent = false
        var fence: Fence?

        func flushText(upTo end: Int) {
            if end > textStart {
                pieces.append(.text(decode(s, textStart..<end), byteRange: textStart..<end))
            }
            textStart = end
        }

        while i < n {
            let c = s[i]
            if c == newline { lineHasContent = false; i += 1; continue }
            if !lineHasContent {
                if isSpace(c) { i += 1; continue }
                if let w = zeroWidthLength(s, i) { i += w; continue }
            }
            let atLineStart = !lineHasContent
            lineHasContent = true

            if atLineStart, let next = fenceTransition(s, at: i, current: fence) {
                fence = next.fence
                i = next.lineEnd
                continue
            }

            if c == lt {
                switch openingTag(s, at: i) {
                case .partial:
                    flushText(upTo: i)
                    pieces.append(.partialTag(byteRange: i..<n))
                    return pieces
                case .complete(let tagEnd):
                    let openTag = decode(s, i..<tagEnd)
                    let attrs = attributes(in: openTag)
                    let structural = attrs["type"].map { structuralTypes.contains($0.lowercased()) } ?? false
                    if fence != nil && !structural {
                        i = tagEnd   // literal text inside a code block
                        continue
                    }
                    let close = structural
                        ? findClose(s, from: tagEnd, codeAware: false)
                        : findClose(s, from: tagEnd, codeAware: true) ?? findClose(s, from: tagEnd, codeAware: false)
                    if let close {
                        flushText(upTo: i)
                        pieces.append(.block(Block(
                            byteRange: i..<close.end, openTag: openTag,
                            body: decode(s, tagEnd..<close.start),
                            closeTag: decode(s, close.start..<close.end),
                            isClosed: true, attributes: attrs
                        )))
                        textStart = close.end
                        i = close.end
                        if structural { fence = nil }
                        continue
                    }
                    if structural || atLineStart {
                        flushText(upTo: i)
                        pieces.append(.block(Block(
                            byteRange: i..<n, openTag: openTag,
                            body: decode(s, tagEnd..<n), closeTag: "",
                            isClosed: false, attributes: attrs
                        )))
                        return pieces
                    }
                    i = tagEnd   // mid-line and never closed: keep as prose
                    continue
                case .none:
                    break
                }
                if fence == nil, n - i >= 3, n - i < closePrefix.count,
                   Array(closePrefix.prefix(n - i)) == s[i...].map(lowercase) {
                    // "</det" still arriving at the very end.
                    flushText(upTo: i)
                    pieces.append(.partialTag(byteRange: i..<n))
                    return pieces
                }
                if fence == nil, matches(s, at: i, closePrefix), isTagBoundary(s, i + closePrefix.count) {
                    // Orphan close tag outside code: drop it so it never leaks.
                    flushText(upTo: i)
                    guard let gt = indexOf(gtByte, in: s, from: i + closePrefix.count) else {
                        pieces.append(.partialTag(byteRange: i..<n))
                        return pieces
                    }
                    textStart = gt + 1
                    i = gt + 1
                    continue
                }
                i += 1
                continue
            }

            if fence == nil, c == backtick {
                let end = endOfInlineCode(s, at: i)
                // A code span never swallows a structural block.
                i = spanContainsStructuralTag(s, i..<end) ? i + 1 : end
                continue
            }
            i += 1
        }
        flushText(upTo: n)
        return pieces
    }
}
