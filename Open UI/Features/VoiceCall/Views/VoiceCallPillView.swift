import SwiftUI

/// A compact floating square pill that appears when a voice call is minimized.
/// Fixed in the top-trailing corner. Tap to restore the full voice call sheet.
struct VoiceCallPillView: View {
    let viewModel: VoiceCallViewModel
    let onExpand: () -> Void
    let onEndCall: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Main tappable square — tap anywhere to expand
            Button(action: onExpand) {
                VStack(spacing: 5) {
                    StateDotView(state: viewModel.callState)

                    Text(viewModel.formattedDuration)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .contentTransition(.numericText())
                }
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 5)
            }
            .buttonStyle(.plain)

            // Small end-call badge in the corner
            Button(action: onEndCall) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.red, in: Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
        }
        .transition(
            .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
        )
    }
}

// MARK: - State Dot

private struct StateDotView: View {
    let state: VoiceCallViewModel.CallState
    @State private var pulsing = false

    var body: some View {
        ZStack {
            // Outer pulse ring
            Circle()
                .fill(dotColor.opacity(0.3))
                .frame(width: 18, height: 18)
                .scaleEffect(pulsing ? 1.6 : 1.0)
                .opacity(pulsing ? 0 : 0.5)

            // Core dot
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
        }
        .frame(width: 18, height: 18)
        .onAppear { startPulse() }
        .onChange(of: state) { _, _ in startPulse() }
    }

    private var dotColor: Color {
        switch state {
        case .listening:    return .blue
        case .speaking:     return .green
        case .processing:   return .purple
        case .paused:       return .orange
        case .connecting:   return .white.opacity(0.6)
        default:            return .gray
        }
    }

    private var shouldAnimate: Bool {
        switch state {
        case .listening, .speaking, .processing, .connecting: return true
        default: return false
        }
    }

    private func startPulse() {
        pulsing = false
        guard shouldAnimate else { return }
        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
            pulsing = true
        }
    }
}
