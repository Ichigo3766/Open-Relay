import SwiftUI

// MARK: - DictationOverlayView

/// A recording bar that replaces the chat input field during dictation.
///
/// Observes `DictationService` directly so the waveform reacts to live
/// intensity changes without any stale-capture issues.
///
/// Layout: [✕ cancel] [engine chip] [~~~~waveform~~~~] [0:00] [■ stop]
///
/// The engine chip shows the active backend (On-Device / Server). Tapping
/// it calls `service.switchEngine()` which cleanly restarts the session on
/// the new backend while preserving any text accumulated so far.
struct DictationOverlayView: View {

    /// Live DictationService — `@Observable` ensures SwiftUI re-renders
    /// whenever `intensity`, `state`, `activeEngine`, or `recordingDuration` change.
    var service: DictationService
    var onStop: () -> Void
    var onCancel: () -> Void

    @Environment(\.theme) private var theme

    // MARK: - Waveform State

    /// Ring buffer of normalised (0–1) amplitude samples, newest on the right.
    /// Seeded with gentle random noise so the waveform is never completely flat.
    @State private var waveformSamples: [CGFloat] = DictationOverlayView.makeSeedSamples()
    @State private var sampleTimer: Timer?

    /// Tracks whether the engine switch is in progress (prevents double-taps).
    @State private var isSwitchingEngine = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: 10) {
            cancelButton
            engineChip
                .fixedSize()
            waveformArea
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                durationLabel
                stopButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(theme.brandPrimary.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(
            color: theme.isDark ? Color.black.opacity(0.3) : Color.black.opacity(0.1),
            radius: 8, x: 0, y: 2
        )
        .padding(.horizontal, 16)
        .onAppear { startSampling() }
        .onDisappear { stopSampling() }
        .onChange(of: service.state) { _, newState in
            if newState == .idle { stopSampling() }
        }
    }

    // MARK: - Cancel Button

    private var cancelButton: some View {
        Button(action: onCancel) {
            ZStack {
                Circle()
                    .fill(theme.surfaceContainer.opacity(0.8))
                    .frame(width: 32, height: 32)
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel dictation")
    }

    // MARK: - Engine Chip

    /// Tappable pill showing the active ASR backend.
    /// Tapping calls `service.switchEngine()` — the DictationService stops
    /// the current backend, flips `activeEngine`, and restarts on the new one,
    /// carrying over any text already accumulated this session.
    private var engineChip: some View {
        Button {
            guard !isSwitchingEngine else { return }
            isSwitchingEngine = true
            Haptics.play(.medium)
            Task {
                await service.switchEngine()
                isSwitchingEngine = false
            }
        } label: {
            HStack(spacing: 4) {
                if isSwitchingEngine {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(theme.brandPrimary)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: service.currentEngineIcon)
                        .scaledFont(size: 10, weight: .semibold)
                }
                Text(isSwitchingEngine ? "Switching…" : service.currentEngineName)
                    .scaledFont(size: 11, weight: .semibold)
            }
            .foregroundStyle(theme.brandPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(theme.brandPrimary.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .strokeBorder(theme.brandPrimary.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSwitchingEngine)
        .animation(.easeInOut(duration: 0.15), value: isSwitchingEngine)
        .animation(.easeInOut(duration: 0.15), value: service.activeEngine)
        .accessibilityLabel("STT engine: \(service.currentEngineName). Tap to switch.")
    }

    // MARK: - Stop Button

    private var stopButton: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .fill(theme.error.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "stop.fill")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(theme.error)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop dictation")
    }

    // MARK: - Duration Label

    private var durationLabel: some View {
        Text(formattedDuration)
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(theme.textSecondary)
            .monospacedDigit()
            .frame(minWidth: 34, alignment: .trailing)
    }

    // MARK: - Waveform Area

    @ViewBuilder
    private var waveformArea: some View {
        switch service.state {
        case .processing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.brandPrimary)
                Text("Processing…")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity)

        default:
            WaveformBarsView(samples: waveformSamples, color: theme.brandPrimary)
        }
    }

    // MARK: - Background

    private var composerBackground: Color {
        theme.isDark
            ? theme.cardBackground.opacity(0.95)
            : theme.inputBackground
    }

    // MARK: - Duration Formatting

    private var formattedDuration: String {
        let total = Int(service.recordingDuration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Waveform Sampling

    /// Polls `service.intensity` at 20 fps and pushes new samples into the ring buffer.
    ///
    /// Because `service` is `@Observable`, every `service.intensity` read inside the
    /// Timer body is always the latest value — never a stale captured copy.
    ///
    /// To prevent the waveform from looking completely flat during quiet moments,
    /// we add a small random "breathing" offset on top of the real intensity.
    private func startSampling() {
        stopSampling()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { _ in
            Task { @MainActor in
                // Normalise intensity (0–10) to 0–1
                let rawLevel = CGFloat(service.intensity) / 10.0

                // Add subtle breathing noise so the waveform never looks solid/flat.
                // When speaking, noise is tiny relative to real signal.
                // When silent, noise gives the gentle idle animation.
                let noise = CGFloat.random(in: 0.0...0.06)
                let sample = min(1.0, rawLevel + noise)

                waveformSamples.removeFirst()
                waveformSamples.append(sample)
            }
        }
    }

    private func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    // MARK: - Seed

    /// Generates a gentle randomised baseline so the waveform looks alive from frame 1.
    private static func makeSeedSamples() -> [CGFloat] {
        (0..<60).map { _ in CGFloat.random(in: 0.04...0.12) }
    }
}

// MARK: - WaveformBarsView

/// Renders an array of normalised samples (0–1) as animated vertical capsule bars.
///
/// Older samples on the left, newest on the right — matching Apple's voice
/// memo waveform style. Each bar animates smoothly between height values.
private struct WaveformBarsView: View {
    let samples: [CGFloat]
    let color: Color

    private let barWidth: CGFloat = 3.0
    private let barSpacing: CGFloat = 2.0
    private let minHeightFraction: CGFloat = 0.10

    var body: some View {
        GeometryReader { geo in
            let totalBarWidth = barWidth + barSpacing
            let count = min(samples.count, Int(geo.size.width / totalBarWidth))
            let startIndex = max(0, samples.count - count)
            let visibleSamples = Array(samples[startIndex...])

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<visibleSamples.count, id: \.self) { i in
                    let fraction = max(minHeightFraction, visibleSamples[i])
                    let barHeight = fraction * geo.size.height

                    Capsule()
                        .fill(color.opacity(barOpacity(for: i, total: visibleSamples.count)))
                        .frame(width: barWidth, height: barHeight)
                        .animation(
                            .interactiveSpring(response: 0.12, dampingFraction: 0.7),
                            value: barHeight
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 36)
    }

    /// Most-recent bars (right side) are fully opaque; older bars fade toward the left.
    private func barOpacity(for index: Int, total: Int) -> Double {
        guard total > 1 else { return 1.0 }
        let progress = Double(index) / Double(total - 1)
        // Smooth S-curve: starts at 0.25 opacity on the far left, ramps to 1.0 on the right.
        return 0.25 + 0.75 * progress
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let service = DictationService()
    return VStack(spacing: 20) {
        DictationOverlayView(
            service: service,
            onStop: {},
            onCancel: {}
        )
    }
    .padding()
    .background(Color(.systemBackground))
}
#endif
