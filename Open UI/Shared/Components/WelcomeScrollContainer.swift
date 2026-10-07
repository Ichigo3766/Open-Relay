import SwiftUI
import UIKit

/// Scroll container for the new-chat welcome screen.
///
/// The welcome content is centred inside a minimum height. That height used to be copied
/// from the message list, which only updates in 30pt steps — so dragging the keyboard
/// down made the greeting and cards jump in steps. This measures its own height instead
/// and only ever grows it (the keyboard can only shrink the visible area), so the
/// content stays perfectly still while the keyboard comes and goes and only the composer
/// follows it. A width change (rotation, split view) resets the measurement.
struct WelcomeScrollContainer<Content: View>: View {
    /// Used until the first measurement lands.
    let fallbackHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var measuredHeight: CGFloat = 0
    @State private var measuredWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .frame(minHeight: measuredHeight > 0 ? measuredHeight : max(fallbackHeight, 0))
                .background(WelcomeScrollPin())
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            if abs(size.width - measuredWidth) > 1 {
                measuredWidth = size.width
                measuredHeight = size.height
            } else if size.height > measuredHeight {
                measuredHeight = size.height
            }
        }
    }

/// Holds the enclosing `UIScrollView` still while the keyboard is up.
///
/// The content keeps its keyboard-down height, so with the keyboard open it is taller
/// than the visible area and the whole page could be scrolled. The welcome screen is one
/// fixed page: the pan gesture keeps running (dragging down still closes the keyboard
/// interactively) but the offset is pinned. With the keyboard down it scrolls normally,
/// so tall content (large text sizes, many cards) stays reachable.
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
        private var tokens: [NSObjectProtocol] = []
        private var keyboardUp = false
        private var pinnedY: CGFloat = 0

        func attach(to view: UIView) {
            guard scrollView == nil else { return }
            var current = view.superview
            while let v = current, !(v is UIScrollView) { current = v.superview }
            guard let sv = current as? UIScrollView else { return }
            scrollView = sv

            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(forName: UIResponder.keyboardWillShowNotification,
                                         object: nil, queue: .main) { [weak self] _ in
                guard let self, let sv = self.scrollView, !self.keyboardUp else { return }
                let top = -sv.adjustedContentInset.top
                self.pinnedY = min(max(sv.contentOffset.y, top), self.maxOffset(sv))
                self.keyboardUp = true
            })
            tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                         object: nil, queue: .main) { [weak self] _ in
                self?.keyboardUp = false
            })

            observation = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, change in
                guard let self, self.keyboardUp, let offset = change.newValue else { return }
                if abs(offset.y - self.pinnedY) > 0.5 {
                    sv.contentOffset = CGPoint(x: offset.x, y: self.pinnedY)
                }
            }
        }

        private func maxOffset(_ sv: UIScrollView) -> CGFloat {
            max(-sv.adjustedContentInset.top,
                sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            scrollView = nil
        }
    }
}

}
