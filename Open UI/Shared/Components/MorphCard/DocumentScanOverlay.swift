import SwiftUI

// MARK: - Live Outline + Guidance

struct DocumentScanOverlay: View {
    let quad: DocumentQuad?
    let guidance: ScanGuidance

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let quad {
                    let outline = Self.path(for: quad, in: geo.size)
                    outline.fill(Color.yellow.opacity(guidance == .capturing ? 0.32 : 0.18))
                    outline.stroke(Color.yellow, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                }
                Text(guidance.message)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .contentTransition(.opacity)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.42)
            }
            .animation(.easeOut(duration: 0.12), value: quad)
            .animation(.easeOut(duration: 0.2), value: guidance)
        }
    }

    /// Vision coordinates are normalized to the portrait 3:4 frame with a bottom-left
    /// origin; the preview is aspect-filled, so map through the fill rect.
    static func path(for quad: DocumentQuad, in size: CGSize) -> Path {
        let frameAspect: CGFloat = 3.0 / 4.0
        let fillWidth = max(size.width, size.height * frameAspect)
        let fillHeight = fillWidth / frameAspect
        let originX = (size.width - fillWidth) / 2
        let originY = (size.height - fillHeight) / 2
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: originX + p.x * fillWidth, y: originY + (1 - p.y) * fillHeight)
        }
        return Path { path in
            path.move(to: map(quad.topLeft))
            path.addLine(to: map(quad.topRight))
            path.addLine(to: map(quad.bottomRight))
            path.addLine(to: map(quad.bottomLeft))
            path.closeSubpath()
        }
    }
}

// MARK: - Page Stack

/// Thumbnails of captured pages stacked with a count badge (like the system scanner).
struct ScannedPageStack: View {
    let pages: [UIImage]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ForEach(Array(pages.suffix(3).enumerated()), id: \.offset) { index, page in
                    let depth = CGFloat(min(pages.count, 3) - 1 - index)
                    Image(uiImage: page)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                        .rotationEffect(.degrees(Double(depth) * -5))
                        .offset(x: -depth * 3)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                }
            }
            if !pages.isEmpty {
                Text("\(pages.count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(Color.yellow))
                    .offset(x: 8, y: -8)
                    .contentTransition(.numericText(value: Double(pages.count)))
            }
        }
        .animation(MorphCardMetrics.controlSpring, value: pages.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pages.count) pages scanned")
    }
}
