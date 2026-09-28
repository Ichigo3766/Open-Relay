import Foundation
import AVFoundation
import Speech
import UIKit
import os.log

/// Voice call UI state. Delegates the audio pipeline to `CallOrchestrator`
/// (one shared engine with echo cancellation, VAD turn-taking, streaming TTS).
@MainActor @Observable
final class VoiceCallViewModel {

    enum CallState: Sendable, Equatable {
        case idle, connecting, listening, paused, processing, speaking
        case error(String)
        case disconnected
    }

    private(set) var callState: CallState = .idle
    private(set) var currentTranscript: String = ""
    /// Voice intensity for the waveform (0–10).
    private(set) var voiceIntensity: Int = 0
    private(set) var isMuted = false
    private(set) var isPaused = false
    private(set) var isSpeakerOn = true
    private(set) var modelName = ""
    private(set) var callDuration: TimeInterval = 0
    var errorMessage: String?
    /// Live turn-taking readout (nil unless Diagnostics is on).
    private(set) var diagnostics: CallDiagnostics?

    /// True when the active STT engine transcribes the whole utterance after the turn ends.
    private(set) var isUsingServerSTT = false

    // MARK: - Dependencies
    let ttsService: TextToSpeechService
    let vadModelStore: VADModelStore
    let settings: VoiceCallSettings
    let apiClientProvider: @MainActor () -> APIClient?
    var conversationManager: ConversationManager?
    var chatViewModel: ChatViewModel?

    @ObservationIgnored var orchestrator: CallOrchestrator?
    @ObservationIgnored let audioSession = CallAudioSession()
    @ObservationIgnored var durationTimer: Task<Void, Never>?
    @ObservationIgnored var callStartTime: Date?
    @ObservationIgnored let logger = Logger(subsystem: "com.openui", category: "VoiceCall")
    @ObservationIgnored var backgroundObservers: [NSObjectProtocol] = []
    @ObservationIgnored var wasPausedByInterruption = false
    @ObservationIgnored let liveActivity = VoiceCallLiveActivityController()
    /// Short background-task assertion held while a turn is being answered, so
    /// iOS doesn't suspend networking in the gap between mic and speaker audio.
    @ObservationIgnored var turnBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(
        ttsService: TextToSpeechService,
        vadModelStore: VADModelStore,
        settings: VoiceCallSettings,
        apiClientProvider: @escaping @MainActor () -> APIClient?
    ) {
        self.ttsService = ttsService
        self.vadModelStore = vadModelStore
        self.settings = settings
        self.apiClientProvider = apiClientProvider
        self.isSpeakerOn = settings.defaultSpeakerOn
    }

    func configure(conversationManager: ConversationManager, chatViewModel: ChatViewModel, modelName: String) {
        self.conversationManager = conversationManager
        self.chatViewModel = chatViewModel
        self.modelName = modelName
        // features.voice=true → server injects VOICE_MODE_PROMPT_TEMPLATE.
        chatViewModel.isVoiceMode = true
    }

    // MARK: - Labels

    var formattedDuration: String {
        String(format: "%02d:%02d", Int(callDuration) / 60, Int(callDuration) % 60)
    }

    var stateLabel: String {
        switch callState {
        case .idle: return "Ready"
        case .connecting: return "Connecting…"
        case .listening: return "Listening…"
        case .paused: return "Paused"
        case .processing: return isUsingServerSTT ? "Transcribing…" : "Thinking…"
        case .speaking: return "Speaking"
        case .error: return "Error"
        case .disconnected: return "Call Ended"
        }
    }
}

// MARK: - Call lifecycle

extension VoiceCallViewModel {

    func startCall() async {
        switch callState {
        case .idle, .disconnected: break
        case .error:
            await endCall()
            chatViewModel?.isVoiceMode = true
        default: return
        }
        guard let chat = chatViewModel else {
            fail("Voice call isn't configured.")
            return
        }
        errorMessage = nil
        callState = .connecting
        guard await chat.authorizeWebSearch() else {
            fail(chat.errorMessage ?? "Web search was not approved. Turn it off or try again.")
            return
        }
        guard callState == .connecting else { return }
        ttsService.stop()
        ttsService.readAloudPlayer.stop()

        guard await Self.requestPermissions(needsSpeech: settings.sttEngine == "apple") else {
            fail("Please grant microphone and speech recognition permissions in Settings.")
            return
        }
        guard callState == .connecting else { return }

        do {
            try audioSession.activate(preferSpeaker: isSpeakerOn)
            audioSession.setSpeakerOverride(isSpeakerOn)
        } catch {
            fail("Couldn't start audio: \(error.localizedDescription)")
            return
        }

        // Load engines + VAD models in parallel with each other.
        let api = apiClientProvider()
        async let vadReady: Void = vadModelStore.loadIfNeeded()
        let stt = await CallEngineFactory.makeSTT(settings: settings, apiClient: api)
        let tts = await CallEngineFactory.makeTTS(settings: settings, apiClient: api, ttsService: ttsService)
        _ = await vadReady
        guard callState == .connecting else { stt.shutdown(); tts.shutdown(); return }
        isUsingServerSTT = stt is ServerCallSTTEngine

        let orch = CallOrchestrator(stt: stt, tts: tts, vadStore: vadModelStore, settings: settings, chat: chat)
        bind(orch)
        orchestrator = orch
        do {
            try orch.start()
        } catch {
            fail("Microphone unavailable: \(error.localizedDescription)")
            return
        }
        orch.isMicMuted = isMuted
        wireAudioSession()
        let start = Date()
        callStartTime = start
        startDurationTimer()
        startLiveActivity(startDate: start)
        // The app may already be leaving the foreground (e.g. locked while
        // connecting) — make sure GPU engines are swapped out right away.
        if UIApplication.shared.applicationState != .active { leaveForeground() }
    }

    func endCall() async {
        callState = .disconnected
        unwireAudioSession()
        orchestrator?.stop()
        orchestrator = nil
        durationTimer?.cancel()
        durationTimer = nil
        currentTranscript = ""
        voiceIntensity = 0
        isPaused = false
        liveActivity.end()
        endTurnBackgroundTask()
        audioSession.deactivate()
        // Restore the app's baseline session so read-aloud / HTML audio keep working.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers])
        try? session.setActive(true)
        chatViewModel?.webSearchConsent.cancelPending()
        chatViewModel?.isVoiceMode = false
    }

    func pauseListening() {
        guard orchestrator != nil else { return }
        isPaused = true
        orchestrator?.pause()
    }

    func resumeListening() async {
        isPaused = false
        orchestrator?.resume()
    }

    /// Mute only silences the mic (voice processing input mute); replies keep playing.
    func toggleMute() {
        isMuted.toggle()
        orchestrator?.isMicMuted = isMuted
        updateLiveActivity()
    }

    func cancelSpeaking() async {
        orchestrator?.interrupt()
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        applySpeakerOverride()
    }

    func applySpeakerOverride() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        // Never pull audio away from CarPlay / Bluetooth.
        guard !outputs.contains(where: { $0.portType == .carAudio || $0.portType == .bluetoothHFP }) else { return }
        audioSession.setSpeakerOverride(isSpeakerOn)
    }
}


// MARK: - Helpers

extension VoiceCallViewModel {

    fileprivate func fail(_ message: String) {
        callState = .error(message)
        errorMessage = message
        unwireAudioSession()
        orchestrator?.stop()
        orchestrator = nil
        liveActivity.end()
        endTurnBackgroundTask()
    }

    fileprivate static func requestPermissions(needsSpeech: Bool) async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        guard needsSpeech else { return true }
        let status = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return status == .authorized
    }

    fileprivate func startLiveActivity(startDate: Date) {
        liveActivity.onToggleMute = { [weak self] in self?.toggleMute() }
        liveActivity.onEndCall = { [weak self] in
            guard let self, self.callState != .disconnected else { return }
            Task { await self.endCall() }
        }
        liveActivity.start(modelName: modelName, startDate: startDate,
                           phase: activityPhase, isMuted: isMuted)
    }

    /// Call state mapped onto the Live Activity's phase.
    fileprivate var activityPhase: VoiceCallActivityAttributes.Phase {
        switch callState {
        case .listening: return .listening
        case .processing: return .thinking
        case .speaking: return .speaking
        case .paused: return .paused
        default: return .connecting
        }
    }

    fileprivate func updateLiveActivity() {
        liveActivity.update(phase: activityPhase, isMuted: isMuted)
    }

    /// Held from end-of-turn until the reply starts playing (or the turn is
    /// abandoned). In the background the mic keeps the app alive, but a brief
    /// assertion makes sure the request/stream isn't throttled in between.
    fileprivate func updateTurnBackgroundTask() {
        if callState == .processing {
            guard turnBackgroundTask == .invalid else { return }
            turnBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VoiceCallTurn") { [weak self] in
                self?.endTurnBackgroundTask()
            }
        } else {
            endTurnBackgroundTask()
        }
    }

    fileprivate func endTurnBackgroundTask() {
        guard turnBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(turnBackgroundTask)
        turnBackgroundTask = .invalid
    }

    fileprivate func bind(_ orch: CallOrchestrator) {
        orch.onPhaseChanged = { [weak self] phase in
            guard let self, self.callState != .disconnected else { return }
            switch phase {
            case .idle: break
            case .listening: self.callState = .listening
            case .processing: self.callState = .processing
            case .speaking: self.callState = .speaking
            case .paused: self.callState = .paused
            }
            self.updateLiveActivity()
            self.updateTurnBackgroundTask()
        }
        orch.onLevel = { [weak self] rms in
            guard let self else { return }
            // Map RMS (speech ≈ 0.02–0.25) onto 0–10 for the waveform.
            let level = self.isMuted ? 0 : Int(min(10, (rms * 40).rounded()))
            if level != self.voiceIntensity { self.voiceIntensity = level }
        }
        orch.onPartialTranscript = { [weak self] text in
            guard let self, self.currentTranscript != text else { return }
            self.currentTranscript = text
        }
        orch.onUserTurn = { [weak self] text in self?.currentTranscript = text }
        orch.onDiagnostics = { [weak self] d in
            guard let self, self.diagnostics != d else { return }
            self.diagnostics = d
        }
        orch.onError = { [weak self] message in
            self?.errorMessage = message
            self?.logger.error("Call turn error: \(message)")
        }
    }

    /// Interruptions (a phone call, Siri, alarm) pause the call and resume it
    /// when they end; route changes re-apply the speaker preference (the
    /// audio engine rebuilds itself on the resulting configuration change).
    fileprivate func wireAudioSession() {
        audioSession.onInterruption = { [weak self] type in
            guard let self, self.orchestrator != nil else { return }
            switch type {
            case .began:
                self.logger.info("Audio interruption began — pausing call")
                self.wasPausedByInterruption = !self.isPaused
                self.orchestrator?.pause()
            case .ended:
                self.logger.info("Audio interruption ended")
                guard self.wasPausedByInterruption else { return }
                self.wasPausedByInterruption = false
                // Without CallKit the app owns the session: take it back and
                // resume (resume() rebuilds the audio engine if it stopped).
                self.audioSession.reactivate()
                self.applySpeakerOverride()
                if !self.isPaused { self.orchestrator?.resume() }
            @unknown default:
                break
            }
        }
        audioSession.onRouteChange = { [weak self] reason in
            guard let self, self.orchestrator != nil else { return }
            self.logger.info("Audio route changed (reason \(reason.rawValue))")
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override, .categoryChange:
                self.applySpeakerOverride()
            default:
                break
            }
            self.orchestrator?.audioRouteChanged()
        }
        backgroundObservers.forEach(NotificationCenter.default.removeObserver)
        backgroundObservers = [
            // willResignActive (not didEnterBackground) — it fires first, with
            // enough headroom to stop submitting Metal work before iOS forbids it.
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.leaveForeground() }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                MLXCallLock.gpuAllowed = true
            },
        ]
    }

    /// iOS kills apps that submit Metal work in the background, so the GPU
    /// gate closes immediately and on-device (MLX) STT/TTS engines are swapped
    /// for Apple Speech / the system voice for the rest of the call. VAD
    /// always runs on the CPU and needs no change.
    fileprivate func leaveForeground() {
        MLXCallLock.gpuAllowed = false
        guard let orch = orchestrator else { return }
        if orch.usesGPUTTS {
            orch.replaceTTS(CallEngineFactory.makeSystemTTS())
        }
        guard orch.usesGPUSTT else { return }
        Task { [weak self] in
            let apple = await CallEngineFactory.makeAppleSTT()
            guard let self, let orch = self.orchestrator, orch.usesGPUSTT else {
                apple.shutdown()
                return
            }
            orch.replaceSTT(apple)
            self.isUsingServerSTT = false
        }
    }

    fileprivate func unwireAudioSession() {
        audioSession.onInterruption = nil
        audioSession.onRouteChange = nil
        backgroundObservers.forEach(NotificationCenter.default.removeObserver)
        backgroundObservers = []
        wasPausedByInterruption = false
    }

    fileprivate func startDurationTimer() {
        durationTimer?.cancel()
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let start = self.callStartTime else { return }
                self.callDuration = Date().timeIntervalSince(start)
            }
        }
    }
}
