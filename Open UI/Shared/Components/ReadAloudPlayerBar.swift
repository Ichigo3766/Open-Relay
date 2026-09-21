import SwiftUI
import UIKit
import Combine

// MARK: - Unified Read-Aloud Player
//
// Floats as an overlay in ChatDetailView. Two states:
//
//  • Collapsed — a compact self-sizing pill  ⏸ "Playing" ×
//    Tap it → spring-expands to full controls.
//    Scroll the chat → auto-collapses back to pill.
//
//  • Expanded — wider card with play/pause (server TTS),
//    speed, skip ±15s, scrubber (server TTS).
//    On-device TTS shows the waveform + stop button in the
//    pill only (no seeking available from AVSpeechSynthesizer).

struct ReadAloudPlayerBar: View {
    @Environment(\.theme) private var theme

    let player: ReadAloudPlayer?           // nil when using system/Kokoro TTS
    let readFromHere: (String) -> Void     // server TTS transcript action
    let isGenerating: Bool                 // ttsGeneratingMessageId != nil
    let isPlaying: Bool                    // speakingMessageId != nil
    let onStop: () -> Void
    let isUserScrolling: Bool              // auto-collapse trigger from ChatDetailView

    @State private var isExpanded = false
    @State private var showingTranscript = false

    private var sp: ReadAloudPlayer? { player?.isVisible == true ? player : nil }

    var body: some View {
        Group {
            if isExpanded {
                expandedCard
            } else {
                collapsedPill
            }
        }
        .onChange(of: isUserScrolling) { _, scrolling in
            if scrolling && isExpanded {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded = false
                }
            }
        }
        .sheet(isPresented: $showingTranscript) {
            if let p = sp { transcriptSheet(p) }
        }
    }

    // MARK: - Collapsed Pill

    private var collapsedPill: some View {
        HStack(spacing: 8) {
            // Icon circle
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.15))
                    .frame(width: 32, height: 32)
                pillIcon
                    .foregroundStyle(theme.brandPrimary)
            }

            // Label
            pillLabel
                .lineLimit(1)

            // Close ×
            Button {
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
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                isExpanded = true
            }
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    @ViewBuilder
    private var pillIcon: some View {
        if let p = sp {
            if p.error != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
            } else if p.isGenerating && !p.isPlaying {
                ProgressView().scaleEffect(0.6).tint(theme.brandPrimary)
            } else {
                Image(systemName: p.wantsPlayback ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
        } else {
            Image(systemName: isGenerating ? "waveform" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.variableColor.iterative.reversing, isActive: isPlaying || isGenerating)
        }
    }

    @ViewBuilder
    private var pillLabel: some View {
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

    // MARK: - Expanded Card

    private var expandedCard: some View {
        VStack(spacing: 0) {
            // Top row: icon + title + close
            HStack(spacing: 10) {
                // Tappable icon for play/pause (server) or nothing (on-device)
                ZStack {
                    Circle()
                        .fill(theme.brandPrimary.opacity(0.15))
                        .frame(width: 38, height: 38)
                    expandedIcon
                        .foregroundStyle(theme.brandPrimary)
                }
                .onTapGesture {
                    if let p = sp {
                        if p.error != nil { p.retry() }
                        else { p.togglePlayback() }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(sp?.title ?? "Playing")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    expandedSubtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded = false
                    }
                    if let p = sp { p.stop() }
                    onStop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, sp != nil ? 4 : 12)

            // Server TTS controls
            if let p = sp {
                Divider().padding(.horizontal, 10)

                serverControls(p)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var expandedIcon: some View {
        if let p = sp {
            if p.error != nil {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
            } else if p.isGenerating && !p.isPlaying {
                ProgressView().scaleEffect(0.7).tint(theme.brandPrimary)
            } else {
                Image(systemName: p.wantsPlayback ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
        } else {
            Image(systemName: isGenerating ? "waveform" : "speaker.wave.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .symbolEffect(.variableColor.iterative.reversing, isActive: isPlaying || isGenerating)
        }
    }

    @ViewBuilder
    private var expandedSubtitle: some View {
        if let p = sp {
            if let err = p.error {
                Text(err).font(.caption2).foregroundStyle(theme.error).lineLimit(1)
            } else if p.isGenerating && !p.isPlaying {
                Text(p.canSeek ? "Buffering…" : "Preparing…").font(.caption2).foregroundStyle(.secondary)
            } else if p.bufferedDuration > 0 {
                HStack(spacing: 5) {
                    Text(ReadAloudPlayerBar.fmtTime(p.elapsed))
                        .font(.system(.caption2, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(height: 2)
                            Capsule()
                                .fill(theme.brandPrimary)
                                .frame(width: geo.size.width * min(p.bufferedDuration > 0 ? p.elapsed / p.bufferedDuration : 0, 1), height: 2)
                        }
                    }
                    .frame(height: 4)
                }
            } else {
                Text("Ready").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text(isGenerating ? "Preparing…" : "Playing").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Server TTS Controls

    private func serverControls(_ p: ReadAloudPlayer) -> some View {
        VStack(spacing: 8) {
            // Scrubber
            if p.canSeek, let dur = p.duration, dur > 0 {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(get: { p.elapsed }, set: { p.seek(to: $0) }),
                        in: 0...dur
                    )
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, 4)
                    HStack {
                        Text(ReadAloudPlayerBar.fmtTime(p.elapsed))
                        Spacer()
                        Text(ReadAloudPlayerBar.fmtTime(dur))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }
                .padding(.top, 6)
            }

            // Transport: ⏮  1×  ⏭
            HStack(spacing: 0) {
                Spacer()
                ctlBtn("gobackward.15", size: 22) { p.skip(-15) }
                    .disabled(!p.canSeek || p.elapsed <= 0)
                Spacer()
                Button { p.cycleRate() } label: {
                    Text(ReadAloudPlayerBar.fmtRate(p.rate))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .frame(width: 50, height: 40)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(theme.textPrimary)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                Spacer()
                ctlBtn("goforward.15", size: 22) { p.skip(15) }
                    .disabled(!p.canSeek || p.elapsed >= p.bufferedDuration)
                Spacer()
            }
            .padding(.bottom, 2)

            // Transcript
            if !p.transcript.isEmpty {
                Button { showingTranscript = true } label: {
                    Label("View Transcript", systemImage: "text.quote")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func ctlBtn(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 48, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                            Text(ReadAloudPlayerBar.fmtTime(p.elapsed))
                            Spacer()
                            Text(ReadAloudPlayerBar.fmtTime(dur))
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

    // MARK: - Helpers

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
        v.accessibilityIdentifier = "speech.transcript"
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
        context.coordinator.readFromHere = readFromHere
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var readFromHere: (String) -> Void
        init(readFromHere: @escaping (String) -> Void) { self.readFromHere = readFromHere }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let text = textView.text, range.location < (text as NSString).length else { return nil }
            let suffix = (text as NSString).substring(from: range.location)
            let action = UIAction(title: "Play from here", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                self?.readFromHere(suffix)
            }
            return UIMenu(children: [action] + suggestedActions)
        }
    }
}
