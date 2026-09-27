import Foundation
import AVFoundation
import os.log

// MARK: - DictationState

enum DictationState: Sendable, Equatable {
    case idle
    case requesting      // Asking for permissions
    case listening       // Actively recording
    case processing      // Uploading / transcribing
    case error(String)
}

// MARK: - DictationService

/// Orchestrates dictation (voice-to-text into the chat input field).
///
/// Both device and server backends use the same `AVAudioRecorder`-based
/// recording approach — the only difference is what happens on stop:
/// - **Server mode** → upload audio to `/api/v1/audio/transcriptions`
/// - **Device mode** → feed audio to `OnDeviceASRService.transcribe()` (Qwen3 ASR, multilingual)
///
/// Using `AVAudioRecorder` for both modes means the waveform meter is
/// always live and continuous — no segment restart gaps.
@MainActor @Observable
final class DictationService {

    // MARK: - State

    private(set) var state: DictationState = .idle

    /// Audio waveform intensity level (0–10), updated during recording.
    private(set) var intensity: Int = 0

    /// Elapsed recording time in seconds.
    private(set) var recordingDuration: TimeInterval = 0

    /// The engine key that is actually being used for the current session.
    /// Publicly readable so the overlay can display the correct label/icon.
    private(set) var activeEngine: String = "device"

    /// Human-readable name of the active ASR engine.
    var currentEngineName: String {
        activeEngine == "server" ? "Server" : "On-Device"
    }

    /// SF Symbol name for the active ASR engine.
    var currentEngineIcon: String {
        activeEngine == "server" ? "icloud" : "brain"
    }

    /// Whether the service is currently recording (listening or processing).
    var isActive: Bool {
        switch state {
        case .listening, .processing, .requesting: return true
        default: return false
        }
    }

    let recoveryStore: DictationRecoveryStore
    private(set) var context: DictationContext?
    private(set) var pendingRecording: DictationRecoveryStore.Recording?
    private(set) var attemptTask: Task<Void, Never>?
    private var attemptID: UUID?
    private var recordingSession = UUID()
    private var isCurrentContext: (() -> Bool)?
    private var currentDraft: (() -> String?)?

    var savedAudioURL: URL? { pendingRecording.map(recoveryStore.audioURL) }
    var showsRecovery: Bool { pendingRecording != nil && state != .listening && state != .requesting }
    var canTranscribeOnDevice: Bool {
        guard let service = onDeviceASRService, service.isAvailable else { return false }
        return service.state != .loading && service.state != .transcribing
    }

    init(recoveryStore: DictationRecoveryStore? = nil) {
        self.recoveryStore = recoveryStore ?? .shared
    }

    func bind(to context: DictationContext, isCurrent: @escaping () -> Bool,
              draft: @escaping () -> String?, deliver: @escaping (String) -> Void) {
        guard isCurrent() else { unbind(); return }
        let changed = self.context != context
        if changed { unbind() }
        self.context = context
        isCurrentContext = isCurrent
        currentDraft = draft
        onTranscriptReady = deliver
        guard changed || (state != .listening && state != .requesting && attemptTask == nil) else { return }
        do {
            pendingRecording = try recoveryStore.load(context)?.recording
            if let pending = pendingRecording {
                recordingDuration = pending.duration
                activeEngine = pending.engine
                if pending.committed {
                    // The draft was durably committed before a previous interruption.
                    if let entry = try recoveryStore.load(context) { deliver(entry.draft) }
                    try recoveryStore.discard(context)
                    pendingRecording = nil
                    state = .idle
                } else {
                    state = .error(pending.completed ? "Transcription failed" : "Recording interrupted")
                }
            }
        } catch { fail(error) }
    }

    /// Navigation/account changes never delete completed or in-progress audio.
    func unbind() {
        if state == .listening { finishRecording() }
        cancelAttempt()
        recordingSession = UUID()
        context = nil
        pendingRecording = nil
        currentDraft = nil
        isCurrentContext = nil
        onTranscriptReady = nil
        state = .idle
    }

    // MARK: - Callbacks

    /// Delivers the complete, already-persisted draft (not an uncommitted transcript).
    var onTranscriptReady: ((String) -> Void)?

    /// Fired when an error occurs (e.g. permission denied).
    var onError: ((String) -> Void)?

    // MARK: - Dependencies

    var serverSpeechService: ServerSpeechRecognitionService?
    var onDeviceASRService: OnDeviceASRService?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "Dictation")

    /// `AVAudioRecorder` used for both device and server modes.
    private var recorder: AVAudioRecorder?
    private var meteringTimer: Timer?
    private var durationTimer: Timer?

    // MARK: - Engine Preference

    private var preferredEngine: String {
        UserDefaults.standard.string(forKey: "sttEngine") ?? "device"
    }

    private var shouldUseServerSTT: Bool {
        preferredEngine == "server" && (serverSpeechService?.isAvailable == true)
    }

    // MARK: - Public API

    /// Starts dictation. Picks device or server backend based on `sttEngine` preference.
    func startDictation() async {
        guard !isActive, attemptTask == nil, pendingRecording == nil,
              context != nil, isCurrentContext?() == true else { return }

        state = .requesting
        intensity = 0
        recordingDuration = 0

        // Latch the engine choice for this session
        activeEngine = shouldUseServerSTT ? "server" : "device"

        logger.info("Starting dictation with engine: \(self.activeEngine)")
        recordingSession = UUID()
        await startRecording()
    }

    /// Stops recording and triggers transcription.
    func stopDictation() {
        guard state == .listening else { return }
        finishRecording()
        retry()
    }

    private func finishRecording() {
        stopTimers()
        recordingDuration = recorder?.currentTime ?? recordingDuration
        recorder?.stop()
        recorder = nil
        intensity = 0
        guard let context, var pending = pendingRecording else { return }
        pending.duration = recordingDuration
        pending.completed = true
        pendingRecording = pending
        do {
            try recoveryStore.update(pending, for: context)
            state = .error("Recording saved")
        } catch { fail(error) }
    }

    func cancelAttempt() {
        attemptID = nil
        attemptTask?.cancel()
        // Keep the task until it exits, even if a backend ignores cancellation.
        if pendingRecording != nil { state = .error("Transcription stopped") }
    }

    func discardRecording() {
        cancelAttempt()
        recordingSession = UUID()
        stopTimers()
        recorder?.stop()
        recorder = nil
        do {
            if let context { try recoveryStore.discard(context) }
            pendingRecording = nil
            intensity = 0
            recordingDuration = 0
            state = .idle
        } catch { fail(error) }
    }

    func retry(onDevice: Bool = false) {
        guard attemptTask == nil, state != .listening, state != .requesting,
              let context, let pending = pendingRecording,
              isCurrentContext?() == true else { return }
        if pending.committed {
            discardRecording()
            return
        }
        let client = serverSpeechService?.apiClient
        // Freeze authorization before the async work; an account switch must not
        // cause this recording to use the newly selected account's credentials.
        let authorization = client?.network.authToken.map { "Bearer " + $0 }
        let localService = onDeviceASRService
        let useDevice = onDevice || pending.engine != "server"
        let id = UUID()
        attemptID = id
        activeEngine = useDevice ? "device" : "server"
        state = .processing
        attemptTask = Task { [weak self] in
            guard let self else { return }
            defer { self.attemptTask = nil }
            do {
                try Task.checkCancellation()
                guard self.context == context, isCurrentContext?() == true else {
                    cancelAttempt()
                    return
                }
                let audio = try Data(contentsOf: recoveryStore.audioURL(pending))
                let text: String
                if useDevice {
                    guard let localService, canTranscribeOnDevice else {
                        throw DictationRecoveryStore.RecoveryError.unavailable
                    }
                    text = try await localService.transcribe(audioData: audio, fileName: "Recording.m4a")
                } else {
                    guard let client, let authorization else {
                        throw DictationRecoveryStore.RecoveryError.unavailable
                    }
                    let result = try await client.transcribeSpeech(audioData: audio, fileName: "Recording.m4a",
                                                                   authorization: authorization, timeout: 360)
                    text = result["text"] as? String ?? ""
                }
                try Task.checkCancellation()
                guard attemptID == id, self.context == context,
                      pendingRecording?.id == pending.id else { return }
                guard isCurrentContext?() == true, let draft = currentDraft?(),
                      let deliver = onTranscriptReady else { cancelAttempt(); return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw DictationRecoveryStore.RecoveryError.emptyTranscript }
                let merged = try recoveryStore.commit(trimmed, recordingID: pending.id, draft: draft, context: context)
                pendingRecording?.committed = true
                deliver(merged)
                try recoveryStore.discard(context)
                pendingRecording = nil
                recordingDuration = 0
                state = .idle
            } catch {
                guard attemptID == id, self.context == context, pendingRecording?.id == pending.id else { return }
                fail(error)
            }
        }
    }

    /// Cancels dictation without producing any transcript.
    func cancelDictation() {
        if showsRecovery { cancelAttempt() } else { discardRecording() }
    }

    /// Switches the ASR engine mid-session (called by the engine chip in the overlay).
    /// Stops the current recording, flips `activeEngine`, saves the preference,
    /// and restarts dictation with the new engine.
    func switchEngine() async {
        guard state == .listening else { return }

        // Stop current recording and discard audio
        discardRecording()
        guard pendingRecording == nil else { return }

        // Flip engine
        let newEngine: String
        if activeEngine == "server" {
            newEngine = "device"
        } else {
            newEngine = (serverSpeechService?.isAvailable == true) ? "server" : "device"
        }
        UserDefaults.standard.set(newEngine, forKey: "sttEngine")
        activeEngine = newEngine

        state = .requesting
        intensity = 0
        // Keep recordingDuration running

        logger.info("Engine switched to \(newEngine)")
        await startRecording()
    }

    // MARK: - Recording (shared by both backends)

    /// Configures the audio session, creates an `AVAudioRecorder`, and starts recording.
    /// Used for both device (Qwen3) and server modes.
    private func startRecording() async {
        let sessionID = recordingSession
        // Check / request mic permission
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { result in
                    continuation.resume(returning: result)
                }
            }
        }
        guard sessionID == recordingSession, isCurrentContext?() == true else { return }
        guard granted else {
            state = .error("Microphone permission denied")
            onError?("Microphone permission denied")
            return
        }

        // Configure audio session
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            let msg = error.localizedDescription
            state = .error(msg)
            onError?(msg)
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32000
        ]

        do {
            guard let context, let draft = currentDraft?() else { return }
            let pending = try recoveryStore.begin(context, draft: draft, engine: activeEngine)
            pendingRecording = pending
            let url = recoveryStore.audioURL(pending)
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            guard recorder?.record() == true else {
                state = .error("Failed to start recording")
                onError?("Failed to start recording")
                return
            }
        } catch {
            let msg = error.localizedDescription
            state = .error(msg)
            onError?(msg)
            return
        }

        state = .listening
        startDurationTimer()
        startMeteringTimer()
        logger.info("Recording started (\(self.activeEngine) mode)")
    }

    private func fail(_ error: Error) {
        state = .error(error.localizedDescription)
        onError?(error.localizedDescription)
    }

    // MARK: - Timers

    private func startDurationTimer() {
        durationTimer?.invalidate()
        let start = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .listening else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func startMeteringTimer() {
        meteringTimer?.invalidate()
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let rec = self.recorder, rec.isRecording else { return }
                rec.updateMeters()
                let power = rec.averagePower(forChannel: 0)
                // Map -60 dB..0 dB → 0..10
                let normalized = max(0.0, min(1.0, (power + 60.0) / 60.0))
                let scaled = Int((normalized * 10).rounded())
                self.intensity = min(10, max(0, scaled))
            }
        }
    }

    private func stopTimers() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil
    }
}
