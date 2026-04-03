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

    // MARK: - Callbacks

    /// Fired when transcription is complete. Append the string to the input field.
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
    private var recordingURL: URL?
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
        guard !isActive else { return }

        state = .requesting
        intensity = 0
        recordingDuration = 0

        // Latch the engine choice for this session
        activeEngine = shouldUseServerSTT ? "server" : "device"

        logger.info("Starting dictation with engine: \(self.activeEngine)")
        await startRecording()
    }

    /// Stops recording and triggers transcription.
    func stopDictation() {
        stopTimers()
        recorder?.stop()
        recorder = nil

        guard let url = recordingURL else {
            state = .idle
            return
        }
        recordingURL = nil
        intensity = 0
        recordingDuration = 0
        state = .processing

        if activeEngine == "server" {
            uploadForServerTranscription(url: url)
        } else {
            transcribeOnDevice(url: url)
        }
    }

    /// Cancels dictation without producing any transcript.
    func cancelDictation() {
        stopTimers()
        recorder?.stop()
        recorder = nil
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
        intensity = 0
        recordingDuration = 0
        state = .idle
        logger.info("Dictation cancelled")
    }

    /// Switches the ASR engine mid-session (called by the engine chip in the overlay).
    /// Stops the current recording, flips `activeEngine`, saves the preference,
    /// and restarts dictation with the new engine.
    func switchEngine() async {
        guard isActive else { return }

        // Stop current recording and discard audio
        stopTimers()
        recorder?.stop()
        recorder = nil
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

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

        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "dictation_\(Int(Date().timeIntervalSince1970)).m4a"
        let url = tempDir.appendingPathComponent(fileName)
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32000
        ]

        do {
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

    // MARK: - Server Transcription

    private func uploadForServerTranscription(url: URL) {
        guard let service = serverSpeechService else {
            state = .idle
            logger.warning("Server STT not available")
            return
        }

        Task { [weak self] in
            guard let self else { return }

            guard FileManager.default.fileExists(atPath: url.path) else {
                await MainActor.run { self.state = .idle }
                return
            }

            guard let client = service.apiClient else {
                await MainActor.run {
                    self.state = .error("No server configured")
                    self.onError?("No server configured")
                }
                return
            }

            do {
                let audioData = try Data(contentsOf: url)
                defer { try? FileManager.default.removeItem(at: url) }

                guard audioData.count > 512 else {
                    self.logger.info("Recording too short (\(audioData.count) bytes), ignoring")
                    await MainActor.run { self.state = .idle }
                    return
                }

                self.logger.info("Uploading dictation audio: \(audioData.count) bytes to server")
                let result = try await client.transcribeSpeech(
                    audioData: audioData,
                    fileName: url.lastPathComponent
                )
                self.logger.info("Server transcription response keys: \(result.keys.joined(separator: ", "))")

                let text: String
                if let transcript = result["text"] as? String {
                    text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    self.logger.warning("No 'text' key in response: \(result)")
                    text = ""
                }

                await MainActor.run {
                    self.state = .idle
                    if !text.isEmpty {
                        self.logger.info("Server dictation delivered: \(text.count) chars")
                        self.onTranscriptReady?(text)
                    } else {
                        self.logger.info("Server dictation returned empty text")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                let msg = error.localizedDescription
                self.logger.error("Server dictation upload failed: \(msg)")
                await MainActor.run {
                    self.state = .error(msg)
                    self.onError?(msg)
                }
            }
        }
    }

    // MARK: - On-Device Transcription (Qwen3 ASR)

    private func transcribeOnDevice(url: URL) {
        guard let asrService = onDeviceASRService else {
            logger.warning("OnDeviceASRService not available")
            state = .idle
            return
        }

        Task { [weak self] in
            guard let self else { return }

            guard FileManager.default.fileExists(atPath: url.path) else {
                await MainActor.run { self.state = .idle }
                return
            }

            do {
                let audioData = try Data(contentsOf: url)
                defer { try? FileManager.default.removeItem(at: url) }

                guard audioData.count > 512 else {
                    self.logger.info("Recording too short (\(audioData.count) bytes), ignoring")
                    await MainActor.run { self.state = .idle }
                    return
                }

                self.logger.info("Transcribing dictation on-device: \(audioData.count) bytes")
                let text = try await asrService.transcribe(
                    audioData: audioData,
                    fileName: url.lastPathComponent
                )

                await MainActor.run {
                    self.state = .idle
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.logger.info("On-device dictation delivered: \(trimmed.count) chars")
                        self.onTranscriptReady?(trimmed)
                    } else {
                        self.logger.info("On-device dictation returned empty text")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                let msg = error.localizedDescription
                self.logger.error("On-device transcription failed: \(msg)")
                await MainActor.run {
                    self.state = .error(msg)
                    self.onError?(msg)
                }
            }
        }
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
