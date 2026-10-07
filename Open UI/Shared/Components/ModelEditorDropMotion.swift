import SwiftUI

// MARK: - Model Editor Drop: Motion
//
// The whole drop is one continuous motion described by a single number, `t`, from
// 0 to 1. Everything (position, stretch, tail, glow) is a pure function of `t`, so the
// chat screen only has to animate `t` and the result is always smooth and reversible.
//
//   0.00 ─ 0.28  swell:  a bead grows at the button's lower edge, tail attached
//   0.28 ─ 0.40  pinch:  the tail thins and breaks, the bead hangs for a beat
//   0.40 ─ 0.82  fall:   gravity — slow start, stretching tall as it speeds up
//   0.82 ─ 1.00  splat:  squashes wide and flat, ready to become the sheet's top edge

struct DropPose {
    /// Centre of the body, as fractions of travel: 0 = at the button, 1 = at the landing.
    var travel: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// How much of the connecting tail remains (1 = fully attached, 0 = gone).
    var tail: CGFloat
    var opacity: Double
}

enum DropMotion {
    /// Linear 0…1 helper.
    private static func norm(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        min(1, max(0, (t - a) / (b - a)))
    }
    private static func easeOut(_ x: CGFloat) -> CGFloat { 1 - pow(1 - x, 3) }
    private static func easeInQuad(_ x: CGFloat) -> CGFloat { x * x }
    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat { a + (b - a) * x }

    /// - Parameters:
    ///   - t: progress of the motion, 0…1.
    ///   - landingWidth: width of the flat bar the drop lands as.
    static func pose(at t: CGFloat, landingWidth: CGFloat) -> DropPose {
        let swell = easeOut(norm(t, 0.0, 0.28))
        let pinch = norm(t, 0.28, 0.40)
        let fall = easeInQuad(norm(t, 0.40, 0.82))
        let splat = easeOut(norm(t, 0.82, 1.0))

        // Position: hangs just below the button while swelling, then falls with gravity.
        let hang: CGFloat = 0.02 * swell
        let travel = hang + (1 - hang) * fall

        // Size: round while swelling, stretched while falling fast, flat on landing.
        let speed = norm(t, 0.40, 0.82)          // 0 → 1 across the fall
        let stretch = 1 + 0.75 * sin(speed * .pi / 2) * (1 - splat)
        let baseWidth = lerp(6, 24, swell)
        let width = lerp(baseWidth / sqrt(stretch), landingWidth, splat)
        let height = lerp(baseWidth * stretch * 1.15, 8, splat)

        // Tail: attached through the swell, thins during the pinch, gone for the fall.
        let tail = (1 - pinch) * swell

        return DropPose(travel: travel, width: width, height: height, tail: tail,
                        opacity: t <= 0.001 ? 0 : 1)
    }
}
