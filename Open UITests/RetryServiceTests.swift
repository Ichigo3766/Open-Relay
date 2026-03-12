import XCTest
@testable import Open_UI

/// Unit tests for ``RetryService`` verifying exponential backoff,
/// error classification, and retry logic.
final class RetryServiceTests: XCTestCase {

    // MARK: - Successful Operations

    func testSuccessfulOperationReturnsImmediately() async throws {
        var callCount = 0

        let result = try await RetryService.withRetry(maxAttempts: 3) {
            callCount += 1
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 1, "Should only call the operation once on success")
    }

    // MARK: - Retry Behaviour

    func testRetriesOnRetryableError() async throws {
        var callCount = 0

        let result = try await RetryService.withRetry(
            maxAttempts: 3,
            initialDelay: 0.01 // Fast for testing
        ) {
            callCount += 1
            if callCount < 3 {
                throw APIError.networkError(underlying: URLError(.timedOut))
            }
            return "recovered"
        }

        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(callCount, 3, "Should retry twice before succeeding")
    }

    func testDoesNotRetryNonRetryableError() async {
        var callCount = 0

        do {
            _ = try await RetryService.withRetry(
                maxAttempts: 3,
                initialDelay: 0.01
            ) {
                callCount += 1
                throw APIError.unauthorized
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 1, "Should not retry non-retryable errors")
            if case APIError.unauthorized = error {
                // Expected
            } else {
                XCTFail("Expected unauthorized error, got \(error)")
            }
        }
    }

    func testRespectsMaxAttempts() async {
        var callCount = 0

        do {
            _ = try await RetryService.withRetry(
                maxAttempts: 2,
                initialDelay: 0.01
            ) {
                callCount += 1
                throw APIError.networkError(underlying: URLError(.timedOut))
            }
            XCTFail("Should have thrown after max attempts")
        } catch {
            XCTAssertEqual(callCount, 2, "Should stop after maxAttempts")
        }
    }

    // MARK: - Custom Retry Predicate

    func testCustomRetryPredicate() async throws {
        struct CustomError: Error {}
        var callCount = 0

        let result = try await RetryService.withRetry(
            maxAttempts: 3,
            initialDelay: 0.01,
            shouldRetry: { _ in true } // Always retry
        ) {
            callCount += 1
            if callCount < 3 {
                throw CustomError()
            }
            return "done"
        }

        XCTAssertEqual(result, "done")
        XCTAssertEqual(callCount, 3)
    }

    func testCustomPredicateCanPreventRetry() async {
        var callCount = 0

        do {
            _ = try await RetryService.withRetry(
                maxAttempts: 5,
                initialDelay: 0.01,
                shouldRetry: { _ in false } // Never retry
            ) {
                callCount += 1
                throw APIError.networkError(underlying: URLError(.timedOut))
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 1, "Should not retry when predicate returns false")
        }
    }

    // MARK: - Single Attempt

    func testSingleAttemptThrowsImmediately() async {
        var callCount = 0

        do {
            _ = try await RetryService.withRetry(
                maxAttempts: 1,
                initialDelay: 0.01
            ) {
                callCount += 1
                throw APIError.streamError("broken")
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 1)
        }
    }
}

/// Unit tests for ``CrashLogger`` verifying log persistence and export.
final class CrashLoggerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CrashLogger.shared.clearLogs()
    }

    func testLogEntry() {
        CrashLogger.shared.log(.error, "Test error", context: "UnitTest")

        // Allow async queue to process
        let expectation = XCTestExpectation(description: "Log processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let entries = CrashLogger.shared.recentEntries(count: 10)
            XCTAssertFalse(entries.isEmpty, "Should have at least one entry")
            XCTAssertEqual(entries.first?.message, "Test error")
            XCTAssertEqual(entries.first?.context, "UnitTest")
            XCTAssertEqual(entries.first?.level, .error)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testLogLevels() {
        CrashLogger.shared.log(.debug, "Debug message")
        CrashLogger.shared.log(.info, "Info message")
        CrashLogger.shared.log(.warning, "Warning message")
        CrashLogger.shared.log(.error, "Error message")
        CrashLogger.shared.log(.fatal, "Fatal message")

        let expectation = XCTestExpectation(description: "Logs processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let entries = CrashLogger.shared.recentEntries(count: 10)
            XCTAssertEqual(entries.count, 5)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testClearLogs() {
        CrashLogger.shared.log(.info, "To be cleared")

        let expectation = XCTestExpectation(description: "Clear processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            CrashLogger.shared.clearLogs()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let entries = CrashLogger.shared.recentEntries(count: 10)
                XCTAssertTrue(entries.isEmpty, "Should be empty after clearing")
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testExportLogs() {
        CrashLogger.shared.log(.error, "Export test")

        let expectation = XCTestExpectation(description: "Export processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let exported = CrashLogger.shared.exportLogs()
            XCTAssertTrue(exported.contains("Export test"))
            XCTAssertTrue(exported.contains("ERROR"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
