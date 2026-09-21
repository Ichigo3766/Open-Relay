import SwiftUI
import UIKit
import Combine

// MARK: - Main Player Bar

struct ReadAloudPlayerBar: View {
    @Environment(\.theme) private var theme
    let player: ReadAloudPlayer
    /// Called when "Play from here" is tapped (server TTS only)
    let readFromHere: (String) -> Void

    @State private var isExpanded = false
    @State private var showingTranscript = false

    private var isSeekable: Bool { player.canSeek }
    private var showProgress: Bool { player.bufferedDuration > 0 }

    var body: some View {
        VStack(spacing: 0) {
            // Compact bar — always visible
            compactBar
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }

            // Expanded controls — slides in below
            if isExpanded {
                expandedControls
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
            }

            // Error banner
            if let error = player.error {
                errorBanner(error)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .sheet(isPresented: $showingTranscript) {
            transcriptSheet
        }
    }

    // MARK: - Compact Bar

    private var compactBar: some View {
        HStack(spacing: 10) {
            // Play/Pause/Retry button
            playPauseButton
                .frame(width: 44, height: 44)

            // Center — title + progress
            VStack(alignment: .leading, spacing: 2) {
                Text(player.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(theme.textPrimary)

                progressLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Expand chevron
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 44)

            // Close button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded = false
                }
                player.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close audio player")
            .accessibilityIdentifier("speech.close")
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Play/Pause Button

    private var playPauseButton: some View {
        Button {
            if player.error != nil {
                player.retry()
            } else {
                player.togglePlayback()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.12))
                    .frame(width: 36, height: 36)

                Group {
                    if player.error != nil {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.brandPrimary)
                    } else if player.isGenerating && !player.isPlaying {
                        // Buffering spinner
                        ProgressView()
                            .scaleEffect(0.75)
                            .tint(theme.brandPrimary)
                    } else {
                        Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.brandPrimary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.error != nil ? "Retry audio" : (player.wantsPlayback ? "Pause" : "Play"))
        .accessibilityIdentifier("speech.playPause")
    }

    // MARK: - Progress Line

    private var progressLine: some View {
        HStack(spacing: 6) {
            if player.isGenerating && !player.isPlaying && player.wantsPlayback {
                Text(player.canSeek ? "Buffering…" : "Preparing…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if showProgress {
                Text(Self.formatTime(player.elapsed))
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                // Thin inline progress track
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.tertiary)
                            .frame(height: 2)
                        let progress = player.bufferedDuration > 0
                            ? min(player.elapsed / player.bufferedDuration, 1.0)
                            : 0
                        Capsule()
                            .fill(theme.brandPrimary)
                            .frame(width: geo.size.width * progress, height: 2)
                    }
                }
                .frame(height: 6)
            } else {
                Text("Ready")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Expanded Controls

    private var expandedControls: some View {
        VStack(spacing: 12) {
            Divider().padding(.horizontal, 6)

            // Scrubber (seekable only)
            if isSeekable, let duration = player.duration, duration > 0 {
                scrubberRow(duration: duration)
            }

            // Transport row
            transportRow

            // Transcript button (server TTS — has transcript)
            if !player.transcript.isEmpty {
                Button {
                    showingTranscript = true
                } label: {
                    Label("View Transcript", systemImage: "text.quote")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Scrubber

    private func scrubberRow(duration: Double) -> some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.elapsed },
                    set: { player.seek(to: $0) }
                ),
                in: 0...duration
            )
            .tint(theme.brandPrimary)
            .padding(.horizontal, 8)
            .accessibilityLabel("Audio position")
            .accessibilityIdentifier("speech.position")

            HStack {
                Text(Self.formatTime(player.elapsed))
                Spacer()
                Text(Self.formatTime(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Transport Row

    private var transportRow: some View {
        HStack(spacing: 0) {
            Spacer()

            // Skip back 15s
            transportButton("gobackward.15", label: "Back 15 seconds", id: "speech.back") {
                player.skip(-15)
            }
            .disabled(!isSeekable || player.elapsed <= 0)

            Spacer()

            // Speed button
            Button {
                player.cycleRate()
            } label: {
                Text(Self.formatRate(player.rate))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 52, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(theme.textPrimary)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed: \(Self.formatRate(player.rate))")
            .accessibilityIdentifier("speech.speed")

            Spacer()

            // Skip forward 15s
            transportButton("goforward.15", label: "Forward 15 seconds", id: "speech.forward") {
                player.skip(15)
            }
            .disabled(!isSeekable || player.elapsed >= player.bufferedDuration)

            Spacer()
        }
        .padding(.bottom, 4)
    }

    private func transportButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.error)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.error)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityIdentifier("speech.error")
    }

    // MARK: - Transcript Sheet

    private var transcriptSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let duration = player.duration, duration > 0 {
                    VStack {
                        Slider(
                            value: Binding(get: { player.elapsed }, set: { player.seek(to: $0) }),
                            in: 0...duration
                        )
                        .tint(theme.brandPrimary)
                        .accessibilityLabel("Audio position")
                        .accessibilityIdentifier("speech.position")

                        HStack {
                            Text(Self.formatTime(player.elapsed))
                            Spacer()
                            Text(Self.formatTime(duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                Text("Select a word, then choose \"Play from here\".")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                SpeechTranscriptView(text: player.transcript) { suffix in
                    showingTranscript = false
                    readFromHere(suffix)
                }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingTranscript = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Helpers

    private static func formatTime(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }

    private static func formatRate(_ rate: Float) -> String {
        if rate == 1.0 { return "1×" }
        let formatted = rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f×", rate)
            : String(format: "%.2g×", rate)
        return formatted
    }
}

// MARK: - Simple Player Bar (System / On-Device TTS)

/// Shown when TTS engine is not server-based (system / Kokoro / Qwen3).
/// No seeking — just play/pause/stop with a pulsing "Playing…" indicator.
struct SimpleReadAloudPlayerBar: View {
    @Environment(\.theme) private var theme
    let title: String
    let isGenerating: Bool
    let isPlaying: Bool
    let onStop: () -> Void

    @State private var dotPhase: Int = 0
    private let dotTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            // Animated wave icon
            Image(systemName: isGenerating ? "waveform" : "speaker.wave.2.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.brandPrimary)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying || isGenerating)
                .frame(width: 36, height: 36)
                .background(theme.brandPrimary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(theme.textPrimary)
                Text(isGenerating ? "Preparing…" : "Playing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onStop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop audio")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

// MARK: - Transcript UITextView

/// Native selection preserves exact text offsets without inventing audio word timestamps.
private struct SpeechTranscriptView: UIViewRepresentable {
    let text: String
    let readFromHere: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(readFromHere: readFromHere) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "speech.transcript"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        context.coordinator.readFromHere = readFromHere
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var readFromHere: (String) -> Void
        init(readFromHere: @escaping (String) -> Void) { self.readFromHere = readFromHere }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0,
                  let text = textView.text,
                  range.location < (text as NSString).length else { return nil }
            let suffix = (text as NSString).substring(from: range.location)
            let action = UIAction(title: "Play from here", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                self?.readFromHere(suffix)
            }
            return UIMenu(children: [action] + suggestedActions)
        }
    }
}
