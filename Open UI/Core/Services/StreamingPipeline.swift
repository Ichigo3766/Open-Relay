import Foundation

/// Pre-sliced content prepared off-main. Markdown is never split at guessed
/// paragraph boundaries; only completed reasoning/tool blocks form a prefix.
struct StreamingSnapshot: Sendable {
    let displayContent: String
    let frozenContent: String
    let liveTail: String
    let isActive: Bool

    static let idle = StreamingSnapshot(
        displayContent: "", frozenContent: "", liveTail: "", isActive: false
    )
}

/// Processes cumulative content on arrival, with no reveal timer or holdback.
/// A single consumer in StreamingContentStore bounds pending work.
actor StreamingPipeline {
    private let onSnapshot: @MainActor (StreamingSnapshot) -> Void
    private var buffer = ""
    private var frozenContent = ""
    private var isFinished = false

    init(onSnapshot: @escaping @MainActor (StreamingSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func beginWithPrefix(_ prefix: String) async {
        buffer = ""
        frozenContent = ""
        isFinished = false
        await append(prefix)
    }

    func append(_ content: String) async {
        guard !isFinished, content != buffer, !Task.isCancelled else { return }
        await publish(content, isFinal: false)
    }

    func setFinalContent(_ content: String) async {
        guard !isFinished, !Task.isCancelled else { return }
        isFinished = true
        await publish(content, isFinal: true)
        guard !Task.isCancelled else { return }
        await onSnapshot(.idle)
    }

    private func publish(_ content: String, isFinal: Bool) async {
        if !content.hasPrefix(buffer) { frozenContent = "" }
        buffer = content

        // Reconstruct the index in the NEW string; indices cannot be retained
        // across replacements. Already-closed blocks are not scanned again.
        let utf8Boundary = content.utf8.index(content.utf8.startIndex, offsetBy: frozenContent.utf8.count)
        let boundary = String.Index(utf8Boundary, within: content) ?? content.startIndex
        let tail = String(content[boundary...])
        let details = Self.detailsBoundaries(in: tail)
        let visibleEnd = isFinal ? tail.endIndex : details.openStart ?? tail.endIndex
        let visibleTail = String(tail[..<visibleEnd])
        let visible = frozenContent + visibleTail
        if let closedEnd = details.closedEnd {
            frozenContent += String(tail[..<closedEnd])
        }
        let liveStart = details.closedEnd ?? tail.startIndex
        let liveTail = liveStart <= visibleEnd ? String(tail[liveStart..<visibleEnd]) : ""
        guard !Task.isCancelled else { return }
        await onSnapshot(StreamingSnapshot(
            displayContent: visible,
            frozenContent: frozenContent,
            liveTail: frozenContent.isEmpty ? "" : liveTail,
            isActive: true
        ))
    }

    /// Recognizes structural details tags, including nested blocks and quoted
    /// attributes. An unfinished structural tag is not sent to the prose view.
    private static func detailsBoundaries(in text: String) -> (
        closedEnd: String.Index?, openStart: String.Index?
    ) {
        var cursor = text.startIndex
        var blockStart: String.Index?
        var closedEnd: String.Index?
        var depth = 0
        while let start = text[cursor...].firstIndex(of: "<") {
            cursor = text.index(after: start)
            let remainder = text[start...]
            let closing = remainder.prefix(9).lowercased() == "</details"
            let name = closing ? "</details" : "<details"
            guard remainder.prefix(name.count).lowercased() == name else { continue }
            let nameEnd = text.index(start, offsetBy: name.count)
            guard nameEnd == text.endIndex || text[nameEnd].isWhitespace || text[nameEnd] == ">" else {
                continue
            }
            var end = nameEnd
            var quote: Character?
            while end < text.endIndex {
                let character = text[end]
                if let current = quote {
                    if character == "\\" {
                        end = text.index(after: end)
                        if end < text.endIndex { end = text.index(after: end) }
                        continue
                    }
                    if character == current { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                }
                end = text.index(after: end)
            }
            guard end < text.endIndex else {
                return (closedEnd, blockStart ?? (closing ? nil : start))
            }
            cursor = text.index(after: end)
            if closing {
                if depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        closedEnd = cursor
                        blockStart = nil
                    }
                }
            } else if depth > 0 {
                depth += 1
            } else {
                let tag = text[start..<cursor].lowercased()
                if tag.contains("type=\"reasoning\"") || tag.contains("type='reasoning'")
                    || tag.contains("type=\"tool_calls\"") || tag.contains("type='tool_calls'") {
                    blockStart = start
                    depth = 1
                }
            }
        }
        return (closedEnd, blockStart)
    }
}
