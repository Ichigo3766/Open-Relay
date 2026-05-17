import Foundation
import AVFoundation
import os.log

   /// Centralized AVAudioSession manager with interruption handling, route change
/// recovery, and CarPlay volume-change interception.
///
/// Problem solved: CarPlay volume knob changes trigger an implicit audio
/// interruption. Without handling, iOS deactivates our session and resumes
/// background media (Spotify, Apple Music, etc.). This manager:
/// 1. Listens for interruptions and reactivates the session when they end
/// 2. Listens for route changes and re-activates the session on device change
/// 3. Provides a serial actor to prevent concurrent setCategory/setActive calls
@MainActor
final class AudioSessionManager {

    private let logger = Logger(subsystem: "com.openui", category: "AudioSession")

    /// Serial actor to prevent concurrent audio session reconfiguration.
    /// Multiple services (TTS, STT, VoiceCall) call setCategory/setActive independently.
    /// This actor ensures they execute sequentially, preventing race conditions.
    private let sessionQueue = AudioSessionQueue()

    /// Whether we're in an active voice call (affects deactivation behavior).
    private var isVoiceCallActive: Bool = false

    /// Callback fired when an interruption ends and playback should resume.
    var onInterruptionEnded: (() -> Void)?

    /// Callback fired when audio route changes (e.g., CarPlay connects/disconnects).
    var onRouteChanged: (() -> Void)?

    /// Notification observers (stored for cleanup).
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?
    private var mediaServicesResetObserver: Any?

    // MARK: - Lifecycle

    func startListening() {
        // 1. Interruption notification
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleInterruption(notification)
            }
        }

        // 2. Route change notification (CarPlay connect/disconnect, volume knob)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
            }
        }

        // 3. Media services reset (rare but should be handled)
        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logger.info("Media services were reset — reactivating session")
                self?.reactivateSession()
            }
        }

        logger.info("AudioSessionManager: listeners installed")
    }

    func stopListening() {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeChangeObserver = nil
        }
        if let obs = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(obs)
            mediaServicesResetObserver = nil
        }

        logger.info("AudioSessionManager: listeners removed")
    }

    // MARK: - Voice Call Lifecycle

    /// Called when a voice call starts. Prevents `.notifyOthersOnDeactivation` during call.
    func voiceCallStarted() {
        isVoiceCallActive = true
    }

    /// Called when a voice call ends.
    func voiceCallEnded() {
        isVoiceCallActive = false
    }

    /// Whether TTS should use `.notifyOthersOnDeactivation` on stop.
    /// Returns `false` during voice calls to prevent Spotify/music from resuming
    /// when TTS naturally completes between listen/speak cycles.
    var shouldNotifyOthersOnDeactivation: Bool {
        !isVoiceCallActive
    }

    // MARK: - Interruption Handling

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            logger.info("Audio interruption began")
            // Interruption began (e.g., phone call, CarPlay volume change misinterpreted).
            // TTS should pause, not stop. The onComplete callback won't fire.

        case .ended:
            logger.info("Audio interruption ended")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            if options.contains(.shouldResume) {
                // Resume playback after interruption ends.
                // This is the key fix: after CarPlay volume change, we reactivate
                // the session instead of letting background media take over.
                reactivateSession()
                onInterruptionEnded?()
            }

        @unknown default:
            break
        }
    }

    // MARK: - Route Change Handling

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }

        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        logger.info("Audio route changed: \(reason?.rawValue ?? 0)")

        switch reason {
        case .newDeviceAvailable:
            // New audio device connected (e.g., CarPlay, BT headset)
            onRouteChanged?()

        case .oldDeviceUnavailable:
            // Audio device disconnected
            onRouteChanged?()

        case .categoryChange:
            // Category was changed by something else — reassert our configuration
            if isVoiceCallActive {
                reactivateSession()
            }

        case .override:
            // Output port override changed — re-apply routing
            onRouteChanged?()

        default:
            break
        }
    }

    // MARK: - Session Reactivation

    /// Re-activates the audio session after an interruption or route change.
    /// Uses the serial queue to avoid racing with other session configuration.
    private func reactivateSession() {
        Task.detached {
            await self.sessionQueue.configure { session in
                // Re-activate with current category (don't change category, just activate)
                try? session.setActive(true)
                // Re-apply output override for CarPlay safety
                let isCarPlayOrHFP = session.currentRoute.outputs.contains { output in
                    output.portType == .carAudio || output.portType == .bluetoothHFP
                }
                if !isCarPlayOrHFP {
                    try? session.overrideOutputAudioPort(.speaker)
                }
            }
        }
    }

    // MARK: - Serial Configuration

    /// Configures the audio session through the serial queue to prevent races.
    /// Call this instead of calling setCategory/setActive directly from services.
    func configureSession(_ configuration: @escaping (AVAudioSession) throws -> Void) {
        Task.detached {
            await self.sessionQueue.configure(configuration)
        }
    }
}

// MARK: - Serial Actor for Audio Session Configuration

/// Ensures setCategory/setActive calls execute one at a time.
/// Without this, concurrent calls from TTS/STT/VoiceCall can cause the session
/// to end up in an inconsistent state.
actor AudioSessionQueue {

    func configure(_ configuration: (AVAudioSession) throws -> Void) {
        let session = AVAudioSession.sharedInstance()
        do {
            try configuration(session)
        } catch {
            // Log but don't propagate — individual services handle their own errors
        }
    }
}
