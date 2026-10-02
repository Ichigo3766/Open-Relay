import AVFoundation
import Foundation

// MARK: - Playback

extension WatchAudio {

    /// Queues audio (any format) after what's already playing.
    func schedule(_ buffer: AVAudioPCMBuffer) {
        guard let player, let engine, engine.isRunning, let pcm = converted(buffer) else { return }
        if pendingBuffers == 0 { playbackStartedAt = Date() }
        pendingBuffers += 1
        let gen = generation
        player.scheduleBuffer(pcm, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Rebind weakly inside the main-actor task so no captured var crosses isolation.
            Task { @MainActor [weak self] in self?.bufferPlayed(generation: gen) }
        }
        if !player.isPlaying { player.play() }
    }

    func stopPlayback() {
        generation &+= 1
        pendingBuffers = 0
        playbackStartedAt = nil
        player?.stop()
    }

    private func bufferPlayed(generation gen: Int) {
        guard gen == generation else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        guard pendingBuffers == 0 else { return }
        playbackStartedAt = nil
        // Release the audio session shortly after a typed reply finishes.
        guard mode == .playback else { return }
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.mode == .playback, self.pendingBuffers == 0 else { return }
            self.stop()
        }
    }

    private func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == playFormat { return buffer }
        let key = "\(buffer.format.sampleRate)-\(buffer.format.channelCount)-\(buffer.format.commonFormat.rawValue)"
        guard let converter = converters[key] ?? AVAudioConverter(from: buffer.format, to: playFormat) else { return nil }
        converters[key] = converter
        converter.reset()
        let ratio = playFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

/// Mic tap shared by the engine and the current recorder. Converts to
/// 16 kHz Int16 and tracks loudness. All methods are thread-safe.
nonisolated final class MicTap: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: WatchProtocol.audioSampleRate,
                                          channels: 1, interleaved: true)!
    private var sink: PCMBuffer?
    private var peak: Float = 0
    private var muted = false
    private var frames = 0
    private var maxLevel: Float = 0
    private var minLevel: Float = .greatestFiniteMagnitude
    /// Last ~1 s of converted mic audio, kept while not recording so the
    /// words that interrupt a reply aren't lost.
    private var preRoll = Data()
    private static let preRollBytes = Int(WatchProtocol.audioSampleRate) * 2

    /// Resets the counters for a new engine. The converter is built from the
    /// first buffer that arrives (and rebuilt if the input format changes),
    /// so a format change after the engine starts can't break conversion.
    func attach() {
        lock.lock()
        converter = nil
        frames = 0; maxLevel = 0; minLevel = .greatestFiniteMagnitude; preRoll = Data()
        lock.unlock()
    }

    func detach() {
        lock.lock()
        converter = nil; sink = nil; peak = 0; frames = 0; maxLevel = 0
        minLevel = .greatestFiniteMagnitude; preRoll = Data()
        lock.unlock()
    }

    /// Mic frames received since `attach` (counts even while muted) — used
    /// to detect a mic that isn't delivering audio.
    var framesReceived: Int { lock.lock(); defer { lock.unlock() }; return frames }
    /// Loudest level since `attach`.
    var loudestSinceStart: Float { lock.lock(); defer { lock.unlock() }; return maxLevel }
    /// True when the mic has delivered audio but every buffer was exactly
    /// the same level (flat digital silence) — a real mic never does that.
    var isFlatSilence: Bool {
        lock.lock(); defer { lock.unlock() }
        return frames > 16_000 && maxLevel < 0.000_01 && maxLevel - (minLevel == .greatestFiniteMagnitude ? 0 : minLevel) < 0.000_001
    }

    /// Hands over (and clears) the kept pre-roll audio.
    func takePreRoll() -> Data {
        lock.lock(); defer { lock.unlock() }
        let data = preRoll
        preRoll = Data()
        return data
    }

    /// Starts / stops delivering audio into `buffer` (nil = level only).
    func record(into buffer: PCMBuffer?) {
        lock.lock(); sink = buffer; lock.unlock()
    }

    func setMuted(_ value: Bool) {
        lock.lock(); muted = value; peak = 0; lock.unlock()
    }

    /// Peak loudness since the last call (0 while muted).
    func takeLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }

    func receive(_ pcm: AVAudioPCMBuffer) {
        lock.lock()
        frames += Int(pcm.frameLength)
        if converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: outFormat)
        }
        let converter = converter, sink = sink, muted = muted
        lock.unlock()
        guard !muted else { return }
        let level = AudioConversion.rms(pcm)
        lock.lock()
        peak = max(peak, level)
        maxLevel = max(maxLevel, level)
        minLevel = min(minLevel, level)
        lock.unlock()
        guard let converter else { return }
        let converted = AudioConversion.convert(pcm, with: converter, to: outFormat)
        if let sink {
            sink.append(converted, level: level)
        } else {
            lock.lock()
            preRoll.append(converted)
            if preRoll.count > Self.preRollBytes { preRoll.removeFirst(preRoll.count - Self.preRollBytes) }
            lock.unlock()
        }
    }
}
