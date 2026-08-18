import Foundation
import AVFoundation
import UIKit
import os.log

/// Orchestrates voice call functionality by coordinating speech recognition,
/// text-to-speech, and CallKit services.
///
/// Manages the listen → process → speak → listen cycle for hands-free
/// conversational AI interaction.
///
/// Supports two STT backends:
/// - **Apple on-device** (`SpeechRecognitionService`) — default, works offline
/// - **Server-side** (`ServerSpeechRecognitionService`) — records mic → uploads to
///   `POST /api/v1/audio/transcriptions` when `sttEngine == "server"`
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

    /// Whether audio is routed to the loudspeaker.
    private(set) var isSpeakerOn: Bool = true

    /// The model name being used.
    private(set) var modelName: String = ""

    /// Call duration in seconds.
    private(set) var callDuration: TimeInterval = 0

    /// Error message if in error state.
    var errorMessage: String?

    // MARK: - Dependencies

    /// Apple on-device STT — set when not using server STT.
    private let speechService: SpeechRecognitionService?
    /// Server-side STT — set when `sttEngine == "server"`.
    private let serverSpeechService: ServerSpeechRecognitionService?
    private let ttsService: TextToSpeechService
    private let callKitManager: CallKitManager
    private var conversationManager: ConversationManager?
    private var chatViewModel: ChatViewModel?

    /// True when using the server-based STT (records → uploads) instead of Apple Speech.
    var isUsingServerSTT: Bool { serverSpeechService != nil }

    private let logger = Logger(subsystem: "com.openui", category: "VoiceCall")
    private var durationTimer: Task<Void, Never>?
    private var callStartTime: Date?
    /// Tracks the task running `handleFinalTranscript` → `waitForResponseAndSpeak`.
    /// Cancelled in `endCall()` so TTS stops immediately when the user disconnects.
    private var responseTask: Task<Void, Never>?

    // MARK: - Init (Apple on-device STT)

    init(
        speechService: SpeechRecognitionService,
        ttsService: TextToSpeechService,
        callKitManager: CallKitManager
    ) {
        self.speechService = speechService
        self.serverSpeechService = nil
        self.ttsService = ttsService
        self.callKitManager = callKitManager

        setupCallbacks()
    }

    // MARK: - Init (Server-side STT)

    init(
        serverSpeechService: ServerSpeechRecognitionService,
        ttsService: TextToSpeechService,
        callKitManager: CallKitManager
    ) {
        self.speechService = nil
        self.serverSpeechService = serverSpeechService
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
        // Signal voice mode so every sendMessage() includes features.voice=true,
        // causing the server to inject the admin-configured VOICE_MODE_PROMPT_TEMPLATE.
        chatViewModel.isVoiceMode = true
    }

    // MARK: - Call Lifecycle

    /// Starts a new voice call session.
    func startCall() async {
        guard callState == .idle || callState == .disconnected else { return }

        callState = .connecting

        // Request permissions (both STT backends need mic access)
        let authorized: Bool
        if let serverSTT = serverSpeechService {
            authorized = await serverSTT.requestPermissions()
        } else {
            authorized = await speechService?.requestPermissions() ?? false
        }

        guard authorized else {
            callState = .error("Microphone and speech recognition permissions are required.")
            errorMessage = "Please grant microphone and speech recognition permissions in Settings."
            return
        }

        // Prevent the screen from auto-locking during a voice call.
        // The call requires continuous STT + TTS + LLM streaming — all of which
        // stop working if the device sleeps. Restored in endCall().
        UIApplication.shared.isIdleTimerDisabled = true

        // Start CallKit session
        do {
            try await callKitManager.startCall(displayName: modelName.isEmpty ? "AI Assistant" : modelName)
        } catch {
            logger.warning("CallKit start failed (non-fatal): \(error.localizedDescription)")
        }

        // Apply the user's TTS configuration so voice calls use identical
        // settings to the chat read-aloud button (speech rate, voice, engine).
        let rate = UserDefaults.standard.double(forKey: "ttsSpeechRate")
        if rate > 0 {
            ttsService.speechRate = Float(rate) * AVSpeechUtteranceDefaultSpeechRate
        }
        let voiceId = UserDefaults.standard.string(forKey: "ttsVoiceIdentifier") ?? ""
        ttsService.voiceIdentifier = voiceId.isEmpty ? nil : voiceId

        // Preload on-device TTS model if the user chose Kokoro or Qwen3
        if ttsService.preferredEngine == .kokoro || ttsService.preferredEngine == .qwen3 {
            let modelName = ttsService.preferredEngine == .qwen3 ? "Qwen3" : "Kokoro"
            logger.info("Voice call: preloading \(modelName) TTS model...")
            await ttsService.preloadKokoroModel()
        }

        // Keep .playAndRecord session alive for the full call duration so the mic
        // stays active during TTS. Speaker vs earpiece routing is controlled
        // separately via applySpeakerOverride() — don't tie it to speakerOverrideEnabled.
        ttsService.speakerOverrideEnabled = true

        // Start call timer
        callStartTime = Date()
        startDurationTimer()

        // Start listening
        await startListening()
    }

    /// Ends the current voice call.
    func endCall() async {
        stopActiveSTT()
        // Cancel the response pipeline first so waitForResponseAndSpeak() stops looping
        // and cannot call finishStreamingTTS() or startListening() after we end the call.
        responseTask?.cancel()
        responseTask = nil
        ttsService.stop()
        await callKitManager.endCall()

        durationTimer?.cancel()
        durationTimer = nil
        callState = .disconnected
        currentTranscript = ""
        voiceIntensity = 0

        // Re-enable auto-lock now that the call is over.
        UIApplication.shared.isIdleTimerDisabled = false

        // Disable speaker override so TTS outside a call behaves normally
        ttsService.speakerOverrideEnabled = false
        ttsService.outputPortOverride = .none

        // Restore the global baseline audio session so HTML audio and regular TTS
        // continue working after the voice call ends.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP,
                                           .allowBluetoothA2DP, .mixWithOthers])
        try? session.setActive(true)

        // Reset voice mode flag so normal chat from the same ChatViewModel
        // doesn't continue sending features.voice=true after the call ends.
        chatViewModel?.isVoiceMode = false

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
        stopActiveSTT()
        callState = .paused
    }

    /// Resumes listening after pause.
    func resumeListening() async {
        isPaused = false
        await startListening()
    }

    /// Toggles mute state.
    /// Mute only silences the microphone — it does NOT stop TTS playback,
    /// interrupt any in-progress response, or change the call state.
    /// Unmuting restarts the mic only when the call is idle/listening;
    /// if TTS is still playing the existing onComplete callback will restart it.
    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            // If we were listening and have a partial transcript, submit it so the
            // request still goes through even though we're muting mid-listen.
            let partialTranscript = activeCurrentTranscript
            stopActiveSTT()
            if callState == .listening && !partialTranscript.isEmpty {
                Task { await handleFinalTranscript(partialTranscript) }
            }
            // Otherwise just silence the mic — TTS/streaming keep running untouched.
        } else {
            // Only restart mic if we're not already speaking/processing a response.
            // If speaking, ttsService.onComplete will call startListening() when done.
            if callState != .speaking && callState != .processing {
                Task { await startListening() }
            }
        }
    }

    /// Cancels the current TTS playback and resumes listening.
    func cancelSpeaking() async {
        ttsService.stop()
        await startListening()
    }

    /// Toggles audio output between loudspeaker and earpiece.
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        // speakerOverrideEnabled stays true for the whole call (keeps .playAndRecord active).
        // Only the output port routing needs to change here.
        applySpeakerOverride()
    }

    /// Applies the current speaker routing preference to the active audio session.
    func applySpeakerOverride() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Don't override routing when audio is going through CarPlay or BT HFP —
            // overrideOutputAudioPort(.speaker) would pull audio away from the car.
            let isCarPlayOrHFP = session.currentRoute.outputs.contains { output in
                output.portType == .carAudio || output.portType == .bluetoothHFP
            }
            guard !isCarPlayOrHFP else { return }
            let portOverride: AVAudioSession.PortOverride = isSpeakerOn ? .speaker : .none
            // Persist into TTS service so it re-applies the override whenever it
            // reconfigures the audio session (setActive resets overrideOutputAudioPort).
            ttsService.outputPortOverride = portOverride
            try session.overrideOutputAudioPort(portOverride)
        } catch {
            logger.warning("Speaker override failed: \(error.localizedDescription)")
        }
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
        case .listening:
            return isUsingServerSTT ? "Recording…" : "Listening…"
        case .paused: return "Paused"
        case .processing:
            return isUsingServerSTT ? "Transcribing…" : "Thinking…"
        case .speaking: return "Speaking"
        case .error: return "Error"
        case .disconnected: return "Call Ended"
        }
    }

    // MARK: - Private Helpers

    /// Stops whichever STT service is active.
    private func stopActiveSTT() {
        if let serverSTT = serverSpeechService {
            serverSTT.stopListening()
        } else {
            speechService?.stopListening()
        }
    }

    /// Current intensity from whichever STT service is active.
    private var activeIntensity: Int {
        if let serverSTT = serverSpeechService { return serverSTT.intensity }
        return speechService?.intensity ?? 0
    }

    /// Current transcript from whichever STT service is active.
    private var activeCurrentTranscript: String {
        if let serverSTT = serverSpeechService { return serverSTT.currentTranscript }
        return speechService?.currentTranscript ?? ""
    }

    /// Clears all callbacks installed on shared services.
    /// Must be called when the call ends to prevent a stale VM from
    /// restarting the microphone the next time any TTS plays elsewhere in the app.
    private func clearCallbacks() {
        speechService?.onFinalTranscript = nil
        speechService?.onStateChanged = nil
        speechService?.onError = nil
        serverSpeechService?.onFinalTranscript = nil
        serverSpeechService?.onStateChanged = nil
        serverSpeechService?.onError = nil
        ttsService.onStart = nil
        ttsService.onComplete = nil
        ttsService.onError = nil
        callKitManager.onCallEnded = nil
        callKitManager.onMuteToggled = nil
        callKitManager.onAudioSessionActivated = nil
    }

    /// Sets up callbacks between services.
    private func setupCallbacks() {
        // --- Apple on-device STT callbacks ---
        speechService?.onFinalTranscript = { [weak self] transcript in
            Task { @MainActor [weak self] in
                await self?.handleFinalTranscript(transcript)
            }
        }

        speechService?.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .listening:
                    self.voiceIntensity = self.speechService?.intensity ?? 0
                case .error(let msg):
                    self.logger.error("Speech error: \(msg)")
                default:
                    break
                }
            }
        }

        speechService?.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.logger.error("Speech recognition error: \(error)")
            }
        }

        // --- Server STT callbacks ---
        serverSpeechService?.onFinalTranscript = { [weak self] transcript in
            Task { @MainActor [weak self] in
                await self?.handleFinalTranscript(transcript)
            }
        }

        serverSpeechService?.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .listening:
                    self.voiceIntensity = self.serverSpeechService?.intensity ?? 0
                case .processing:
                    // Server is uploading/transcribing — show a processing state
                    if self.callState == .listening {
                        self.callState = .processing
                    }
                case .error(let msg):
                    self.logger.error("Server STT error: \(msg)")
                    // On error, restart listening so the call continues
                    if !self.isPaused && !self.isMuted {
                        Task { await self.startListening() }
                    }
                default:
                    break
                }
            }
        }

        serverSpeechService?.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.logger.error("Server STT error: \(error)")
                // On network error during voice call, fall back gracefully
                if let self, !self.isPaused && !self.isMuted {
                    await self.startListening()
                }
            }
        }

        // --- TTS callbacks ---
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

        // --- CallKit callbacks ---
        callKitManager.onCallEnded = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.endCall()
            }
        }

        callKitManager.onMuteToggled = { [weak self] muted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isMuted = muted
                if muted {
                    // Hardware mute: only silence the mic, leave TTS and response pipeline running
                    self.stopActiveSTT()
                } else {
                    // Only restart mic if not speaking/processing — onComplete handles the rest
                    if self.callState != .speaking && self.callState != .processing {
                        await self.startListening()
                    }
                }
            }
        }

        callKitManager.onAudioSessionActivated = { [weak self] in
            Task { @MainActor [weak self] in
                // CallKit reset the audio session — re-apply our speaker preference
                self?.applySpeakerOverride()
            }
        }
    }

    /// Starts speech recognition using whichever STT backend is active.
    private func startListening() async {
        guard !isMuted, !isPaused else {
            callState = .paused
            return
        }

        // Reconfigure audio session for recording (TTS may have left it in .playback).
        // .allowBluetooth enables HFP input (car mic / BT headset mic).
        // .allowBluetoothA2DP enables A2DP output.
        // Without .allowBluetooth the CarPlay / BT mic is not routed and STT hears silence.
        do {
            let session = AVAudioSession.sharedInstance()
            // Do NOT use .defaultToSpeaker here — it overrides overrideOutputAudioPort(.none)
            // on every cycle and prevents the speaker button from turning off.
            // Speaker routing is controlled exclusively via applySpeakerOverride().
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true)
            applySpeakerOverride()
        } catch {
            logger.warning("Audio session reconfig for listening: \(error.localizedDescription)")
        }

        currentTranscript = ""
        callState = .listening

        if let serverSTT = serverSpeechService {
            // Server STT: record audio → upload → onFinalTranscript fires when done
            do {
                try await serverSTT.startListening()
            } catch {
                logger.error("Server STT failed to start: \(error.localizedDescription)")
                callState = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
                return
            }
            // Re-apply speaker preference — serverSTT.startListening() calls setCategory
            // with .defaultToSpeaker internally, which resets overrideOutputAudioPort(.none).
            applySpeakerOverride()
            // Monitor intensity from server STT recorder
            monitorServerSTTIntensity()
        } else {
            // Apple on-device STT
            do {
                try await speechService?.startListening()
            } catch {
                logger.error("Failed to start listening: \(error.localizedDescription)")
                callState = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
                return
            }
            // Re-apply speaker preference — speechService.startListening() calls setCategory
            // with .defaultToSpeaker internally, which resets overrideOutputAudioPort(.none).
            applySpeakerOverride()
            monitorAppleSTTIntensity()
        }
    }

    /// Monitors voice intensity from the Apple STT service for waveform display.
    private func monitorAppleSTTIntensity() {
        Task {
            while callState == .listening {
                voiceIntensity = speechService?.intensity ?? 0
                currentTranscript = speechService?.currentTranscript ?? ""
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Monitors voice intensity from the server STT recorder for waveform display.
    private func monitorServerSTTIntensity() {
        Task {
            while callState == .listening {
                voiceIntensity = serverSpeechService?.intensity ?? 0
                // Server STT has no real-time partial transcripts — show empty
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

    /// Handles the final transcript from whichever STT service is active.
    private func handleFinalTranscript(_ transcript: String) async {
        guard !transcript.isEmpty else {
            if !isPaused && !isMuted {
                await startListening()
            }
            return
        }

        // Stop STT first to release the audio session
        stopActiveSTT()

        callState = .processing
        currentTranscript = transcript

        guard let chatViewModel else {
            callState = .error("Chat not configured")
            return
        }

        // Wait for speech recognizer / recorder to fully release audio routes.
        // SFSpeechRecognizer holds the audio session for ~200-300ms after stopListening().
        // AVAudioRecorder also needs a moment.
        try? await Task.sleep(for: .milliseconds(400))

        // Pre-configure the audio session before TTS starts.
        // Keep .allowBluetooth so CarPlay / BT HFP stays routed for the full cycle.
        for attempt in 1...3 {
            do {
                let session = AVAudioSession.sharedInstance()
                // Do NOT use .defaultToSpeaker — see startListening() comment.
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.allowBluetoothHFP, .allowBluetoothA2DP])
                try session.setActive(true)
                applySpeakerOverride()
                break
            } catch {
                logger.warning("Audio session attempt \(attempt)/3: \(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        chatViewModel.inputText = transcript

        // Fire sendMessage concurrently — DO NOT await it.
        // Awaiting sendMessage() blocks until the entire stream finishes, which
        // means waitForResponseAndSpeak()'s polling loop sees isStreaming==false
        // immediately and never feeds any incremental text to TTS.
        // By launching it as a detached task, the polling loop below runs
        // concurrently with the LLM stream, feeding sentences to TTS as they arrive.
        Task { await chatViewModel.sendMessage() }

        // Wait event-driven until the server has accepted the request and streaming
        // has actually started. This fixes the "first voice call message not spoken"
        // bug where the 120ms blind sleep wasn't long enough for the first message
        // (which must create the conversation on the server before streaming begins).
        // waitForStreamingToStart() returns instantly on subsequent messages and is
        // bounded by the server's request timeout — never hangs indefinitely.
        await chatViewModel.waitForStreamingToStart()

        // Store the task so endCall() can cancel it if the user disconnects mid-response.
        responseTask = Task { [weak self] in
            await self?.waitForResponseAndSpeak()
        }
        await responseTask?.value
        responseTask = nil
    }

    /// Waits for the streaming response and speaks it incrementally.
    /// Sentences are fed to TTS as soon as they're complete (not waiting for full response).
    /// When TTS finishes, the `onComplete` callback (set up in `setupCallbacks()`)
    /// automatically restarts listening — no need to poll state here.
    ///
    /// This method runs inside `responseTask` so it can be cancelled immediately by
    /// `endCall()`. All early-exit paths check `Task.isCancelled` before restarting
    /// the microphone or feeding text to TTS.
    private func waitForResponseAndSpeak() async {
        guard let chatViewModel else { return }
        guard !Task.isCancelled else { return }

        // Always start TTS regardless of mute state.
        // Mute only silences the microphone — the user should still hear the AI response.
        ttsService.startStreamingTTS()

        // Poll for streaming content — feed sentences to TTS pipeline as they arrive.
        //
        // IMPORTANT: During streaming, ChatViewModel routes every token delta into
        // the streamingStore (an isolated @Observable store) rather than
        // into conversation.messages[idx].content — this is a performance optimisation
        // that prevents all message views from re-evaluating on every token.
        // Reading messages.last?.content here would always see "" (the frozen placeholder)
        // until streaming fully completes. We must read directly from the streaming store.
        // Use displayContent (the typewriter-drained content) for TTS — it's the
        // same authoritative text, available from the thin @MainActor wrapper.
        var lastContent = ""
        while chatViewModel.isStreaming {
            guard !Task.isCancelled else {
                ttsService.stop()
                return
            }

            // Prefer live content from the streaming store; fall back to messages array
            // for socket-based external streams that bypass the store.
            let newContent: String
            if chatViewModel.streamingStore.isActive {
                newContent = chatViewModel.streamingStore.displayContent
            } else {
                newContent = chatViewModel.messages.last(where: { $0.role == .assistant })?.content ?? ""
            }

            if newContent != lastContent {
                lastContent = newContent
                ttsService.feedStreamingText(newContent)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }

        // Bail out if the call was ended while we were polling
        guard !Task.isCancelled else {
            ttsService.stop()
            return
        }

        // Send any remaining text to TTS.
        // After streaming ends, the store has been flushed to conversation.messages,
        // so reading from messages here is correct for final cleanup.
        if let finalMessage = chatViewModel.messages.last(where: { $0.role == .assistant }) {
            let finalContent = finalMessage.content
            if !finalContent.isEmpty {
                ttsService.finishStreamingTTS(finalText: finalContent)
                // onComplete callback will call startListening() when TTS finishes (if not muted)
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
