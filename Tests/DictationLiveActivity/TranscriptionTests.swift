import Foundation
import XCTest

@MainActor final class TranscriptionTests: XCTestCase {
    let context = DictationContext(server: "https://example.invalid", account: "synthetic", conversation: "paper-craft")
    var delivered: [String] = []

    override func setUp() async throws {
        UIApplication.shared.applicationState = .active
        UIApplication.shared.grantsTime = true
        UIApplication.shared.started = 0
        UIApplication.shared.ended = []
        UIApplication.shared.tasks = [:]
        AVAudioApplication.allowed = true
        AVAudioSession.fails = false
        AVAudioRecorder.starts = true; AVAudioRecorder.prepares = true
        UserDefaults.standard.set("server", forKey: "sttEngine")
        UserDefaults.standard.set(0, forKey: DictationService.autoStopKey)
        delivered = []
    }

    func fixture() async throws -> DictationService {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let service = DictationService(recoveryStore: DictationRecoveryStore(directory: directory))
        service.serverSpeechService = ServerSpeechRecognitionService()
        service.onDeviceASRService = OnDeviceASRService()
        service.bind(to: context, isCurrent: { true }, draft: { "Synthetic draft" }, deliver: { [weak self] in self?.delivered.append($0) })
        await service.startDictation()
        return service
    }

    func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }

    func testServerCanFinishWhileBackgroundedAndReleasesAssertion() async throws {
        let service = try await fixture()
        service.serverSpeechService?.apiClient?.response = {
            try await Task.sleep(for: .milliseconds(100))
            return ["text": "Paper flowers"]
        }
        service.stopDictation()
        XCTAssertEqual(UIApplication.shared.tasks.count, 1)
        UIApplication.shared.transition(to: .background)
        await service.attemptTask?.value
        XCTAssertEqual(delivered, ["Synthetic draft Paper flowers"])
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(UIApplication.shared.started, 1)
        XCTAssertEqual(UIApplication.shared.ended.count, 1)
        XCTAssertTrue(UIApplication.shared.tasks.isEmpty)
    }

    func testExpiredServerAttemptResumesOnceOnReturn() async throws {
        let service = try await fixture()
        let client = try XCTUnwrap(service.serverSpeechService?.apiClient)
        client.response = { try await Task.sleep(for: .seconds(60)); return ["text": "Paper flowers"] }
        service.stopDictation()
        UIApplication.shared.transition(to: .background)
        try await settle()
        let expiry = try XCTUnwrap(UIApplication.shared.tasks.values.first)
        expiry()
        await service.attemptTask?.value
        XCTAssertEqual(service.state, .processing)
        XCTAssertNotNil(service.savedAudioURL)
        XCTAssertTrue(UIApplication.shared.tasks.isEmpty)
        client.response = { ["text": "Paper flowers"] }
        UIApplication.shared.transition(to: .active)
        try await settle()
        UIApplication.shared.transition(to: .active)
        try await settle()
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(UIApplication.shared.started, UIApplication.shared.ended.count)
    }

    func testConnectionLossAfterReturningRetriesWithoutManualButton() async throws {
        let service = try await fixture()
        let client = try XCTUnwrap(service.serverSpeechService?.apiClient)
        client.response = {
            if client.calls == 1 {
                try await Task.sleep(for: .milliseconds(200))
                throw URLError(.networkConnectionLost)
            }
            return ["text": "Paper flowers"]
        }
        service.stopDictation()
        UIApplication.shared.transition(to: .background)
        try await settle()
        UIApplication.shared.transition(to: .active)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(service.state, .idle)
    }

    func testForegroundErrorsAndServerRejectionsDoNotAutoRetry() async throws {
        for background in [false, true] {
            let service = try await fixture()
            let client = try XCTUnwrap(service.serverSpeechService?.apiClient)
            client.response = {
                try await Task.sleep(for: .milliseconds(100))
                if background { throw CocoaError(.fileReadNoPermission) }
                throw URLError(.networkConnectionLost)
            }
            service.stopDictation()
            if background { UIApplication.shared.transition(to: .background) }
            await service.attemptTask?.value
            UIApplication.shared.transition(to: .active)
            try await settle()
            XCTAssertEqual(client.calls, 1)
            XCTAssertNotEqual(service.state, .processing)
            XCTAssertNotNil(service.savedAudioURL)
            service.discardRecording()
        }
    }

    func testDeviceInterruptionResumesOnReturnIncludingServerFallback() async throws {
        for fallback in [false, true] {
            UserDefaults.standard.set(fallback ? "server" : "device", forKey: "sttEngine")
            let service = try await fixture()
            var calls = 0
            service.onDeviceASRService?.response = {
                calls += 1
                if calls == 1 {
                    try await Task.sleep(for: .milliseconds(100))
                    throw ASRError.backgroundInterrupted
                }
                return "Paper flowers"
            }
            service.stopDictation()
            if fallback { await service.attemptTask?.value; service.retry(onDevice: true) }
            UIApplication.shared.transition(to: .background)
            await service.attemptTask?.value
            XCTAssertEqual(service.state, .processing)
            XCTAssertEqual(calls, 1)
            UIApplication.shared.transition(to: .active)
            try await settle()
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(delivered.count, fallback ? 2 : 1)
            XCTAssertEqual(service.serverSpeechService?.apiClient?.calls, fallback ? 1 : 0)
            service.discardRecording()
        }
    }

    func testDeviceAutoStopInBackgroundWaitsForForeground() async throws {
        UserDefaults.standard.set("device", forKey: "sttEngine")
        let service = try await fixture()
        var calls = 0
        service.onDeviceASRService?.response = { calls += 1; return "Paper flowers" }
        UIApplication.shared.transition(to: .background)
        service.stopDictation()
        try await settle()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(service.state, .processing)
        UIApplication.shared.transition(to: .active)
        try await settle()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(delivered.count, 1)
    }

    func testCancelDiscardAndNavigationPreventAutomaticResume() async throws {
        for action in 0..<3 {
            let service = try await fixture()
            let client = try XCTUnwrap(service.serverSpeechService?.apiClient)
            client.response = { try await Task.sleep(for: .seconds(60)); return ["text": "Paper flowers"] }
            service.stopDictation()
            UIApplication.shared.transition(to: .background)
            try await settle()
            try XCTUnwrap(UIApplication.shared.tasks.values.first)()
            await service.attemptTask?.value
            if action == 0 { service.cancelAttempt() }
            else if action == 1 { service.discardRecording() }
            else { service.unbind() }
            UIApplication.shared.transition(to: .active)
            try await settle()
            XCTAssertEqual(client.calls, 1)
            XCTAssertTrue(delivered.isEmpty)
            XCTAssertTrue(UIApplication.shared.tasks.isEmpty)
        }
    }

    func testDeniedBackgroundTimeStillAllowsForegroundTranscription() async throws {
        UIApplication.shared.grantsTime = false
        let service = try await fixture()
        service.serverSpeechService?.apiClient?.response = { ["text": "Paper flowers"] }
        service.stopDictation()
        await service.attemptTask?.value
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(UIApplication.shared.ended.isEmpty)
    }

    func testQueuedExpiryCannotCancelReplacementAttempt() async throws {
        let service = try await fixture()
        let client = try XCTUnwrap(service.serverSpeechService?.apiClient)
        client.response = { try await Task.sleep(for: .seconds(60)); return ["text": "Paper flowers"] }
        service.stopDictation()
        try await settle()
        let oldExpiry = try XCTUnwrap(UIApplication.shared.tasks.values.first)
        service.cancelAttempt()
        XCTAssertTrue(UIApplication.shared.tasks.isEmpty)
        await service.attemptTask?.value
        client.response = {
            try await Task.sleep(for: .milliseconds(100))
            return ["text": "Paper flowers"]
        }
        service.retry()
        oldExpiry()
        await service.attemptTask?.value
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(UIApplication.shared.started, UIApplication.shared.ended.count)
    }

    func testChangedContextCannotReceiveOrRetryInterruptedAudio() async throws {
        let service = try await fixture()
        let client = try XCTUnwrap(service.serverSpeechService?.apiClient)
        client.response = { try await Task.sleep(for: .seconds(60)); return ["text": "Paper flowers"] }
        service.stopDictation()
        UIApplication.shared.transition(to: .background)
        try await settle()
        try XCTUnwrap(UIApplication.shared.tasks.values.first)()
        await service.attemptTask?.value
        let savedAudio = try XCTUnwrap(service.savedAudioURL)
        let other = DictationContext(server: "https://other.example.invalid", account: "synthetic-other", conversation: "origami")
        service.bind(to: other, isCurrent: { true }, draft: { "Other synthetic draft" }, deliver: { _ in XCTFail("Old recording must not enter a new context") })
        UIApplication.shared.transition(to: .active)
        try await settle()
        XCTAssertEqual(client.calls, 1)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedAudio.path))
        XCTAssertEqual(service.state, .idle)
        service.unbind()
    }
}
