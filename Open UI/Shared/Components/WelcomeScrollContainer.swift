import SwiftUI
import UIKit

/// Scroll container for the new-chat welcome screen.
///
/// The page can never be scrolled by hand: the underlying scroll view is held at its
/// resting offset at all times. It stays a scroll view only so its pan gesture can drive
/// iOS's interactive keyboard dismissal (the keyboard follows the finger down).
///
/// The content is centred inside a minimum height equal to the visible area measured
/// with the keyboard closed. While the keyboard is open the height is never reduced, so
/// the greeting and cards stay perfectly still and only the composer follows the
/// keyboard. Layout passes while the app is not active (iOS lays the screen out at other
/// sizes for its snapshots) are ignored, and the height is re-measured when the app
/// returns. A width change (rotation, split view) resets the measurement.
struct WelcomeScrollContainer<Content: View>: View {
    /// Used until the first measurement lands.
    let fallbackHeight: CGFloat
    /// Whether the keyboard is up (from the screen's `KeyboardTracker`).
    let keyboardVisible: Bool
    @ViewBuilder let content: () -> Content

    @State private var measuredHeight: CGFloat = 0
    @State private var measuredWidth: CGFloat = 0
    /// Latest size seen while the app was active.
    @State private var lastSize: CGSize = .zero

    var body: some View {
        ScrollView {
            content()
                .frame(minHeight: measuredHeight > 0 ? measuredHeight : max(fallbackHeight, 0))
                .background(WelcomeScrollPin())
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard UIApplication.shared.applicationState == .active else { return }
            lastSize = size
            if abs(size.width - measuredWidth) > 1 {
                measuredWidth = size.width
                measuredHeight = size.height
            } else if !keyboardVisible {
                if abs(size.height - measuredHeight) > 0.5 { measuredHeight = size.height }
            } else if size.height > measuredHeight {
                measuredHeight = size.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if !keyboardVisible, lastSize.height > 0 { measuredHeight = lastSize.height }
        }
    }
}

/// Finds the enclosing `UIScrollView` and holds it at its resting offset, so the page
/// can't be scrolled or bounced while its pan gesture keeps driving keyboard dismissal.
private struct WelcomeScrollPin: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async { context.coordinator.attach(to: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard context.coordinator.scrollView == nil else { return }
        DispatchQueue.main.async { context.coordinator.attach(to: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        func attach(to view: UIView) {
            guard scrollView == nil else { return }
            var current = view.superview
            while let v = current, !(v is UIScrollView) { current = v.superview }
            guard let sv = current as? UIScrollView else { return }
            scrollView = sv
            // Keep the pan gesture alive even when the content fits, so a drag can
            // always reach the keyboard.
            sv.alwaysBounceVertical = true
            sv.showsVerticalScrollIndicator = false
            observation = sv.observe(\.contentOffset, options: [.new]) { sv, change in
                guard let offset = change.newValue else { return }
                let rest = -sv.adjustedContentInset.top
                if abs(offset.y - rest) > 0.5 {
                    sv.contentOffset = CGPoint(x: offset.x, y: rest)
                }
            }
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            scrollView = nil
        }
    }
}
