import Foundation
import AVFoundation
import os.log

#if canImport(MLXAudioCore)
import MLXAudioCore
#endif

/// One mic tap buffer: the native buffer (Apple STT), the same audio
/// converted to mono at the requested rate (16 kHz VAD/STT or 24 kHz Realtime),
/// its RMS level, and when it
/// was captured on the call's wall clock (start of the buffer).
nonisolated struct MicFrame: @unchecked Sendable {
    let native: AVAudioPCMBuffer
    let vadSamples: [Float]
    let rms: Float
    let capturedAt: Date
}

/// State touched from the real-time tap thread. Guarded by a lock so the
/// main actor can swap the converter / continuation safely.
private nonisolated final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    #if canImport(MLXAudioCore)
    private var converter: PCMStreamConverter?
    #endif
    private var continuation: AsyncStream<MicFrame>.Continuation?
    private var sampleRate = CallAudioEngine.vadSampleRate

    func configure(continuation: AsyncStream<MicFrame>.Continuation?, sampleRate: Double = CallAudioEngine.vadSampleRate) {
        lock.lock()
        self.continuation = continuation
        self.sampleRate = sampleRate
        #if canImport(MLXAudioCore)
        converter = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1, interleaved: false
        ).map { PCMStreamConverter(outputFormat: $0) }
        #endif
        lock.unlock()
    }

    /// Recreate the converter (input format changed after a route change).
    func resetConverter() {
        lock.lock()
        let c = continuation
        let rate = sampleRate
        lock.unlock()
        configure(continuation: c, sampleRate: rate)
    }

    func clear() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        #if canImport(MLXAudioCore)
        converter = nil
        #endif
        lock.unlock()
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        #if canImport(MLXAudioCore)
        guard let converter, let bufs = try? converter.push(buffer) else { return [] }
        var out: [Float] = []
        for b in bufs {
            guard let ch = b.floatChannelData?[0] else { continue }
            out.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(b.frameLength)))
        }
        return out
        #else
        return []
        #endif
    }

    func yield(_ frame: MicFrame) {
        lock.lock()
        let c = continuation
        lock.unlock()
        c?.yield(frame)
    }
}


/// Single shared `AVAudioEngine` for a voice call: mic capture and TTS
/// playback in one full-duplex graph with Apple's voice processing
/// (echo cancellation, AGC, noise suppression).
///
/// **Graph setup order matters.** Voice processing subtracts what the output
/// node plays from the mic signal and builds that echo reference when it is
/// enabled. So the playback graph (player → main mixer → output) is attached
/// and connected *first*, voice processing is enabled *second* (engine
/// stopped), and the mic tap is installed *last* in the post-VP format.
/// Enabling VP before the playback path exists leaves it with an empty
/// reference, and the AI's own voice reaches the mic almost untouched.
///
/// Teardown mirrors it: tap removed, engine stopped, VP disabled. Route /
/// configuration changes rebuild the whole graph through the same code path.
///
/// Mic audio is delivered through `frames` — an ordered, bounded stream.
/// Sample-rate conversion runs on the tap thread, not the main thread.
@MainActor
final class CallAudioEngine {

    nonisolated static let vadSampleRate: Double = 16000

    private let logger = Logger(subsystem: "com.openui", category: "CallAudioEngine")
    private(set) var engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    private(set) var isRunning = false
    private var configChangeObserver: Task<Void, Never>?
    private nonisolated let tapState = TapState()

    /// Fired after the engine was rebuilt (route / config change) so the
    /// player can rebuild its output converter and timeline.
    var onRebuilt: (() -> Void)?

    /// Mutes the mic without stopping the engine.
    var isMicMuted = false {
        didSet { if isRunning { engine.inputNode.isVoiceProcessingInputMuted = isMicMuted } }
    }

    /// Format the player node renders in — and therefore what every TTS
    /// buffer must be converted to. Fixed per graph build (mono float at the
    /// output hardware rate) and used for the player → mixer connection, so
    /// the converter target and the node's format can never disagree.
    private(set) var playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    )!

    // MARK: - Lifecycle

    /// Starts the engine and returns the mic frame stream for this call.
    func start(sampleRate: Double = CallAudioEngine.vadSampleRate) throws -> AsyncStream<MicFrame> {
        if isRunning { stop() }
        // Bounded: if the consumer stalls, drop the oldest audio (~3 s kept).
        let (stream, continuation) = AsyncStream<MicFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(150)
        )
        tapState.configure(continuation: continuation, sampleRate: sampleRate)
        try buildGraphAndStart()
        isRunning = true
        observeConfigurationChanges()
        return stream
    }

    func stop() {
        configChangeObserver?.cancel()
        configChangeObserver = nil
        teardownGraph()
        tapState.clear()
        isRunning = false
        logger.info("CallAudioEngine stopped")
    }

    /// Full rebuild after a route / configuration change (AirPods, CarPlay,
    /// speaker toggle, media services reset): formats and the VP echo
    /// reference are stale, so the graph is rebuilt in the canonical order.
    func rebuild() {
        guard isRunning else { return }
        teardownGraph()
        do {
            try buildGraphAndStart()
            logger.info("CallAudioEngine rebuilt after configuration change")
            onRebuilt?()
        } catch {
            logger.error("CallAudioEngine rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}


// MARK: - Graph

private extension CallAudioEngine {

    /// The one place the duplex graph is built. See the type doc for why the
    /// order is playback → voice processing → capture.
    func buildGraphAndStart() throws {
        let input = engine.inputNode
        let output = engine.outputNode

        // 1. Playback path — this is what voice processing uses as its echo reference.
        if playerNode.engine == nil { engine.attach(playerNode) }
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: output, format: nil)

        // 2. Voice processing (the engine must be stopped).
        if !input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(true) }
        if !output.isVoiceProcessingEnabled { try output.setVoiceProcessingEnabled(true) }
        input.isVoiceProcessingBypassed = false
        input.isVoiceProcessingAGCEnabled = true
        if #available(iOS 17.0, *) {
            // Keep other apps' audio (music, navigation) as loud as possible.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .min
                )
        }

        // VP can change the hardware format, so the player's format is fixed
        // only now: mono float at the output rate. The player is reconnected
        // with exactly this format — the converter in CallAudioPlayer targets
        // the same object, so scheduled buffers always match the node.
        let hwRate = output.outputFormat(forBus: 0).sampleRate
        let rate = hwRate > 0 ? hwRate : 48_000
        if let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 1, interleaved: false) {
            playbackFormat = fmt
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        // 3. Capture — tap in the post-VP format (nil = the node's output format).
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, when in
            self?.handleMicBuffer(buf, when: when)
        }
        tapState.resetConverter()
        input.isVoiceProcessingInputMuted = isMicMuted

        engine.prepare()
        try engine.start()

        let micRate = input.outputFormat(forBus: 0).sampleRate
        let outRate = playbackFormat.sampleRate
        logger.info("CallAudioEngine started — VP in:\(input.isVoiceProcessingEnabled) out:\(output.isVoiceProcessingEnabled), mic \(micRate, format: .fixed(precision: 0)) Hz, out \(outRate, format: .fixed(precision: 0)) Hz")
    }

    /// Reverse of `buildGraphAndStart`. VP is disabled only after the engine
    /// has stopped — toggling it on a running engine is unsupported.
    func teardownGraph() {
        guard playerNode.engine != nil else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        if input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(false) }
        engine.disconnectNodeOutput(playerNode)
    }

    func observeConfigurationChanges() {
        configChangeObserver?.cancel()
        configChangeObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .AVAudioEngineConfigurationChange
            ) {
                guard let self, self.isRunning else { continue }
                try? await Task.sleep(for: .milliseconds(150))
                self.rebuild()
            }
        }
    }

    // MARK: Tap

    /// Runs on the audio tap thread: RMS + 16 kHz conversion happen here,
    /// never on the main thread. Frames are delivered in order via the stream.
    nonisolated func handleMicBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let rms = Self.rmsAmplitude(of: buffer)
        let samples = tapState.convert(buffer)
        let captured = Self.wallClock(for: when, frames: buffer.frameLength, rate: buffer.format.sampleRate)
        tapState.yield(MicFrame(native: buffer, vadSamples: samples, rms: rms, capturedAt: captured))
    }

    /// Converts the tap's host time to the wall clock the playback timeline
    /// uses, so mic frames and played audio can be compared directly. Falls
    /// back to "now minus the buffer duration" if host time is missing.
    nonisolated static func wallClock(for when: AVAudioTime, frames: AVAudioFrameCount, rate: Double) -> Date {
        let now = Date()
        guard when.isHostTimeValid else {
            return rate > 0 ? now.addingTimeInterval(-Double(frames) / rate) : now
        }
        let delta = AVAudioTime.seconds(forHostTime: when.hostTime) - AVAudioTime.seconds(forHostTime: mach_absolute_time())
        return now.addingTimeInterval(delta - AVAudioSession.sharedInstance().inputLatency)
    }

    nonisolated static func rmsAmplitude(of buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return (sum / Float(n)).squareRoot()
    }
}

