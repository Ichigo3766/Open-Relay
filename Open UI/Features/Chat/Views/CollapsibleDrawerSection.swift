import SwiftUI

/// A collapsible section header + content used in the chat drawer.
///
/// Tapping the header toggles the section open/closed with a smooth
/// chevron rotation animation. State is kept locally — no server sync needed.
struct CollapsibleDrawerSection<Content: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header (tap to collapse/expand) ──────────────────────
            Button {
                withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                    isExpanded.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.easeInOut(duration: AnimDuration.fast), value: isExpanded)

                    Text(title)
                        .font(AppTypography.captionFont)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    if let count {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.surfaceContainer)
                            .clipShape(Capsule())
                    }

                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── Content (hidden when collapsed) ──────────────────────
            if isExpanded {
                content()
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
