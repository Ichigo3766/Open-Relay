import XCTest
import AVFoundation
@testable import RecoveryQA

@MainActor final class RecoveryTests: XCTestCase {
    final class Draft {
        var text = "Workshop plan."
        var valid = true
        var deliveries = 0
    }
    let original = DictationContext(server: "https://example.invalid", account: "synthetic-account", conversation: "synthetic-chat")

    func fixture() throws -> (DictationService, DictationRecoveryStore, Draft, URL) {
        MockBackend.shared.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecoveryStore(directory: directory)
        let service = configured(store)
        let draft = Draft()
        bind(service, draft)
        let data = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "five-minute", withExtension: "m4a")))
        let url = try service.qaRecord(data)
        return (service, store, draft, url)
    }

    func configured(_ store: DictationRecoveryStore) -> DictationService {
        let service = DictationService(recoveryStore: store)
        service.serverSpeechService = ServerSpeechRecognitionService()
        service.onDeviceASRService = OnDeviceASRService()
        return service
    }

    func bind(_ service: DictationService, _ draft: Draft, context: DictationContext? = nil) {
        service.bind(to: context ?? original, isCurrent: { draft.valid }, draft: { draft.text },
                     deliver: { draft.text = $0; draft.deliveries += 1 })
    }

    func waitForHeldAttempt() async throws {
        for _ in 0..<100 {
            if MockBackend.shared.continuation != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Mock attempt never started")
    }

    func testFailureAndRepeatedRetryReuseFiveMinuteAudioThenCommitOnce() async throws {
        let (service, store, draft, url) = try fixture()
        let originalAudio = try Data(contentsOf: url)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 300, accuracy: 0.1)
        MockBackend.shared.outcomes = [.fail, .fail, .fail, .success]
        service.stopDictation()
        await service.attemptTask?.value
        for _ in 0..<2 {
            XCTAssertEqual(try Data(contentsOf: url), originalAudio)
            XCTAssertEqual(service.recordingDuration, 300)
            XCTAssertEqual(try store.load(original)?.recording?.duration, 300)
            service.retry()
            await service.attemptTask?.value
        }
        service.retry()
        await service.attemptTask?.value
        XCTAssertEqual(MockBackend.shared.calls.count, 4)
        XCTAssertTrue(MockBackend.shared.calls.allSatisfy { $0.data == originalAudio })
        XCTAssertEqual(draft.deliveries, 1)
        XCTAssertEqual(draft.text, "Workshop plan. Fold the paper kite and attach a blue ribbon.")
        XCTAssertEqual(try store.load(original)?.draft, draft.text)
        XCTAssertNil(try store.load(original)?.recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        service.retry()
        XCTAssertEqual(MockBackend.shared.calls.count, 4)
    }

    func testEmptyTranscriptRemainsRecoverable() async throws {
        let (service, store, draft, url) = try fixture()
        MockBackend.shared.outcomes = [.empty]
        service.stopDictation()
        await service.attemptTask?.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(try store.load(original)?.recording)
        XCTAssertEqual(draft.deliveries, 0)
        guard case .error(let message) = service.state else { return XCTFail("Expected recovery state") }
        XCTAssertTrue(message.contains("No transcript"))
    }

    func testLocalFallbackUsesOriginalAudioAndKeepsItOnFailure() async throws {
        let (service, _, draft, url) = try fixture()
        let audio = try Data(contentsOf: url)
        let preference = UserDefaults.standard.string(forKey: "sttEngine")
        MockBackend.shared.outcomes = [.fail, .fail, .success]
        service.stopDictation()
        await service.attemptTask?.value
        service.retry(onDevice: true)
        await service.attemptTask?.value
        XCTAssertEqual(try Data(contentsOf: url), audio)
        XCTAssertEqual(draft.deliveries, 0)
        service.retry(onDevice: true)
        await service.attemptTask?.value
        XCTAssertEqual(MockBackend.shared.calls.map(\.local), [false, true, true])
        XCTAssertTrue(MockBackend.shared.calls.allSatisfy { $0.data == audio })
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sttEngine"), preference)
        XCTAssertEqual(draft.deliveries, 1)
    }

    func testUnavailableOrBusyLocalBackendCannotConsumeRecording() async throws {
        let (service, _, draft, url) = try fixture()
        service.stopDictation()
        await service.attemptTask?.value
        service.onDeviceASRService?.state = .transcribing
        XCTAssertFalse(service.canTranscribeOnDevice)
        service.retry(onDevice: true)
        await service.attemptTask?.value
        XCTAssertEqual(MockBackend.shared.calls.count, 1)
        service.onDeviceASRService?.state = .unloaded
        service.onDeviceASRService?.isAvailable = false
        XCTAssertFalse(service.canTranscribeOnDevice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(draft.deliveries, 0)
    }

    func testExportDoesNotConsumeRecordingAndDiscardRemovesIt() async throws {
        let (service, store, _, url) = try fixture()
        service.stopDictation()
        await service.attemptTask?.value
        let audio = try Data(contentsOf: url)
        for _ in 0..<3 {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(service.savedAudioURL)), audio)
        }
        XCTAssertNotNil(try store.load(original)?.recording)
        service.discardRecording()
        XCTAssertNil(try store.load(original)?.recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(service.state, .idle)
    }

    func testDuplicateRetryAndCancellationWithNonCooperativeBackend() async throws {
        let (service, store, draft, url) = try fixture()
        MockBackend.shared.outcomes = [.hold, .success]
        service.stopDictation()
        try await waitForHeldAttempt()
        for _ in 0..<10 { service.retry() }
        XCTAssertEqual(MockBackend.shared.calls.count, 1)
        service.cancelAttempt()
        service.retry()
        XCTAssertEqual(MockBackend.shared.calls.count, 1, "No overlapping attempt while cancellation settles")
        MockBackend.shared.continuation?.resume(returning: "Late result must not be inserted")
        await service.attemptTask?.value
        XCTAssertEqual(draft.deliveries, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(try store.load(original)?.recording)
        service.retry()
        await service.attemptTask?.value
        XCTAssertEqual(draft.deliveries, 1)
    }

    func testDiscardSuppressesLateResponse() async throws {
        let (service, store, draft, url) = try fixture()
        MockBackend.shared.outcomes = [.hold]
        service.stopDictation()
        try await waitForHeldAttempt()
        service.discardRecording()
        MockBackend.shared.continuation?.resume(returning: "Late result")
        await service.attemptTask?.value
        XCTAssertEqual(draft.deliveries, 0)
        XCTAssertNil(try store.load(original)?.recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(service.state, .idle)
    }

    func testNavigationAndRelaunchRestoreWithoutAutomaticUpload() async throws {
        let (service, store, _, url) = try fixture()
        service.stopDictation()
        await service.attemptTask?.value
        service.unbind()
        let relaunched = configured(DictationRecoveryStore(directory: store.directory))
        bind(relaunched, Draft())
        XCTAssertEqual(relaunched.savedAudioURL, url)
        XCTAssertEqual(relaunched.recordingDuration, 300)
        XCTAssertEqual(MockBackend.shared.calls.count, 1)
        XCTAssertTrue(relaunched.showsRecovery)
    }

    func testChatAndAccountSwitchCannotMisrouteAudioOrText() async throws {
        let (service, store, draft, url) = try fixture()
        MockBackend.shared.outcomes = [.hold]
        service.stopDictation()
        try await waitForHeldAttempt()
        let otherDraft = Draft()
        let other = DictationContext(server: original.server, account: "another-account", conversation: original.conversation)
        bind(service, otherDraft, context: other)
        service.retry()
        MockBackend.shared.continuation?.resume(returning: "Old response")
        await service.attemptTask?.value
        XCTAssertEqual(draft.deliveries, 0)
        XCTAssertEqual(otherDraft.deliveries, 0)
        XCTAssertNil(service.savedAudioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(try store.load(other))
        let otherChat = DictationContext(server: original.server, account: original.account, conversation: "another-chat")
        bind(service, otherDraft, context: otherChat)
        XCTAssertNil(service.savedAudioURL)
        XCTAssertNil(try store.load(otherChat))
        bind(service, draft)
        XCTAssertEqual(service.savedAudioURL, url)
    }

    func testAccountInvalidatedBeforeAttemptDoesNotUpload() async throws {
        let (service, _, draft, url) = try fixture()
        service.stopDictation()
        draft.valid = false
        await service.attemptTask?.value
        XCTAssertTrue(MockBackend.shared.calls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAuthorizationIsFrozenAndLateAccountChangeCannotDeliver() async throws {
        let (service, _, draft, url) = try fixture()
        MockBackend.shared.outcomes = [.hold]
        service.stopDictation()
        try await waitForHeldAttempt()
        service.serverSpeechService?.apiClient?.network.authToken = "another-synthetic-session"
        draft.valid = false
        XCTAssertEqual(MockBackend.shared.calls.first?.authorization, "Bearer synthetic-session")
        XCTAssertEqual(MockBackend.shared.calls.first?.timeout, 360)
        MockBackend.shared.continuation?.resume(returning: "Unwanted result")
        await service.attemptTask?.value
        XCTAssertEqual(draft.deliveries, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnresolvedRecordingCannotBeOverwritten() async throws {
        let (service, store, _, url) = try fixture()
        service.stopDictation()
        await service.attemptTask?.value
        let id = service.pendingRecording?.id
        await service.startDictation()
        XCTAssertEqual(service.pendingRecording?.id, id)
        XCTAssertThrowsError(try store.begin(original, draft: "Replacement", engine: "server"))
        XCTAssertEqual(service.savedAudioURL, url)
    }

    func testInterruptedCommitRestoresDraftAndDoesNotAppendTwice() async throws {
        let (service, store, _, url) = try fixture()
        service.unbind()
        let pending = try XCTUnwrap(store.load(original)?.recording)
        let text = try store.commit("Recovered text.", recordingID: pending.id, draft: "Draft.", context: original)
        XCTAssertEqual(try store.commit("Duplicate", recordingID: pending.id, draft: text, context: original), text)
        let restored = configured(DictationRecoveryStore(directory: store.directory))
        let draft = Draft()
        bind(restored, draft)
        XCTAssertEqual(draft.text, "Draft. Recovered text.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(MockBackend.shared.calls.isEmpty)
        XCTAssertNil(try store.load(original)?.recording)
        try store.saveDraft("", for: original)
        XCTAssertEqual(try store.load(original)?.draft, "", "Sent/cleared text must not reappear")
    }

    func testNewChatPromotionMovesRecoveryWithoutChangingAudio() async throws {
        let (_, store, _, _) = try fixture()
        let newChat = DictationContext(server: original.server, account: original.account, conversation: nil)
        let pending = try store.begin(newChat, draft: "Unsent draft.", engine: "server")
        let promoted = DictationContext(server: original.server, account: original.account, conversation: "assigned-id")
        try store.move(from: newChat, to: promoted)
        XCTAssertNil(try store.load(newChat))
        XCTAssertEqual(try store.load(promoted)?.recording?.id, pending.id)
    }

    func testDraftCommitFailurePreservesAudioAndDoesNotDeliver() async throws {
        let (service, store, draft, url) = try fixture()
        MockBackend.shared.outcomes = [.hold]
        service.stopDictation()
        try await waitForHeldAttempt()
        let metadata = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.directory,
                                            includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        // A directory where the metadata should be makes the commit fail deterministically.
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        MockBackend.shared.continuation?.resume(returning: "A valid transcript")
        await service.attemptTask?.value
        XCTAssertEqual(draft.deliveries, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(service.pendingRecording)
    }

    func testComposerRestoresEditsAndClearsAcrossAccounts() throws {
        let context = DictationContext(server: "https://example.invalid", account: UUID().uuidString, conversation: "draft")
        let store = DictationRecoveryStore.shared
        try store.save(.init(draft: "Recovered workshop draft.", recording: nil), for: context)
        let model = ChatDraftQA()
        try model.restoreDictationDraft(for: context)
        XCTAssertEqual(model.inputText, "Recovered workshop draft.")
        model.inputText = "Edited draft."
        XCTAssertEqual(try store.load(context)?.draft, "Edited draft.")
        let other = DictationContext(server: context.server, account: UUID().uuidString, conversation: context.conversation)
        try model.restoreDictationDraft(for: other)
        XCTAssertEqual(model.inputText, "", "Another account must not inherit a dictated draft")
        try model.restoreDictationDraft(for: context)
        XCTAssertEqual(model.inputText, "Edited draft.")
        model.inputText = ""
        let relaunched = ChatDraftQA()
        try relaunched.restoreDictationDraft(for: context)
        XCTAssertEqual(relaunched.inputText, "", "Sending or clearing a draft must remain cleared")
    }

    func testOrdinaryDraftSurvivesNewChatPromotion() throws {
        let context = DictationContext(server: "https://example.invalid", account: UUID().uuidString, conversation: nil)
        let model = ChatDraftQA()
        try model.restoreDictationDraft(for: context)
        model.inputText = "Keep this ordinary unsent draft."
        model.conversation = Conversation(id: "assigned-id")
        XCTAssertEqual(model.inputText, "Keep this ordinary unsent draft.")
    }

    func testComposerPromotesNewChatEvenWithoutVisibleView() throws {
        let context = DictationContext(server: "https://example.invalid", account: UUID().uuidString, conversation: nil)
        let store = DictationRecoveryStore.shared
        let recording = try store.begin(context, draft: "New workshop draft.", engine: "server")
        let model = ChatDraftQA()
        try model.restoreDictationDraft(for: context)
        model.conversation = Conversation(id: "assigned-id")
        let promoted = DictationContext(server: context.server, account: context.account, conversation: "assigned-id")
        XCTAssertNil(try store.load(context))
        XCTAssertEqual(try store.load(promoted)?.recording?.id, recording.id)
        model.inputText = ""
        XCTAssertEqual(try store.load(promoted)?.draft, "")
        try store.discard(promoted)
    }
}
