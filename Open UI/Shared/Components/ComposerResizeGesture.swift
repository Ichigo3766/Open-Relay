import SwiftUI
import UIKit

/// A vertical-only pan for resizing the chat composer by dragging.
///
/// Built on UIKit (like `SidebarOpeningGesture`) because SwiftUI drag gestures
/// don't reliably receive touches that start on the composer's `UITextView`.
/// It only begins for clearly vertical movement, so taps, cursor placement,
/// selection and the composer buttons are unaffected. When the drag starts
/// inside a text view that can scroll in that direction, the text view keeps
/// the touch and scrolls instead.
struct ComposerResizeGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// Called with the vertical translation in points (negative = upward).
    var onChanged: (CGFloat) -> Void
    /// Called with translation, vertical velocity (pt/s), and whether it was cancelled.
    var onEnded: (CGFloat, CGFloat, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        // Let the text view / buttons keep receiving touches until we commit.
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = false
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let window = pan.view?.window
        let dy = pan.translation(in: window).y
        switch pan.state {
        case .began, .changed: onChanged(dy)
        case .ended: onEnded(dy, pan.velocity(in: window).y, false)
        case .cancelled, .failed: onEnded(dy, 0, true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var touchedView: UIView?

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchedView = touch.view
            // Never steal touches from buttons / menus inside the composer.
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view?.window)
            // Clearly vertical only (keeps horizontal cursor drags / selection intact).
            guard abs(velocity.y) > abs(velocity.x) * 1.4 else { return false }
            // If the touch started in a scrollable text view, let it scroll first.
            if let scroll = enclosingScrollView(of: touchedView), scroll.isScrollEnabled,
               scroll.contentSize.height > scroll.bounds.height + 1 {
                let atTop = scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1
                let atBottom = scroll.contentOffset.y + scroll.bounds.height
                    >= scroll.contentSize.height + scroll.adjustedContentInset.bottom - 1
                // Dragging down (collapse) only once the text is scrolled to the top;
                // dragging up (expand) only once it's at the bottom.
                if velocity.y > 0 && !atTop { return false }
                if velocity.y < 0 && !atBottom { return false }
            }
            // Don't hijack an in-progress text selection.
            if let text = enclosingTextView(of: touchedView), text.selectedRange.length > 0 { return false }
            return true
        }

        // Run alongside the composer's simultaneous press-feedback / tap gestures.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // But never scroll the text view and resize at the same time.
            !(other.view is UITextView && other is UIPanGestureRecognizer)
        }

        private func enclosingScrollView(of view: UIView?) -> UIScrollView? {
            var current = view
            while let v = current {
                if let scroll = v as? UIScrollView { return scroll }
                current = v.superview
            }
            return nil
        }

        private func enclosingTextView(of view: UIView?) -> UITextView? {
            var current = view
            while let v = current {
                if let text = v as? UITextView { return text }
                current = v.superview
            }
            return nil
        }
    }
}
