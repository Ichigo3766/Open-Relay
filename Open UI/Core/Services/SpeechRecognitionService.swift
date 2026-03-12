import Foundation
import Speech
import AVFoundation
import os.log

/// Manages speech recognition using Apple's Speech framework.
///
/// Provides real-time transcription from microphone input with
/// voice activity detection and intensity monitoring.
@MainActor @Observable
final class SpeechRecognitionService {

    // MARK: - State

    enum RecognitionState: Sendable, Equatable {
        case idle
        case requesting
        case listening
        case processing
        case error(String)
        case unavailable
    }

    /// Current recognition state.
    private(set) var state: RecognitionState = .idle

    /// The current interim transcript text.
    private(set) var currentTranscript: String = ""

    /// Voice intensity level (0–10) for waveform visualization.
    private(set) var intensity: Int = 0

    /// Whether the service has microphone and speech recognition permissions.
    private(set) var isAuthorized: Bool = false

    // MARK: - Callbacks

    /// Called when the final transcript is ready after speech ends.
    var onFinalTranscript: ((String) -> Void)?

    /// Called when the recognition state changes.
    var onStateChanged: ((RecognitionState) -> Void)?

    /// Called when an error occurs.
    var onError: ((String) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "SpeechRecognition")
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: Timer?
    private var intensityDecayTimer: Timer?
    private let silenceDuration: TimeInterval = 2.0
    private var lastSpeechTime: Date = .now

    // MARK: - Initialization

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
    }

    // MARK: - Permissions

    /// Checks and requests both speech recognition and microphone permissions.
    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            logger.warning("Speech recognition not authorized: \(String(describing: speechStatus))")
            isAuthorized = false
            return false
        }

        let micStatus: Bool
        if #available(iOS 17.0, *) {
            micStatus = await AVAudioApplication.requestRecordPermission()
        } else {
            micStatus = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard micStatus else {
            logger.warning("Microphone permission not granted")
            isAuthorized = false
            return false
        }

        isAuthorized = true
        return true
    }

    /// Checks current authorization status without prompting.
    func checkAuthorization() -> Bool {
        let speechAuth = SFSpeechRecognizer.authorizationStatus() == .authorized
        let micAuth: Bool
        if #available(iOS 17.0, *) {
            micAuth = AVAudioApplication.shared.recordPermission == .granted
        } else {
            micAuth = AVAudioSession.sharedInstance().recordPermission == .granted
        }
        isAuthorized = speechAuth && micAuth
        return isAuthorized
    }

    // MARK: - Start / Stop

    /// Begins listening for speech input via the microphone.
    func startListening() async throws {
        guard let recognizer, recognizer.isAvailable else {
            updateState(.unavailable)
            throw SpeechError.recognizerUnavailable
        }

        if !isAuthorized {
            let granted = await requestPermissions()
            guard granted else {
                updateState(.error("Permissions not granted"))
                throw SpeechError.notAuthorized
            }
        }

        // Stop any existing session
        stopListening()

        updateState(.requesting)

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.recognitionRequest = request

        // Set up audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install audio tap for recognition and intensity monitoring
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)
            Task { @MainActor [weak self] in
                self?.processAudioBuffer(buffer)
            }
        }

        engine.prepare()
        try engine.start()

        currentTranscript = ""
        lastSpeechTime = .now

        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    // Ignore cancellation errors
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        // "Request was canceled" - normal shutdown
                        return
                    }
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 209 {
                        // "No speech detected" - normal timeout
                        self.finishRecognition()
                        return
                    }
                    self.logger.error("Recognition error: \(error.localizedDescription)")
                    self.updateState(.error(error.localizedDescription))
                    self.onError?(error.localizedDescription)
                    return
                }

                guard let result else { return }

                self.currentTranscript = result.bestTranscription.formattedString
                self.lastSpeechTime = .now

                if result.isFinal {
                    self.finishRecognition()
                }
            }
        }

        updateState(.listening)
        startSilenceDetection()
        startIntensityDecay()
    }

    /// Stops listening and returns the final transcript.
    @discardableResult
    func stopListening() -> String {
        silenceTimer?.invalidate()
        silenceTimer = nil
        intensityDecayTimer?.invalidate()
        intensityDecayTimer = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        let transcript = currentTranscript
        if state != .idle {
            updateState(.idle)
        }
        intensity = 0

        return transcript
    }

    // MARK: - Private Helpers

    /// Finishes recognition and fires the final transcript callback.
    private func finishRecognition() {
        let transcript = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening()
        if !transcript.isEmpty {
            onFinalTranscript?(transcript)
        }
    }

    /// Monitors silence and auto-stops after the configured duration.
    private func startSilenceDetection() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let elapsed = Date.now.timeIntervalSince(self.lastSpeechTime)
                if elapsed > self.silenceDuration && !self.currentTranscript.isEmpty {
                    self.finishRecognition()
                }
            }
        }
    }

    /// Gradually decays intensity when no audio input is received.
    private func startIntensityDecay() {
        intensityDecayTimer?.invalidate()
        intensityDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.intensity > 0 else { return }
                self.intensity = max(0, self.intensity - 1)
            }
        }
    }

    /// Extracts audio intensity from the buffer for waveform visualization.
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        var peak: Float = 0
        for i in 0..<frameLength {
            let sample = abs(channelData[i])
            if sample > peak { peak = sample }
        }

        let scaled = Int((peak * 12).rounded())
        intensity = min(10, max(0, scaled))
    }

    /// Updates state and fires the callback.
    private func updateState(_ newState: RecognitionState) {
        state = newState
        onStateChanged?(newState)
    }
}

// MARK: - Errors

enum SpeechError: LocalizedError {
    case recognizerUnavailable
    case notAuthorized
    case audioSessionFailed

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition is not available on this device."
        case .notAuthorized:
            return "Speech recognition or microphone permission was denied."
        case .audioSessionFailed:
            return "Failed to configure the audio session."
        }
    }
}
