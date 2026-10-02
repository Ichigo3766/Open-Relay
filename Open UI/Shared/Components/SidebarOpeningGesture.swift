import Litext
import SwiftUI

/// A direction-locked pan that yields to scrolling, selection, and controls.
struct SidebarOpeningGesture: UIGestureRecognizerRepresentable {
    /// Which way the finger must travel to begin.
    enum Direction { case rightward, leftward }

    var isEnabled: Bool
    var direction: Direction = .rightward
    /// When set, the pan only begins if the touch starts within this many points
    /// of the edge it moves away from (trailing edge for `.leftward`).
    var edgeWidth: CGFloat? = nil
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = SidebarPanRecognizer()
        pan.maximumNumberOfTouches = 1
        // Once the pan is recognised, the touched view receives touchesCancelled,
        // so raw-touch views (e.g. selectable message text) stop reacting.
        pan.cancelsTouchesInView = true
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        context.coordinator.direction = direction
        context.coordinator.edgeWidth = edgeWidth
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = isEnabled
        context.coordinator.direction = direction
        context.coordinator.edgeWidth = edgeWidth
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        // Window coordinates remain stable while the page follows the finger.
        let translation = pan.translation(in: pan.view?.window).x
        switch pan.state {
        case .began:
            // Freeze the page the instant the drag is accepted: scrolling,
            // long-press menus, text selection and taps underneath all cancel.
            context.coordinator.freezeUnderlyingInteractions(except: pan)
            onChanged(translation)
        case .changed: onChanged(translation)
        case .ended: onEnded(translation, pan.velocity(in: pan.view?.window).x, false)
        case .cancelled: onEnded(0, 0, true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var touchedView: UIView?
        var direction: Direction = .rightward
        var edgeWidth: CGFloat?

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchedView = touch.view
            if let edgeWidth, let host = gestureRecognizer.view {
                let x = touch.location(in: host).x
                let fromEdge = direction == .leftward ? host.bounds.width - x : x
                guard fromEdge <= edgeWidth else { return false }
            }
            return allowsOpening(from: touch.view)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // A swipe that started on a message belongs to that message (swipe-to-reply).
            if MessageGestureArbiter.isTouchOnMessage { return false }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  allowsOpening(from: touchedView) else { return false }
            // Translation is still zero at UIKit's begin decision; velocity is available.
            let velocity = pan.velocity(in: pan.view?.window)
            let along = direction == .rightward ? velocity.x : -velocity.x
            return along > abs(velocity.y) * 1.5
        }

        // The chat's simultaneous drag observer must not cancel an accepted pan —
        // but a message's reply swipe is exclusive: never run both together.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            !(otherGestureRecognizer is MessagePanRecognizer)
        }

        // If a message reply swipe is in play, the sidebar waits for it to fail.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is MessagePanRecognizer
        }

        /// Cancels every other gesture between the touched view and the pan's
        /// host view. Toggling `isEnabled` is UIKit's supported way to cancel an
        /// in-flight recognizer (or fail a pending one) without side effects.
        /// Recognizers above the host view (navigation, system) are untouched.
        func freezeUnderlyingInteractions(except pan: UIGestureRecognizer) {
            guard let host = pan.view else { return }
            var ancestor: UIView? = touchedView ?? host
            var visited = Set<ObjectIdentifier>()
            while let view = ancestor {
                for recognizer in view.gestureRecognizers ?? [] where recognizer !== pan {
                    guard recognizer.isEnabled,
                          visited.insert(ObjectIdentifier(recognizer)).inserted else { continue }
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                }
                if view === host { break }
                ancestor = view.superview
            }
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

/// Named subclass so message gestures can identify (and exclude) the sidebar pan.
final class SidebarPanRecognizer: UIPanGestureRecognizer {}
