import AVFoundation
import Foundation

/// The watch's single audio engine for Talk: mic in + reply audio out.
///
/// In **conversation** mode the mic and the player share one engine with
/// Apple's voice processing (echo cancellation) on, so the mic hears you but
/// not the reply — that's what makes "speak to interrupt" work.
/// **Playback** mode (typed questions) plays replies without the mic.
@MainActor
final class WatchAudio {

    static let shared = WatchAudio()

    enum Mode { case off, playback, conversation }

    private(set) var mode: Mode = .off
    /// Echo cancellation is active (not every route supports it).
    private(set) var echoCancelling = false
    /// When the reply currently playing started (nil = nothing playing).
    var playbackStartedAt: Date?
    var pendingBuffers = 0

    /// Receives mic audio in conversation mode. Thread-safe.
    let mic = MicTap()
    /// Fixed format every scheduled buffer is converted to.
    let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    var engine: AVAudioEngine?
    var player: AVAudioPlayerNode?
    /// A mic tap is installed on the engine's input node.
    private var tapInstalled = false
    var generation = 0
    var converters: [String: AVAudioConverter] = [:]
    var idleStop: Task<Void, Never>?

    var isPlaying: Bool { pendingBuffers > 0 }

    var isMuted = false {
        didSet {
            mic.setMuted(isMuted)
            if echoCancelling, let engine { engine.inputNode.isVoiceProcessingInputMuted = isMuted }
        }
    }

    /// Echo cancellation was seen to deliver no audio during this launch, so
    /// Talk uses plain recording until the app restarts or "Try Again".
    /// (Deliberately not saved — a quiet room once must not disable it forever.)
    private static var echoBrokenThisLaunch = false
    var echoAllowed: Bool {
        get { !Self.echoBrokenThisLaunch }
        set { Self.echoBrokenThisLaunch = !newValue }
    }

    /// Settings → "Try Again": re-enable echo cancellation for the next Talk.
    func retryEcho() {
        echoAllowed = true
        if mode == .conversation { stop() }
    }

    /// Starts mic + speaker. Uses echo cancellation unless it's been found
    /// not to work here (`echoAllowed`) or `useEcho` is false.
    private init() {
        // Older builds saved "echo cancellation broken" permanently — clear it.
        UserDefaults.standard.removeObject(forKey: "watch.echoCancellationBroken")
        // The engine stops itself when the audio route or hardware format changes.
        // Restart it so the mic keeps delivering and playback never runs on a
        // stopped engine (playing a node on a stopped engine crashes).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    private var configObserver: NSObjectProtocol?

    private func engineConfigurationChanged() {
        guard let engine, !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            if pendingBuffers > 0, let player, !player.isPlaying { player.play() }
        } catch {
            stop()
        }
    }

    func startConversation(useEcho: Bool? = nil) throws {
        idleStop?.cancel()
        guard mode != .conversation else { return }
        stop()
        do {
            try configureConversation(wantEcho: useEcho ?? echoAllowed)
        } catch {
            // Never leave a half-built engine (or an open mic) behind.
            stop()
            throw error
        }
    }

    private func configureConversation(wantEcho: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: wantEcho ? .voiceChat : .default, options: [])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        echoCancelling = wantEcho && (try? input.setVoiceProcessingEnabled(true)) != nil
        // A mic that isn't available has no format; tapping it would raise an
        // Objective-C exception (an instant crash), so refuse early.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "WatchAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable"])
        }
        // Build the output graph first, then tap the input, then start.
        // The tap uses the input's own format (nil): starting the engine or
        // switching echo cancellation can change the hardware format, and a
        // tap installed with a stale format crashes.
        try attachPlayer(to: engine, start: false)
        mic.attach()
        Self.installMicTap(on: input, tap: mic)
        tapInstalled = true
        engine.prepare()
        try engine.start()
        mode = .conversation
        if echoCancelling { input.isVoiceProcessingInputMuted = isMuted }
    }

    /// Installed from a non-isolated context: the tap block runs on the
    /// audio thread, never on the main actor.
    private nonisolated static func installMicTap(on input: AVAudioInputNode, tap: MicTap) {
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in tap.receive(buffer) }
    }

    /// Restarts the mic without echo cancellation (and remembers that).
    func fallBackToPlainMic() throws {
        echoAllowed = false
        stop()
        try startConversation(useEcho: false)
    }

    /// Makes sure replies can play (conversation mode already can).
    func ensureOutput() async -> Bool {
        idleStop?.cancel()
        if mode != .off { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
            guard try await session.activate(options: []) else { return false }
            guard mode == .off else { return true }
            try attachPlayer(to: AVAudioEngine())
            mode = .playback
            return true
        } catch {
            return false
        }
    }

    func stop() {
        idleStop?.cancel()
        stopPlayback()
        let hadEngine = engine != nil
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        tapInstalled = false
        engine = nil
        player = nil
        echoCancelling = false
        mic.detach()
        if mode != .off || hadEngine {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        mode = .off
    }

    private func attachPlayer(to engine: AVAudioEngine, start: Bool = true) throws {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        // Keep a reference first so `stop()` can clean up if starting fails.
        self.engine = engine
        self.player = player
        if start {
            engine.prepare()
            try engine.start()
        }
    }
}
