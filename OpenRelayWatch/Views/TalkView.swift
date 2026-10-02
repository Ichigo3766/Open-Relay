import SwiftUI
import WatchKit

/// Talk — the one conversation screen. Speak, or tap the keyboard to type /
/// Scribble. Listens → sends → speaks the reply → listens again. Speaking
/// over a reply interrupts it. Opens with a chat to continue it.
struct TalkView: View {
    var chatId: String? = nil
    var chatTitle: String? = nil
    /// Start on the keyboard instead of listening (Type complication).
    var startTyping = false
    /// Text typed on Home — sent as soon as the screen opens.
    var initialPrompt: String? = nil

    @Environment(WatchStore.self) var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State var capture = VoiceCapture()
    @State var turn = TurnController()
    @State var loop: Task<Void, Never>?
    @State var idleTimer: Task<Void, Never>?
    @State var stopListening = false
    @State var paused = false
    @State var status = "Starting…"
    @State var muted = false
    @State private var started = false
    @State private var showDiagnostics = false

    /// "Starting mic…" until audio is actually arriving.
    private var displayStatus: String {
        capture.micStarting ? "Starting mic…" : status
    }

    /// Long-press the status to show: echo cancellation, frames, current mic
    /// level, interrupt threshold and learned reply echo.
    private var diagnostics: String {
        let audio = WatchAudio.shared
        let aec = audio.echoCancelling ? "AEC on" : (audio.echoAllowed ? "AEC off" : "AEC failed")
        let frames = audio.mic.framesReceived / 1000
        return String(format: "%@ · %dk\nlvl %.3f · need %.3f · echo %.3f",
                      aec, frames, capture.lastRMS, capture.threshold, capture.learnedEcho)
    }

    var body: some View {
        VStack(spacing: 4) {
            OrbView(level: capture.level, mode: orbMode, reduced: isLuminanceReduced || reduceMotion)
                .frame(width: isLuminanceReduced ? 56 : 72, height: isLuminanceReduced ? 56 : 72)
                .onTapGesture { tapOrb() }
                .accessibilityElement()
                .accessibilityLabel(orbAccessibilityLabel)
                .accessibilityHint(orbAccessibilityHint)
                .accessibilityAddTraits(.isButton)
            HStack(spacing: 4) {
                if turn.speaksOnPhone && turn.isSpeaking {
                    Image(systemName: "airpods").font(.caption2).accessibilityHidden(true)
                }
                Text(displayStatus)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isLuminanceReduced ? .secondary : .primary)
            .onLongPressGesture { showDiagnostics.toggle() }
            if showDiagnostics && !isLuminanceReduced {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(diagnostics).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                }
            }
            if !isLuminanceReduced {
                TalkContentView(turn: turn, capture: capture, onChip: { send(typed: $0) })
            }
            Spacer(minLength: 0)
            if !isLuminanceReduced { controls }
        }
        .navigationTitle(turn.chatTitle ?? "Talk")
        .navigationBarTitleDisplayMode(.inline)
        .handoff(chatId: turn.chatId)
        .onAppear {
            guard !started else { return }
            started = true
            ReplyNotifier.requestPermissionIfNeeded()
            if let chatId { turn = TurnController(chatId: chatId, chatTitle: chatTitle) }
            // Mute is shared with the audio engine — never carry it over
            // from a previous Talk screen.
            muted = false
            WatchAudio.shared.isMuted = false
            if let initialPrompt {
                send(typed: initialPrompt)
            } else if startTyping {
                goIdle("Tap ⌨︎ to type, or the orb to talk")
            } else {
                startLoop()
            }
        }
        .onDisappear {
            stopAll()
            idleTimer?.cancel()
            WatchAudio.shared.isMuted = false
            WatchAudio.shared.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            // Finish the utterance if the watch is put away mid-sentence.
            if phase == .background, capture.state == .listening { stopListening = true }
        }
        .onChange(of: isLuminanceReduced) { _, dimmed in
            // Screen dimmed while nothing is happening → release the mic now.
            if dimmed, paused { WatchAudio.shared.stop() }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button { toggleMute() } label: {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
            }
            .tint(muted ? .red : .gray)
            .accessibilityLabel(muted ? "Unmute" : "Mute")

            TextFieldLink(prompt: Text("Type a message")) {
                Image(systemName: "keyboard")
            } onSubmit: { text in
                send(typed: text)
            }
            .accessibilityLabel("Type")
            // Free the mic before the system keyboard / dictation sheet opens,
            // so the two never fight over the microphone.
            .simultaneousGesture(TapGesture().onEnded { pauseForInput() })

            Button(role: .destructive) { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .tint(.red)
            .accessibilityLabel("End")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.circle)
    }

    private var orbMode: OrbView.Mode {
        if muted && capture.state == .listening { return .idle }
        if capture.state == .listening { return .listening }
        if turn.isSpeaking { return .speaking }
        if turn.isBusy || capture.state == .finishing { return .thinking }
        return .idle
    }

    private var orbAccessibilityLabel: String {
        switch orbMode {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .idle: return muted ? "Muted" : "Talk"
        }
    }

    private var orbAccessibilityHint: String {
        switch orbMode {
        case .listening: return "Double-tap to send what you said."
        case .thinking, .speaking: return "Double-tap to stop the reply."
        case .idle: return "Double-tap to start talking."
        }
    }

    private func tapOrb() {
        if capture.state == .listening {
            stopListening = true
        } else if turn.isBusy || turn.isSpeaking {
            turn.cancel()  // interrupt; the loop goes back to listening
        } else if paused {
            paused = false
            startLoop()
        }
    }

    private func toggleMute() {
        muted.toggle()
        WatchAudio.shared.isMuted = muted
        WKInterfaceDevice.current().play(.click)
        if muted, capture.state == .listening { status = "Muted" }
    }

    /// Typed / Scribbled / chip message: stop listening, send, keep going.
    func send(typed text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopAll()
        paused = false
        idleTimer?.cancel()
        loop = Task {
            // Only open the mic now if the reply can be interrupted by speaking;
            // otherwise the reply just needs audio output (the mic starts when
            // listening resumes).
            if store.interruptBySpeaking { try? await capture.prepare() }
            guard !Task.isCancelled else { return }
            turn.ask(trimmed, modelId: store.effectiveModelId, speak: true, voice: true)
            let interrupted = await waitForReply()
            await runLoop(startInterrupted: interrupted)
        }
    }

    func startLoop() {
        loop?.cancel()
        paused = false
        idleTimer?.cancel()
        loop = Task { await runLoop() }
    }

    /// The keyboard / dictation sheet is about to open: stop listening and
    /// release the microphone and audio session.
    func pauseForInput() {
        stopAll()
        WatchAudio.shared.stop()
        goIdle("Tap the orb to talk")
    }

    /// Nothing happening: show a hint, release the mic after 30 s.
    func goIdle(_ message: String) {
        paused = true
        status = message
        idleTimer?.cancel()
        idleTimer = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, paused else { return }
            WatchAudio.shared.stop()
            status = "Tap the orb to talk"
        }
    }

    func stopAll() {
        loop?.cancel()
        loop = nil
        capture.cancel()
        turn.cancel()
    }
}
