import Foundation
import AVFoundation
import os.log

/// Orchestrates voice call functionality by coordinating speech recognition,
/// text-to-speech, and CallKit services.
///
/// Manages the listen → process → speak → listen cycle for hands-free
/// conversational AI interaction.
@MainActor @Observable
final class VoiceCallViewModel {

    // MARK: - State

    enum CallState: Sendable, Equatable {
        case idle
        case connecting
        case listening
        case paused
        case processing
        case speaking
        case error(String)
        case disconnected
    }

    /// Current call state.
    private(set) var callState: CallState = .idle

    /// The current user's speech transcript (shown briefly while listening).
    private(set) var currentTranscript: String = ""

    /// Voice intensity for waveform (0–10).
    private(set) var voiceIntensity: Int = 0

    /// Whether the microphone is muted.
    private(set) var isMuted: Bool = false

    /// Whether the call is paused.
    private(set) var isPaused: Bool = false

    /// The model name being used.
    private(set) var modelName: String = ""

    /// Call duration in seconds.
    private(set) var callDuration: TimeInterval = 0

    /// Error message if in error state.
    var errorMessage: String?

    // MARK: - Dependencies

    private let speechService: SpeechRecognitionService
    private let ttsService: TextToSpeechService
    private let callKitManager: CallKitManager
    private var conversationManager: ConversationManager?
    private var chatViewModel: ChatViewModel?

    private let logger = Logger(subsystem: "com.openui", category: "VoiceCall")
    private var durationTimer: Task<Void, Never>?
    private var callStartTime: Date?

    // MARK: - Init

    init(
        speechService: SpeechRecognitionService,
        ttsService: TextToSpeechService,
        callKitManager: CallKitManager
    ) {
        self.speechService = speechService
        self.ttsService = ttsService
        self.callKitManager = callKitManager

        setupCallbacks()
    }

    // MARK: - Configuration

    /// Configures the voice call with a conversation manager and chat view model.
    func configure(
        conversationManager: ConversationManager,
        chatViewModel: ChatViewModel,
        modelName: String
    ) {
        self.conversationManager = conversationManager
        self.chatViewModel = chatViewModel
        self.modelName = modelName
    }

    // MARK: - Call Lifecycle

    /// Starts a new voice call session.
    func startCall() async {
        guard callState == .idle || callState == .disconnected else { return }

        callState = .connecting

        // Request permissions
        let authorized = await speechService.requestPermissions()
        guard authorized else {
            callState = .error("Microphone and speech recognition permissions are required.")
            errorMessage = "Please grant microphone and speech recognition permissions in Settings."
            return
        }

        // Start CallKit session
        do {
            try await callKitManager.startCall(displayName: modelName.isEmpty ? "AI Assistant" : modelName)
        } catch {
            logger.warning("CallKit start failed (non-fatal): \(error.localizedDescription)")
        }

        // Preload MarvisTTS model only if the user explicitly chose Marvis
        if ttsService.preferredEngine == .marvis {
            logger.info("Voice call: preloading MarvisTTS model...")
            await ttsService.preloadMarvisModel()
        }

        // Start call timer
        callStartTime = Date()
        startDurationTimer()

        // Start listening
        await startListening()
    }

    /// Ends the current voice call.
    func endCall() async {
        speechService.stopListening()
        ttsService.stop()
        await callKitManager.endCall()

        durationTimer?.cancel()
        durationTimer = nil
        callState = .disconnected
        currentTranscript = ""
        voiceIntensity = 0

        // CRITICAL: Clear all shared service callbacks so a stale VM reference
        // cannot restart the microphone after the call ends. Without this, the
        // ttsService.onComplete closure (which calls startListening) remains set
        // on the shared singleton and fires the next time any TTS plays — causing
        // the mic to turn on permanently in the background.
        clearCallbacks()
    }

    /// Pauses listening.
    func pauseListening() {
        isPaused = true
        speechService.stopListening()
        callState = .paused
    }

    /// Resumes listening after pause.
    func resumeListening() async {
        isPaused = false
        await startListening()
    }

    /// Toggles mute state.
    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            ttsService.stop()
            speechService.stopListening()
            callState = .paused
        } else {
            Task { await startListening() }
        }
    }

    /// Cancels the current TTS playback and resumes listening.
    func cancelSpeaking() async {
        ttsService.stop()
        await startListening()
    }

    // MARK: - Formatted Duration

    var formattedDuration: String {
        let mins = Int(callDuration) / 60
        let secs = Int(callDuration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - State Label

    var stateLabel: String {
        switch callState {
        case .idle: return "Ready"
        case .connecting: return "Connecting…"
        case .listening: return "Listening…"
        case .paused: return "Paused"
        case .processing: return "Thinking…"
        case .speaking: return "Speaking"
        case .error: return "Error"
        case .disconnected: return "Call Ended"
        }
    }

    // MARK: - Private

    /// Clears all callbacks installed on shared services.
    /// Must be called when the call ends to prevent a stale VM from
    /// restarting the microphone the next time any TTS plays elsewhere in the app.
    private func clearCallbacks() {
        speechService.onFinalTranscript = nil
        speechService.onStateChanged = nil
        speechService.onError = nil
        ttsService.onStart = nil
        ttsService.onComplete = nil
        ttsService.onError = nil
        callKitManager.onCallEnded = nil
        callKitManager.onMuteToggled = nil
    }

    /// Sets up callbacks between services.
    private func setupCallbacks() {
        // Speech recognition callbacks
        speechService.onFinalTranscript = { [weak self] transcript in
            Task { @MainActor [weak self] in
                await self?.handleFinalTranscript(transcript)
            }
        }

        speechService.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .listening:
                    self.voiceIntensity = self.speechService.intensity
                case .error(let msg):
                    self.logger.error("Speech error: \(msg)")
                default:
                    break
                }
            }
        }

        // TTS callbacks
        ttsService.onStart = { [weak self] in
            Task { @MainActor [weak self] in
                self?.callState = .speaking
            }
        }

        ttsService.onComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isPaused && !self.isMuted {
                    await self.startListening()
                }
            }
        }

        ttsService.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.logger.error("TTS error: \(error)")
                if let self, !self.isPaused && !self.isMuted {
                    await self.startListening()
                }
            }
        }

        // CallKit callbacks
        callKitManager.onCallEnded = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.endCall()
            }
        }

        callKitManager.onMuteToggled = { [weak self] muted in
            Task { @MainActor [weak self] in
                self?.isMuted = muted
                if muted {
                    self?.speechService.stopListening()
                    self?.ttsService.stop()
                } else {
                    await self?.startListening()
                }
            }
        }
    }

    /// Starts speech recognition.
    private func startListening() async {
        guard !isMuted, !isPaused else {
            callState = .paused
            return
        }

        // Reconfigure audio session for recording (TTS may have left it in .playback)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            logger.warning("Audio session reconfig for listening: \(error.localizedDescription)")
        }

        currentTranscript = ""
        callState = .listening

        do {
            try await speechService.startListening()
        } catch {
            logger.error("Failed to start listening: \(error.localizedDescription)")
            callState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }

        monitorIntensity()
    }

    /// Monitors voice intensity for waveform display.
    private func monitorIntensity() {
        Task {
            while callState == .listening {
                voiceIntensity = speechService.intensity
                currentTranscript = speechService.currentTranscript
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Starts the call duration timer.
    private func startDurationTimer() {
        durationTimer = Task {
            while !Task.isCancelled {
                if let start = callStartTime {
                    callDuration = Date().timeIntervalSince(start)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Handles the final transcript from speech recognition.
    private func handleFinalTranscript(_ transcript: String) async {
        guard !transcript.isEmpty else {
            if !isPaused && !isMuted {
                await startListening()
            }
            return
        }

        // Stop speech recognition FIRST to release the audio session
        speechService.stopListening()

        callState = .processing
        currentTranscript = transcript

        guard let chatViewModel else {
            callState = .error("Chat not configured")
            return
        }

        // Wait for speech recognizer to fully release audio routes.
        // SFSpeechRecognizer holds the audio session for ~200-300ms after stopListening().
        try? await Task.sleep(for: .milliseconds(400))

        // Pre-configure the audio session to .playback (matching LocalAudioPlayer's
        // internal configureAudioSession). This must succeed before the player starts.
        for attempt in 1...3 {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                break
            } catch {
                logger.warning("Audio session attempt \(attempt)/3: \(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        chatViewModel.inputText = transcript
        await chatViewModel.sendMessage()

        await waitForResponseAndSpeak()
    }

    /// Waits for the streaming response and speaks it incrementally.
    /// Sentences are fed to TTS as soon as they're complete (not waiting for full response).
    /// When TTS finishes, the `onComplete` callback (set up in `setupCallbacks()`)
    /// automatically restarts listening — no need to poll state here.
    private func waitForResponseAndSpeak() async {
        guard let chatViewModel else { return }

        if !isMuted {
            ttsService.startStreamingTTS()
        }

        // Poll for streaming content — feed sentences to TTS pipeline as they arrive
        var lastContent = ""
        while chatViewModel.isStreaming {
            if let lastMessage = chatViewModel.messages.last(where: { $0.role == .assistant }) {
                let newContent = lastMessage.content
                if newContent != lastContent {
                    lastContent = newContent
                    if !isMuted {
                        ttsService.feedStreamingText(newContent)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(60))
        }

        // Send any remaining text to TTS
        if let finalMessage = chatViewModel.messages.last(where: { $0.role == .assistant }) {
            let finalContent = finalMessage.content

            if !isMuted && !finalContent.isEmpty {
                ttsService.finishStreamingTTS(finalText: finalContent)
                // onComplete callback will call startListening() when TTS finishes
            } else {
                ttsService.stop()
                if !isPaused && !isMuted {
                    await startListening()
                }
            }
        } else {
            ttsService.stop()
            if !isPaused && !isMuted {
                await startListening()
            }
        }
    }
}
