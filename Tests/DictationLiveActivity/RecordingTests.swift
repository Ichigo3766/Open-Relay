import ActivityKit
import AVFoundation
import XCTest

@MainActor final class RecordingTests: XCTestCase {
    typealias RecordingActivity = Activity<DictationActivityAttributes>
    let context = DictationContext(server: "https://example.invalid", account: "synthetic", conversation: "paper-craft")

    override func setUp() async throws {
        ActivityStorage.values = []; ActivityStorage.enabled = true; ActivityStorage.fails = false
        AVAudioApplication.allowed = true
        AVAudioSession.fails = false
        AVAudioRecorder.starts = true; AVAudioRecorder.prepares = true
        UserDefaults.standard.set("server", forKey: "sttEngine")
        UserDefaults.standard.set(0, forKey: DictationService.autoStopKey)
    }

    func fixture() -> DictationService {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let service = DictationService(recoveryStore: DictationRecoveryStore(directory: directory))
        service.serverSpeechService = ServerSpeechRecognitionService()
        service.bind(to: context, isCurrent: { true }, draft: { "Synthetic draft" }, deliver: { _ in XCTFail("Must not insert a transcript") })
        return service
    }

    func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }

    func testStartOnlyAfterSuccessfulCaptureAndStopBeforeTranscription() async throws {
        let service = fixture()
        XCTAssertTrue(RecordingActivity.activities.isEmpty)
        await service.startDictation()
        XCTAssertEqual(service.state, .listening)
        let activity = try XCTUnwrap(RecordingActivity.activities.first)
        let url = try XCTUnwrap(service.savedAudioURL)
        service.stopDictation()
        await service.attemptTask?.value
        try await settle()
        XCTAssertTrue(activity.ended)
        XCTAssertEqual(service.serverSpeechService?.apiClient?.calls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(service.recordingDuration, 301)
        XCTAssertEqual(try service.recoveryStore.load(context)?.recording?.duration, 301)
    }

    func testNoActivityForDeniedPermissionOrFailedRecording() async throws {
        AVAudioApplication.allowed = false
        await fixture().startDictation()
        AVAudioApplication.allowed = true; AVAudioSession.fails = true
        await fixture().startDictation()
        AVAudioSession.fails = false; AVAudioRecorder.prepares = false
        await fixture().startDictation()
        AVAudioRecorder.prepares = true; AVAudioRecorder.starts = false
        await fixture().startDictation()
        XCTAssertTrue(RecordingActivity.activities.isEmpty)
    }

    func testAudioFileProtection() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Data Protection requires verification on a physical iOS device.")
        #else
        let service = fixture()
        await service.startDictation()
        let url = try XCTUnwrap(service.savedAudioURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        service.discardRecording()
        #endif
    }

    func testDisabledOrFailedLiveActivityDoesNotPreventRecording() async throws {
        for enabled in [false, true] {
            ActivityStorage.enabled = enabled; ActivityStorage.fails = enabled
            let service = fixture()
            await service.startDictation()
            XCTAssertEqual(service.state, .listening)
            XCTAssertTrue(AVAudioRecorder.latest?.isRecording == true)
            XCTAssertTrue(RecordingActivity.activities.isEmpty)
            service.discardRecording()
        }
    }

    func testInterruptionStopsActivityWithoutUploadingOrDiscarding() async throws {
        let service = fixture()
        await service.startDictation()
        let url = try XCTUnwrap(service.savedAudioURL)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await settle()
        XCTAssertEqual(service.state, .error("Recording interrupted · Audio saved"))
        XCTAssertTrue(RecordingActivity.activities.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(service.serverSpeechService?.apiClient?.calls, 0)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        try await settle()
        XCTAssertFalse(AVAudioRecorder.latest?.isRecording == true)
        service.unbind()
    }

    func testMediaResetAndRecorderFailureAreRecoverable() async throws {
        for delegateFailure in [false, true] {
            let service = fixture()
            await service.startDictation()
            if delegateFailure {
                service.audioRecorderEncodeErrorDidOccur(try XCTUnwrap(AVAudioRecorder.latest), error: nil)
            } else {
                NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            }
            try await settle()
            XCTAssertTrue(RecordingActivity.activities.isEmpty)
            XCTAssertTrue(service.showsRecovery)
            XCTAssertNotNil(try service.recoveryStore.load(context)?.recording)
            service.unbind()
        }
    }

    func testDiscardAndNavigationEndActivity() async throws {
        for discard in [false, true] {
            let service = fixture()
            await service.startDictation()
            let url = try XCTUnwrap(service.savedAudioURL)
            if discard { service.discardRecording() } else { service.unbind() }
            try await settle()
            XCTAssertTrue(RecordingActivity.activities.isEmpty)
            XCTAssertEqual(FileManager.default.fileExists(atPath: url.path), !discard)
        }
    }

    func testOldRecorderCallbackCannotStopNewRecording() async throws {
        let service = fixture()
        await service.startDictation()
        let oldRecorder = try XCTUnwrap(AVAudioRecorder.latest)
        service.discardRecording()
        await service.startDictation()
        service.audioRecorderDidFinishRecording(oldRecorder, successfully: true)
        try await settle()
        XCTAssertEqual(service.state, .listening)
        XCTAssertEqual(RecordingActivity.activities.count, 1)
        service.discardRecording()
    }

    func testQueuedInterruptionCannotStopAReplacementRecording() async throws {
        let service = fixture()
        await service.startDictation()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        service.discardRecording()
        await service.startDictation()
        try await settle()
        XCTAssertEqual(service.state, .listening)
        XCTAssertEqual(RecordingActivity.activities.count, 1)
        service.discardRecording()
    }

    func testRecorderStoppingWithoutDelegateCallbackEndsActivity() async throws {
        let service = fixture()
        await service.startDictation()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(service.recordingDuration, 301)
        AVAudioRecorder.latest?.isRecording = false
        AVAudioRecorder.latest?.currentTime = 0 // Invalid once recording has stopped.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.state, .error("Recording interrupted · Audio saved"))
        XCTAssertTrue(RecordingActivity.activities.isEmpty)
        XCTAssertTrue(service.showsRecovery)
        XCTAssertEqual(service.recordingDuration, 301)
        XCTAssertEqual(try service.recoveryStore.load(context)?.recording?.duration, 301)
    }

    func testDeviceAndServerDictationUseTheSameActivityLifecycle() async throws {
        for engine in ["device", "server"] {
            UserDefaults.standard.set(engine, forKey: "sttEngine")
            let service = fixture()
            await service.startDictation()
            XCTAssertEqual(service.activeEngine, engine)
            XCTAssertEqual(RecordingActivity.activities.count, 1)
            service.cancelDictation()
            try await settle()
            XCTAssertTrue(RecordingActivity.activities.isEmpty)
            XCTAssertEqual(service.state, .idle)
        }
    }

    func testSystemTimerNeedsOnlyThrottledLivenessUpdates() async throws {
        let controller = DictationLiveActivityController()
        let start = Date.now
        controller.start(at: start)
        controller.start(at: start)
        let activity = try XCTUnwrap(RecordingActivity.activities.first)
        for second in 0..<30 { controller.confirmRecording(at: start.addingTimeInterval(Double(second))) }
        try await settle()
        XCTAssertEqual(RecordingActivity.activities.count, 1)
        XCTAssertEqual(activity.updates.count, 1)
        controller.confirmRecording(at: start.addingTimeInterval(30))
        try await settle()
        XCTAssertEqual(activity.updates.count, 2)
        XCTAssertEqual(activity.updates.last?.staleDate, start.addingTimeInterval(120))
        controller.end()
        controller.confirmRecording(at: start.addingTimeInterval(60))
        try await settle()
        XCTAssertTrue(activity.ended)
        XCTAssertEqual(activity.updates.count, 2)
    }

    func testRelaunchCleanupDoesNotEndNewActivity() async throws {
        let previous = DictationLiveActivityController()
        previous.start()
        let old = try XCTUnwrap(RecordingActivity.activities.first)
        let next = DictationLiveActivityController()
        next.start()
        let new = try XCTUnwrap(RecordingActivity.activities.last)
        try await settle()
        XCTAssertTrue(old.ended)
        XCTAssertFalse(new.ended)
        next.end()
    }

    func testWidgetPayloadContainsNoDraftOrIdentity() throws {
        let payload = DictationActivityAttributes(startDate: .now)
        let fields = Mirror(reflecting: payload).children.compactMap(\.label)
        XCTAssertEqual(fields, ["startDate"])
        let content = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DictationActivityAttributes.ContentState(confirmedAt: .now))) as? [String: Any]
        XCTAssertEqual(Set(content?.keys.map { $0 } ?? []), ["confirmedAt"])
    }
}
