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
    /// Where call audio is currently heard — drives the route picker button.
    private(set) var outputRoute: CallOutputRoute = .speaker
    private(set) var modelName = ""
    private(set) var callDuration: TimeInterval = 0
    var errorMessage: String?
    /// Live turn-taking readout (nil unless Diagnostics is on).
    private(set) var diagnostics: CallDiagnostics?

    /// True when the active STT engine transcribes the whole utterance after the turn ends.
    var isUsingServerSTT = false

    // MARK: - Dependencies
    let ttsService: TextToSpeechService
    let vadModelStore: VADModelStore
    let settings: VoiceCallSettings
    let apiClientProvider: @MainActor () -> APIClient?
    var conversationManager: ConversationManager?
    var chatViewModel: ChatViewModel?

    @ObservationIgnored var orchestrator: CallOrchestrator?
    @ObservationIgnored var realtimeCall: RealtimeCallSession?
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
    /// Shown under the model name while a stand-in engine is used
    /// (e.g. "Using server voice while in background").
    var engineNotice: String?
    @ObservationIgnored var settingsObserver: NSObjectProtocol?
    @ObservationIgnored var engineSyncTask: Task<Void, Never>?
    @ObservationIgnored var debounceTask: Task<Void, Never>?
    /// On-device model the call used before a stand-in took over (Auto mode).
    @ObservationIgnored var autoModelLoaded: OnDeviceTTSModel?
    /// Signatures the running `engineSyncTask` is loading.
    @ObservationIgnored var syncTarget: String?

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
        // Honor the server's web search confirmation before any voice turn is sent.
        guard await chat.authorizeWebSearch() else {
            fail(chat.errorMessage ?? "Web search was not approved. Turn it off or try again.")
            return
        }
        guard callState == .connecting else { return }
        ttsService.stop()
        ttsService.readAloudPlayer.stop()

        guard await Self.requestPermissions(needsSpeech: !settings.useRealtimeBridge && settings.sttEngine == "apple") else {
            fail("Please grant microphone and speech recognition permissions in Settings.")
            return
        }
        guard callState == .connecting else { return }

        do {
            try audioSession.activate()
            audioSession.applyInitialRoute(preferSpeaker: settings.defaultSpeakerOn)
            refreshOutputRoute()
        } catch {
            fail("Couldn't start audio: \(error.localizedDescription)")
            return
        }

        // Load engines + VAD models in parallel with each other.
        let api = apiClientProvider()
        if settings.useRealtimeBridge {
            guard let api else { fail("Connect to a server to use Realtime calls."); return }
            let call = RealtimeCallSession(api: api, chat: chat)
            realtimeCall = call
            call.onState = { [weak self] state in
                guard let self, self.callState != .disconnected else { return }
                self.callState = state
                self.updateLiveActivity()
                self.updateTurnBackgroundTask()
            }
            call.onTranscript = { [weak self] in self?.currentTranscript = $0 }
            call.onLevel = { [weak self] in self?.voiceIntensity = Int(min(10, ($0 * 40).rounded())) }
            call.onError = { [weak self] in self?.fail($0) }
            call.setMuted(isMuted)
            do { try await call.start() } catch {
                if callState != .disconnected { fail(error.localizedDescription) }
                return
            }
            guard callState != .disconnected, realtimeCall != nil else { call.stop(); return }
            engineNotice = "Realtime voice"
            isUsingServerSTT = false
            wireAudioSession()
            let start = Date()
            callStartTime = start
            startDurationTimer()
            startLiveActivity(startDate: start)
            return
        }
        async let vadReady: Void = vadModelStore.loadIfNeeded()
        let stt = await CallEngineFactory.makeSTT(settings: settings, apiClient: api)
        let tts = await CallEngineFactory.makeTTS(settings: settings, apiClient: api, ttsService: ttsService)
        _ = await vadReady
        guard callState == .connecting else { stt.shutdown(); tts.shutdown(); return }
        isUsingServerSTT = stt is ServerCallSTTEngine
        // Record what was actually built: if an engine fell back at start
        // (e.g. the on-device model failed to load), its signature differs
        // from the wanted one, so the next sync (settings change or return
        // to the foreground) retries the user's choice.
        let wanted = CallEngineSelection.resolve(
            settings: settings, ttsService: ttsService, hasServer: api != nil, inForeground: true,
            onDeviceLoaded: (tts as? MLXCallTTSEngine)?.model
        )
        let startSelection = (
            voice: CallEngineFactory.matches(tts, wanted.voice) ? wanted.voiceSignature : "start|\(tts.displayName)",
            listening: CallEngineFactory.matches(stt, wanted.listening) ? wanted.listeningSignature : "start|\(stt.displayName)"
        )

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
        orch.ttsSignature = startSelection.voice
        orch.sttSignature = startSelection.listening
        startEngineSync()
        let start = Date()
        callStartTime = start
        startDurationTimer()
        startLiveActivity(startDate: start)
        // The app may already be leaving the foreground (e.g. locked while
        // connecting) — make sure GPU engines are swapped out right away.
        if !isInForeground { enterBackground() }
    }

    func endCall() async {
        callState = .disconnected
        stopEngineSync()
        unwireAudioSession()
        realtimeCall?.stop()
        realtimeCall = nil
        engineNotice = nil
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
        guard orchestrator != nil || realtimeCall != nil else { return }
        isPaused = true
        orchestrator?.pause()
        realtimeCall?.setPaused(true)
    }

    func resumeListening() async {
        isPaused = false
        orchestrator?.resume()
        realtimeCall?.setPaused(false)
    }

    /// Mute only silences the mic (voice processing input mute); replies keep playing.
    func toggleMute() {
        isMuted.toggle()
        orchestrator?.isMicMuted = isMuted
        realtimeCall?.setMuted(isMuted)
        updateLiveActivity()
    }

    func cancelSpeaking() async {
        orchestrator?.interrupt()
        await realtimeCall?.interrupt()
    }

    /// Re-reads where call audio is heard (earpiece, speaker, AirPods, car…).
    /// Output choices themselves are made in the system route picker.
    func refreshOutputRoute() {
        let route = CallOutputRoute.current()
        if route != outputRoute { outputRoute = route }
    }
}


// MARK: - Helpers

extension VoiceCallViewModel {

    fileprivate func fail(_ message: String) {
        callState = .error(message)
        errorMessage = message
        if let realtimeCall { realtimeCall.stop(); self.realtimeCall = nil; audioSession.deactivate() }
        stopEngineSync()
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
            // The user is talking again — an earlier turn error is stale.
            if !text.isEmpty, self.errorMessage != nil { self.errorMessage = nil }
        }
        orch.onUserTurn = { [weak self] text in
            self?.currentTranscript = text
            self?.errorMessage = nil
        }
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
            guard let self, self.orchestrator != nil || self.realtimeCall != nil else { return }
            switch type {
            case .began:
                self.logger.info("Audio interruption began — pausing call")
                self.wasPausedByInterruption = !self.isPaused
                self.orchestrator?.pause()
                self.realtimeCall?.setPaused(true)
            case .ended:
                self.logger.info("Audio interruption ended")
                guard self.wasPausedByInterruption else { return }
                self.wasPausedByInterruption = false
                // Without CallKit the app owns the session: take it back and
                // resume (resume() rebuilds the audio engine if it stopped).
                self.audioSession.reactivate()
                self.audioSession.applyInitialRoute(preferSpeaker: self.settings.defaultSpeakerOn)
                self.refreshOutputRoute()
                if !self.isPaused { self.orchestrator?.resume() }
                if !self.isPaused { self.realtimeCall?.setPaused(false) }
            @unknown default:
                break
            }
        }
        audioSession.onRouteChange = { [weak self] reason in
            guard let self, self.orchestrator != nil || self.realtimeCall != nil else { return }
            self.logger.info("Audio route changed (reason \(reason.rawValue))")
            switch reason {
            case .newDeviceAvailable:
                // Headset / car connected mid-call: drop any speaker override
                // so audio (and the mic) move to it.
                if CallOutputRoute.hasExternalDevice() { self.audioSession.setSpeakerOverride(false) }
                self.audioSession.preferExternalInputIfAvailable()
            case .oldDeviceUnavailable:
                // Device went away: fall back to the user's starting preference.
                self.audioSession.applyInitialRoute(preferSpeaker: self.settings.defaultSpeakerOn)
            default:
                // .override / .categoryChange / picker selections are the
                // user's (or system's) choice — never undo them.
                break
            }
            self.refreshOutputRoute()
            self.orchestrator?.audioRouteChanged()
            self.realtimeCall?.audioRouteChanged()
        }
        backgroundObservers.forEach(NotificationCenter.default.removeObserver)
        backgroundObservers = [
            // willResignActive (not didEnterBackground) — it fires first, with
            // enough headroom to stop submitting Metal work before iOS forbids it.
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterBackground() }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterForeground() }
            },
        ]
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

