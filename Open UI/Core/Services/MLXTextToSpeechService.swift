import Foundation
import UIKit
import AVFoundation
import os.log

#if canImport(MLXAudioTTS)
import MLXAudioTTS
import MLXAudioCore
import MLX
import MLXLMCommon
import HuggingFace
#endif

// MARK: - Marvis TTS Configuration

struct MarvisTTSConfig {
    var voice: String = "conversationalA"
    var qualityLevel: Int = 32 // 8=low, 16=medium, 24=high, 32=maximum
    /// Seconds of audio buffered per streaming yield. Higher values reduce
    /// stuttering between sentence boundaries at the cost of initial latency.
    var streamingInterval: Double = 1.5
}

// MARK: - Marvis TTS State

enum MarvisTTSState: Sendable, Equatable {
    case unloaded
    case downloading(progress: Double)
    case loading
    case ready
    case generating
    case error(String)
}

// MARK: - Marvis Text-to-Speech Service
///
/// Uses the MLXAudioTTS library (via mlx-audio-swift) for on-device neural TTS
/// with streaming playback. Audio is streamed directly as generated — no sentence
/// splitting or WAV conversion needed. The library handles text segmentation internally.
///
/// Backed by `MarvisTTSModel` from the mlx-audio-swift unified audio package.
/// A single persistent `AudioPlayer` from MLXAudioCore handles all streaming
/// playback. Creating a new AudioPlayer per play causes zombie AVAudioEngine
/// instances that fight for audio resources — the canonical pattern (from the
/// library's VoicesApp example) is to create ONE player and reuse it.
///
/// Usage:
///   1. Call `loadModel()` to download & warm up the model.
///   2. Call `speak(_:)` to generate + stream-play text.
///   3. Call `stop()` to cancel generation and playback.

@MainActor @Observable
final class MarvisTTSService {

    // MARK: - State

    private(set) var state: MarvisTTSState = .unloaded
    var isReady: Bool { state == .ready }
    var isPlaying: Bool { isRunning }

    var isAvailable: Bool {
        #if canImport(MLXAudioTTS)
        return true
        #else
        return false
        #endif
    }

    private(set) var downloadProgress: Double = 0

    // MARK: - Configuration

    var config = MarvisTTSConfig()

    // MARK: - Callbacks

    var onSpeakingStarted: (() -> Void)?
    var onSpeakingComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "MarvisTTS")

    #if canImport(MLXAudioTTS)
    private var model: MarvisTTSModel?
    /// Single persistent audio player — reused across all playback sessions.
    /// Creating a new AudioPlayer per play leaves zombie AVAudioEngine instances
    /// that cause stuttering on subsequent plays. This matches the canonical
    /// pattern from the library's VoicesApp example.
    private let audioPlayer = AudioPlayer()
    #endif

    private var isLoadInProgress = false
    private var isRunning = false
    private var generationTask: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    /// Queue of sentences waiting to be generated + played (used by streaming enqueue).
    private var sentenceQueue: [String] = []

    // MARK: - Model Loading

    func loadModel() async throws {
        guard isAvailable else { throw MarvisTTSServiceError.notAvailable }

        #if canImport(MLXAudioTTS)
        if isLoadInProgress { return }
        if model != nil, case .ready = state { return }

        isLoadInProgress = true
        state = .downloading(progress: 0)
        downloadProgress = 0
        logger.info("Loading MarvisTTS model via mlx-audio-swift…")

        do {
            let modelCache = HubCache(location: .fixed(directory: StorageManager.modelCacheDirectory))
            let loaded = try await MarvisTTSModel.fromPretrained(
                "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit",
                cache: modelCache
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let p = progress.fractionCompleted
                    self.downloadProgress = p
                    self.state = .downloading(progress: p)
                }
            }
            model = loaded
            downloadProgress = 1.0
            state = .ready
            isLoadInProgress = false
            logger.info("MarvisTTS model loaded (sampleRate=\(loaded.sampleRate))")
            // Clean up Hub blob cache (models--* dirs) left behind by the HuggingFace
            // download library — these are duplicates of the working copy in mlx-audio/.
            Task.detached(priority: .utility) {
                StorageManager.shared.cleanupHubCache()
            }
        } catch {
            let msg = error.localizedDescription
            state = .error("Model loading failed: \(msg)")
            isLoadInProgress = false
            throw MarvisTTSServiceError.modelLoadFailed(msg)
        }
        #else
        throw MarvisTTSServiceError.notAvailable
        #endif
    }

    func unloadModel() {
        stop()
        #if canImport(MLXAudioTTS)
        model = nil
        Memory.clearCache()
        #endif
        isLoadInProgress = false
        state = .unloaded
        logger.info("MarvisTTS model unloaded")
    }

    /// STORAGE FIX: Unloads the model AND deletes the downloaded files from disk.
    /// Frees ~250MB of storage. The model will re-download on next use.
    func unloadAndDeleteModel() {
        unloadModel()
        let freed = StorageManager.shared.deleteMarvisTTSModelFiles()
        if freed > 0 {
            logger.info("MarvisTTS model files deleted (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))")
        }
    }

    // MARK: - Public API

    /// Speaks text with streaming playback. Loads model on demand if needed.
    func speak(_ text: String) async {
        let cleaned = TTSTextPreprocessor.prepareForSpeech(text)
        guard !cleaned.isEmpty else { return }

        do { try await loadModel() } catch {
            logger.error("Cannot speak: \(error.localizedDescription)")
            onError?("MarvisTTS model not available: \(error.localizedDescription)")
            return
        }

        stop()
        startGeneration(cleaned)
    }

    /// Enqueues a sentence for sequential generation + playback.
    /// If the pipeline is already running, the sentence is appended to the queue
    /// and will be spoken after the current sentence finishes. If idle, starts immediately.
    func enqueue(_ text: String) async {
        let cleaned = TTSTextPreprocessor.prepareForSpeech(text)
        guard !cleaned.isEmpty else { return }

        if model == nil {
            do { try await loadModel() } catch {
                logger.error("Cannot enqueue: \(error.localizedDescription)")
                onError?("MarvisTTS model not available")
                return
            }
        }

        // Split into sentences and add to queue
        let sentences = TTSTextPreprocessor.splitIntoSentences(cleaned)
        let pieces = sentences.isEmpty ? [cleaned] : sentences
        sentenceQueue.append(contentsOf: pieces)

        // Start pipeline if not already running
        if !isRunning {
            startQueuePipeline()
        }
    }

    func stop() {
        // Cancel generation task first
        generationTask?.cancel()
        generationTask = nil
        sentenceQueue.removeAll()

        #if canImport(MLXAudioTTS)
        // Stop audio playback on the persistent player
        audioPlayer.stop()
        if state == .generating {
            Memory.clearCache()
            state = .ready
        }
        #endif
        isRunning = false
        removeBackgroundObserver()
    }

    /// Stops generation AND unloads the model to release all GPU resources.
    /// Use when going to background to prevent Metal crashes.
    func stopAndUnload() {
        stop()
        #if canImport(MLXAudioTTS)
        model = nil
        Memory.clearCache()
        #endif
        state = .unloaded
    }

    // MARK: - Generation Pipeline

    private func startGeneration(_ text: String) {
        #if canImport(MLXAudioTTS)
        guard model != nil else { return }
        isRunning = true

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.runGeneration(text)
        }
        #endif
    }

    #if canImport(MLXAudioTTS)
    /// Generates speech and streams it to the persistent AudioPlayer.
    /// Uses the same pattern as the library's VoicesApp example:
    /// 1. `audioPlayer.startStreaming(sampleRate:)` — resets and prepares the engine
    /// 2. `model.generateStream()` — yields `.audio(MLXArray)` events
    /// 3. `audioPlayer.scheduleAudioChunk()` — schedules each chunk with crossfade
    /// 4. `audioPlayer.finishStreamingInput()` — signals end of stream
    private func runGeneration(_ text: String) async {
        guard let model else {
            isRunning = false
            onSpeakingComplete?()
            removeBackgroundObserver()
            return
        }

        state = .generating

        let voice = resolveVoice()?.rawValue

        // Prepare the persistent audio player for a new streaming session
        audioPlayer.startStreaming(sampleRate: Double(model.sampleRate))

        // Wire up completion callback
        audioPlayer.onDidFinishStreaming = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.state = .ready
                self.removeBackgroundObserver()
                self.onSpeakingComplete?()
            }
        }

        let sentences = TTSTextPreprocessor.splitIntoSentences(text)
        let pieces = sentences.isEmpty ? [text] : sentences
        logger.info("Generating \(pieces.count) piece(s) for \(text.count) chars")

        // Set cache limit for generation
        Memory.cacheLimit = 512 * 1024 * 1024

        var firedStart = false

        do {
            // Use SpeechGenerationModel.generateStream() — the canonical API
            // that yields AudioGeneration events (.token, .info, .audio)
            for piece in pieces {
                try Task.checkCancellation()

                let parameters = GenerateParameters(
                    maxTokens: Int(60000 / 80.0),
                    temperature: 0.9,
                    topP: 0.8
                )

                for try await event in model.generateStream(
                    text: piece,
                    voice: voice,
                    refAudio: nil,
                    refText: nil,
                    language: nil,
                    generationParameters: parameters
                ) {
                    try Task.checkCancellation()

                    switch event {
                    case .token:
                        break
                    case .info:
                        break
                    case .audio(let audioData):
                        autoreleasepool {
                            let samples = audioData.asArray(Float.self)
                            audioPlayer.scheduleAudioChunk(samples, withCrossfade: true)
                        }

                        if !firedStart {
                            firedStart = true
                            onSpeakingStarted?()
                        }
                    }
                }

                // Clear GPU cache between pieces (matches example pattern)
                Memory.clearCache()
            }

            // Signal end of stream — player fires onDidFinishStreaming when done
            audioPlayer.finishStreamingInput()

        } catch is CancellationError {
            audioPlayer.stop()
            Memory.clearCache()
            isRunning = false
            state = .ready
            removeBackgroundObserver()
        } catch {
            audioPlayer.stop()
            Memory.clearCache()
            isRunning = false
            state = .ready
            removeBackgroundObserver()
            onError?(error.localizedDescription)
        }
    }
    #endif

    // MARK: - Queue Pipeline (for streaming TTS / voice calls)

    private func startQueuePipeline() {
        #if canImport(MLXAudioTTS)
        guard model != nil else { return }
        isRunning = true

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.runQueuePipeline()
        }
        #endif
    }

    #if canImport(MLXAudioTTS)
    /// Processes sentences from the queue one at a time using the persistent
    /// AudioPlayer. Optimized for voice call latency — fires onSpeakingStarted
    /// as soon as first audio chunk is scheduled.
    private func runQueuePipeline() async {
        guard let model else {
            isRunning = false
            onSpeakingComplete?()
            removeBackgroundObserver()
            return
        }

        state = .generating

        let voice = resolveVoice()?.rawValue

        // Prepare the persistent audio player for a new streaming session
        audioPlayer.startStreaming(sampleRate: Double(model.sampleRate))

        // Wire up completion callback
        audioPlayer.onDidFinishStreaming = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only complete if queue is empty and streaming is done
                if self.sentenceQueue.isEmpty {
                    self.isRunning = false
                    self.state = .ready
                    self.removeBackgroundObserver()
                    self.onSpeakingComplete?()
                }
            }
        }

        var firedStart = false

        // Process sentences: dequeue on MainActor, generate via async stream
        while !Task.isCancelled {
            // Dequeue next sentence (MainActor)
            guard !sentenceQueue.isEmpty else {
                // Wait briefly for more sentences to arrive
                try? await Task.sleep(for: .milliseconds(200))
                if sentenceQueue.isEmpty { break }
                continue
            }

            let sentence = sentenceQueue.removeFirst()
            guard !sentence.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            logger.info("Queue pipeline: generating (\(sentence.count) chars)")

            do {
                let parameters = GenerateParameters(
                    maxTokens: Int(60000 / 80.0),
                    temperature: 0.9,
                    topP: 0.8
                )

                for try await event in model.generateStream(
                    text: sentence,
                    voice: voice,
                    refAudio: nil,
                    refText: nil,
                    language: nil,
                    generationParameters: parameters
                ) {
                    try Task.checkCancellation()

                    switch event {
                    case .token:
                        break
                    case .info:
                        break
                    case .audio(let audioData):
                        autoreleasepool {
                            let samples = audioData.asArray(Float.self)
                            audioPlayer.scheduleAudioChunk(samples, withCrossfade: true)
                        }

                        if !firedStart {
                            firedStart = true
                            onSpeakingStarted?()
                        }
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                logger.warning("Queue pipeline generation error: \(error.localizedDescription)")
            }
        }

        // Signal end of stream or clean up on cancellation
        if !Task.isCancelled {
            audioPlayer.finishStreamingInput()
            // onDidFinishStreaming callback will handle final cleanup
        } else {
            audioPlayer.stop()
            isRunning = false
            state = .ready
            removeBackgroundObserver()
        }

        Memory.clearCache()
    }
    #endif

    // MARK: - Voice & Quality Resolution

    #if canImport(MLXAudioTTS)
    private func resolveVoice() -> MarvisTTSModel.Voice? {
        switch config.voice {
        case "conversationalB": return .conversationalB
        default: return .conversationalA
        }
    }

    private func resolveQuality() -> MarvisTTSModel.QualityLevel {
        switch config.qualityLevel {
        case 8: return .low
        case 16: return .medium
        case 24: return .high
        default: return .maximum
        }
    }
    #endif

    // MARK: - Helpers

    private func removeBackgroundObserver() {
        if let obs = backgroundObserver {
            NotificationCenter.default.removeObserver(obs)
            backgroundObserver = nil
        }
    }
}

// MARK: - Errors

enum MarvisTTSServiceError: LocalizedError {
    case notAvailable
    case modelNotLoaded
    case modelLoadFailed(String)
    case emptyText
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "MarvisTTS not available on this device."
        case .modelNotLoaded: return "MarvisTTS model not loaded."
        case .modelLoadFailed(let r): return "Model load failed: \(r)"
        case .emptyText: return "Cannot synthesize empty text."
        case .generationFailed(let r): return "Generation failed: \(r)"
        }
    }
}
