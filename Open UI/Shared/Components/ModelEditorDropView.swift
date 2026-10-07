import SwiftUI

// MARK: - Model Editor Drop View
//
// A glass droplet that forms under the nav-bar model button, pinches off, falls to the
// bottom of the screen and flattens into the top edge of the editor sheet; closing the
// editor plays the same motion in reverse. See `DropMotion` for the choreography.
//
// `progress` is the only thing that changes. The chat screen animates it inside
// `withAnimation`, so SwiftUI interpolates the shape every frame.

/// The droplet itself: a round body with an optional tail that stays attached to the
/// button until it pinches off. Animatable on `progress`.
struct DropletShape: Shape {
    var progress: CGFloat
    let buttonBottom: CGPoint
    let landing: CGPoint
    let landingWidth: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let pose = DropMotion.pose(at: progress, landingWidth: landingWidth)
        guard pose.opacity > 0 else { return Path() }

        let cx = buttonBottom.x + (landing.x - buttonBottom.x) * pose.travel
        let cy = buttonBottom.y + (landing.y - buttonBottom.y) * pose.travel + pose.height / 2
        let body = CGRect(x: cx - pose.width / 2, y: cy - pose.height / 2,
                          width: pose.width, height: pose.height)

        var path = Path()
        path.addRoundedRect(in: body, cornerSize: CGSize(width: pose.width / 2, height: min(pose.height / 2, pose.width / 2)),
                            style: .continuous)

        // Tail: a thin neck from the button down to the body, narrowing as it pinches.
        if pose.tail > 0.02 {
            let neckWidth = max(1.5, pose.width * 0.38 * pose.tail)
            let top = buttonBottom.y - 3
            let neck = CGRect(x: cx - neckWidth / 2, y: top,
                              width: neckWidth, height: max(0, body.minY + 4 - top))
            path.addRoundedRect(in: neck, cornerSize: CGSize(width: neckWidth / 2, height: neckWidth / 2),
                                style: .continuous)
        }
        return path
    }
}

struct ModelEditorDropView: View {
    /// 0 = nothing / at the button, 1 = landed as a flat bar at the bottom.
    let progress: CGFloat
    /// While true the landed bar stays on screen (waiting for the sheet); when false and
    /// `progress` is 1 it fades out because the sheet has taken over.
    let isHandedOff: Bool
    let buttonRect: CGRect
    let containerSize: CGSize

    private var landingWidth: CGFloat { min(containerSize.width * 0.62, 260) }
    private var shape: DropletShape {
        DropletShape(
            progress: progress,
            buttonBottom: CGPoint(x: buttonRect.midX, y: buttonRect.maxY - 2),
            landing: CGPoint(x: containerSize.width / 2, y: containerSize.height - 40),
            landingWidth: landingWidth
        )
    }

    var body: some View {
        Color.clear
            .frame(width: containerSize.width, height: containerSize.height)
            .overlay { droplet }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Glass on iOS 26, frosted material with a bright edge before that.
    @ViewBuilder
    private var droplet: some View {
        if #available(iOS 26.0, *) {
            shape
                .fill(Color.white.opacity(0.001))
                .glassEffect(.regular, in: shape)
                .opacity(isHandedOff ? 0 : 1)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.stroke(Color.white.opacity(0.28), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
                .opacity(isHandedOff ? 0 : 1)
        }
    }
}
