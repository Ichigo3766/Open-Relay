import XCTest
import AVFoundation
import MediaPlayer
@testable import SpeechTestHost

@MainActor final class PlayerTests: XCTestCase {
    func waitUntil(_ condition: @escaping () -> Bool, timeout: Double = 5, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func settle(_ seconds: Double = 0.3) async { try? await Task.sleep(for: .seconds(seconds)) }
    func wav(_ seconds: Double = 2) -> Data {
        let frames = UInt32(seconds * 16000)
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); word(UInt32(36) + frames * 2)
        data.append(Data("WAVEfmt ".utf8)); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(16000)); word(UInt32(32000)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(frames * 2)
        data.append(Data(repeating: 0, count: Int(frames * 2)))
        return data
    }
    func start(_ p: ReadAloudPlayer, chunks: [String] = ["A blue kite floats.", "A green lantern glows."], seconds: Double = 2) {
        let data = wav(seconds)
        p.start(messageID: "synthetic", title: "Invented audio", prepare: { chunks }, generate: { _ in (data, "audio/wav") })
    }
    func testSplittingAndServerInheritance() {
        let text = "A blue lantern glows softly. A paper kite rests nearby.\n\nThe green door opens slowly."
        XCTAssertEqual(SpeechSplitting.followServer.resolved(serverValue: "none"), .wholeMessage)
        XCTAssertEqual(SpeechSplitting.followServer.resolved(serverValue: "paragraphs"), .paragraphs)
        XCTAssertEqual(SpeechSplitting.followServer.resolved(serverValue: "unknown"), .sentences)
        XCTAssertEqual(SpeechSplitting.wholeMessage.resolved(serverValue: "punctuation"), .wholeMessage)
        XCTAssertEqual(SpeechSplitting.wholeMessage.chunks(from: text).count, 1)
        XCTAssertEqual(SpeechSplitting.paragraphs.chunks(from: text).count, 2)
        XCTAssertEqual(SpeechSplitting.sentences.chunks(from: text).count, 3)
        XCTAssertEqual(SpeechSplitting.paragraphs.chunks(from: "\n\n "), [])
        XCTAssertEqual(SpeechSplitting.wholeMessage.chunks(from: ""), [])
    }
    func testNativePlaybackTimingAndCompletion() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        start(p, chunks: ["A paper kite rests nearby.", "The blue lantern glows."], seconds: 0.9)
        await waitUntil { p.isPlaying && p.elapsed > 0 }
        XCTAssertEqual(p.duration ?? 0, 1.8, accuracy: 0.03)
        await waitUntil { p.elapsed > 0.95 && p.isPlaying && !p.isFinished }
        await waitUntil { p.isFinished && !p.wantsPlayback }
        XCTAssertTrue(p.isVisible, "Retain finished audio for rewind/replay")
    }
    func testPauseWhileGeneratingDoesNotAutoResume() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(8)
        var requests = 0
        p.start(messageID: "pause", title: "Pause", prepare: { ["First.", "Second."] }, generate: { _ in
            requests += 1
            if requests == 2 { try await Task.sleep(for: .milliseconds(900)) }
            return (data, "audio/wav")
        })
        await waitUntil { p.isPlaying }
        p.pause(); let position = p.elapsed
        await waitUntil { p.duration != nil }
        await settle()
        XCTAssertFalse(p.wantsPlayback); XCTAssertFalse(p.isPlaying)
        XCTAssertEqual(p.elapsed, position, accuracy: 0.12)
        p.resume(); await waitUntil { p.isPlaying && p.elapsed > position + 0.1 }
    }
    func testSeekAcrossChunksInBothDirections() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        start(p, seconds: 20)
        await waitUntil { p.duration != nil }
        p.pause(); p.seek(to: 23)
        await settle()
        XCTAssertEqual(p.elapsed, 23, accuracy: 0.1)
        p.skip(-15); await settle()
        XCTAssertEqual(p.elapsed, 8, accuracy: 0.1)
        p.skip(15); await settle()
        XCTAssertEqual(p.elapsed, 23, accuracy: 0.1)
        XCTAssertFalse(p.wantsPlayback)
        p.resume(); await waitUntil { p.isPlaying && p.elapsed > 23.1 }
    }
    func testSeekClampsToAvailableAudioAndReplaysWithoutSynthesis() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(2); var requests = 0
        p.start(messageID: "bounds", title: "Bounds", prepare: { ["Blue kite."] }, generate: { _ in
            requests += 1; return (data, "audio/wav")
        })
        await waitUntil { p.duration != nil }
        p.pause(); p.seek(to: -20); await settle()
        XCTAssertEqual(p.elapsed, 0, accuracy: 0.05)
        p.skip(15); await settle()
        XCTAssertEqual(p.elapsed, 2, accuracy: 0.05)
        p.resume(); await waitUntil { p.isPlaying && p.elapsed < 1 }
        XCTAssertEqual(requests, 1)
    }
    func testDurationRemainsUnknownWhilePreparingLaterChunks() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(3)
        p.start(messageID: "duration", title: "Duration", prepare: { ["First", "Second"] }, generate: { text in
            if text == "Second" { try await Task.sleep(for: .milliseconds(700)) }
            return (data, "audio/wav")
        })
        await waitUntil { p.bufferedDuration > 0 }
        XCTAssertNil(p.duration)
        await waitUntil { p.duration != nil }
        XCTAssertEqual(p.duration ?? 0, 6, accuracy: 0.01)
    }
    func testFailureRetriesOnlyTheFailedChunk() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(3); var requests: [String] = []; var fail = true
        p.start(messageID: "retry", title: "Retry", prepare: { ["First", "Second"] }, generate: { text in
            requests.append(text)
            if text == "Second", fail { throw NSError(domain: "fixture", code: 1) }
            return (data, "audio/wav")
        })
        await waitUntil { p.error != nil }
        XCTAssertFalse(p.wantsPlayback)
        fail = false; p.retry()
        await waitUntil { p.duration != nil }
        XCTAssertEqual(requests, ["First", "Second", "Second"])
        XCTAssertNil(p.error)
        XCTAssertEqual(p.duration ?? 0, 6, accuracy: 0.01)
    }
    func testAllRequestsFailAndCanRetry() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(); var fail = true
        p.start(messageID: "failure", title: "Failure", prepare: { ["First"] }, generate: { _ in
            if fail { throw NSError(domain: "fixture", code: 1) }
            return (data, "audio/wav")
        })
        await waitUntil { p.error != nil }
        XCTAssertFalse(p.isGenerating); XCTAssertFalse(p.canSeek)
        fail = false; p.retry()
        await waitUntil { p.isPlaying }
    }
    func testCloseDiscardsLateResponses() async {
        let p = ReadAloudPlayer(); let data = wav()
        p.start(messageID: "cancel", title: "Cancel", prepare: { ["First"] }, generate: { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return (data, "audio/wav")
        })
        await settle(0.1); p.stop(); await settle(0.5)
        XCTAssertFalse(p.isVisible); XCTAssertFalse(p.isPlaying)
        XCTAssertEqual(p.bufferedDuration, 0)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }
    func testReplacingSessionRejectsStaleAudio() async {
        let p = ReadAloudPlayer(); defer { p.stop() }; let data = wav(10)
        p.start(messageID: "old", title: "Old", prepare: { ["Old text"] }, generate: { _ in
            try? await Task.sleep(for: .milliseconds(500)); return (data, "audio/wav")
        })
        await settle(0.1)
        start(p, chunks: ["New text"], seconds: 2)
        await waitUntil { p.duration != nil }
        await settle(0.6)
        XCTAssertEqual(p.transcript, "New text")
        XCTAssertEqual(p.duration ?? 0, 2, accuracy: 0.01)
    }
    func testRateCycleAndNowPlaying() async {
        UserDefaults.standard.removeObject(forKey: "readAloudPlaybackRate")
        let p = ReadAloudPlayer(); defer { p.stop(); UserDefaults.standard.removeObject(forKey: "readAloudPlaybackRate") }
        start(p, seconds: 8)
        await waitUntil { p.isPlaying }
        for expected: Float in [1.25, 1.5, 1.75, 2, 1] { p.cycleRate(); XCTAssertEqual(p.rate, expected) }
        await settle()
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo!
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Invented audio")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0, 16, accuracy: 0.01)
        XCTAssertEqual(MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals, [15])
        p.pause(); await settle()
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber, NSNumber(value: 0))
    }
    func testInterruptionAndHeadphoneRemovalPause() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        start(p, seconds: 8); await waitUntil { p.isPlaying }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await waitUntil { !p.wantsPlayback }
        p.resume(); await waitUntil { p.isPlaying }
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        await waitUntil { !p.wantsPlayback }
    }
    func testCorruptAudioCanRetry() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let valid = wav(3); var corrupt = true
        p.start(messageID: "corrupt", title: "Corrupt", prepare: { ["Blue kite"] }, generate: { _ in
            (corrupt ? Data("invalid audio".utf8) : valid, "audio/wav")
        })
        await waitUntil { p.error != nil }
        XCTAssertFalse(p.isPlaying)
        corrupt = false; p.retry()
        await waitUntil { p.isPlaying }
    }
    func testQueueUnderrunResumesWhenNextChunkArrives() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let short = wav(0.4), long = wav(3)
        p.start(messageID: "underrun", title: "Underrun", prepare: { ["First", "Second"] }, generate: { text in
            if text == "Second" { try await Task.sleep(for: .seconds(1.4)); return (long, "audio/wav") }
            return (short, "audio/wav")
        })
        await waitUntil { p.elapsed >= 0.39 && p.isGenerating && !p.isPlaying }
        XCTAssertTrue(p.wantsPlayback)
        await waitUntil { p.isPlaying && p.elapsed > 0.5 && p.duration != nil }
        XCTAssertEqual(p.duration ?? 0, 3.4, accuracy: 0.01)
    }
    func testCloseRemovesSessionAudioFiles() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        func directories() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("read-aloud-") } ?? [])
        }
        let before = directories()
        start(p); await waitUntil { p.duration != nil }
        XCTAssertEqual(directories().subtracting(before).count, 1)
        p.stop()
        XCTAssertEqual(directories(), before)
    }

}
