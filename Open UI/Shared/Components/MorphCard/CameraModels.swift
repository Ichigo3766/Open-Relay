import CoreGraphics
import Foundation

// MARK: - Camera Models

/// A detected document outline in normalized image space (origin bottom-left,
/// matching Vision and Core Image).
nonisolated struct DocumentQuad: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Largest corner movement between two outlines (normalized units).
    func distance(to other: DocumentQuad) -> CGFloat {
        zip(corners, other.corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
    }

    /// Rough area in normalized units (shoelace formula).
    var area: CGFloat {
        let p = corners
        var sum: CGFloat = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}

/// Zoom capabilities of the active camera, in the native "display" scale
/// (so the ultra-wide reads 0.5×, like the Camera app).
nonisolated struct CameraZoomInfo: Equatable, Sendable {
    /// Device zoom factor = display factor / multiplier.
    var multiplier: CGFloat = 1
    var minDisplay: CGFloat = 1
    var maxDisplay: CGFloat = 1
}

/// Live scan guidance, mirroring the system document camera.
nonisolated enum ScanGuidance: Equatable, Sendable {
    case searching      // "Position the document in view"
    case moveCloser     // "Move closer"
    case holdSteady     // "Hold steady"
    case capturing      // "Scanning…"

    var message: String {
        switch self {
        case .searching: return String(localized: "Position the document in view")
        case .moveCloser: return String(localized: "Move closer")
        case .holdSteady: return String(localized: "Hold steady")
        case .capturing: return String(localized: "Scanning…")
        }
    }
}
