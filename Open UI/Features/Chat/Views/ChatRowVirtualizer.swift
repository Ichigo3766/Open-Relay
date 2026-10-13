import SwiftUI
import UIKit

// MARK: - Chat Row Virtualizer
//
// Draw only turns near the viewport; represent offscreen runs with their
// combined cached height. The cumulative height index serves range selection,
// programmatic jumps, and reading-anchor correction without observing row positions.
// When a measured height above the anchor changes, shift the UIKit offset by
// the same delta so the content being read remains in place.

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

    /// The slot under the reading line, and its list position when picked.
    private var anchorId: String?
    private var anchorIndex: Int?
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
        if !layoutDirty, layoutIds.count == messages.count,
           layoutIds.indices.allSatisfy({ layoutIds[$0] == messages[$0].id }) {
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
        if let anchorId, let index = layoutIds.firstIndex(of: anchorId) {
            anchorIndex = index
            let nextTop = rowTop(index)
            let delta = nextTop - anchorMinY
            anchorMinY = nextTop
            if abs(delta) > 0.5, Date() >= compensationHoldUntil, let scrollView {
                compensate(by: delta, in: scrollView)
            }
        } else {
            anchorIndex = nil
        }
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

    /// Combined height of an offscreen run, without creating a view per row.
    func height(for range: Range<Int>, messages: [ChatMessage]) -> CGFloat {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= messages.count else { return 0 }
        rebuildLayoutIfNeeded(messages)
        return rowEnds[range.upperBound - 1] - rowTop(range.lowerBound)
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

    // MARK: - Height measurement + offset correction

    /// Row positions come from the height index; geometry observes height only.
    /// A change above the reading anchor shifts the offset by the same delta.
    func report(id: String, index: Int, height: CGFloat) {
        guard height > 0.5 else { return }
        let oldHeight = measuredHeights[id] ?? estimatedHeights[id] ?? height
        guard measuredHeights[id] != height else { return }
        measuredHeights[id] = height
        layoutDirty = true
        guard anchorId != nil, let anchorIndex, index < anchorIndex,
              layoutIds.indices.contains(index), layoutIds[index] == id else { return }
        let delta = height - oldHeight
        anchorMinY += delta
        guard Date() >= compensationHoldUntil, let scrollView else { return }
        compensate(by: delta, in: scrollView)
    }

    /// Pick the row under the reading line from the cumulative height index.
    func updateAnchor(messages: [ChatMessage]) {
        guard Date() >= compensationHoldUntil, !messages.isEmpty, viewportHeight > 0 else {
            anchorId = nil
            anchorIndex = nil
            return
        }
        rebuildLayoutIfNeeded(messages)
        let readingLine = visibleTop + 1
        guard readingLine > 1 else { anchorId = nil; anchorIndex = nil; return }
        let index = min(firstIndex(endingAfter: readingLine), messages.count - 1)
        guard readingLine < rowEnds[index] else { anchorId = nil; anchorIndex = nil; return }
        anchorId = messages[index].id
        anchorIndex = index
        anchorMinY = rowTop(index)
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
        visibleTop += target - current
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
