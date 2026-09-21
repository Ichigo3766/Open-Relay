import SwiftUI
import UIKit
import Combine

// MARK: - Unified Read-Aloud Player
//
// One component for ALL TTS engines (server, Kokoro, system).
// Two visual states driven by `isExpanded`:
//
//  • Collapsed — a compact pill showing a waveform icon + "Playing"
//    (or elapsed time for server TTS) + a close ×.
//    Auto-collapses when the user scrolls the chat (via `isUserScrolling`).
//
//  • Expanded — full controls with play/pause, speed, skip ±15s (server),
//    scrubber (server), and transcript (server). Tap the pill or scroll
//    to collapse back.

struct ReadAloudPlayerBar: View {
    @Environment(\.theme) private var theme

    // ── Server TTS player (nil for on-device/system TTS) ──────────────
    let player: ReadAloudPlayer?
    /// Called when "Play from here" is tapped in the transcript sheet.
    let readFromHere: (String) -> Void

    // ── On-device / system TTS state ──────────────────────────────────
    let isGenerating: Bool   // ttsGeneratingMessageId != nil
    let isPlaying: Bool      // speakingMessageId != nil
    let onStop: () -> Void   // called for all TTS types to stop

    // ── Collapse trigger from ChatDetailView ──────────────────────────
    /// Set to true by ChatDetailView when the user starts scrolling.
    /// Automatically collapses the player back to pill state.
    let isUserScrolling: Bool

    // ── Local UI state ─────────────────────────────────────────────────
    @State private var isExpanded = false
    @State private var showingTranscript = false

    // Server-TTS convenience flags
    private var serverPlayer: ReadAloudPlayer? { player?.isVisible == true ? player : nil }
    private var isServerMode: Bool { serverPlayer != nil }
    private var canSeek: Bool { serverPlayer?.canSeek ?? false }
    private var showProgress: Bool { (serverPlayer?.bufferedDuration ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 0) {
            pillRow
                .contentShape(Rectangle())            // ← blocks tap-through
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        isExpanded.toggle()
                    }
                }

            if isExpanded {
                expandedPanel
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -6)),
                        removal:   .opacity.combined(with: .offset(y: -6))
                    ))
            }
        }
        // Solid blocking background so taps never fall through to the chat
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: isExpanded ? 18 : 22))
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, isExpanded ? 8 : 4)
        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        // Auto-collapse on scroll
        .onChange(of: isUserScrolling) { _, scrolling in
            if scrolling && isExpanded {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded = false
                }
            }
        }
        .sheet(isPresented: $showingTranscript) {
            if let p = serverPlayer {
                transcriptSheet(player: p)
            }
        }
    }

    // MARK: - Pill Row (always visible)

    private var pillRow: some View {
        HStack(spacing: 10) {
            // ── Leading icon ────────────────────────────────────────────
            leadingIcon
                .frame(width: 36, height: 36)

            // ── Center label ────────────────────────────────────────────
            centerLabel
                .frame(maxWidth: .infinity, alignment: .leading)

            // ── Expand/collapse chevron ─────────────────────────────────
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 36)

            // ── Close / stop ────────────────────────────────────────────
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded = false
                }
                if let p = serverPlayer { p.stop() }
                onStop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop audio")
            .accessibilityIdentifier("speech.close")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Leading icon (waveform / play / pause / spinner)

    @ViewBuilder
    private var leadingIcon: some View {
        ZStack {
            Circle()
                .fill(theme.brandPrimary.opacity(0.14))

            if let p = serverPlayer {
                // Server TTS — tap icon to toggle playback
                Button {
                    if p.error != nil { p.retry() }
                    else { p.togglePlayback() }
                } label: {
                    serverIconImage(player: p)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.wantsPlayback ? "Pause" : "Play")
                .accessibilityIdentifier("speech.playPause")
            } else {
                // On-device TTS — tap icon to stop
                Button { onStop() } label: {
                    Image(systemName: isGenerating ? "waveform" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.brandPrimary)
                        .symbolEffect(.variableColor.iterative.reversing,
                                      isActive: isPlaying || isGenerating)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop audio")
            }
        }
    }

    @ViewBuilder
    private func serverIconImage(player p: ReadAloudPlayer) -> some View {
        if p.error != nil {
            Image(systemName: "arrow.clockwise")
        } else if p.isGenerating && !p.isPlaying {
            ProgressView().scaleEffect(0.65).tint(theme.brandPrimary)
        } else {
            Image(systemName: p.wantsPlayback ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
        }
    }

    // MARK: - Center label (title + status/progress)

    private var centerLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Title
            if let p = serverPlayer {
                Text(p.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(theme.textPrimary)
            } else {
                Text(isGenerating ? "Preparing…" : "Playing")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
            }

            // Progress / status
            if let p = serverPlayer {
                serverProgressLabel(player: p)
            } else {
                Text("Tap to stop")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func serverProgressLabel(player p: ReadAloudPlayer) -> some View {
        if let err = p.error {
            Text(err)
                .font(.caption2)
                .foregroundStyle(theme.error)
                .lineLimit(1)
        } else if p.isGenerating && !p.isPlaying && p.wantsPlayback {
            Text(p.canSeek ? "Buffering…" : "Preparing…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if showProgress {
            HStack(spacing: 5) {
                Text(Self.formatTime(p.elapsed))
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                // Thin inline track
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 2)
                        let pct = p.bufferedDuration > 0
                            ? min(p.elapsed / p.bufferedDuration, 1.0) : 0
                        Capsule()
                            .fill(theme.brandPrimary)
                            .frame(width: geo.size.width * pct, height: 2)
                    }
                }
                .frame(height: 4)
            }
        } else {
            Text("Ready")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Expanded Panel

    @ViewBuilder
    private var expandedPanel: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 8).padding(.top, 2)

            if let p = serverPlayer {
                // ── Full server-TTS controls ───────────────────────────
                serverControls(player: p)
            } else {
                // ── On-device controls (no seeking) ────────────────────
                onDeviceControls
            }
        }
    }

    // MARK: - Server TTS controls

    private func serverControls(player p: ReadAloudPlayer) -> some View {
        VStack(spacing: 10) {
            // Scrubber
            if canSeek, let dur = p.duration, dur > 0 {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(get: { p.elapsed }, set: { p.seek(to: $0) }),
                        in: 0...dur
                    )
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Audio position")
                    .accessibilityIdentifier("speech.position")

                    HStack {
                        Text(Self.formatTime(p.elapsed))
                        Spacer()
                        Text(Self.formatTime(dur))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }
                .padding(.top, 6)
            }

            // Transport row: ⏮  1×  ⏭
            HStack(spacing: 0) {
                Spacer()
                iconButton("gobackward.15", label: "Back 15s", id: "speech.back", size: 22) {
                    p.skip(-15)
                }
                .disabled(!canSeek || p.elapsed <= 0)
                Spacer()

                Button { p.cycleRate() } label: {
                    Text(Self.formatRate(p.rate))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .frame(width: 52, height: 40)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(theme.textPrimary)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speed: \(Self.formatRate(p.rate))")
                .accessibilityIdentifier("speech.speed")
                Spacer()

                iconButton("goforward.15", label: "Forward 15s", id: "speech.forward", size: 22) {
                    p.skip(15)
                }
                .disabled(!canSeek || p.elapsed >= p.bufferedDuration)
                Spacer()
            }
            .padding(.bottom, 2)

            // Transcript
            if !p.transcript.isEmpty {
                Button { showingTranscript = true } label: {
                    Label("View Transcript", systemImage: "text.quote")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: - On-device controls (system / Kokoro / Qwen3)

    private var onDeviceControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                // Big stop button
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded = false
                    }
                    onStop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(theme.brandPrimary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop audio")
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Text("On-device TTS — no scrubbing available")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Helpers

    private func iconButton(_ symbol: String, label: String, id: String,
                             size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 48, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private static func formatTime(_ seconds: Double) -> String {
        let v = Int(max(0, seconds))
        return v >= 3600
            ? String(format: "%d:%02d:%02d", v / 3600, v / 60 % 60, v % 60)
            : String(format: "%d:%02d", v / 60, v % 60)
    }

    private static func formatRate(_ rate: Float) -> String {
        rate == 1.0 ? "1×" :
        rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f×", rate)
            : String(format: "%.2g×", rate)
    }

    // MARK: - Transcript Sheet

    private func transcriptSheet(player p: ReadAloudPlayer) -> some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let dur = p.duration, dur > 0 {
                    VStack {
                        Slider(
                            value: Binding(get: { p.elapsed }, set: { p.seek(to: $0) }),
                            in: 0...dur
                        )
                        .tint(theme.brandPrimary)
                        .accessibilityLabel("Audio position")
                        .accessibilityIdentifier("speech.position")
                        HStack {
                            Text(Self.formatTime(p.elapsed))
                            Spacer()
                            Text(Self.formatTime(dur))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                Text("Select a word, then choose \"Play from here\".")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                SpeechTranscriptView(text: p.transcript) { suffix in
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
}

// MARK: - Transcript UITextView

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

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0,
                  let text = textView.text,
                  range.location < (text as NSString).length else { return nil }
            let suffix = (text as NSString).substring(from: range.location)
            let action = UIAction(title: "Play from here",
                                  image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                self?.readFromHere(suffix)
            }
            return UIMenu(children: [action] + suggestedActions)
        }
    }
}
