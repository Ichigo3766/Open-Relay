import Foundation
import UIKit
import AVFoundation
import os.log

#if canImport(MLXAudioTTS)
@preconcurrency import MLXAudioTTS
import MLXAudioCore
import MLX
import MLXLMCommon
import HuggingFace
#endif

// MARK: - On-Device TTS Model Enum

/// Represents the on-device neural TTS model to use.
enum OnDeviceTTSModel: String, CaseIterable, Sendable {
    case kokoro = "kokoro"
    case qwen3  = "qwen3"

    /// HuggingFace model repository identifier.
    var modelRepo: String {
        switch self {
        case .kokoro: return "mlx-community/Kokoro-82M-bf16"
        case .qwen3:  return "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
        }
    }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .qwen3:  return "Qwen3"
        }
    }

    /// Estimated download size description.
    var estimatedSize: String {
        switch self {
        case .kokoro: return "~50 MB"
        case .qwen3:  return "~300 MB"
        }
    }

    /// Whether this model uses an explicit language parameter at inference time.
    /// - Kokoro: language is implied by the voice ID prefix (e.g. "af_" = American English).
    /// - Qwen3: language must be passed explicitly (e.g. "German", "Korean", "auto").
    var supportsLanguageParameter: Bool {
        switch self {
        case .kokoro: return false
        case .qwen3:  return true
        }
    }
}

// MARK: - On-Device TTS Configuration

struct OnDeviceTTSConfig {
    /// Active on-device model.
    var activeModel: OnDeviceTTSModel = .kokoro
    /// Voice ID for Kokoro (e.g. "af_heart"). Ignored when Qwen3 is active.
    var kokoroVoice: String = "af_heart"
    /// Speaker name for Qwen3 (e.g. "Ryan", "Aiden"). Ignored when Kokoro is active.
    var qwen3Voice: String = "Aiden"
    /// Language string for Qwen3 (e.g. "English", "Korean", "auto"). Ignored when Kokoro is active.
    var qwen3Language: String = "auto"
    /// Speech rate multiplier (Kokoro only). 1.0 = normal.
    var speed: Float = 1.0
    /// Playback speed multiplier for Qwen3 (applied at the AudioPlayer sample rate).
    /// Qwen3 has no built-in speed property — we multiply the declared sample rate by this
    /// factor so AVAudioEngine plays the audio faster (higher declared rate = faster playback).
    /// 1.1 = 10% faster than raw output, which counteracts Qwen3's tendency to speak slightly slowly.
    var qwen3Speed: Float = 1.1
}

// MARK: - Legacy KokoroTTSConfig (kept for backward compatibility)

/// Thin wrapper that reads/writes the Kokoro fields in OnDeviceTTSConfig.
/// External callers (TextToSpeechService) can keep using `.voice` and `.speed`.
struct KokoroTTSConfig {
    /// Proxied from OnDeviceTTSConfig.kokoroVoice.
    var voice: String = "af_heart"
    /// Proxied from OnDeviceTTSConfig.speed.
    var speed: Float = 1.0
}

// MARK: - TTS State

enum KokoroTTSState: Sendable, Equatable {
    case unloaded
    case downloading
    case loading
    case ready
    case generating
    case error(String)
}

// MARK: - On-Device Text-to-Speech Service
///
/// Unified on-device neural TTS service supporting both Kokoro (54 voices, 9 languages,
/// ~50 MB) and Qwen3 (7 preset speakers, 11 languages including Korean/German/Spanish,
/// ~300 MB). Only one model is loaded at a time.
///
/// Both models implement `SpeechGenerationModel` from mlx-audio-swift and share
/// an identical streaming audio pipeline via `AudioPlayer.scheduleAudioChunk()`.
///
/// Key differences handled internally:
/// - Kokoro: `voice` = voice pack ID (e.g. "af_heart"), `language` = nil,
///   `model.speed` property controls rate, non-autoregressive (fast).
/// - Qwen3: `voice` = speaker name (e.g. "Ryan"), `language` = e.g. "Korean",
///   `streamingInterval: 0.32` for responsive chunked output, autoregressive.
///
/// Usage:
///   1. Set `config.activeModel` to `.kokoro` or `.qwen3`.
///   2. Call `loadModel()` to download & warm up the selected model.
///   3. Call `speak(_:)` or `enqueue(_:)` to generate + stream audio.
///   4. Call `stop()` to cancel generation and playback.

#if canImport(MLXAudioTTS)
/// Sendable wrapper for `any SpeechGenerationModel` so it can cross actor boundaries.
/// Safe because MLX models are internally thread-safe reference types.
private final class ModelRef: @unchecked Sendable {
    nonisolated(unsafe) let value: any SpeechGenerationModel
    init(_ m: any SpeechGenerationModel) { value = m }
}
#endif

@MainActor @Observable
final class OnDeviceTTSService {

    // MARK: - State

    private(set) var state: KokoroTTSState = .unloaded
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

    var config = OnDeviceTTSConfig()

    /// Convenience accessor that reads/writes Kokoro-specific fields in `config`.
    /// Provided for backward compatibility with TextToSpeechService.
    var kokoroLegacyConfig: KokoroTTSConfig {
        get { KokoroTTSConfig(voice: config.kokoroVoice, speed: config.speed) }
        set {
            config.kokoroVoice = newValue.voice
            config.speed       = newValue.speed
        }
    }

    // MARK: - Callbacks

    var onSpeakingStarted: (() -> Void)?
    var onSpeakingComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "OnDeviceTTS")

    #if canImport(MLXAudioTTS)
    /// The currently loaded speech generation model (either KokoroModel or Qwen3TTSModel).
    private var model: (any SpeechGenerationModel)?
    /// Which model is currently loaded. Used to detect when a reload is needed.
    private var loadedModel: OnDeviceTTSModel?
    /// Multilingual text processor — Kokoro-specific, nil when Qwen3 is loaded.
    private var multilingualProcessor: KokoroMultilingualProcessor?
    /// Single persistent audio player — reused across all playback sessions.
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
        guard isAvailable else { throw OnDeviceTTSServiceError.notAvailable }

        #if canImport(MLXAudioTTS)
        let targetModel = config.activeModel

        // Already loaded and correct model → fast return
        if let loaded = loadedModel, loaded == targetModel, model != nil, case .ready = state {
            return
        }

        if isLoadInProgress { return }

        // If a different model is currently loaded, unload it first to free memory
        if let loaded = loadedModel, loaded != targetModel {
            logger.info("Switching model from \(loaded.displayName) → \(targetModel.displayName), unloading old model")
            model = nil
            multilingualProcessor = nil
            loadedModel = nil
            Memory.clearCache()
        }

        isLoadInProgress = true
        state = .downloading
        downloadProgress = 0
        logger.info("Loading \(targetModel.displayName) TTS model (\(targetModel.modelRepo))…")

        do {
            let modelCache = HubCache(location: .fixed(directory: StorageManager.modelCacheDirectory))

            switch targetModel {
            case .kokoro:
                let loaded = try await KokoroModel.fromPretrained(
                    targetModel.modelRepo,
                    cache: modelCache
                )
                let processor = KokoroMultilingualProcessor()
                loaded.setTextProcessor(processor)
                multilingualProcessor = processor
                model = loaded
                loadedModel = .kokoro
                downloadProgress = 1.0
                state = .ready
                isLoadInProgress = false
                logger.info("Kokoro TTS model loaded (sampleRate=\(loaded.sampleRate))")

                // Proactively warm up G2P for the current voice's language
                let voiceForPrep = self.config.kokoroVoice
                Task.detached(priority: .utility) { [weak processor] in
                    await self.prepareG2PForVoiceBackground(voiceForPrep, processor: processor)
                }

            case .qwen3:
                let loaded = try await Qwen3TTSModel.fromPretrained(
                    targetModel.modelRepo,
                    cache: modelCache
                )
                model = loaded
                loadedModel = .qwen3
                downloadProgress = 1.0
                state = .ready
                isLoadInProgress = false
                logger.info("Qwen3 TTS model loaded (sampleRate=\(loaded.sampleRate))")
            }

            // Clean up Hub blob cache left behind by the HuggingFace download library
            Task.detached(priority: .utility) {
                await StorageManager.shared.cleanupHubCache()
            }

        } catch {
            let msg = error.localizedDescription
            state = .error("Model loading failed: \(msg)")
            isLoadInProgress = false
            throw OnDeviceTTSServiceError.modelLoadFailed(msg)
        }
        #else
        throw OnDeviceTTSServiceError.notAvailable
        #endif
    }

    func unloadModel() {
        stop()
        #if canImport(MLXAudioTTS)
        model = nil
        multilingualProcessor = nil
        loadedModel = nil
        Memory.clearCache()
        #endif
        isLoadInProgress = false
        state = .unloaded
        logger.info("On-device TTS model unloaded")
    }

    /// Prepares the G2P text processor for the given Kokoro voice's language.
    /// No-op when Qwen3 is the active model.
    func prepareG2PForVoice(_ voice: String) {
        #if canImport(MLXAudioTTS)
        guard config.activeModel == .kokoro, let processor = multilingualProcessor else { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.prepareG2PForVoiceBackground(voice, processor: processor)
        }
        #endif
    }

    /// Unloads the model AND deletes downloaded files from disk.
    func unloadAndDeleteModel() {
        let activeModel = config.activeModel
        unloadModel()
        switch activeModel {
        case .kokoro:
            let freed = StorageManager.shared.deleteKokoroTTSModelFiles()
            if freed > 0 {
                logger.info("Kokoro TTS model files deleted (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))")
            }
        case .qwen3:
            let freed = StorageManager.shared.deleteQwen3TTSModelFiles()
            if freed > 0 {
                logger.info("Qwen3 TTS model files deleted (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))")
            }
        }
    }

    // MARK: - Public API

    /// Speaks text with streaming playback. Loads model on demand if needed.
    func speak(_ text: String) async {
        let cleaned = TTSTextPreprocessor.prepareForSpeech(text)
        guard !cleaned.isEmpty else { return }

        do { try await loadModel() } catch {
            logger.error("Cannot speak: \(error.localizedDescription)")
            onError?("On-device TTS model not available: \(error.localizedDescription)")
            return
        }

        stop()
        startGeneration(cleaned)
    }

    /// Enqueues a sentence for sequential generation + playback.
    func enqueue(_ text: String) async {
        let cleaned = TTSTextPreprocessor.prepareForSpeech(text)
        guard !cleaned.isEmpty else { return }

        if model == nil {
            do { try await loadModel() } catch {
                logger.error("Cannot enqueue: \(error.localizedDescription)")
                onError?("On-device TTS model not available")
                return
            }
        }

        let sentences = TTSTextPreprocessor.splitIntoSentences(cleaned)
        let pieces = sentences.isEmpty ? [cleaned] : sentences
        sentenceQueue.append(contentsOf: pieces)

        if !isRunning {
            startQueuePipeline()
        }
    }

    func stop() {
        generationTask?.cancel()
        generationTask = nil
        sentenceQueue.removeAll()

        #if canImport(MLXAudioTTS)
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
    func stopAndUnload() {
        stop()
        #if canImport(MLXAudioTTS)
        model = nil
        loadedModel = nil
        Memory.clearCache()
        #endif
        state = .unloaded
    }

    // MARK: - G2P Preparation (Kokoro-specific, Background)

    #if canImport(MLXAudioTTS)
    private nonisolated func prepareG2PForVoiceBackground(
        _ voice: String,
        processor: KokoroMultilingualProcessor?
    ) async {
        guard let processor else { return }
        guard let lang = KokoroMultilingualProcessor.languageForVoice(voice) else { return }
        guard lang != "en-us", lang != "en-gb" else { return }

        do {
            try await processor.prepare(for: lang)
            await MainActor.run {
                self.logger.info("OnDeviceTTS (Kokoro): G2P ready for language '\(lang)' (voice: \(voice))")
            }
        } catch {
            await MainActor.run {
                self.logger.warning("OnDeviceTTS (Kokoro): G2P prep failed for '\(lang)': \(error.localizedDescription)")
            }
        }
    }
    #endif

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

        generationTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.runGeneration(text)
        }
        #endif
    }

    #if canImport(MLXAudioTTS)
    /// Generates speech and streams each audio chunk to the persistent AudioPlayer.
    ///
    /// Kokoro: splits text into sentences, generates one shot per sentence.
    /// Qwen3: autoregressive — streams token chunks via `streamingInterval: 0.32`.
    ///
    /// NOTE: Runs in Task.detached context (off MainActor). All state mutations
    /// hop back to MainActor explicitly via `await MainActor.run { }`.
    private nonisolated func runGeneration(_ text: String) async {
        // Capture all MainActor state upfront
        let (modelRef, activeModel, kokoroVoice, qwen3Voice, qwen3Language, speed, qwen3Speed, onStarted, onErr)
            = await MainActor.run {
                (self.model.map(ModelRef.init),
                 self.config.activeModel,
                 self.config.kokoroVoice,
                 self.config.qwen3Voice,
                 self.config.qwen3Language,
                 self.config.speed,
                 self.config.qwen3Speed,
                 self.onSpeakingStarted,
                 self.onError)
            }

        guard let modelRef else {
            await MainActor.run {
                self.isRunning = false
                self.onSpeakingComplete?()
                self.removeBackgroundObserver()
            }
            return
        }
        let model = modelRef.value
        let sampleRate = model.sampleRate

        // Set MLX memory limit once before generation begins (not inside the per-sentence loop)
        Memory.cacheLimit = 512 * 1024 * 1024

        await MainActor.run {
            self.state = .generating
            // For Qwen3, divide the sample rate by the speed factor so the OS plays audio
            // faster — Qwen3 has no native speed property, this is the only control point.
            let effectiveSampleRate: Double
            if activeModel == .qwen3 && qwen3Speed > 0 {
                effectiveSampleRate = Double(sampleRate) * Double(qwen3Speed)
            } else {
                effectiveSampleRate = Double(sampleRate)
            }
            self.audioPlayer.startStreaming(sampleRate: effectiveSampleRate)
            self.audioPlayer.onDidFinishStreaming = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRunning = false
                    self.state = .ready
                    self.removeBackgroundObserver()
                    self.onSpeakingComplete?()
                }
            }
        }

        let sentences = await MainActor.run { TTSTextPreprocessor.splitIntoSentences(text) }
        let pieces = sentences.isEmpty ? [text] : sentences

        var firedStart = false

        do {
            for piece in pieces {
                try Task.checkCancellation()
                guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                // Kokoro uses the model's default parameters (temp 0.9).
                // Qwen3 uses temperature 0.2 for a stable, consistent reading
                // voice — the default 0.9 causes wildly varying emotion/prosody
                // each generation (excited, sad, slow, etc.).
                let parameters = GenerateParameters(
                    temperature: activeModel == .qwen3 ? 0.2 : 0.9,
                    topP: activeModel == .qwen3 ? 0.9 : 1.0
                )

                // Build the stream based on active model
                let stream: AsyncThrowingStream<AudioGeneration, Error>

                switch activeModel {
                case .kokoro:
                    // Apply speed setting (Kokoro-specific property)
                    if let kokoroModel = model as? KokoroModel {
                        kokoroModel.speed = speed
                    }
                    stream = model.generateStream(
                        text: piece,
                        voice: kokoroVoice,
                        refAudio: nil,
                        refText: nil,
                        language: nil,
                        generationParameters: parameters
                    )

                case .qwen3:
                    let lang: String? = qwen3Language == "auto" ? nil : qwen3Language
                    stream = model.generateStream(
                        text: piece,
                        voice: qwen3Voice,
                        refAudio: nil,
                        refText: nil,
                        language: lang,
                        generationParameters: parameters,
                        streamingInterval: 0.32
                    )
                }

                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .token:
                        break
                    case .info:
                        break
                    case .audio(let audioData):
                        let samples = audioData.asArray(Float.self)
                        await MainActor.run {
                            self.audioPlayer.scheduleAudioChunk(samples, withCrossfade: activeModel == .kokoro)
                        }
                        if !firedStart {
                            firedStart = true
                            await MainActor.run { onStarted?() }
                        }
                    }
                }

                Memory.clearCache()
            }

            await MainActor.run { self.audioPlayer.finishStreamingInput() }

        } catch is CancellationError {
            Memory.clearCache()
            await MainActor.run {
                self.audioPlayer.stop()
                self.isRunning = false
                self.state = .ready
                self.removeBackgroundObserver()
            }
        } catch {
            Memory.clearCache()
            await MainActor.run {
                self.audioPlayer.stop()
                self.isRunning = false
                self.state = .ready
                self.removeBackgroundObserver()
                onErr?(error.localizedDescription)
            }
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

        generationTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.runQueuePipeline()
        }
        #endif
    }

    #if canImport(MLXAudioTTS)
    private nonisolated func runQueuePipeline() async {
        let (modelRef, activeModelForSetup, qwen3SpeedForSetup, onStarted) = await MainActor.run {
            (self.model.map(ModelRef.init), self.config.activeModel, self.config.qwen3Speed, self.onSpeakingStarted)
        }

        guard let modelRef else {
            await MainActor.run {
                self.isRunning = false
                self.onSpeakingComplete?()
                self.removeBackgroundObserver()
            }
            return
        }
        let model = modelRef.value
        let sampleRate = model.sampleRate

        await MainActor.run {
            self.state = .generating
            // Apply Qwen3 speed at the AudioPlayer level (same as runGeneration)
            let effectiveSampleRate: Double
            if activeModelForSetup == .qwen3 && qwen3SpeedForSetup > 0 {
                effectiveSampleRate = Double(sampleRate) * Double(qwen3SpeedForSetup)
            } else {
                effectiveSampleRate = Double(sampleRate)
            }
            self.audioPlayer.startStreaming(sampleRate: effectiveSampleRate)
            self.audioPlayer.onDidFinishStreaming = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.sentenceQueue.isEmpty {
                        self.isRunning = false
                        self.state = .ready
                        self.removeBackgroundObserver()
                        self.onSpeakingComplete?()
                    }
                }
            }
        }

        var firedStart = false

        while !Task.isCancelled {
            let sentence: String? = await MainActor.run {
                guard !self.sentenceQueue.isEmpty else { return nil }
                return self.sentenceQueue.removeFirst()
            }

            guard let sentence else {
                try? await Task.sleep(for: .milliseconds(200))
                let hasMore = await MainActor.run { !self.sentenceQueue.isEmpty }
                if !hasMore { break }
                continue
            }

            guard !sentence.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            // Fetch latest config on every sentence
            let (activeModel, kokoroVoice, qwen3Voice, qwen3Language, speed) = await MainActor.run {
                (self.config.activeModel,
                 self.config.kokoroVoice,
                 self.config.qwen3Voice,
                 self.config.qwen3Language,
                 self.config.speed)
            }

            do {
                // Same temperature logic as runGeneration — Qwen3 uses 0.2 for
                // a stable, consistent reading voice; Kokoro keeps its default 0.9.
                let parameters = GenerateParameters(
                    temperature: activeModel == .qwen3 ? 0.2 : 0.9,
                    topP: activeModel == .qwen3 ? 0.9 : 1.0
                )
                let stream: AsyncThrowingStream<AudioGeneration, Error>

                switch activeModel {
                case .kokoro:
                    if let kokoroModel = model as? KokoroModel {
                        kokoroModel.speed = speed
                    }
                    stream = model.generateStream(
                        text: sentence,
                        voice: kokoroVoice,
                        refAudio: nil,
                        refText: nil,
                        language: nil,
                        generationParameters: parameters
                    )

                case .qwen3:
                    let lang: String? = qwen3Language == "auto" ? nil : qwen3Language
                    stream = model.generateStream(
                        text: sentence,
                        voice: qwen3Voice,
                        refAudio: nil,
                        refText: nil,
                        language: lang,
                        generationParameters: parameters,
                        streamingInterval: 0.32
                    )
                }

                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .token:
                        break
                    case .info:
                        break
                    case .audio(let audioData):
                        let samples = audioData.asArray(Float.self)
                        await MainActor.run {
                            self.audioPlayer.scheduleAudioChunk(samples, withCrossfade: activeModel == .kokoro)
                        }
                        if !firedStart {
                            firedStart = true
                            await MainActor.run { onStarted?() }
                        }
                    }
                }

                Memory.clearCache()
            } catch is CancellationError {
                break
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self.logger.warning("Queue pipeline generation error: \(msg)")
                }
            }
        }

        if !Task.isCancelled {
            await MainActor.run { self.audioPlayer.finishStreamingInput() }
        } else {
            Memory.clearCache()
            await MainActor.run {
                self.audioPlayer.stop()
                self.isRunning = false
                self.state = .ready
                self.removeBackgroundObserver()
            }
        }

        Memory.clearCache()
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

// MARK: - Legacy KokoroTTSService Typealias

/// Backward-compatibility alias — existing callers keep compiling unchanged.
typealias KokoroTTSService = OnDeviceTTSService

// MARK: - Errors

enum OnDeviceTTSServiceError: LocalizedError {
    case notAvailable
    case modelNotLoaded
    case modelLoadFailed(String)
    case emptyText
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:         return "On-device TTS not available on this device."
        case .modelNotLoaded:       return "On-device TTS model not loaded."
        case .modelLoadFailed(let r): return "Model load failed: \(r)"
        case .emptyText:            return "Cannot synthesize empty text."
        case .generationFailed(let r): return "Generation failed: \(r)"
        }
    }
}

// Keep the old error enum name as a typealias for backward compatibility
typealias KokoroTTSServiceError = OnDeviceTTSServiceError

// MARK: - Qwen3 Voice Catalog

/// Preset speakers for the Qwen3-TTS Base models.
/// Any speaker can speak any supported language — the speaker name selects voice timbre.
struct Qwen3VoiceCatalog {
    struct VoiceGroup {
        let language: String
        let flag: String
        let voices: [(id: String, name: String)]
    }

    /// Supported output languages (pass as `language` parameter at inference time).
    /// "auto" lets the model infer from text content.
    static let supportedLanguages: [(id: String, name: String)] = [
        ("auto",       "Auto Detect"),
        ("English",    "🇺🇸 English"),
        ("Korean",     "🇰🇷 Korean"),
        ("German",     "🇩🇪 German"),
        ("Spanish",    "🇪🇸 Spanish"),
        ("Chinese",    "🇨🇳 Chinese"),
        ("Japanese",   "🇯🇵 Japanese"),
        ("French",     "🇫🇷 French"),
        ("Italian",    "🇮🇹 Italian"),
        ("Portuguese", "🇧🇷 Portuguese"),
        ("Russian",    "🇷🇺 Russian"),
    ]

    static let groups: [VoiceGroup] = [
        VoiceGroup(language: "English", flag: "🇺🇸", voices: [
            ("Ryan",  "Ryan (M) ★"),
            ("Aiden", "Aiden (M)"),
        ]),
        VoiceGroup(language: "Chinese", flag: "🇨🇳", voices: [
            ("Vivian",    "Vivian (F)"),
            ("Serena",    "Serena (F)"),
            ("Uncle_Fu",  "Uncle Fu (M)"),
            ("Dylan",     "Dylan (M)"),
            ("Eric",      "Eric (M)"),
        ]),
        VoiceGroup(language: "Japanese", flag: "🇯🇵", voices: [
            ("Ono_Anna", "Ono Anna (F)"),
        ]),
        VoiceGroup(language: "Korean", flag: "🇰🇷", voices: [
            ("Sohee", "Sohee (F)"),
        ]),
    ]

    /// Flat list of all speaker IDs.
    static var allVoiceIds: [String] {
        groups.flatMap { $0.voices.map { $0.id } }
    }

    /// Returns the display name for a given speaker ID, or the ID itself as fallback.
    static func displayName(for id: String) -> String {
        for group in groups {
            if let match = group.voices.first(where: { $0.id == id }) {
                return "\(group.flag) \(match.name)"
            }
        }
        return id
    }

    /// Display name for a language ID.
    static func languageDisplayName(for id: String) -> String {
        supportedLanguages.first(where: { $0.id == id })?.name ?? id
    }
}

// MARK: - Kokoro Voice Catalog

/// All 54 Kokoro voices grouped by language, for display in the UI.
struct KokoroVoiceCatalog {
    struct VoiceGroup {
        let language: String
        let flag: String
        let voices: [(id: String, name: String)]
    }

    static let groups: [VoiceGroup] = [
        VoiceGroup(language: "American English", flag: "🇺🇸", voices: [
            ("af_alloy",   "Alloy (F)"),
            ("af_aoede",   "Aoede (F)"),
            ("af_bella",   "Bella (F)"),
            ("af_heart",   "Heart (F) ★"),
            ("af_jessica", "Jessica (F)"),
            ("af_kore",    "Kore (F)"),
            ("af_nicole",  "Nicole (F)"),
            ("af_nova",    "Nova (F)"),
            ("af_river",   "River (F)"),
            ("af_sarah",   "Sarah (F)"),
            ("af_sky",     "Sky (F)"),
            ("am_adam",    "Adam (M)"),
            ("am_echo",    "Echo (M)"),
            ("am_eric",    "Eric (M)"),
            ("am_fenrir",  "Fenrir (M)"),
            ("am_liam",    "Liam (M)"),
            ("am_michael", "Michael (M)"),
            ("am_onyx",    "Onyx (M)"),
            ("am_puck",    "Puck (M)"),
            ("am_santa",   "Santa (M)"),
        ]),
        VoiceGroup(language: "British English", flag: "🇬🇧", voices: [
            ("bf_alice",    "Alice (F)"),
            ("bf_emma",     "Emma (F)"),
            ("bf_isabella", "Isabella (F)"),
            ("bf_lily",     "Lily (F)"),
            ("bm_daniel",   "Daniel (M)"),
            ("bm_fable",    "Fable (M)"),
            ("bm_george",   "George (M)"),
            ("bm_lewis",    "Lewis (M)"),
        ]),
        VoiceGroup(language: "Spanish", flag: "🇪🇸", voices: [
            ("ef_dora",  "Dora (F)"),
            ("em_alex",  "Alex (M)"),
            ("em_santa", "Santa (M)"),
        ]),
        VoiceGroup(language: "French", flag: "🇫🇷", voices: [
            ("ff_siwis", "Siwis (F)"),
        ]),
        VoiceGroup(language: "Hindi", flag: "🇮🇳", voices: [
            ("hf_alpha", "Alpha (F)"),
            ("hf_beta",  "Beta (F)"),
            ("hm_omega", "Omega (M)"),
            ("hm_psi",   "Psi (M)"),
        ]),
        VoiceGroup(language: "Italian", flag: "🇮🇹", voices: [
            ("if_sara",   "Sara (F)"),
            ("im_nicola", "Nicola (M)"),
        ]),
        VoiceGroup(language: "Japanese", flag: "🇯🇵", voices: [
            ("jf_alpha",     "Alpha (F)"),
            ("jf_gongitsune","Gongitsune (F)"),
            ("jf_nezumi",    "Nezumi (F)"),
            ("jf_tebukuro",  "Tebukuro (F)"),
            ("jm_kumo",      "Kumo (M)"),
        ]),
        VoiceGroup(language: "Portuguese", flag: "🇧🇷", voices: [
            ("pf_dora",  "Dora (F)"),
            ("pm_alex",  "Alex (M)"),
            ("pm_santa", "Santa (M)"),
        ]),
        VoiceGroup(language: "Chinese", flag: "🇨🇳", voices: [
            ("zf_xiaobei",  "Xiaobei (F)"),
            ("zf_xiaoni",   "Xiaoni (F)"),
            ("zf_xiaoxiao", "Xiaoxiao (F)"),
            ("zf_xiaoyi",   "Xiaoyi (F)"),
            ("zm_yunjian",  "Yunjian (M)"),
            ("zm_yunxi",    "Yunxi (M)"),
            ("zm_yunxia",   "Yunxia (M)"),
            ("zm_yunyang",  "Yunyang (M)"),
        ]),
    ]

    /// Flat list of all voice IDs.
    static var allVoiceIds: [String] {
        groups.flatMap { $0.voices.map { $0.id } }
    }

    /// Returns the display name for a given voice ID, or the ID itself as fallback.
    static func displayName(for id: String) -> String {
        for group in groups {
            if let match = group.voices.first(where: { $0.id == id }) {
                return "\(group.flag) \(match.name)"
            }
        }
        return id
    }
}
