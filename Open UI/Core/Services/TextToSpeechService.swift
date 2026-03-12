import Foundation
import AVFoundation
import os.log
import NaturalLanguage

/// Manages text-to-speech with support for both Apple's AVSpeechSynthesizer,
/// on-device MarvisTTS, and server-side TTS.
///
/// ## TTS Engine Default
/// **AVSpeechSynthesizer** (system) is the default — works instantly with no
/// downloads. Users can opt in to MarvisTTS or Server TTS in Settings.
///
/// ## Auto Mode Priority (when selected by user)
/// 1. **MarvisTTS** (on-device neural) — if model is downloaded and loaded
/// 2. **Server TTS** (OpenWebUI API) — if configured
/// 3. **AVSpeechSynthesizer** (system) — fallback
@MainActor @Observable
final class TextToSpeechService: NSObject {

    // MARK: - Engine Selection

    enum TTSEngine: String, Sendable {
        case marvis   // On-device MarvisTTS
        case server   // Server-side TTS via OpenWebUI API
        case system   // Apple AVSpeechSynthesizer
        case auto     // Prefer MarvisTTS if loaded → server → system
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

    var isMarvisAvailable: Bool { marvisService.isAvailable }
    var marvisState: MarvisTTSState { marvisService.state }
    var marvisDownloadProgress: Double { marvisService.downloadProgress }

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

    func configureServerTTS(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()
    let marvisService = MarvisTTSService()
    private let logger = Logger(subsystem: "com.openui", category: "TTS")

    // System TTS queue
    private var systemQueue: [String] = []
    private var isSpeakingSystemChunk = false

    // Server TTS state
    private var serverQueue: [String] = []
    private var isRunningServerQueue = false
    private var serverAudioPlayer: AVAudioPlayer?

    // Active engine flags
    private var isUsingMarvis = false
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

        // Restore saved engine preference
        if let saved = UserDefaults.standard.string(forKey: "ttsEngine") {
            switch saved {
            case "marvis", "mlx": preferredEngine = .marvis
            case "server":        preferredEngine = .server
            case "system":        preferredEngine = .system
            default:              preferredEngine = .auto
            }
        }

        // Wire MarvisTTS callbacks
        marvisService.onSpeakingStarted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.state = .speaking
                self?.onStart?()
            }
        }

        marvisService.onSpeakingComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // If streaming mode is still active, more text may arrive — don't complete yet.
                if self.isStreamingTTS {
                    self.logger.info("MarvisTTS done but streaming still active — waiting")
                    return
                }
                self.state = .idle
                self.isUsingMarvis = false
                // Model stays loaded for fast re-use; unloaded only on background/explicit stop
                self.onComplete?()
            }
        }

        marvisService.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.error("MarvisTTS error: \(error)")
                self.isUsingMarvis = false
                self.onError?(error)
            }
        }
    }

    // MARK: - MarvisTTS Configuration

    var marvisConfig: MarvisTTSConfig {
        get { marvisService.config }
        set { marvisService.config = newValue }
    }

    func preloadMarvisModel() async {
        guard marvisService.isAvailable else { return }
        do {
            try await marvisService.loadModel()
            logger.info("MarvisTTS model preloaded")
        } catch {
            logger.warning("MarvisTTS preload failed: \(error.localizedDescription)")
        }
    }

    func unloadMarvisModel() {
        marvisService.unloadModel()
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
        case .marvis:
            speakWithMarvis(cleaned)
        case .server:
            speakWithServer(cleaned)
        case .system, .auto:
            speakWithSystem(cleaned)
        }
    }

    /// Stops all speech and clears all queues.
    func stop() {
        // Stop MarvisTTS
        marvisService.stop()
        isUsingMarvis = false

        // Stop server TTS
        serverAudioPlayer?.stop()
        serverAudioPlayer = nil
        serverQueue.removeAll()
        isRunningServerQueue = false
        isUsingServer = false

        // Stop system TTS
        systemQueue.removeAll()
        isSpeakingSystemChunk = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        // Stop streaming state
        isStreamingTTS = false
        streamingSpokenLength = 0

        state = .idle
    }

    func pause() {
        if isUsingMarvis {
            marvisService.stop()
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
            .filter { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    // MARK: - Streaming TTS

    /// Call before streaming begins. Resets spoken-length tracking.
    /// Does NOT unload the model — only stops playback and clears queues.
    func startStreamingTTS() {
        // Stop any active speech without unloading the model
        marvisService.stop()
        isUsingMarvis = false

        serverAudioPlayer?.stop()
        serverAudioPlayer = nil
        serverQueue.removeAll()
        isRunningServerQueue = false
        isUsingServer = false

        systemQueue.removeAll()
        isSpeakingSystemChunk = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        state = .idle
        isStreamingTTS = true
        streamingSpokenLength = 0
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

        // For MarvisTTS, join all chunks into one — the library handles streaming internally
        if engine == .marvis {
            let joined = newChunks.joined(separator: " ")
            enqueueChunk(joined, engine: engine)
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
            // Nothing left to speak — check if TTS is already idle
            let marvisBusy = isUsingMarvis && marvisService.isPlaying
            let serverBusy = isUsingServer
            let systemBusy = isSpeakingSystemChunk
            if !marvisBusy && !serverBusy && !systemBusy {
                state = .idle
                onComplete?()
            }
            return
        }

        if engine == .marvis {
            let joined = remaining.joined(separator: " ")
            enqueueChunk(joined, engine: engine)
        } else {
            for chunk in remaining {
                enqueueChunk(chunk, engine: engine)
            }
        }
    }

    // MARK: - Engine Resolution

    private func resolveEngine() -> TTSEngine {
        switch preferredEngine {
        case .marvis:
            return marvisService.isAvailable ? .marvis : .system
        case .server:
            return isServerAvailable ? .server : .system
        case .system:
            return .system
        case .auto:
            if marvisService.isAvailable && marvisService.isReady { return .marvis }
            if isServerAvailable { return .server }
            return .system
        }
    }

    // MARK: - MarvisTTS

    private func speakWithMarvis(_ text: String) {
        isUsingMarvis = true
        state = .speaking
        Task {
            await marvisService.speak(text)
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
            Task { await processServerQueue() }
        }
    }

    private func processServerQueue() async {
        guard !serverQueue.isEmpty else {
            isRunningServerQueue = false
            isUsingServer = false
            if !isStreamingTTS {
                state = .idle
                onComplete?()
            }
            return
        }

        isRunningServerQueue = true
        let chunk = serverQueue.removeFirst()

        guard let apiClient else {
            logger.error("Server TTS: no API client, falling back to system")
            isRunningServerQueue = false
            isUsingServer = false
            let remaining = ([chunk] + serverQueue).joined(separator: " ")
            serverQueue.removeAll()
            speakWithSystem(remaining)
            return
        }

        do {
            let (audioData, _) = try await apiClient.generateSpeech(
                text: chunk,
                voice: serverVoiceId
            )

            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                     options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try? session.setActive(true)

            let player = try AVAudioPlayer(data: audioData)
            self.serverAudioPlayer = player
            player.prepareToPlay()
            player.play()

            while player.isPlaying {
                try? await Task.sleep(for: .milliseconds(50))
            }

            await processServerQueue()
        } catch {
            logger.error("Server TTS chunk failed: \(error.localizedDescription)")
            isRunningServerQueue = false
            isUsingServer = false

            if preferredEngine == .auto {
                let remaining = serverQueue.joined(separator: " ")
                serverQueue.removeAll()
                if !remaining.isEmpty { speakWithSystem(remaining) }
            } else {
                serverQueue.removeAll()
                state = .idle
                onError?("Server TTS failed: \(error.localizedDescription)")
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
            if !isStreamingTTS && !isUsingMarvis && !isUsingServer {
                state = .idle
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
            utterance.voice = AVSpeechSynthesisVoice(
                language: Locale.current.language.languageCode?.identifier ?? "en-US")
        }

        utterance.rate = speechRate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.volume = volume
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.05

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            logger.warning("Audio session config skipped: \(error.localizedDescription)")
        }

        isSpeakingSystemChunk = true
        state = .speaking
        if systemQueue.isEmpty { onStart?() }

        synthesizer.speak(utterance)
    }

    // MARK: - Chunk Enqueuing (used by streaming TTS)

    private func enqueueChunk(_ chunk: String, engine: TTSEngine) {
        switch engine {
        case .marvis:
            isUsingMarvis = true
            Task { await marvisService.enqueue(chunk) }
        case .server:
            isUsingServer = true
            serverQueue.append(chunk)
            if !isRunningServerQueue {
                Task { await processServerQueue() }
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
