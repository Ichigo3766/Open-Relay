import Foundation
import AVFoundation
import os.log

/// Manages audio recording for voice notes.
///
/// Records audio to a temporary file using AVAudioRecorder,
/// provides real-time metering for waveform visualization,
/// and returns the recorded data on completion.
@MainActor @Observable
final class AudioRecordingService: NSObject {

    // MARK: - State

    enum RecordingState: Sendable, Equatable {
        case idle
        case recording
        case paused
        case error(String)
    }

    /// Current recording state.
    private(set) var state: RecordingState = .idle

    /// Duration of the current recording in seconds.
    private(set) var duration: TimeInterval = 0

    /// Audio level (0–1) for waveform visualization.
    private(set) var audioLevel: Float = 0

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "AudioRecording")
    private var recorder: AVAudioRecorder?
    private var meteringTimer: Timer?
    private var durationTimer: Timer?
    private var recordingURL: URL?

    // MARK: - Public API

    /// Starts recording audio to a temporary file.
    func startRecording() throws {
        guard recorder == nil else { return }

        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        // Create temporary file URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "voice_note_\(Int(Date.now.timeIntervalSince1970)).m4a"
        let url = tempDir.appendingPathComponent(fileName)
        recordingURL = url

        // Recording settings - AAC for good quality/size ratio
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.isMeteringEnabled = true

        guard recorder?.record() == true else {
            state = .error("Failed to start recording")
            throw RecordingError.failedToStart
        }

        state = .recording
        duration = 0
        startTimers()
    }

    /// Pauses the current recording.
    func pauseRecording() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
        stopTimers()
    }

    /// Resumes a paused recording.
    func resumeRecording() {
        guard state == .paused else { return }
        recorder?.record()
        state = .recording
        startTimers()
    }

    /// Stops recording and returns the recorded audio data.
    func stopRecording() -> RecordingResult? {
        guard let recorder, recordingURL != nil else { return nil }

        let finalDuration = recorder.currentTime
        recorder.stop()
        stopTimers()

        self.recorder = nil
        state = .idle
        audioLevel = 0

        guard let url = recordingURL else { return nil }
        recordingURL = nil

        guard let data = try? Data(contentsOf: url) else {
            logger.error("Failed to read recorded audio data")
            return nil
        }

        // Clean up temp file
        try? FileManager.default.removeItem(at: url)

        return RecordingResult(
            data: data,
            duration: finalDuration,
            format: "m4a",
            fileName: url.lastPathComponent
        )
    }

    /// Cancels recording without saving.
    func cancelRecording() {
        recorder?.stop()
        stopTimers()
        recorder = nil
        state = .idle
        audioLevel = 0
        duration = 0

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }

    /// Whether the app has microphone permission.
    func checkPermission() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    /// Requests microphone permission.
    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func startTimers() {
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMetering()
            }
        }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.duration = self?.recorder?.currentTime ?? 0
            }
        }
    }

    private func stopTimers() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func updateMetering() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        // Normalize from dB (-160 to 0) to 0–1
        let normalized = max(0, (power + 50) / 50)
        audioLevel = min(1, normalized)
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecordingService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            Task { @MainActor [weak self] in
                self?.state = .error("Recording failed")
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.state = .error(error?.localizedDescription ?? "Encoding error")
        }
    }
}

// MARK: - Types

/// The result of a completed audio recording.
struct RecordingResult: Sendable {
    let data: Data
    let duration: TimeInterval
    let format: String
    let fileName: String
}

/// Recording-related errors.
enum RecordingError: LocalizedError {
    case failedToStart
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .failedToStart:
            return "Failed to start audio recording."
        case .permissionDenied:
            return "Microphone permission is required to record audio."
        }
    }
}
