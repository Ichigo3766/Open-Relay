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

    /// Finds the end of the last closed `<details>` block and the start of an
    /// unfinished one (or a partially-arrived tag) using the shared
    /// `DetailsBlockScanner` — the same rules the message parser uses, so
    /// tool calls, thinking, code interpreter and plain sections (filter output,
    /// model-written blocks) are all held back until closed and never leak raw.
    private static func detailsBoundaries(in text: String) -> (
        closedEnd: String.Index?, openStart: String.Index?
    ) {
        guard text.utf8.contains(UInt8(ascii: "<")) else { return (nil, nil) }
        var closedEnd: Int?
        var openStart: Int?
        for piece in DetailsBlockScanner.scan(text) {
            switch piece {
            case .text:
                continue
            case .block(let block):
                if block.isClosed { closedEnd = block.byteRange.upperBound } else { openStart = block.byteRange.lowerBound }
            case .partialTag(let range):
                openStart = range.lowerBound
            }
        }
        // Scanner offsets always fall on ASCII bytes or whole zero-width
        // characters, so they are valid String indices.
        func index(_ offset: Int?) -> String.Index? {
            offset.map { text.utf8.index(text.utf8.startIndex, offsetBy: $0) }
        }
        return (index(closedEnd), index(openStart))
    }
}
