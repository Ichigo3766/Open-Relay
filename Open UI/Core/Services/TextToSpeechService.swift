import Foundation
import AVFoundation
import NaturalLanguage

/// Manages text-to-speech with support for both Apple's AVSpeechSynthesizer,
/// on-device neural TTS (Kokoro or Qwen3), and server-side TTS.
///
/// ## TTS Engine Default
/// **AVSpeechSynthesizer** (system) is the default — works instantly with no
/// downloads. Users can opt in to on-device neural TTS or Server TTS in Settings.
///
/// ## Auto Mode Priority (when selected by user)
/// 1. **On-device neural TTS** (Kokoro or Qwen3) — if model is downloaded and loaded
/// 2. **Server TTS** (OpenWebUI API) — if configured
/// 3. **AVSpeechSynthesizer** (system) — fallback
@MainActor @Observable
final class TextToSpeechService: NSObject {

    // MARK: - Engine Selection

    enum TTSEngine: String, Sendable {
        case kokoro   // On-device Kokoro TTS
        case qwen3    // On-device Qwen3 TTS (multilingual)
        case server   // Server-side TTS via OpenWebUI API
        case system   // Apple AVSpeechSynthesizer
        case auto     // Prefer on-device neural if loaded → server → system
    }

    // MARK: - State

    enum TTSState: Sendable {
        case idle
        case speaking
        case paused
    }

    private(set) var state: TTSState = .idle
    private(set) var isAvailable: Bool = true
    private(set) var activeEngine: TTSEngine = .system

    var isKokoroAvailable: Bool { kokoroService.isAvailable }
    var kokoroState: KokoroTTSState { kokoroService.state }
    var kokoroDownloadProgress: Double { kokoroService.downloadProgress }

    /// Convenience for the on-device model state (alias for kokoroState when using any on-device model).
    var onDeviceTTSState: KokoroTTSState { kokoroService.state }

    // MARK: - Callbacks

    var onStart: (() -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Configuration

    var preferredEngine: TTSEngine = .system
    var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitchMultiplier: Float = 1.0
    var volume: Float = 1.0
    var voiceIdentifier: String?

    // MARK: - Server TTS

    var serverVoiceId: String?
    var serverSpeechRate: Double = 1.0
    var isServerAvailable: Bool { apiClient != nil }
    private(set) var apiClient: APIClient?

    /// The voice configured on the server (from /api/v1/audio/config tts.VOICE).
    /// Used as the fallback when the user selects "Server Default" (serverVoiceId == nil).
    var serverDefaultVoice: String?

    /// When set to true, output is forced to the loudspeaker after each audio session setup.
    /// Set by VoiceCallViewModel to persist speaker routing through the TTS pipeline.
    var speakerOverrideEnabled: Bool = false

    func configureServerTTS(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()
    /// Unified on-device TTS service — supports both Kokoro and Qwen3 models.
    let kokoroService = KokoroTTSService()

    // System TTS queue
    private var systemQueue: [String] = []
    private var isSpeakingSystemChunk = false

    // Server TTS state
    private var serverQueue: [String] = []
    private var isRunningServerQueue = false

    // Server TTS gapless pipeline (AVQueuePlayer-based)
    /// Gapless player — items are enqueued as audio data arrives from the server.
    private var queuePlayer: AVQueuePlayer?
    /// KVO observation for end-of-queue detection.
    private var queuePlayerObservation: NSKeyValueObservation?
    /// Tracks how many items are currently queued or playing.
    private var queuedItemCount: Int = 0
    /// Tracks how many items have finished playing.
    private var finishedItemCount: Int = 0

    /// Max number of audio chunks to fetch ahead of the currently playing chunk.
    private let serverPrefetchCount = 2
    /// Buffer of pre-fetched AVPlayerItem instances ready to enqueue (FIFO).
    private var prefetchedItems: [AVPlayerItem] = []
    /// Background task that keeps the prefetch buffer filled.
    private var prefetchTask: Task<Void, Never>?
    /// Maps each AVPlayerItem to the temp file URL backing it so we can delete after playback.
    private var playerItemTempURLs: [AVPlayerItem: URL] = [:]
    /// Token for the `didPlayToEndTimeNotification` observer — must be removed via this token,
    /// NOT via `removeObserver(self, ...)`, because the closure-based API returns an opaque token.
    private var playerItemEndObserver: (any NSObjectProtocol)?

    // Active engine flags
    private var isUsingKokoro = false
    private var isUsingServer = false

    // MARK: - Streaming TTS State

    /// Character offset of cleaned text already enqueued for TTS.
    private(set) var streamingSpokenLength: Int = 0

    /// Whether streaming TTS mode is active (text is still arriving).
    private(set) var isStreamingTTS: Bool = false

    // MARK: - Init

    override init() {
        super.init()
        synthesizer.delegate = self

        // Restore saved engine preference.
        // Migration: "marvis" and "mlx" both map to the new "kokoro" engine.
        if let saved = UserDefaults.standard.string(forKey: "ttsEngine") {
            switch saved {
            case "kokoro", "marvis", "mlx": preferredEngine = .kokoro
            case "qwen3":                   preferredEngine = .qwen3
            case "server":                  preferredEngine = .server
            case "system":                  preferredEngine = .system
            case "ondevice":
                // New unified "On-Device" selection — determine sub-model from ttsOnDeviceModel key
                if UserDefaults.standard.string(forKey: "ttsOnDeviceModel") == "qwen3" {
                    preferredEngine = .qwen3
                } else {
                    preferredEngine = .kokoro
                }
            default:                        preferredEngine = .auto
            }
        }

        // Restore saved server voice selection
        let savedServerVoice = UserDefaults.standard.string(forKey: "ttsServerVoiceId") ?? ""
        serverVoiceId = savedServerVoice.isEmpty ? nil : savedServerVoice

        // Restore on-device model selection from UserDefaults.
        // IMPORTANT: Always derive activeModel from preferredEngine first so the
        // cold-start path is never stuck with a mismatched model (e.g. engine=.qwen3
        // but activeModel=.kokoro). The ttsOnDeviceModel key is used as a tiebreak
        // when the engine is "ondevice" / "auto".
        switch preferredEngine {
        case .kokoro:
            kokoroService.config.activeModel = .kokoro
        case .qwen3:
            kokoroService.config.activeModel = .qwen3
        default:
            // For server/system/auto, restore whatever was saved explicitly
            if let savedModelRaw = UserDefaults.standard.string(forKey: "ttsOnDeviceModel"),
               let savedModel = OnDeviceTTSModel(rawValue: savedModelRaw) {
                kokoroService.config.activeModel = savedModel
            }
        }

        // Restore Kokoro voice & speed from UserDefaults so the user's
        // selection survives cold starts / model unload-reload cycles.
        // Migration: map legacy Marvis voice keys to valid Kokoro voice IDs.
        let rawVoice = UserDefaults.standard.string(forKey: "ttsKokoroVoice")
            ?? UserDefaults.standard.string(forKey: "ttsMarvisVoice")
            ?? ""
        let kokoroVoice: String
        switch rawVoice {
        case "conversationalB": kokoroVoice = "af_bella"
        case "conversationalA", "": kokoroVoice = "af_heart"
        default: kokoroVoice = KokoroVoiceCatalog.allVoiceIds.contains(rawVoice) ? rawVoice : "af_heart"
        }
        let savedSpeed = UserDefaults.standard.float(forKey: "ttsKokoroSpeed")
        kokoroService.config.kokoroVoice = kokoroVoice
        kokoroService.config.speed = savedSpeed > 0 ? savedSpeed : 1.0

        // Restore Qwen3 voice, language, and speed from UserDefaults
        let savedQwen3Voice = UserDefaults.standard.string(forKey: "ttsQwen3Voice") ?? "Aiden"
        let savedQwen3Language = UserDefaults.standard.string(forKey: "ttsQwen3Language") ?? "auto"
        kokoroService.config.qwen3Voice = Qwen3VoiceCatalog.allVoiceIds.contains(savedQwen3Voice) ? savedQwen3Voice : "Aiden"
        kokoroService.config.qwen3Language = savedQwen3Language
        kokoroService.config.qwen3Speed = 1.1

        // Wire on-device TTS callbacks
        kokoroService.onSpeakingStarted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.state = .speaking
                self?.onStart?()
            }
        }

        kokoroService.onSpeakingComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // If streaming mode is still active, more text may arrive — don't complete yet.
                if self.isStreamingTTS {
                    return
                }
                self.state = .idle
                self.isUsingKokoro = false
                // Model stays loaded for fast re-use; unloaded only on background/explicit stop
                self.onComplete?()
            }
        }

        kokoroService.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isUsingKokoro = false
                self.onError?(error)
            }
        }
    }

    // MARK: - On-Device TTS Configuration

    /// Kokoro-specific voice/speed config (legacy accessor for Kokoro voices).
    var kokoroConfig: KokoroTTSConfig {
        get { kokoroService.kokoroLegacyConfig }
        set { kokoroService.kokoroLegacyConfig = newValue }
    }

    func preloadKokoroModel() async {
        guard kokoroService.isAvailable else { return }
        try? await kokoroService.loadModel()
    }

    func unloadKokoroModel() {
        kokoroService.unloadModel()
    }

    // MARK: - Public API

    /// Speaks text immediately, interrupting any current speech.
    func speak(_ text: String) {
        let cleaned = TTSTextPreprocessor.prepareForSpeech(text)
        guard !cleaned.isEmpty else { return }

        stop()

        let engine = resolveEngine()
        activeEngine = engine

        switch engine {
        case .kokoro, .qwen3:
            speakWithKokoro(cleaned)
        case .server:
            speakWithServer(cleaned)
        case .system, .auto:
            speakWithSystem(cleaned)
        }
    }

    /// Stops all speech and clears all queues.
    func stop() {
        // Clear streaming mode flag BEFORE stopping the on-device service so the
        // queue pipeline's wait-loop exits cleanly rather than waiting for more text.
        kokoroService.streamingModeActive = false

        // Stop on-device TTS
        kokoroService.stop()
        isUsingKokoro = false

        // Stop server TTS — cancel prefetch and tear down queue player
        stopServerPlayback()

        // Stop system TTS
        systemQueue.removeAll()
        isSpeakingSystemChunk = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        // Stop streaming state
        isStreamingTTS = false
        streamingSpokenLength = 0

        state = .idle

        // Deactivate audio session to release hardware resources
        deactivateAudioSession()
    }

    /// Tears down the server TTS pipeline cleanly.
    private func stopServerPlayback() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedItems.removeAll()
        serverQueue.removeAll()
        isRunningServerQueue = false
        isUsingServer = false
        queuedItemCount = 0
        finishedItemCount = 0
        queuePlayerObservation?.invalidate()
        queuePlayerObservation = nil
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        // Remove the end-of-item observer via its token (closure-based API requires this).
        if let token = playerItemEndObserver {
            NotificationCenter.default.removeObserver(token)
            playerItemEndObserver = nil
        }
        // Delete any temp files that were prefetched but not yet played
        // (e.g. user pressed Stop mid-sentence, or app interrupted TTS).
        let orphanedURLs = playerItemTempURLs.values
        playerItemTempURLs.removeAll()
        for url in orphanedURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func pause() {
        if isUsingKokoro {
            kokoroService.stop()
            state = .paused
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            state = .paused
        }
    }

    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            state = .speaking
        }
    }

    func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language != rhs.language {
                    return lhs.language < rhs.language
                }
                return lhs.quality.rawValue > rhs.quality.rawValue
            }
    }

    /// Detects the dominant language of `text` using NLLanguageRecognizer and
    /// returns the highest-quality installed `AVSpeechSynthesisVoice` for that
    /// language. Falls back to the device locale voice if detection fails or no
    /// matching voice is installed.
    private func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage?.rawValue  // e.g. "fr", "de", "ja"

        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        // Try to find a voice whose BCP-47 tag starts with the detected language code
        if let lang = detected, !lang.isEmpty {
            let match = allVoices
                .filter { $0.language.hasPrefix(lang) }
                .sorted { $0.quality.rawValue > $1.quality.rawValue }
                .first
            if let match { return match }
        }

        // Fallback: device locale
        let deviceLang = Locale.current.language.languageCode?.identifier ?? "en"
        return allVoices
            .filter { $0.language.hasPrefix(deviceLang) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
            .first
        ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - Streaming TTS

    /// Call before streaming begins. Resets spoken-length tracking.
    /// Does NOT unload the model — only stops playback and clears queues.
    func startStreamingTTS() {
        // Stop any active speech without unloading the model
        kokoroService.stop()
        isUsingKokoro = false

        stopServerPlayback()

        systemQueue.removeAll()
        isSpeakingSystemChunk = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        state = .idle
        isStreamingTTS = true
        streamingSpokenLength = 0

        // Tell the on-device queue pipeline to keep its audio session alive
        // while text is still being streamed — prevents premature pipeline exit
        // that causes pauses, skipped sentences, and double-generation.
        kokoroService.streamingModeActive = true
    }

    /// Feed accumulated streaming text. Extracts new complete sentences and enqueues them.
    func feedStreamingText(_ accumulatedText: String) {
        guard isStreamingTTS else { return }

        let (newChunks, newLength) = TTSTextPreprocessor.extractNewSpeakableChunks(
            from: accumulatedText,
            alreadySpokenLength: streamingSpokenLength
        )
        guard !newChunks.isEmpty else { return }
        streamingSpokenLength = newLength

        let engine = resolveEngine()
        activeEngine = engine

        // For on-device TTS, join all chunks into one — sentence-level streaming handles it
        if engine == .kokoro || engine == .qwen3 {
            enqueueChunk(newChunks.joined(separator: " "), engine: engine)
        } else {
            for chunk in newChunks {
                enqueueChunk(chunk, engine: engine)
            }
        }
    }

    /// Call when streaming is complete. Speaks any remaining text then fires onComplete.
    func finishStreamingTTS(finalText: String) {
        guard isStreamingTTS else { return }

        let (remaining, newLength) = TTSTextPreprocessor.extractFinalChunks(
            from: finalText,
            alreadySpokenLength: streamingSpokenLength
        )
        streamingSpokenLength = newLength
        isStreamingTTS = false  // Mark streaming done BEFORE enqueuing final chunks

        let engine = resolveEngine()
        activeEngine = engine

        if remaining.isEmpty {
            // No final chunks to enqueue — clear the streaming flag so the queue
            // pipeline drains its remaining buffer and completes naturally.
            kokoroService.streamingModeActive = false

            // If TTS is already idle (no buffered audio), fire onComplete now.
            if !(isUsingKokoro && kokoroService.isPlaying) && !isUsingServer && !isSpeakingSystemChunk {
                state = .idle
                onComplete?()
            }
            return
        }

        // Enqueue any final chunks, then clear the streaming flag so the queue
        // pipeline knows no more input is coming and can finish after these chunks.
        if engine == .kokoro || engine == .qwen3 {
            enqueueChunk(remaining.joined(separator: " "), engine: engine)
        } else {
            for chunk in remaining {
                enqueueChunk(chunk, engine: engine)
            }
        }

        // Clear the streaming mode flag AFTER enqueuing all final chunks.
        // The queue pipeline will drain the last sentences and then exit cleanly.
        kokoroService.streamingModeActive = false
    }

    // MARK: - Engine Resolution

    private func resolveEngine() -> TTSEngine {
        switch preferredEngine {
        case .kokoro:
            return kokoroService.isAvailable ? .kokoro : .system
        case .qwen3:
            return kokoroService.isAvailable ? .qwen3 : .system
        case .server:
            return isServerAvailable ? .server : .system
        case .system:
            return .system
        case .auto:
            if kokoroService.isAvailable && kokoroService.isReady { return .kokoro }
            if isServerAvailable { return .server }
            return .system
        }
    }

    // MARK: - On-Device TTS (Kokoro + Qwen3)

    private func speakWithKokoro(_ text: String) {
        isUsingKokoro = true
        state = .speaking
        Task {
            await kokoroService.speak(text)
        }
    }

    // MARK: - Server TTS

    private func speakWithServer(_ text: String) {
        isUsingServer = true
        state = .speaking
        onStart?()
        let sentences = TTSTextPreprocessor.splitIntoSentences(text)
        serverQueue.append(contentsOf: sentences)
        if !isRunningServerQueue {
            isRunningServerQueue = true
            startServerPipeline()
        }
    }

    /// Starts the server TTS pipeline using AVQueuePlayer for gapless playback.
    ///
    /// **Producer task** fetches audio from the server and converts each response
    /// into an `AVPlayerItem` backed by an in-memory `AVAsset`. Items are enqueued
    /// into `AVQueuePlayer` as they arrive so playback starts with the first chunk
    /// and continues seamlessly into subsequent chunks without any polling gaps.
    ///
    /// **Completion** is detected by observing `AVQueuePlayer.currentItem` — when
    /// it goes nil and the producer is done, we know all audio has played.
    private func startServerPipeline() {
        guard let apiClient else {
            isRunningServerQueue = false
            isUsingServer = false
            let remaining = serverQueue.joined(separator: " ")
            serverQueue.removeAll()
            speakWithSystem(remaining)
            return
        }

        let voiceId = serverVoiceId ?? serverDefaultVoice
        let speakerOverride = speakerOverrideEnabled

        // Configure audio session before starting the player
        let session = AVAudioSession.sharedInstance()
        if speakerOverride {
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try? session.setActive(true)
            try? session.overrideOutputAudioPort(.speaker)
        } else {
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }

        // Create a fresh AVQueuePlayer for this playback session
        let player = AVQueuePlayer()
        player.volume = 1.0
        queuePlayer = player
        queuedItemCount = 0
        finishedItemCount = 0

        // Observe currentItem going nil (queue exhausted) to detect end-of-playback
        queuePlayerObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // currentItem == nil means the queue is empty and playback finished
                guard player.currentItem == nil else { return }
                // Only fire completion if the producer is done AND we actually played something
                guard !self.isRunningServerQueue else { return }
                self.handleServerPlaybackComplete()
            }
        }

        // Register for per-item end notifications so we can track finished count.
        // Temp files are NOT deleted here — they're deleted in bulk in stopServerPlayback()
        // once the session ends, to avoid any race with AVQueuePlayer's gapless buffering.
        // IMPORTANT: Store the returned token so we can properly remove this observer later.
        // Using removeObserver(self, ...) does NOT work for the closure-based addObserver API.
        playerItemEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.finishedItemCount += 1
                // If producer is done and all enqueued items finished, complete
                if !self.isRunningServerQueue && self.finishedItemCount >= self.queuedItemCount {
                    self.handleServerPlaybackComplete()
                }
            }
        }

        // Producer: fetch audio chunks and enqueue as AVPlayerItems
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            var producedAtLeastOne = false

            while !Task.isCancelled {
                let chunk: String? = await MainActor.run {
                    guard !self.serverQueue.isEmpty else { return nil }
                    return self.serverQueue.removeFirst()
                }

                guard let text = chunk else {
                    // Queue empty — wait briefly for streaming to add more
                    try? await Task.sleep(for: .milliseconds(80))
                    let stillEmpty = await MainActor.run { self.serverQueue.isEmpty }
                    if stillEmpty { break }
                    continue
                }

                // Throttle: don't fetch too far ahead
                while !Task.isCancelled {
                    let ahead = await MainActor.run { self.queuedItemCount - self.finishedItemCount }
                    if ahead < self.serverPrefetchCount { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled else { break }

                do {
                    let (audioData, contentType) = try await apiClient.generateSpeech(
                        text: text,
                        voice: voiceId
                    )
                    // Write audio data to a temp file so AVPlayerItem can load it via URL.
                    // AVPlayerItem has no in-memory data initialiser; a file URL is required.
                    let ext = audioExtension(for: contentType)
                    let tmpURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    try audioData.write(to: tmpURL)

                    await MainActor.run {
                        guard !Task.isCancelled, let player = self.queuePlayer else {
                            try? FileManager.default.removeItem(at: tmpURL)
                            return
                        }
                        let item = AVPlayerItem(url: tmpURL)
                        // Track the temp file so we can delete it after playback finishes.
                        self.playerItemTempURLs[item] = tmpURL
                        player.insert(item, after: nil)
                        self.queuedItemCount += 1
                        producedAtLeastOne = true
                        // Start playing as soon as the first item is enqueued
                        if player.timeControlStatus == .paused || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                            player.play()
                        }
                    }
                } catch {
                    // Server TTS fetch failed for this chunk — skip it
                }
            }

            // Producer done — mark queue as no longer running
            await MainActor.run {
                self.isRunningServerQueue = false
                // If nothing was produced (all chunks errored), complete immediately
                let produced = producedAtLeastOne
                if !produced {
                    self.handleServerPlaybackComplete()
                }
            }
        }
    }

    /// Called when AVQueuePlayer finishes playing all items.
    private func handleServerPlaybackComplete() {
        // Remove the per-item end observer using the stored token.
        // NOTE: removeObserver(self, ...) only works for target-action style observers.
        // For closure-based addObserver calls we must use the returned token.
        if let token = playerItemEndObserver {
            NotificationCenter.default.removeObserver(token)
            playerItemEndObserver = nil
        }
        let hadItems = queuedItemCount > 0
        stopServerPlayback()
        if !isStreamingTTS {
            state = .idle
            deactivateAudioSession()
            if hadItems {
                onComplete?()
            }
        }
    }

    // MARK: - System TTS

    private func speakWithSystem(_ text: String) {
        systemQueue.append(contentsOf: TTSTextPreprocessor.splitIntoSentences(text))
        if !isSpeakingSystemChunk {
            speakNextSystemChunk()
        }
    }

    private func speakNextSystemChunk() {
        guard !systemQueue.isEmpty else {
            isSpeakingSystemChunk = false
            if !isStreamingTTS && !isUsingKokoro && !isUsingServer {
                state = .idle
                deactivateAudioSession()
                onComplete?()
            }
            return
        }

        let chunk = systemQueue.removeFirst()
        let utterance = AVSpeechUtterance(string: chunk)

        if let voiceId = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = voice
        } else {
            // Auto-detect the language of the text and pick a matching voice.
            // This ensures non-English responses are spoken with correct pronunciation.
            utterance.voice = bestVoice(for: chunk)
        }

        utterance.rate = speechRate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.volume = volume
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.05

        do {
            let session = AVAudioSession.sharedInstance()
            if speakerOverrideEnabled {
                // Voice call — keep mic+speaker active and force loudspeaker
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try session.setActive(true)
                try session.overrideOutputAudioPort(.speaker)
            } else {
                // Regular read-aloud — use playback mode which routes to loudspeaker by default
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            }
        } catch {
            // Audio session config failed — proceed anyway, system will use defaults
        }

        isSpeakingSystemChunk = true
        state = .speaking
        if systemQueue.isEmpty { onStart?() }

        synthesizer.speak(utterance)
    }

    // MARK: - Audio Helpers

    /// Maps a Content-Type header value to the corresponding audio file extension.
    /// Used when writing server TTS audio to a temp file for `AVPlayerItem(url:)`.
    private func audioExtension(for contentType: String) -> String {
        let ct = contentType.lowercased()
        if ct.contains("wav")  { return "wav"  }
        if ct.contains("aac")  { return "aac"  }
        if ct.contains("ogg") || ct.contains("opus") { return "ogg" }
        if ct.contains("flac") { return "flac" }
        return "mp3"   // MP3 is the most common TTS backend output format
    }

    // MARK: - Audio Session Management

    /// Deactivates the shared audio session to release hardware resources.
    /// Called after all TTS playback finishes (both natural completion and stop()).
    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - Chunk Enqueuing (used by streaming TTS)

    private func enqueueChunk(_ chunk: String, engine: TTSEngine) {
        switch engine {
        case .kokoro, .qwen3:
            isUsingKokoro = true
            Task { await kokoroService.enqueue(chunk) }
        case .server:
            isUsingServer = true
            serverQueue.append(chunk)
            if !isRunningServerQueue {
                isRunningServerQueue = true
                startServerPipeline()
            }
        case .system, .auto:
            systemQueue.append(chunk)
            if !isSpeakingSystemChunk {
                speakNextSystemChunk()
            }
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TextToSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speakNextSystemChunk()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSpeakingSystemChunk = false
            self.state = .idle
        }
    }
}
