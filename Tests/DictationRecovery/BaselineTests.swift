import XCTest
@testable import RecoveryQA

@MainActor final class BaselineTests: XCTestCase {
    func testFailedTranscriptionRetainsFiveMinuteRecording() async throws {
        MockBackend.shared.reset()
        let service = DictationService()
        service.serverSpeechService = ServerSpeechRecognitionService()
        let audio = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "five-minute", withExtension: "m4a")))
        let url = try service.qaRecord(audio)
        defer { try? FileManager.default.removeItem(at: url) }
        service.stopDictation()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Failed transcription must retain the original recording")
    }
}
