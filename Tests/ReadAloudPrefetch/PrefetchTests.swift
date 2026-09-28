import XCTest
@testable import SpeechTestHost

extension PlayerTests {
    func testLookAheadIsBoundedToTwoRequests() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let chunks = (0..<12).map { "Synthetic paragraph \($0)." }
        let data = wav(1)
        var active = 0, peak = 0, requests = 0
        p.start(messageID: "bounded", title: "Synthetic bound", prepare: { chunks }, generate: { _ in
            active += 1; peak = max(peak, active); requests += 1
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(40))
            return (data, "audio/wav")
        })
        await waitUntil { p.duration != nil }
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(requests, chunks.count)
        XCTAssertEqual(p.duration ?? 0, 12, accuracy: 0.01)
    }

    func testShortThresholdAndSingleChunk() async {
        for length in [160, 161] {
            let p = ReadAloudPlayer(); defer { p.stop() }
            var active = 0, peak = 0
            let data = wav(1)
            p.start(messageID: "threshold", title: "Synthetic threshold", prepare: {
                ["First.", String(repeating: "界", count: length), "Last."]
            }, generate: { _ in
                active += 1; peak = max(peak, active); defer { active -= 1 }
                try await Task.sleep(for: .milliseconds(80))
                return (data, "audio/wav")
            })
            await waitUntil { p.duration != nil }
            XCTAssertEqual(peak, length == 160 ? 2 : 1)
        }
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(1); var requests = 0
        p.start(messageID: "single", title: "Synthetic single", prepare: { ["Only paragraph."] }, generate: { _ in
            requests += 1; return (data, "audio/wav")
        })
        await waitUntil { p.duration != nil }
        XCTAssertEqual(requests, 1)
    }

    func testLookAheadFailureRetriesWithoutReplayingPreparedChunks() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(5)
        var requests: [String: Int] = [:], fail = true
        p.start(messageID: "ahead-failure", title: "Synthetic failure", prepare: { ["First.", "Short.", "Last."] }, generate: { text in
            requests[text, default: 0] += 1
            if text == "Last.", fail { throw NSError(domain: "synthetic", code: 1) }
            return (data, "audio/wav")
        })
        await waitUntil { p.error != nil }
        XCTAssertEqual(p.bufferedDuration, 10, accuracy: 0.01)
        fail = false; p.retry(); p.retry()
        await waitUntil { p.duration != nil }
        XCTAssertEqual(requests, ["First.": 1, "Short.": 1, "Last.": 2])
        XCTAssertEqual(p.duration ?? 0, 15, accuracy: 0.01)
    }

    func testCurrentFailureCancelsLookAheadAndDoesNotSkipText() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(5)
        var aheadStarted = false, cancelled = false, fail = true
        p.start(messageID: "current-failure", title: "Synthetic cancellation", prepare: { ["First.", "Short.", "Last."] }, generate: { text in
            if text == "Last.", fail {
                aheadStarted = true
                do { try await Task.sleep(for: .seconds(5)) }
                catch { cancelled = true; throw error }
            }
            if text == "Short.", fail {
                while !aheadStarted { try await Task.sleep(for: .milliseconds(10)) }
                throw NSError(domain: "synthetic", code: 2)
            }
            return (data, "audio/wav")
        })
        await waitUntil { p.error != nil }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(p.bufferedDuration, 5, accuracy: 0.01)
        fail = false; p.retry()
        await waitUntil { p.duration != nil }
        XCTAssertEqual(p.duration ?? 0, 15, accuracy: 0.01)
    }

    func testPauseAndSeekWhileLookAheadFinishes() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(4)
        var started = 0
        p.start(messageID: "pause-ahead", title: "Synthetic pause", prepare: { ["First.", "Short.", "Last."] }, generate: { text in
            started += 1
            if text != "First." { try await Task.sleep(for: .milliseconds(700)) }
            return (data, "audio/wav")
        })
        await waitUntil { started == 3 && p.isPlaying }
        p.pause(); p.seek(to: 1)
        await waitUntil { p.duration != nil }
        await settle()
        XCTAssertFalse(p.isPlaying); XCTAssertFalse(p.wantsPlayback)
        XCTAssertEqual(p.elapsed, 1, accuracy: 0.1)
        p.seek(to: 9); await settle(); p.resume()
        await waitUntil { p.isPlaying && p.elapsed > 9 }
        XCTAssertEqual(started, 3)
    }

    func testStopAndReplaceRejectsBothLateResponses() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let stale = wav(7), fresh = wav(1)
        var started = 0
        p.start(messageID: "stale", title: "Synthetic old session", prepare: { ["First.", "Short.", "Last."] }, generate: { text in
            started += 1
            if text != "First." { try? await Task.sleep(for: .milliseconds(600)) }
            return (stale, "audio/wav")
        })
        await waitUntil { started == 3 }
        p.stop()
        p.start(messageID: "fresh", title: "Synthetic new session", prepare: { ["Fresh."] }, generate: { _ in
            (fresh, "audio/wav")
        })
        await waitUntil { p.duration != nil }
        await settle(0.8)
        XCTAssertEqual(p.messageID, "fresh")
        XCTAssertEqual(p.duration ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(p.transcript, "Fresh.")
    }

    func testShortParagraphStartsFollowingRequestBeforeItFinishes() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let data = wav(3)
        var started: [String] = [], completed: [String] = []
        p.start(messageID: "overlap", title: "Synthetic overlap", prepare: {
            ["Opening paragraph.", "Brief sentence.", "Following paragraph."]
        }, generate: { text in
            started.append(text)
            if text == "Brief sentence." { try await Task.sleep(for: .milliseconds(600)) }
            completed.append(text)
            return (data, "audio/wav")
        })
        await waitUntil({ started.count == 3 }, timeout: 0.5)
        XCTAssertFalse(completed.contains("Brief sentence."))
        await waitUntil { p.duration != nil }
        XCTAssertEqual(p.duration ?? 0, 9, accuracy: 0.01)
    }

    func testLongParagraphStaysSerialAndFirstAudioIsNotDelayed() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let long = String(repeating: "Long paragraph. ", count: 25)
        let data = wav(3)
        var active = 0, peak = 0, events: [String] = []
        p.start(messageID: "serial", title: "Synthetic serial", prepare: { ["First.", long, "Last."] }, generate: { text in
            active += 1; peak = max(peak, active); events.append("start:" + text)
            defer { active -= 1; events.append("end:" + text) }
            try await Task.sleep(for: .milliseconds(text == "First." ? 100 : 500))
            return (data, "audio/wav")
        })
        await waitUntil({ p.isPlaying }, timeout: 0.5)
        XCTAssertEqual(Array(events.prefix(2)), ["start:First.", "end:First."])
        await waitUntil { p.duration != nil }
        XCTAssertEqual(peak, 1)
    }

    func testOutOfOrderResponsesKeepPlaybackAndSeekOrder() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let chunks = ["Opening.", "Short.", "Following."]
        func directories() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("read-aloud-") } ?? [])
        }
        let before = directories()
        var active = 0, peak = 0, completed: [String] = []
        p.start(messageID: "order", title: "Synthetic order", prepare: { chunks }, generate: { text in
            active += 1; peak = max(peak, active); defer { active -= 1 }
            if text == "Short." { try await Task.sleep(for: .milliseconds(400)) }
            completed.append(text)
            return (self.wav(text == "Short." ? 2 : 4), "audio/wav")
        })
        await waitUntil { p.duration != nil }
        XCTAssertEqual(completed, ["Opening.", "Following.", "Short."])
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(p.duration ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(p.transcript, chunks.joined(separator: "\n\n"))
        let added = directories().subtracting(before)
        XCTAssertEqual(added.count, 1)
        if let name = added.first {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            XCTAssertEqual(try? Data(contentsOf: directory.appendingPathComponent("1.wav")), wav(2))
            XCTAssertEqual(try? Data(contentsOf: directory.appendingPathComponent("2.wav")), wav(4))
        }
        p.pause(); p.seek(to: 5); await settle()
        XCTAssertEqual(p.elapsed, 5, accuracy: 0.1)
        p.seek(to: 8); await settle()
        XCTAssertEqual(p.elapsed, 8, accuracy: 0.1)
    }

    func testSyntheticGapBenchmark() async {
        let p = ReadAloudPlayer(); defer { p.stop() }
        let chunks = ["The first synthetic paragraph.", "Brief sentence.", "The last synthetic paragraph."]
        var started: [Double] = [], ended: [Double] = []
        let beginning = Date()
        p.start(messageID: "benchmark", title: "Synthetic timing", prepare: { chunks }, generate: { text in
            started.append(Date().timeIntervalSince(beginning))
            try await Task.sleep(for: .seconds(1))
            ended.append(Date().timeIntervalSince(beginning))
            return (self.wav(text == "Brief sentence." ? 0.15 : 1.25), "audio/wav")
        })
        await waitUntil { p.isPlaying }
        let firstAudio = Date().timeIntervalSince(beginning)
        var stalled: Double = 0
        var last = Date()
        while !p.isFinished, Date().timeIntervalSince(beginning) < 8 {
            try? await Task.sleep(for: .milliseconds(10))
            let now = Date()
            if p.wantsPlayback && !p.isPlaying { stalled += now.timeIntervalSince(last) }
            last = now
        }
        XCTAssertTrue(p.isFinished)
        print("SYNTHETIC_TIMING first_audio=\(firstAudio) stalled=\(stalled) request_starts=\(started) request_ends=\(ended)")
        XCTAssertLessThan(stalled, 0.25, "Short-paragraph look-ahead should cover the following request")
    }
}
