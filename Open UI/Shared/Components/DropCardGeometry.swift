import SwiftUI

// MARK: - Drop Card Geometry
//
// The model picker is a glass card that grows DOWN out of the nav-bar model button
// and shrinks back into it — the top-anchored twin of the + menu's composer card.

/// The model button's frame, carried up to the chat screen so the card (and the
/// editor drop) can start exactly where the button is.
struct ModelButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// A rounded rectangle pinned to its start frame's top edge whose x, width, height
/// and corner radius interpolate from the button's to the card's.
struct DropCardShape: Shape {
    var progress: CGFloat
    var endHeight: CGFloat
    let start: CGRect
    let endX: CGFloat
    let endWidth: CGFloat
    let startCorner: CGFloat
    let endCorner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, endHeight) }
        set { progress = newValue.first; endHeight = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let p = max(0, progress)
        let r = CGRect(
            x: start.minX + (endX - start.minX) * p,
            y: start.minY,
            width: start.width + (endWidth - start.width) * p,
            height: start.height + (endHeight - start.height) * p
        )
        let corner = startCorner + (endCorner - startCorner) * min(1, p)
        return RoundedRectangle(cornerRadius: min(corner, r.height / 2), style: .continuous).path(in: r)
    }
}

/// Where the card sits for a given button frame and container.
struct DropCardLayout {
    let buttonRect: CGRect
    let containerSize: CGSize

    var width: CGFloat { min(containerSize.width - 24, 440) }
    var x: CGFloat { max(12, min(buttonRect.midX - width / 2, containerSize.width - 12 - width)) }
    /// Space from the button's top edge to the bottom of the screen.
    var available: CGFloat { max(buttonRect.height + 160, containerSize.height - buttonRect.minY - 12) }

    func height(searching: Bool, keyboardHeight: CGFloat) -> CGFloat {
        // Searching: fill everything between the button and just above the keyboard.
        // Otherwise: a comfortable card, capped so it doesn't swallow the whole chat.
        let bottomGap: CGFloat = keyboardHeight > 0 ? 8 : 12
        let room = max(buttonRect.height + 160,
                       containerSize.height - buttonRect.minY - keyboardHeight - bottomGap)
        return searching || keyboardHeight > 0 ? room : min(room, 560)
    }
}
