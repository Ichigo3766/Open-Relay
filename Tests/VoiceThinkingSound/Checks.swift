import Foundation
import AVFoundation

@main
@MainActor
struct Checks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        count += 1
        print("PASS: \(name)")
    }

    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let state = StateFixture()
        let defaults = state.settings.defaults
        defaults.removePersistentDomain(forName: "org.example.voice-thinking-checks")
        defer { defaults.removePersistentDomain(forName: "org.example.voice-thinking-checks") }
        check(!state.settings.thinkingSoundEnabled, "new installs default off")
        state.orchestrator = Session()
        state.transition(.processing)
        check(!state.orchestrator!.audioEngine.thinkingSound.isActive, "default-off processing stays silent")
        state.settings.thinkingSoundEnabled = true
        check(Settings().thinkingSoundEnabled, "opt-in persists across settings instances")
        state.updateThinkingSound()
        check(state.orchestrator!.audioEngine.thinkingSound.isActive, "enable mid-turn")
        state.pause(true)
        check(!state.orchestrator!.audioEngine.thinkingSound.isActive, "pause stops synchronously")
        state.pause(false)
        check(state.orchestrator!.audioEngine.thinkingSound.isActive, "resume gate")
        state.wasPausedByInterruption = true
        check(!state.orchestrator!.audioEngine.thinkingSound.isActive, "system interruption stops synchronously")
        state.wasPausedByInterruption = false
        for realtime in [false, true] {
            state.orchestrator = realtime ? nil : Session()
            state.realtimeCall = realtime ? Session() : nil
            let sound = (state.orchestrator ?? state.realtimeCall)!.audioEngine.thinkingSound
            for next in [StateFixture.CallState.idle, .connecting, .listening, .speaking, .paused, .error("Synthetic failure"), .disconnected] {
                state.transition(.processing)
                check(sound.isActive, "\(realtime ? "realtime" : "standard") processing starts")
                state.transition(next)
                check(!sound.isActive, "\(realtime ? "realtime" : "standard") \(next) stops")
            }
        }
        state.transition(.processing)
        state.settings.thinkingSoundEnabled = false
        state.updateThinkingSound()
        check(!state.realtimeCall!.audioEngine.thinkingSound.isActive, "disable mid-turn")

        for rate in [16000.0, 24000, 44100, 48000, 96000] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let loop = CallThinkingSound.makeLoop(format: format)!
            let samples = Array(UnsafeBufferPointer(start: loop.floatChannelData![0], count: Int(loop.frameLength)))
            check(abs(Double(samples.count) / rate - 2.4) < 1 / rate, "\(rate) Hz duration")
            check(samples.allSatisfy { $0.isFinite && abs($0) <= 0.03501 }, "\(rate) Hz quiet finite samples")
            check(samples.first == 0 && samples.last == 0, "\(rate) Hz silent loop seam")
            check(samples.map(abs).max()! > 0.03, "\(rate) Hz audible pulse")
            check(zip(samples, samples.dropFirst()).allSatisfy { abs($0 - $1) < 0.008 }, "\(rate) Hz no discontinuities")
            if rate == 48000 {
                let file = try AVAudioFile(forWriting: output.appendingPathComponent("thinking-loop.wav"), settings: format.settings)
                try file.write(from: loop)
            }
        }
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let stereoLoop = CallThinkingSound.makeLoop(format: stereo)!
        check((0..<Int(stereoLoop.frameLength)).allSatisfy { stereoLoop.floatChannelData![0][$0] == stereoLoop.floatChannelData![1][$0] }, "identical stereo channels")
        let int16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false)!
        check(CallThinkingSound.makeLoop(format: int16) == nil, "unsupported format rejected")
        try renderChecks(output: output)
        try await realtimeChecks()
        print("\(count) checks passed")
    }

    static func realtimeChecks() async throws {
        let realtime = RealtimeStateFixture()
        realtime.player.onStarted?()
        check(realtime.states.last == .speaking, "realtime audio starts speaking")
        realtime.player.onFinished?()
        check(realtime.states.last == .listening, "realtime finished audio returns to listening")
        realtime.replyTask = Task { try? await Task.sleep(for: .seconds(1)) }
        realtime.player.onFinished?()
        check(realtime.states.last == .processing, "realtime delegated work keeps thinking after audio drains")
        realtime.replyTask?.cancel(); realtime.replyTask = nil
        realtime.paused = true
        realtime.player.onFinished?()
        check(realtime.states.last == .paused, "paused realtime completion stays paused")
        realtime.created(["response": ["id": "synthetic-response"]])
        check(realtime.states.last == .paused, "paused realtime response does not start thinking")
        realtime.paused = false
        realtime.created(["response": ["id": "synthetic-response"]])
        check(realtime.states.last == .processing, "realtime response creation starts thinking")
        realtime.pendingResults["tool"] = "synthetic-response"
        realtime.events.removeAll()
        try await realtime.respondToResult("tool", response: "synthetic-response")
        check(realtime.states.last == .processing && realtime.events == ["state", "send"], "tool continuation starts thinking before network wait")
        realtime.player.isSpeaking = true
        realtime.events.removeAll()
        try await realtime.respondToResult("tool", response: "synthetic-response")
        check(realtime.events == ["send"], "tool continuation cannot replace active speaking state")
        realtime.events.removeAll()
        let interrupt = Task { await realtime.interrupt() }
        try await Task.sleep(for: .milliseconds(10))
        check(realtime.states.last == .listening && realtime.events == ["state", "send"], "interrupt stops thinking before cancellation round trip")
        await interrupt.value
        realtime.paused = true
        await realtime.interrupt()
        check(realtime.states.last == .paused, "realtime pause interrupts into paused state")
        let countBefore = realtime.states.count
        try await realtime.respondToResult("tool", response: "synthetic-response")
        check(realtime.states.count == countBefore, "paused tool continuation remains silent")
    }

    static func renderChecks(output: URL) throws {
        let engine = AVAudioEngine()
        let sound = CallThinkingSound()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        engine.attach(sound.node)
        engine.connect(sound.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { sound.setActive(false); engine.stop() }
        sound.setActive(true)
        check(sound.node.isPlaying, "native node starts")
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var rendered: [Float] = []
        var rendersSucceeded = true
        for _ in 0..<65 {
            let status = try engine.renderOffline(4096, to: pcm)
            rendersSucceeded = rendersSucceeded && status == .success
            rendered += UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))
            sound.setActive(true) // Repeated settings notifications must not restart the loop.
        }
        check(rendersSucceeded, "native offline rendering across two loop boundaries")
        let period = Int(48000 * 2.4)
        check(zip(rendered[4096..<period], rendered[(4096+period)..<(period*2)]).allSatisfy { abs($0 - $1) < 0.0001 }, "native loop repeats without restarting")
        sound.setActive(false)
        check(!sound.node.isPlaying && !sound.isActive, "native stop clears active playback")
        _ = try engine.renderOffline(4096, to: pcm)
        check((0..<Int(pcm.frameLength)).allSatisfy { pcm.floatChannelData![0][$0] == 0 }, "no audio after stop")
        sound.setActive(true)
        sound.node.stop()
        engine.stop()
        engine.disconnectNodeOutput(sound.node)
        engine.connect(sound.node, to: engine.mainMixerNode, format: format)
        try engine.start()
        sound.resumeIfNeeded()
        check(sound.node.isPlaying, "route-style graph rebuild resumes active loop")
        sound.setActive(false)
        sound.node.stop()
        sound.resumeIfNeeded()
        check(!sound.node.isPlaying, "rebuild cannot resume disabled loop")
    }
}
