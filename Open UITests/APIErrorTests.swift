import XCTest
@testable import Open_UI

/// Unit tests for the ``APIError`` type, verifying error classification,
/// user-facing descriptions, retryability, and re-auth detection.
final class APIErrorTests: XCTestCase {

    // MARK: - Error Description

    func testHTTPErrorWithMessage() {
        let error = APIError.httpError(statusCode: 500, message: "Internal Server Error", data: nil)
        XCTAssertEqual(error.errorDescription, "Server error (500): Internal Server Error")
    }

    func testHTTPErrorWithoutMessage() {
        let error = APIError.httpError(statusCode: 404, message: nil, data: nil)
        XCTAssertEqual(error.errorDescription, "Server returned status 404")
    }

    func testUnauthorizedDescription() {
        let error = APIError.unauthorized
        XCTAssertEqual(error.errorDescription, "Authentication required. Please sign in.")
    }

    func testTokenExpiredDescription() {
        let error = APIError.tokenExpired
        XCTAssertEqual(error.errorDescription, "Your session has expired. Please sign in again.")
    }

    func testSSLErrorDescription() {
        let underlying = URLError(.serverCertificateUntrusted)
        let error = APIError.sslError(underlying: underlying)
        XCTAssertTrue(error.errorDescription?.contains("SSL certificate") == true)
    }

    func testCancelledDescription() {
        let error = APIError.cancelled
        XCTAssertEqual(error.errorDescription, "Request was cancelled.")
    }

    // MARK: - Retryability

    func testNetworkErrorIsRetryable() {
        let error = APIError.networkError(underlying: URLError(.timedOut))
        XCTAssertTrue(error.isRetryable)
    }

    func testStreamErrorIsRetryable() {
        let error = APIError.streamError("Connection lost")
        XCTAssertTrue(error.isRetryable)
    }

    func testServerErrorIsRetryable() {
        let error = APIError.httpError(statusCode: 503, message: nil, data: nil)
        XCTAssertTrue(error.isRetryable)
    }

    func testRateLimitErrorIsRetryable() {
        let error = APIError.httpError(statusCode: 429, message: nil, data: nil)
        XCTAssertTrue(error.isRetryable)
    }

    func testClientErrorIsNotRetryable() {
        let error = APIError.httpError(statusCode: 400, message: nil, data: nil)
        XCTAssertFalse(error.isRetryable)
    }

    func testUnauthorizedIsNotRetryable() {
        let error = APIError.unauthorized
        XCTAssertFalse(error.isRetryable)
    }

    func testSSLErrorIsNotRetryable() {
        let error = APIError.sslError(underlying: URLError(.serverCertificateUntrusted))
        XCTAssertFalse(error.isRetryable)
    }

    // MARK: - Requires Reauth

    func testUnauthorizedRequiresReauth() {
        XCTAssertTrue(APIError.unauthorized.requiresReauth)
    }

    func testTokenExpiredRequiresReauth() {
        XCTAssertTrue(APIError.tokenExpired.requiresReauth)
    }

    func testHTTP401RequiresReauth() {
        let error = APIError.httpError(statusCode: 401, message: nil, data: nil)
        XCTAssertTrue(error.requiresReauth)
    }

    func testHTTP500DoesNotRequireReauth() {
        let error = APIError.httpError(statusCode: 500, message: nil, data: nil)
        XCTAssertFalse(error.requiresReauth)
    }

    func testNetworkErrorDoesNotRequireReauth() {
        let error = APIError.networkError(underlying: URLError(.notConnectedToInternet))
        XCTAssertFalse(error.requiresReauth)
    }

    // MARK: - Error Conversion

    func testFromURLErrorCancelled() {
        let urlError = URLError(.cancelled)
        let apiError = APIError.from(urlError)
        if case .cancelled = apiError {
            // Expected
        } else {
            XCTFail("Expected .cancelled, got \(apiError)")
        }
    }

    func testFromURLErrorSSL() {
        let urlError = URLError(.serverCertificateUntrusted)
        let apiError = APIError.from(urlError)
        if case .sslError = apiError {
            // Expected
        } else {
            XCTFail("Expected .sslError, got \(apiError)")
        }
    }

    func testFromURLErrorNetwork() {
        let urlError = URLError(.notConnectedToInternet)
        let apiError = APIError.from(urlError)
        if case .networkError = apiError {
            // Expected
        } else {
            XCTFail("Expected .networkError, got \(apiError)")
        }
    }

    func testFromAPIErrorPassthrough() {
        let original = APIError.tokenExpired
        let converted = APIError.from(original)
        if case .tokenExpired = converted {
            // Expected
        } else {
            XCTFail("Expected .tokenExpired passthrough, got \(converted)")
        }
    }

    func testFromUnknownError() {
        struct CustomError: Error {}
        let apiError = APIError.from(CustomError())
        if case .unknown = apiError {
            // Expected
        } else {
            XCTFail("Expected .unknown, got \(apiError)")
        }
    }
}
