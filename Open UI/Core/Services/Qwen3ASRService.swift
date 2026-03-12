import Foundation
import AVFoundation
import os.log

#if canImport(MLXAudioSTT)
import MLXAudioSTT
import MLXAudioCore
import MLX
#endif

// MARK: - Qwen3 ASR State

enum Qwen3ASRState: Sendable, Equatable {
    case unloaded
    case downloading(progress: Double)
    case loading
    case ready
    case transcribing
    case error(String)
}

// MARK: - Qwen3 ASR Service

/// On-device automatic speech recognition using Qwen3-ASR-0.6B.
/// Transcribes audio files to text locally — no data sent to external servers.
///
/// Backed by `Qwen3ASRModel` from the mlx-audio-swift unified audio package.
/// The library handles long-form audio via built-in energy-based silence detection
/// and smart chunking — no manual chunk management needed.
///
/// Model: `mlx-community/Qwen3-ASR-0.6B-4bit` (~400 MB)
/// Supports 52 languages including English, Chinese, Japanese, etc.
@MainActor @Observable
final class Qwen3ASRService {

    // MARK: - State

    private(set) var state: Qwen3ASRState = .unloaded
    var isReady: Bool { state == .ready }
    private(set) var downloadProgress: Double = 0

    var isAvailable: Bool {
        #if canImport(MLXAudioSTT)
        return true
        #else
        return false
        #endif
    }

    /// Whether auto-transcription of audio attachments is enabled (always on).
    var autoTranscribeEnabled: Bool { true }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "Qwen3ASR")
    private var isLoadInProgress = false

    /// Target sample rate for ASR model input. Qwen3-ASR expects 16kHz audio.
    private let targetSampleRate = 16000

    #if canImport(MLXAudioSTT)
    private var model: Qwen3ASRModel?
    #endif

    // MARK: - Model Loading

    func loadModel() async throws {
        guard isAvailable else { throw Qwen3ASRError.notAvailable }

        #if canImport(MLXAudioSTT)
        if isLoadInProgress {
            logger.info("Qwen3 ASR model load already in progress, ignoring")
            return
        }
        if model != nil && state == .ready { return }
        if case .ready = state { return }

        isLoadInProgress = true
        state = .downloading(progress: 0)
        downloadProgress = 0
        logger.info("Loading Qwen3 ASR model via mlx-audio-swift...")

        let progressTask = Task { [weak self] in
            await self?.pollDownloadProgress()
        }

        do {
            let loadedModel = try await Qwen3ASRModel.fromPretrained(
                "mlx-community/Qwen3-ASR-0.6B-4bit"
            )
            progressTask.cancel()
            self.model = loadedModel
            downloadProgress = 1.0
            state = .ready
            isLoadInProgress = false
            logger.info("Qwen3 ASR model loaded successfully")
        } catch {
            progressTask.cancel()
            let msg = error.localizedDescription
            state = .error("Qwen3 ASR load failed: \(msg)")
            isLoadInProgress = false
            throw Qwen3ASRError.modelLoadFailed(msg)
        }
        #else
        throw Qwen3ASRError.notAvailable
        #endif
    }

    func unloadModel() {
        #if canImport(MLXAudioSTT)
        model = nil
        Memory.clearCache()
        #endif
        isLoadInProgress = false
        state = .unloaded
        logger.info("Qwen3 ASR model unloaded")
    }

    /// STORAGE FIX: Unloads the model AND deletes the downloaded files from disk.
    /// Frees ~400MB of storage. The model will re-download on next use.
    func unloadAndDeleteModel() {
        unloadModel()
        let freed = StorageManager.shared.deleteQwen3ASRModelFiles()
        if freed > 0 {
            logger.info("Qwen3 ASR model files deleted (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))")
        }
    }

    // MARK: - Transcription

    /// Transcribes audio data (WAV, M4A, MP3, etc.) to text.
    /// Audio is resampled to 16kHz (model requirement) before transcription.
    /// The mlx-audio-swift library handles long audio natively via energy-based
    /// silence detection and smart chunking.
    ///
    /// - Parameter audioData: Raw audio file data
    /// - Parameter fileName: Original filename (used to determine format)
    /// - Returns: Transcribed text
    func transcribe(audioData: Data, fileName: String) async throws -> String {
        guard isAvailable else { throw Qwen3ASRError.notAvailable }

        try await loadModel()

        #if canImport(MLXAudioSTT)
        guard let model else { throw Qwen3ASRError.modelNotLoaded }

        state = .transcribing
        logger.info("Transcribing audio: \(fileName) (\(audioData.count) bytes)")

        // Write audio data to a temporary file for AVAudioFile loading
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + fileName)

        defer { try? FileManager.default.removeItem(at: tempURL) }
        try audioData.write(to: tempURL)

        // Load audio and resample to 16kHz (model requirement).
        // loadAudioArray(from:sampleRate:) handles resampling automatically.
        // Without this, 48kHz audio uses 3x the memory and the model
        // produces garbage output or crashes with OOM.
        let (sampleRate, audioArray) = try loadAudioArray(from: tempURL, sampleRate: targetSampleRate)

        let totalSamples = audioArray.dim(0)
        guard totalSamples > 0 else {
            state = .ready
            throw Qwen3ASRError.transcriptionFailed("No audio samples extracted")
        }

        let totalDuration = Double(totalSamples) / Double(sampleRate)
        logger.info("Audio loaded: \(String(format: "%.1f", totalDuration))s at \(sampleRate)Hz (\(totalSamples) samples)")

        // Set memory cache limit to prevent OOM on long files
        Memory.cacheLimit = 512 * 1024 * 1024 // 512MB

        let text: String = await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let output = model.generate(
                    audio: audioArray,
                    generationParameters: STTGenerateParameters(
                        maxTokens: 8192,
                        temperature: 0.0,
                        language: "English",
                        chunkDuration: 300.0,  // 5 min chunks for memory safety
                        minChunkDuration: 1.0
                    )
                )
                continuation.resume(returning: output.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        state = .ready
        Memory.clearCache()

        guard !text.isEmpty else {
            throw Qwen3ASRError.transcriptionFailed("No speech detected in audio")
        }

        logger.info("Transcription complete: \(text.count) chars")
        return text
        #else
        throw Qwen3ASRError.notAvailable
        #endif
    }

    /// Transcribes audio from a file URL.
    func transcribe(fileURL: URL) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        return try await transcribe(audioData: data, fileName: fileURL.lastPathComponent)
    }

    // MARK: - Progress Polling

    private func pollDownloadProgress() async {
        var elapsed: Double = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            elapsed += 0.5
            let progress = min(elapsed / 40.0, 0.95)
            downloadProgress = progress
            state = .downloading(progress: progress)
        }
    }
}

// MARK: - Errors

enum Qwen3ASRError: LocalizedError {
    case notAvailable
    case modelNotLoaded
    case modelLoadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "Qwen3 ASR not available on this device."
        case .modelNotLoaded: return "Qwen3 ASR model not loaded."
        case .modelLoadFailed(let r): return "Qwen3 ASR model load failed: \(r)"
        case .transcriptionFailed(let r): return "Transcription failed: \(r)"
        }
    }
}
