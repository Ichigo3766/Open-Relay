import SwiftUI
import UIKit
import Combine

// MARK: - Unified Read-Aloud Player
//
// One component for ALL TTS engines. Uses a single continuous VStack so
// SwiftUI morphs it smoothly — no view-swap, no cut transitions.
//
//  Collapsed:  compact pill  ▶ "Playing"  ∨  ×
//  Expanded:   same pill top + controls revealed below via opacity/height
//
// Server TTS:   play/pause, speed, skip ±15s, scrubber, transcript
// On-device:    stop button, animated waveform (no seeking available)

struct ReadAloudPlayerBar: View {
    @Environment(\.theme) private var theme

    let player: ReadAloudPlayer?           // nil for on-device/system TTS
    let readFromHere: (String) -> Void
    let isGenerating: Bool                 // ttsGeneratingMessageId != nil
    let isPlaying: Bool                    // speakingMessageId != nil
    let onStop: () -> Void
    let isUserScrolling: Bool

    @State private var isExpanded = false
    @State private var showingTranscript = false

    // Server player shorthand
    private var sp: ReadAloudPlayer? { player?.isVisible == true ? player : nil }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top pill row (always visible) ─────────────────────────
            pillRow
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                        isExpanded.toggle()
                    }
                }

            // ── Expanded controls (animates in/out) ───────────────────
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .transition(.opacity)

                controlsBody
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: isExpanded ? 20 : 999))
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: isExpanded)
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .onChange(of: isUserScrolling) { _, scrolling in
            if scrolling && isExpanded {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    isExpanded = false
                }
            }
        }
        .sheet(isPresented: $showingTranscript) {
            if let p = sp { transcriptSheet(p) }
        }
    }

    // MARK: - Pill Row

    private var pillRow: some View {
        HStack(spacing: 8) {
            // Leading icon
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.15))
                    .frame(width: 32, height: 32)
                leadingIcon
            }

            // Label
            statusLabel

            // Chevron
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            // Close
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    isExpanded = false
                }
                if let p = sp { p.stop() }
                onStop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Leading Icon

    @ViewBuilder
    private var leadingIcon: some View {
        if let p = sp {
            if p.error != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.error)
            } else if p.isGenerating && !p.isPlaying {
                ProgressView().scaleEffect(0.6).tint(theme.brandPrimary)
            } else {
                Image(systemName: p.wantsPlayback ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.brandPrimary)
                    .contentTransition(.symbolEffect(.replace))
            }
        } else {
            Image(systemName: isGenerating ? "waveform" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.brandPrimary)
                .symbolEffect(.variableColor.iterative.reversing, isActive: isPlaying || isGenerating)
        }
    }

    // MARK: - Status Label

    @ViewBuilder
    private var statusLabel: some View {
        if let p = sp {
            if p.bufferedDuration > 0 {
                Text(ReadAloudPlayerBar.fmtTime(p.elapsed))
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
            } else {
                Text(p.isGenerating ? "Preparing…" : "Playing")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
            }
        } else {
            Text(isGenerating ? "Preparing…" : "Playing")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.textPrimary)
        }
    }

    // MARK: - Controls Body (shown when expanded)

    @ViewBuilder
    private var controlsBody: some View {
        if let p = sp {
            serverControls(p)
        } else {
            onDeviceControls
        }
    }

    // MARK: - Server TTS Controls

    private func serverControls(_ p: ReadAloudPlayer) -> some View {
        VStack(spacing: 10) {
            // Error message if any
            if let err = p.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(theme.error)
                    Text(err).font(.caption2).foregroundStyle(theme.error).lineLimit(2)
                }
                .padding(.horizontal, 14)
            }

            // Scrubber — shown once we have buffered duration
            if p.bufferedDuration > 0, let dur = p.duration, dur > 0 {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(get: { p.elapsed }, set: { p.seek(to: $0) }),
                        in: 0...dur
                    )
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, 10)

                    HStack {
                        Text(ReadAloudPlayerBar.fmtTime(p.elapsed))
                        Spacer()
                        Text(ReadAloudPlayerBar.fmtTime(dur))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                }
            } else if p.bufferedDuration > 0 {
                // Buffered but duration unknown yet — show thin progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 3)
                        Capsule()
                            .fill(theme.brandPrimary)
                            .frame(width: geo.size.width * 0.3, height: 3)
                            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: p.isPlaying)
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 14)
            }

            // Transport: ⏮  ▶/⏸  1×  ⏭
            HStack(spacing: 0) {
                Spacer()

                // Skip back
                ctlBtn("gobackward.15", size: 22) { p.skip(-15) }
                    .disabled(!p.canSeek || p.elapsed <= 0)

                Spacer()

                // Play / Pause / Retry (large center button)
                Button {
                    if p.error != nil { p.retry() }
                    else { p.togglePlayback() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme.brandPrimary.opacity(0.15))
                            .frame(width: 48, height: 48)
                        Group {
                            if p.error != nil {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18, weight: .semibold))
                            } else if p.isGenerating && !p.isPlaying {
                                ProgressView().scaleEffect(0.8).tint(theme.brandPrimary)
                            } else {
                                Image(systemName: p.wantsPlayback ? "pause.fill" : "play.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.wantsPlayback ? "Pause" : "Play")

                Spacer()

                // Speed
                Button { p.cycleRate() } label: {
                    Text(ReadAloudPlayerBar.fmtRate(p.rate))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .frame(width: 48, height: 40)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(theme.textPrimary)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)

                Spacer()

                // Skip forward
                ctlBtn("goforward.15", size: 22) { p.skip(15) }
                    .disabled(!p.canSeek || p.elapsed >= p.bufferedDuration)

                Spacer()
            }

            // Transcript button
            if !p.transcript.isEmpty {
                Button { showingTranscript = true } label: {
                    Label("View Transcript", systemImage: "text.quote")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - On-Device Controls

    private var onDeviceControls: some View {
        VStack(spacing: 12) {
            // Animated waveform indicator
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    WaveBar(index: i, isActive: isPlaying || isGenerating, color: theme.brandPrimary)
                }
            }
            .frame(height: 28)

            // Status
            Text(isGenerating ? "Generating speech…" : "On-device TTS playing")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Stop button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    isExpanded = false
                }
                onStop()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .medium))
                    Text("Stop")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(theme.brandPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(theme.brandPrimary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            Text("Seeking is not available for on-device TTS")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func ctlBtn(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func fmtTime(_ s: Double) -> String {
        let v = Int(max(0, s))
        return v >= 3600
            ? String(format: "%d:%02d:%02d", v/3600, v/60%60, v%60)
            : String(format: "%d:%02d", v/60, v%60)
    }

    static func fmtRate(_ r: Float) -> String {
        r == 1.0 ? "1×"
            : r.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f×", r)
            : String(format: "%.2g×", r)
    }

    // MARK: - Transcript Sheet

    private func transcriptSheet(_ p: ReadAloudPlayer) -> some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let dur = p.duration, dur > 0 {
                    VStack {
                        Slider(value: Binding(get: { p.elapsed }, set: { p.seek(to: $0) }), in: 0...dur)
                            .tint(theme.brandPrimary)
                        HStack {
                            Text(Self.fmtTime(p.elapsed))
                            Spacer()
                            Text(Self.fmtTime(dur))
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showingTranscript = false }
            }}
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Animated Wave Bar

private struct WaveBar: View {
    let index: Int
    let isActive: Bool
    let color: Color

    @State private var height: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(isActive ? 0.8 : 0.3))
            .frame(width: 3, height: height)
            .onAppear { animateIfNeeded() }
            .onChange(of: isActive) { _, active in
                if active { animateIfNeeded() }
                else {
                    withAnimation(.easeOut(duration: 0.2)) { height = 4 }
                }
            }
    }

    private func animateIfNeeded() {
        guard isActive else { return }
        let delay = Double(index) * 0.1
        withAnimation(
            Animation.easeInOut(duration: 0.4 + Double(index) * 0.05)
                .repeatForever(autoreverses: true)
                .delay(delay)
        ) {
            height = CGFloat.random(in: 8...24)
        }
    }
}

// MARK: - Transcript UITextView

private struct SpeechTranscriptView: UIViewRepresentable {
    let text: String
    let readFromHere: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(readFromHere: readFromHere) }
    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false; v.isSelectable = true; v.backgroundColor = .clear
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
        v.delegate = context.coordinator
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
        context.coordinator.readFromHere = readFromHere
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var readFromHere: (String) -> Void
        init(readFromHere: @escaping (String) -> Void) { self.readFromHere = readFromHere }
        func textView(_ tv: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let text = tv.text, range.location < (text as NSString).length else { return nil }
            let suffix = (text as NSString).substring(from: range.location)
            let action = UIAction(title: "Play from here", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                self?.readFromHere(suffix)
            }
            return UIMenu(children: [action] + suggestedActions)
        }
    }
}
