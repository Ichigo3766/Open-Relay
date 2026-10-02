import AVFoundation
import Foundation
import Observation
import WatchKit

/// Records one spoken utterance through `WatchAudio`'s mic, detects when
/// the user stops talking, and streams 16 kHz Int16 audio to the iPhone as
/// it goes. Audio that can't be sent (screen dimmed) is kept until the link
/// returns. Also watches for speech while a reply plays (interrupt).
@MainActor @Observable
final class VoiceCapture {

    enum State: Equatable { case idle, listening, finishing }

    private(set) var state: State = .idle
    /// 0…1 loudness for the orb animation.
    private(set) var level: Double = 0
    private(set) var heardSpeech = false
    /// True while the mic is being started / checked ("Starting mic…").
    private(set) var micStarting = false
    /// Diagnostics: current interrupt threshold and learned reply echo level.
    @ObservationIgnored var threshold: Float = 0
    @ObservationIgnored var learnedEcho: Float = 0
    @ObservationIgnored var lastRMS: Float = 0

    @ObservationIgnored let buffer = PCMBuffer()
    @ObservationIgnored var sender: Task<Void, Never>?
    @ObservationIgnored var turnId = 0
    @ObservationIgnored var sentMessages = 0
    @ObservationIgnored private let audio = WatchAudio.shared

    /// Silence after speech that ends the turn.
    static let endSilence: TimeInterval = 1.3
    /// Give up if nothing is said for this long.
    static let noSpeechTimeout: TimeInterval = 8
    static let maxDuration: TimeInterval = 60
    static let speechLevel: Float = 0.02

    enum CaptureError: LocalizedError {
        case micDenied, noSpeech, failed(String)
        var errorDescription: String? {
            switch self {
            case .micDenied: return "Allow microphone access for Open Relay in the Watch app on your iPhone."
            case .noSpeech: return "Didn't hear anything."
            case .failed(let m): return m
            }
        }
    }

    /// Starts the shared mic + speaker engine (with echo cancellation), then
    /// checks the mic actually delivers audio. If it doesn't within ~1 s,
    /// restarts without echo cancellation (and remembers that for next time).
    func prepare() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw CaptureError.micDenied }
        let alreadyRunning = audio.mode == .conversation && audio.mic.framesReceived > 0
        guard !alreadyRunning else { return }
        micStarting = true
        defer { micStarting = false }
        do {
            try audio.startConversation()
        } catch {
            if audio.echoAllowed { try? audio.fallBackToPlainMic() }
            guard audio.mode == .conversation else { throw CaptureError.failed("Couldn't start the microphone.") }
        }
        if await micDelivers() { return try releaseIfCancelled() }
        if audio.echoCancelling {
            try? audio.fallBackToPlainMic()
            if await micDelivers() { return try releaseIfCancelled() }
        }
        try releaseIfCancelled()
        throw CaptureError.failed("Microphone not responding. Close and reopen Talk.")
    }

    /// If the screen was closed while the mic was starting, don't leave it running.
    private func releaseIfCancelled() throws {
        guard Task.isCancelled else { return }
        audio.stop()
        throw CancellationError()
    }

    /// True once mic frames arrive (waits up to ~1.2 s).
    private func micDelivers() async -> Bool {
        for _ in 0..<12 {
            if audio.mic.framesReceived > 0 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return audio.mic.framesReceived > 0
    }

    /// Records until the user stops talking, then returns how many audio
    /// messages were delivered for `turnId`. Waits while muted.
    /// `interrupted`: the user just spoke over a reply — include the last
    /// second of mic audio so their first words aren't lost.
    func record(turnId: Int, interrupted: Bool = false,
                manualStop: @escaping @MainActor () -> Bool) async throws -> Int {
        try await prepare()
        self.turnId = turnId
        sentMessages = 0
        heardSpeech = interrupted
        buffer.reset()
        let preRoll = audio.mic.takePreRoll()
        if interrupted, !preRoll.isEmpty { buffer.append(preRoll, level: 0) }
        _ = audio.mic.takeLevel()
        audio.mic.record(into: buffer)
        state = .listening
        if !interrupted { WKInterfaceDevice.current().play(.start) }
        startSender()
        defer { audio.mic.record(into: nil) }

        var startedAt = Date()
        var lastVoiceAt = Date()
        let listenStart = Date()
        var checkedSilence = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let now = Date()
            if audio.isMuted {
                // Muted: don't time out; start the clock again on unmute.
                level = 0
                startedAt = now
                lastVoiceAt = now
                continue
            }
            // Some watchOS builds deliver flat digital silence with echo
            // cancellation on. Only then (never for a merely quiet room)
            // switch to plain recording for the rest of this launch.
            if !checkedSilence, now.timeIntervalSince(listenStart) > 1.5 {
                checkedSilence = true
                if audio.echoCancelling, audio.mic.isFlatSilence {
                    try? audio.fallBackToPlainMic()
                    audio.mic.record(into: buffer)
                    startedAt = now
                    lastVoiceAt = now
                }
            }
            let rms = audio.mic.takeLevel()
            level = min(1, Double(rms) * 12)
            if rms > Self.speechLevel {
                lastVoiceAt = now
                if now.timeIntervalSince(startedAt) > 0.2 { heardSpeech = true }
            }
            if manualStop() { break }
            if heardSpeech && now.timeIntervalSince(lastVoiceAt) > Self.endSilence { break }
            if !heardSpeech && now.timeIntervalSince(startedAt) > Self.noSpeechTimeout { break }
            if now.timeIntervalSince(startedAt) > Self.maxDuration { break }
        }
        audio.mic.record(into: nil)
        state = .finishing
        level = 0
        WKInterfaceDevice.current().play(.stop)
        guard !Task.isCancelled else { sender?.cancel(); state = .idle; throw CancellationError() }
        guard heardSpeech else { sender?.cancel(); state = .idle; throw CaptureError.noSpeech }
        buffer.finish()
        await sender?.value
        state = .idle
        guard buffer.isDrained else { throw LinkError.unreachable }
        return sentMessages
    }

    /// Returns when the user speaks over the reply.
    ///
    /// - With echo cancellation (or the reply playing on the iPhone) the mic
    ///   barely hears the reply, so normal speech level is enough.
    /// - Without it, the reply's own loudness in the mic is learned while it
    ///   plays (a slowly decaying average of the mic level), and speech must
    ///   be clearly above that (~3×) for ~0.4 s.
    /// Only the first 0.6 s of the whole reply is ignored, not every sentence.
    func waitForInterruption(replyOnPhone: Bool, while active: @escaping @MainActor () -> Bool) async -> Bool {
        _ = audio.mic.takeLevel()
        _ = audio.mic.takePreRoll()
        let startedAt = Date()
        var echoFloor: Float = 0
        var loudFrames = 0
        while !Task.isCancelled, active() {
            try? await Task.sleep(for: .milliseconds(100))
            let rms = audio.mic.takeLevel()
            lastRMS = rms
            level = min(1, Double(rms) * 12)
            let playing = audio.isPlaying && !replyOnPhone
            let sensitive = audio.echoCancelling || !playing
            let learning = Date().timeIntervalSince(startedAt) <= 0.6
            // Learn the reply's echo level. Loud frames that look like speech
            // (above the threshold) are never learned, or the user's own
            // voice would raise the bar until it can't trigger.
            if playing && !audio.echoCancelling && (learning || rms < threshold) {
                echoFloor = rms > echoFloor ? echoFloor * 0.6 + rms * 0.4 : echoFloor * 0.97 + rms * 0.03
            }
            threshold = sensitive ? Self.speechLevel * 1.5 : max(Self.speechLevel * 2, echoFloor * 3)
            learnedEcho = echoFloor
            guard !learning, !audio.isMuted else { loudFrames = 0; continue }
            loudFrames = rms > threshold ? loudFrames + 1 : max(0, loudFrames - 1)
            if loudFrames >= 4 { level = 0; return true }
        }
        level = 0
        return false
    }

    func cancel() {
        sender?.cancel()
        audio.mic.record(into: nil)
        state = .idle
        level = 0
    }
}
