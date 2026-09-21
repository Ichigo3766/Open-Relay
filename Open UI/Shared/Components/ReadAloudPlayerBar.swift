import SwiftUI
import UIKit

struct ReadAloudPlayerBar: View {
    @Environment(\.theme) private var theme
    let player: ReadAloudPlayer
    let readFromHere: (String) -> Void
    @State private var showingTranscript = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                control(player.error == nil ? (player.wantsPlayback ? "pause.fill" : "play.fill") : "arrow.clockwise",
                        label: player.error == nil ? (player.wantsPlayback ? "Pause audio" : "Play audio") : "Retry audio",
                        id: "speech.playPause") {
                    if player.error != nil { player.retry() } else { player.togglePlayback() }
                }
                Button { showingTranscript = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.time(player.elapsed))
                            .font(.system(.subheadline, design: .monospaced)).monospacedDigit()
                        if player.isGenerating && !player.isPlaying && player.wantsPlayback {
                            Text(player.canSeek ? "Buffering…" : "Preparing…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 48, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Playback details")
                .accessibilityValue(Self.time(player.elapsed))
                .accessibilityHint("Shows audio position and selectable text")
                .accessibilityIdentifier("speech.details")
                .disabled(player.transcript.isEmpty)
                Spacer(minLength: 4)
                Button { player.cycleRate() } label: {
                    Text("\(player.rate.formatted(.number.precision(.fractionLength(0...2))))×")
                        .font(.subheadline.weight(.semibold)).minimumScaleFactor(0.7)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Playback speed")
                .accessibilityValue("\(player.rate.formatted(.number.precision(.fractionLength(0...2)))) times")
                .accessibilityHint("Cycles from normal speed to twice normal speed")
                .accessibilityIdentifier("speech.speed")
                control("gobackward.15", label: "Back 15 seconds", id: "speech.back") { player.skip(-15) }
                    .disabled(!player.canSeek || player.elapsed <= 0)
                control("goforward.15", label: "Forward 15 seconds", id: "speech.forward") { player.skip(15) }
                    .disabled(!player.canSeek || player.elapsed >= player.bufferedDuration)
                control("xmark", label: "Close audio player", id: "speech.close") { player.stop() }
            }
            if let error = player.error {
                Text(error).font(.caption).foregroundStyle(theme.error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 8)
                    .accessibilityIdentifier("speech.error")
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, Spacing.md)
        .padding(.top, 4).padding(.bottom, 8)
        .sheet(isPresented: $showingTranscript) {
            NavigationStack {
                VStack(spacing: 12) {
                    if let duration = player.duration, duration > 0 {
                        VStack {
                            Slider(value: Binding(get: { player.elapsed }, set: { player.seek(to: $0) }), in: 0...duration)
                                .accessibilityLabel("Audio position").accessibilityIdentifier("speech.position")
                            HStack {
                                Text(Self.time(player.elapsed))
                                Spacer()
                                Text(Self.time(duration))
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }.padding(.horizontal)
                    }
                    Text("Select a word, then choose Play from here.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    SpeechTranscriptView(text: player.transcript) { suffix in
                        showingTranscript = false
                        readFromHere(suffix)
                    }
                }
                .navigationTitle("Read-Aloud Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingTranscript = false }
                } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func control(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    private static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

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
            guard range.length > 0, let text = textView.text, range.location < (text as NSString).length else { return nil }
            let suffix = (text as NSString).substring(from: range.location)
            let speak = UIAction(title: "Play from here", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                self?.readFromHere(suffix)
            }
            return UIMenu(children: [speak] + suggestedActions)
        }
    }
}
