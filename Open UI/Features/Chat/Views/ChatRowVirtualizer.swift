import SwiftUI
import UIKit

// MARK: - Chat Row Virtualizer
//
// Keeps chat memory bounded WITHOUT a LazyVStack and WITHOUT a sliding window.
//
// Every message always occupies a slot in the chat's VStack, so rows are never
// inserted or removed above the viewport (the root cause of the old paging
// jumps). Rows far from the viewport are drawn as an empty spacer sized to the
// row's last measured height, so the heavy Markdown / WKWebView / image views
// only exist for roughly three screens of content regardless of chat length.
//
// Swapping a measured row for a spacer of the same height is invisible. Rows
// that have never been measured use an estimate. When any row that sits fully
// above the viewport changes height (estimate → real height, async Markdown
// settling, images loading), the scroll offset is shifted by exactly that
// difference in the same layout pass — the technique UITableView uses for
// estimated row heights — so the content being read never moves.

@MainActor
final class ChatRowVirtualizer {
    /// Padding between the scroll content origin and the messages VStack
    /// (must match `.padding(.top, …)` in ChatDetailView.scrollContent).
    static let contentTopPadding: CGFloat = 8

    /// The chat's UIKit scroll view, used for offset correction.
    weak var scrollView: UIScrollView?

    /// While in the future, draw-range updates are paused (a programmatic jump
    /// has already chosen the range it needs).
    var rangeHoldUntil: Date = .distantPast
    /// While in the future, offset correction is paused (a programmatic scroll
    /// owns the offset until it lands).
    var compensationHoldUntil: Date = .distantPast

    /// Latest viewport, in messages-list coordinates (updated by the scroll observer).
    private(set) var visibleTop: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 0

    // MARK: Heights

    private var measuredHeights: [String: CGFloat] = [:]
    private var estimatedHeights: [String: CGFloat] = [:]
    private(set) var width: CGFloat = 0

    // MARK: Layout cache (cumulative row bottoms, in message order)

    private var layoutIds: [String] = []
    private var rowEnds: [CGFloat] = []
    private var layoutDirty = true

    // MARK: Offset correction

    private struct SlotFrame {
        var minY: CGFloat
        var height: CGFloat
    }
    /// Latest reported frame of every row slot (drawn row or spacer), in
    /// messages-list coordinates.
    private var frames: [String: SlotFrame] = [:]
    /// The slot under the reading line, and its list position when picked.
    private var anchorId: String?
    private var anchorMinY: CGFloat = 0
    /// Offset corrections applied since the scroll observer last read them.
    private var pendingCompensation: CGFloat = 0

    /// Pauses range updates and offset correction for a programmatic scroll.
    func hold(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        rangeHoldUntil = max(rangeHoldUntil, until)
        compensationHoldUntil = max(compensationHoldUntil, until)
        anchorId = nil
    }

    /// Ends any hold immediately.
    func releaseHold() {
        rangeHoldUntil = .distantPast
        compensationHoldUntil = .distantPast
    }

    // MARK: - Heights

    /// The height a spacer for this message should use.
    func height(for message: ChatMessage) -> CGFloat {
        if let h = measuredHeights[message.id] { return h }
        if let h = estimatedHeights[message.id] { return h }
        let h = estimate(for: message)
        estimatedHeights[message.id] = h
        return h
    }

    /// Records the chat width used for estimates. Cached heights are kept on
    /// resize (rotation, iPad split view): spacers keep their old height until
    /// they are drawn again, then offset correction absorbs the difference, so
    /// a resize never shifts every off-screen row at once.
    func updateWidth(_ newWidth: CGFloat) {
        guard newWidth > 0, abs(newWidth - width) > 1 else { return }
        width = newWidth
    }

    /// Rough height from text length, role and attachments. Only used until the
    /// row has been drawn once; errors are absorbed by offset correction.
    private func estimate(for message: ChatMessage) -> CGFloat {
        let w = max(width > 0 ? width : UIScreen.main.bounds.width, 200)
        let chars = CGFloat(message.content.utf8.count)
        let fileCount = CGFloat(message.files.count)
        if message.role == .user
            && (message.isInternalMessage || message.content.hasPrefix("[ASYNC SUBAGENT COMPLETE")) {
            return 56
        }
        if message.role == .user {
            let charsPerLine = max(10, (w * 0.72) / 8.5)
            let lines = max(1, (chars / charsPerLine).rounded(.up))
            return lines * 22 + 40 + fileCount * 110
        }
        let charsPerLine = max(10, (w - 32) / 8)
        let lines = max(1, (chars / charsPerLine * 1.15).rounded(.up))
        return max(80, 104 + lines * 24 + fileCount * 120)
    }

    // MARK: - Layout

    private func rebuildLayoutIfNeeded(_ messages: [ChatMessage]) {
        if !layoutDirty,
           layoutIds.elementsEqual(messages.lazy.map(\.id)) {
            return
        }
        layoutIds = messages.map(\.id)
        rowEnds.removeAll(keepingCapacity: true)
        rowEnds.reserveCapacity(messages.count)
        var y: CGFloat = 0
        for message in messages {
            y += height(for: message)
            rowEnds.append(y)
        }
        layoutDirty = false
    }

    private func rowTop(_ index: Int) -> CGFloat {
        index <= 0 ? 0 : rowEnds[index - 1]
    }

    /// First row whose bottom edge is below `y`, i.e. the row containing `y`.
    private func firstIndex(endingAfter y: CGFloat) -> Int {
        var lo = 0, hi = rowEnds.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rowEnds[mid] > y { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    private func indices(from top: CGFloat, to bottom: CGFloat) -> ClosedRange<Int>? {
        guard !rowEnds.isEmpty else { return nil }
        let last = rowEnds.count - 1
        let first = min(firstIndex(endingAfter: top), last)
        let end = min(firstIndex(endingAfter: bottom), last)
        return first...max(first, end)
    }

    /// Index of the message at the top of the viewport.
    func topVisibleIndex(messages: [ChatMessage]) -> Int {
        guard !messages.isEmpty else { return 0 }
        rebuildLayoutIfNeeded(messages)
        return min(firstIndex(endingAfter: visibleTop + 1), messages.count - 1)
    }

    // MARK: - Draw ranges

    /// Records the latest viewport, in messages-list coordinates.
    func updateViewport(top: CGFloat, height: CGFloat) {
        visibleTop = top
        viewportHeight = height
    }

    /// Rows drawn at the bottom of the chat: the last ~2.5 screens, at least 6 rows.
    func bottomRange(messages: [ChatMessage], viewportHeight: CGFloat) -> ClosedRange<Int>? {
        let count = messages.count
        guard count > 0 else { return nil }
        let budget = max(viewportHeight, UIScreen.main.bounds.height) * 2.5
        var start = count
        var accumulated: CGFloat = 0
        while start > 0 && (accumulated < budget || count - start < 6) {
            start -= 1
            accumulated += height(for: messages[start])
        }
        return start...(count - 1)
    }

    /// Returns a new draw range once the viewport has moved far enough out of
    /// the current one, otherwise nil. The core (viewport ± 0.5 screen) must stay
    /// inside the drawn range; when it doesn't, the range is rebuilt at ± 1.25
    /// screens. Updates therefore happen about once per half screen of travel,
    /// never per frame.
    func updatedRange(messages: [ChatMessage], current: ClosedRange<Int>?) -> ClosedRange<Int>? {
        guard Date() >= rangeHoldUntil, !messages.isEmpty, viewportHeight > 0 else { return nil }
        rebuildLayoutIfNeeded(messages)
        let top = visibleTop
        let bottom = visibleTop + viewportHeight
        guard let core = indices(from: top - viewportHeight * 0.5,
                                 to: bottom + viewportHeight * 0.5) else { return nil }
        if let current, current.upperBound < messages.count,
           current.lowerBound <= core.lowerBound, current.upperBound >= core.upperBound {
            return nil
        }
        let desired = indices(from: top - viewportHeight * 1.25, to: bottom + viewportHeight * 1.25)
        guard desired != current else { return nil }
        // The caller applies the range on the next run-loop turn; don't queue the
        // same request again on every frame until it lands.
        let now = Date()
        if desired == lastRequestedRange && now.timeIntervalSince(lastRequestedAt) < 0.1 { return nil }
        lastRequestedRange = desired
        lastRequestedAt = now
        return desired
    }

    private var lastRequestedRange: ClosedRange<Int>?
    private var lastRequestedAt: Date = .distantPast

    /// Draw range for a programmatic jump that places `index` at the top.
    func range(forJumpTo index: Int, messages: [ChatMessage]) -> ClosedRange<Int>? {
        guard !messages.isEmpty else { return nil }
        rebuildLayoutIfNeeded(messages)
        let clamped = min(max(0, index), messages.count - 1)
        let top = rowTop(clamped)
        let vh = max(viewportHeight, UIScreen.main.bounds.height * 0.5)
        guard let r = indices(from: top - vh * 0.75, to: top + vh * 2) else { return nil }
        return min(r.lowerBound, clamped)...max(r.upperBound, clamped)
    }

    // MARK: - Measurement + offset correction
    //
    // Anchor-based: on every user scroll the slot under the reading line (top of
    // the visible area) becomes the anchor. Whenever that slot's position in the
    // list moves — because any row ABOVE it changed height (estimate → real
    // height, a spacer swapped for a freshly drawn row, async Markdown settling)
    // — the scroll offset is moved by exactly the same amount, in the same
    // layout pass. The anchor's own growth (e.g. expanding a reasoning block)
    // doesn't move its top, so on-screen content expands naturally downward.
    // Order-independent: however many rows above change, the anchor's single
    // position delta is the total correction.

    /// Called by every row slot whenever its height or list position changes.
    /// Scrolling never triggers this (list coordinates don't change on scroll).
    func report(id: String, minY: CGFloat, height: CGFloat, isDrawn: Bool) {
        if isDrawn, height > 0.5, abs((measuredHeights[id] ?? -1) - height) > 0.5 {
            measuredHeights[id] = height
            layoutDirty = true
        }
        frames[id] = SlotFrame(minY: minY, height: height)

        guard id == anchorId else { return }
        let delta = minY - anchorMinY
        anchorMinY = minY
        guard abs(delta) > 0.5, Date() >= compensationHoldUntil, let sv = scrollView else { return }
        compensate(by: delta, in: sv)
    }

    /// Re-picks the anchor slot from the latest reported frames. Called by the
    /// scroll observer when the offset moves.
    func updateAnchor(messages: [ChatMessage]) {
        guard Date() >= compensationHoldUntil, !messages.isEmpty, viewportHeight > 0 else {
            anchorId = nil
            return
        }
        rebuildLayoutIfNeeded(messages)
        let readingLine = visibleTop + 1
        // Nothing above the viewport → nothing that could push content around.
        guard readingLine > 1 else { anchorId = nil; return }
        let guess = min(firstIndex(endingAfter: readingLine), messages.count - 1)
        let lower = max(0, guess - 3)
        let upper = min(messages.count - 1, guess + 3)
        for i in lower...upper {
            let id = messages[i].id
            guard let f = frames[id], f.height > 0.5 else { continue }
            if f.minY <= readingLine && f.minY + f.height > readingLine {
                anchorId = id
                anchorMinY = f.minY
                return
            }
        }
        anchorId = nil
    }

    private func compensate(by delta: CGFloat, in sv: UIScrollView) {
        let inset = sv.adjustedContentInset
        let minOffset = -inset.top
        let current = sv.contentOffset.y
        // At the very top nothing is above the viewport to compensate for.
        guard current > minOffset + 0.5 else { return }
        // No upper clamp: contentSize may not reflect this layout pass yet, and
        // UIKit accepts a programmatic offset past the current content end.
        let target = max(minOffset, current + delta)
        guard abs(target - current) > 0.01 else { return }
        pendingCompensation += target - current
        sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: target)
    }

    /// Returns (and clears) offset corrections applied since the last call, so
    /// the scroll observer can exclude them from direction / nav-bar logic.
    func consumeCompensation() -> CGFloat {
        let value = pendingCompensation
        pendingCompensation = 0
        return value
    }
}
