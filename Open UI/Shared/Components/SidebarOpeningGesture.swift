import Litext
import SwiftUI

/// A direction-locked pan that yields to scrolling, selection, and controls.
struct SidebarOpeningGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        // Window coordinates remain stable while the page follows the finger.
        let translation = pan.translation(in: pan.view?.window).x
        switch pan.state {
        case .began, .changed: onChanged(translation)
        case .ended: onEnded(translation, pan.velocity(in: pan.view?.window).x, false)
        case .cancelled: onEnded(0, 0, true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var touchedView: UIView?

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchedView = touch.view
            return allowsOpening(from: touch.view)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  allowsOpening(from: touchedView) else { return false }
            // Translation is still zero at UIKit's begin decision; velocity is available.
            let velocity = pan.velocity(in: pan.view?.window)
            return velocity.x > abs(velocity.y) * 1.5
        }

        // The chat's simultaneous drag observer must not cancel an accepted pan.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        private func allowsOpening(from view: UIView?) -> Bool {
            var ancestor = view
            while let view = ancestor {
                if view is UIControl { return false }
                if let text = view as? UITextView,
                   text.isEditable || text.selectedRange.length > 0 { return false }
                if let text = view as? LTXLabel, text.selectionRange != nil { return false }
                if let scroll = view as? UIScrollView, scroll.isScrollEnabled,
                   scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                ancestor = view.superview
            }
            return true
        }
    }
}
