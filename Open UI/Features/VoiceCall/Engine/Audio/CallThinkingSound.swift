import AVFoundation

/// An original, quiet two-note pulse. Rendered once per playback format and
/// looped on the call's own graph so voice processing can cancel its echo.
@MainActor
final class CallThinkingSound {
    let node = AVAudioPlayerNode()
    private(set) var isActive = false
    private var buffer: AVAudioPCMBuffer?

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            resumeIfNeeded()
        } else {
            node.stop()
            buffer = nil
        }
    }

    /// Also called after the call graph is rebuilt for a new audio route.
    func resumeIfNeeded() {
        guard isActive, !node.isPlaying, let engine = node.engine, engine.isRunning else { return }
        let format = node.outputFormat(forBus: 0)
        guard let loop = Self.makeLoop(format: format) else { return }
        buffer = loop
        node.scheduleBuffer(loop, at: nil, options: .loops, completionHandler: nil)
        node.play()
    }

    static func makeLoop(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        guard rate > 0, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2.4)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let time = Double(i) / rate
            let secondNote = time >= 0.9
            let t = time - (secondNote ? 0.9 : 0)
            let envelope = t < 0.8 ? pow(sin(.pi * t / 0.8), 2) : 0
            let sample = Float(0.035 * envelope * sin(2 * .pi * (secondNote ? 554.37 : 440) * t))
            for channel in 0..<Int(format.channelCount) { channels[channel][i] = sample }
        }
        return buffer
    }
}
