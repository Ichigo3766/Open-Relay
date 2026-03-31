import Foundation
import AVFoundation
import os.log
import BackgroundTasks

#if canImport(MLXAudioSTT)
import MLXAudioSTT
import MLXAudioCore
import MLX
import HuggingFace
#endif

// MARK: - Model Variant

/// Identifies which on-device ASR model is active.
enum ASRModelVariant: String, CaseIterable, Sendable {
    case qwen3ASR = "qwen3asr"

    var displayName: String { "Qwen3 ASR 0.6B" }
    var repoId: String { "mlx-community/Qwen3-ASR-0.6B-8bit" }
}

// MARK: - State

enum ASRState: Sendable, Equatable {
    case unloaded
    case loading
    case ready
    case transcribing
    /// Transcription was paused because the app moved to the background.
    /// Associated value: the attachment ID being processed when paused.
    case paused
    case error(String)
}

// MARK: - Errors

enum ASRError: LocalizedError {
    case notAvailable
    case modelNotLoaded
    case modelLoadFailed(String)
    case transcriptionFailed(String)
    /// Transcription was cancelled because the app entered the background.
    /// The caller should re-start transcription when the app returns to foreground.
    case backgroundInterrupted

    var errorDescription: String? {
        switch self {
        case .notAvailable:             return "On-device ASR not available on this device."
        case .modelNotLoaded:           return "ASR model not loaded."
        case .modelLoadFailed(let r):   return "ASR model load failed: \(r)"
        case .transcriptionFailed(let r): return "Transcription failed: \(r)"
        case .backgroundInterrupted:    return "Transcription paused — app moved to background."
        }
    }
}

// MARK: - OnDeviceASRService

/// On-device automatic speech recognition using Qwen3 ASR 0.6B.
///
/// Backed by the mlx-audio-swift library. Audio is downsampled to 16 kHz
/// off the main actor so the UI spinner remains responsive.
///
/// Qwen3 ASR is a multilingual model that supports automatic language detection.
/// When `language: nil` is passed, it auto-detects the spoken language and
/// transcribes accordingly — no manual language selection needed.
///
/// ## Background Safety
///
/// iOS forbids Metal GPU access from backgrounded apps. When the app moves to
/// `.inactive`/`.background`, call `pauseForBackground()` to gracefully cancel
/// the in-flight MLX task BEFORE iOS revokes GPU access. This prevents the
/// uncatchable `std::runtime_error` crash from MLX's Metal command buffer.
///
/// On iOS 26+ **on devices that support background GPU** (iPad M3+ only),
    /// a `BGContinuedProcessingTask` is submitted so that GPU work continues
    /// uninterrupted. `pauseForBackground()` is a no-op only when such a task
    /// is actually active. All iPhones and unsupported iPads fall through to the
    /// existing cancel-and-unload path.
    ///
    @MainActor @Observable
final class OnDeviceASRService {

    // MARK: - Public State

    private(set) var state: ASRState = .unloaded
    var isReady: Bool { state == .ready }

    /// The model variant that will be used for the next transcription.
    /// Changing this unloads any currently-loaded model.
    private(set) var activeVariant: ASRModelVariant

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

    private let logger = Logger(subsystem: "com.openui", category: "OnDeviceASR")
    private var isLoadInProgress = false

    /// `true` when running on iOS 26+ with a device that supports background GPU
    /// (iPad M3+ only). Determined at runtime via `BGTaskScheduler.supportedResources`.
    /// `nonisolated` so it can be safely called from within the `nonisolated transcribe()` method.
    nonisolated static var supportsBackgroundGPU: Bool {
        if #available(iOS 26, *) {
            return BGTaskScheduler.supportedResources.contains(.gpu)
        }
        return false
    }

    /// Holds the active `BGContinuedProcessingTask` (typed as `AnyObject` to avoid
    /// `@available` annotations on the stored property itself). Non-nil only while
    /// a continued-processing task has been granted by the system on iOS 26+ iPad M3+.
    @ObservationIgnored nonisolated(unsafe) private var activeContinuedTask: AnyObject?

    #if canImport(MLXAudioSTT)
    // nonisolated(unsafe): Qwen3ASRModel is not Sendable, but all writes happen
    // on @MainActor (loadModel / unloadModel) and reads in transcribe() are
    // pre-captured into a local `capturedModel` constant on @MainActor before
    // the detached Task executes — so no concurrent access actually occurs.
    @ObservationIgnored nonisolated(unsafe) private var qwen3Model: Qwen3ASRModel?
    #endif

    /// The currently running transcription Task. Stored so it can be cancelled
    /// when the app moves to the background (to prevent a Metal GPU crash).
    @ObservationIgnored nonisolated(unsafe) private var activeTranscriptionTask: Task<String, Error>?

    // MARK: - Init

    init() {
        let raw = UserDefaults.standard.string(forKey: "sttEngine") ?? "qwen3asr"
        activeVariant = ASRModelVariant(rawValue: raw) ?? .qwen3ASR
        registerBackgroundTaskHandlerIfNeeded()
    }

    // MARK: - BGContinuedProcessingTask Registration

    /// Registers the BGTask handler exactly once during app launch (called from `init()`).
    /// On iOS 26+ devices with background GPU support (iPad M3+), this wires up the
    /// `BGContinuedProcessingTask` so the system can call back when GPU time is granted.
    /// On all other devices this is a no-op.
    private func registerBackgroundTaskHandlerIfNeeded() {
        if #available(iOS 26, *) {
            guard OnDeviceASRService.supportsBackgroundGPU else { return }
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.openui.asr.transcription",
                using: nil
            ) { [weak self] task in
                guard let continuedTask = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                // Store the task so pauseForBackground() knows GPU is live.
                Task { @MainActor [weak self] in
                    self?.activeContinuedTask = continuedTask
                }
                // If the system needs to reclaim GPU early, cancel gracefully.
                continuedTask.expirationHandler = { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.logger.info("BGContinuedProcessingTask expired — pausing ASR")
                        self.endActiveContinuedTask(success: false)
                        self.pauseForBackground()
                    }
                }
            }
        }
    }

    /// Calls `setTaskCompleted` on the active continued processing task and clears
    /// the stored reference. Safe to call when no task is active (no-op).
    private func endActiveContinuedTask(success: Bool) {
        if #available(iOS 26, *) {
            (activeContinuedTask as? BGContinuedProcessingTask)?.setTaskCompleted(success: success)
        }
        activeContinuedTask = nil
    }

    // MARK: - Variant Switching

    /// Switches to a different model variant. Unloads the current model if one
    /// is loaded, so only one model is ever in memory at a time.
    func switchVariant(_ variant: ASRModelVariant) {
        guard variant != activeVariant else { return }
        if state != .unloaded { unloadModel() }
        activeVariant = variant
        UserDefaults.standard.set(variant.rawValue, forKey: "sttEngine")
        logger.info("Switched ASR variant to \(variant.displayName)")
    }

    // MARK: - Model Loading

    func loadModel() async throws {
        guard isAvailable else { throw ASRError.notAvailable }

        #if canImport(MLXAudioSTT)
        let variant = activeVariant
        if isLoadInProgress {
            logger.info("ASR model load already in progress, ignoring (\(variant.displayName, privacy: .public))")
            return
        }
        if qwen3Model != nil && state == .ready { return }
        if case .ready = state { return }

        isLoadInProgress = true
        state = .loading
        logger.info("Loading ASR model: \(variant.displayName, privacy: .public)")

        do {
            let modelCache = HubCache(location: .fixed(directory: StorageManager.modelCacheDirectory))
            qwen3Model = try await Qwen3ASRModel.fromPretrained(variant.repoId, cache: modelCache)
            state = .ready
            isLoadInProgress = false
            logger.info("ASR model loaded: \(variant.displayName, privacy: .public)")
            // Clean up Hub blob cache (models--* dirs) left behind by the HuggingFace
            // download library — these are duplicates of the working copy in mlx-audio/.
            Task.detached(priority: .utility) {
                await StorageManager.shared.cleanupHubCache()
            }
        } catch {
            let msg = error.localizedDescription
            state = .error("\(variant.displayName) load failed: \(msg)")
            isLoadInProgress = false
            throw ASRError.modelLoadFailed(msg)
        }
        #else
        throw ASRError.notAvailable
        #endif
    }

    func unloadModel() {
        #if canImport(MLXAudioSTT)
        qwen3Model = nil
        Memory.clearCache()
        #endif
        isLoadInProgress = false
        state = .unloaded
        let variantName = activeVariant.displayName
        logger.info("ASR model unloaded: \(variantName, privacy: .public)")
    }

    /// Unloads the model AND deletes the downloaded files from disk.
    /// The model will re-download on next use.
    func unloadAndDeleteModel() {
        let variantName = activeVariant.displayName
        unloadModel()
        let freed = StorageManager.shared.deleteASRModelFiles()
        if freed > 0 {
            logger.info("\(variantName, privacy: .public) files deleted (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file), privacy: .public))")
        }
    }

    /// Returns the on-disk size (bytes) of the cached model files.
    func modelSize(for variant: ASRModelVariant) -> Int64 {
        StorageManager.shared.asrModelSize()
    }

    /// Unloads (if active) and deletes the model files from disk.
    func unloadAndDeleteVariant(_ variant: ASRModelVariant) {
        if variant == activeVariant { unloadModel() }
        let freed = StorageManager.shared.deleteASRModelFiles()
        if freed > 0 {
            logger.info("\(variant.displayName) files deleted (\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)))")
        }
    }

    // MARK: - Background Safety

    /// Call this when the app moves to `.inactive` or `.background` to prevent
    /// the Metal GPU crash (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`).
    ///
    /// On iOS 26+ with the Background GPU Access entitlement, this method is a
    /// no-op — the `BGContinuedProcessingTask` keeps GPU work alive.
    ///
    /// On iOS < 26, this cancels any in-flight MLX/Metal task and unloads the model
    /// to release GPU resources before iOS revokes access. The caller is responsible
    /// for restarting transcription when the app returns to the foreground.
    func pauseForBackground() {
        // When a BGContinuedProcessingTask is active, the system has explicitly
        // granted background GPU access for this device (iPad M3+ only).
        // In that case, transcription can continue — don't cancel.
        if activeContinuedTask != nil {
            logger.info("BGContinuedProcessingTask active — GPU access maintained, not pausing ASR")
            return
        }

        // No active continued-processing task: Metal is not accessible from the
        // background. Cancel the active task to prevent the C++ runtime_error crash.
        // This covers ALL iPhones (regardless of iOS version) and iPads without M3+.
        guard case .transcribing = state else { return }

        logger.info("Backgrounding detected — pausing ASR transcription to avoid GPU crash")

        // Cancel the task. This triggers Task.isCancelled in the detached work,
        // causing the generateStream loop to exit cleanly on its next check.
        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil

        // Unload Metal resources immediately so iOS can't revoke access mid-operation.
        // The model is cached on disk — it will reload fast when transcription resumes.
        unloadModel()

        // Transition to paused state so callers know to resume later.
        state = .paused
        logger.info("ASR paused and Metal resources released")
    }

    // MARK: - Transcription

    /// Transcribes audio data (WAV, M4A, MP3, etc.) to text using the active model.
    ///
    /// The method is `nonisolated` so it can be awaited from any actor without
    /// blocking the main thread. State mutations (`state`, `downloadProgress`)
    /// hop back to `@MainActor` via `MainActor.run {}`. The heavy ML token loop
    /// runs on a detached background task so the UI stays fully responsive.
    ///
    /// Qwen3 ASR automatically detects the spoken language when `language: nil`
    /// is used, so Spanish, French, German, etc. are all transcribed correctly
    /// without any manual configuration.
    ///
    /// - Parameter audioData: Raw audio file data
    /// - Parameter fileName: Original filename (used for temp file extension)
    /// - Returns: Transcribed text
    /// - Throws: `ASRError.backgroundInterrupted` if the app moved to background
    ///           (iOS < 26). The caller should restart when foregrounded.
    nonisolated func transcribe(audioData: Data, fileName: String) async throws -> String {
        guard await isAvailable else { throw ASRError.notAvailable }

        try await loadModel()

        #if canImport(MLXAudioSTT)

        await MainActor.run { state = .transcribing }

        // On iOS 26+ devices with background GPU support (iPad M3+), submit a
        // BGContinuedProcessingTask so transcription can survive backgrounding.
        // The registered handler (see registerBackgroundTaskHandlerIfNeeded) stores
        // the task reference, which pauseForBackground() checks before cancelling.
        if #available(iOS 26, *), Self.supportsBackgroundGPU {
            let request = BGContinuedProcessingTaskRequest(
                identifier: "com.openui.asr.transcription",
                title: "Transcribing Audio",
                subtitle: "Processing audio in the background"
            )
            request.requiredResources = [.gpu]
            do {
                try BGTaskScheduler.shared.submit(request)
                logger.info("BGContinuedProcessingTask submitted for background GPU access")
            } catch {
                logger.warning("BGContinuedProcessingTask submit failed (will cancel on background): \(error.localizedDescription, privacy: .public)")
            }
        }

        let variant = await activeVariant
        let logger = self.logger
        let variantDisplayName = await variant.displayName
        logger.info("Transcribing audio: \(fileName, privacy: .public) (\(audioData.count) bytes) with \(variantDisplayName, privacy: .public)")

        // Write to a temp file so the library can load it via AVAudioFile
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + fileName)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try audioData.write(to: tempURL)

        // Load audio and downsample to 16 kHz — Qwen3 ASR requires 16 kHz input.
        // Runs off the main actor to keep the UI spinner responsive.
        let (sampleRate, audioArray) = try await Task.detached(priority: .userInitiated) { [tempURL] in
            try loadAudioArray(from: tempURL, sampleRate: 16000)
        }.value

        let totalSamples = audioArray.dim(0)
        guard totalSamples > 0 else {
            await MainActor.run { state = .ready }
            throw ASRError.transcriptionFailed("No audio samples extracted")
        }

        let totalDuration = Double(totalSamples) / Double(sampleRate)
        logger.info("Audio loaded: \(String(format: "%.1f", totalDuration))s at \(sampleRate)Hz")

        // Use generate() for file transcription.
        // language: nil lets Qwen3 ASR auto-detect the spoken language.
        let params = STTGenerateParameters(
            language: nil,
            chunkDuration: 30
        )

        // Pre-capture the model reference on the main actor before the detached task.
        // nonisolated(unsafe) — no await needed; direct read is safe here because
        // we are still on @MainActor at this point (transcribe() hops back via
        // MainActor.run earlier), so no concurrent write can race with this read.
        let capturedModel: Qwen3ASRModel? = qwen3Model

        // Create the transcription task and register it so pauseForBackground() can cancel it.
        let transcriptionTask = Task.detached(priority: .userInitiated) {
            guard let model = capturedModel else { throw ASRError.modelNotLoaded }
            // Check for cancellation before starting the (potentially long) generate pass.
            try Task.checkCancellation()
            let output = model.generate(audio: audioArray, generationParameters: params)
            // Check again after — if cancelled during generate(), this throws.
            try Task.checkCancellation()
            return output.text
        }

        // Store on main actor so pauseForBackground() can cancel it.
        await MainActor.run { activeTranscriptionTask = transcriptionTask }

        do {
            let resultText = try await transcriptionTask.value

            await MainActor.run {
                activeTranscriptionTask = nil
                endActiveContinuedTask(success: true)
                state = .ready
                Memory.clearCache()
            }

            let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ASRError.transcriptionFailed("No speech detected in audio")
            }

            logger.info("Transcription complete: \(trimmed.count) chars")
            return trimmed

        } catch is CancellationError {
            // The task was cancelled by pauseForBackground().
            // Do NOT call unloadModel() here — pauseForBackground() already
            // unloaded the model before the cancel. Calling it again would log
            // a spurious "unloaded" message and is a no-op anyway.
            await MainActor.run {
                activeTranscriptionTask = nil
                endActiveContinuedTask(success: false)
                // State is already .paused (set by pauseForBackground()).
                // Only reset to .unloaded if somehow state wasn't updated.
                if case .transcribing = state { state = .paused }
            }
            logger.info("Transcription cancelled for background — will resume on foreground")
            throw ASRError.backgroundInterrupted
        }

        #else
        throw ASRError.notAvailable
        #endif
    }

    /// Transcribes audio from a file URL.
    func transcribe(fileURL: URL) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        return try await transcribe(audioData: data, fileName: fileURL.lastPathComponent)
    }

}
