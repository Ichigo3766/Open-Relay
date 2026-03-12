import Foundation

/// Categorized API error types for the OpenWebUI networking layer.
enum APIError: LocalizedError, Sendable {
    /// The server returned an HTTP error status code.
    case httpError(statusCode: Int, message: String?, data: Data?)

    /// The request could not be encoded properly.
    case requestEncoding(underlying: Error)

    /// The response could not be decoded into the expected type.
    case responseDecoding(underlying: Error, data: Data?)

    /// The request URL was malformed or could not be constructed.
    case invalidURL(String)

    /// No authentication token is available for an authenticated request.
    case unauthorized

    /// The auth token was rejected by the server (401).
    case tokenExpired

    /// The server appears to be behind an authentication proxy.
    case proxyAuthRequired

    /// A network-level error occurred (DNS, timeout, connection refused, etc.).
    case networkError(underlying: Error)

    /// The SSL/TLS handshake failed, possibly due to a self-signed certificate.
    case sslError(underlying: Error)

    /// The streaming connection was interrupted or produced an error.
    case streamError(String)

    /// The server returned a redirect, possibly indicating misconfiguration.
    case redirectDetected(location: String?)

    /// A request was cancelled by the caller.
    case cancelled

    /// An unexpected or unclassified error.
    case unknown(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let message, _):
            if let message {
                return "Server error (\(statusCode)): \(message)"
            }
            return "Server returned status \(statusCode)"

        case .requestEncoding(let error):
            return "Failed to encode request: \(error.localizedDescription)"

        case .responseDecoding(let error, _):
            return "Failed to decode response: \(error.localizedDescription)"

        case .invalidURL(let url):
            return "Invalid URL: \(url)"

        case .unauthorized:
            return "Authentication required. Please sign in."

        case .tokenExpired:
            return "Your session has expired. Please sign in again."

        case .proxyAuthRequired:
            return "Server requires proxy authentication."

        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"

        case .sslError:
            return "SSL certificate error. Enable self-signed certificates if using a private server."

        case .streamError(let message):
            return "Streaming error: \(message)"

        case .redirectDetected(let location):
            if let location {
                return "Server redirected to: \(location)"
            }
            return "Server redirect detected. Check your URL configuration."

        case .cancelled:
            return "Request was cancelled."

        case .unknown(let error):
            if let error {
                return "Unexpected error: \(error.localizedDescription)"
            }
            return "An unexpected error occurred."
        }
    }

    /// Whether this error indicates the user should re-authenticate.
    var requiresReauth: Bool {
        switch self {
        case .unauthorized, .tokenExpired:
            return true
        case .httpError(let statusCode, _, _):
            return statusCode == 401
        default:
            return false
        }
    }

    /// Whether this error is recoverable by retrying.
    var isRetryable: Bool {
        switch self {
        case .networkError, .streamError:
            return true
        case .httpError(let statusCode, _, _):
            return statusCode >= 500 || statusCode == 429
        default:
            return false
        }
    }

    /// Creates an `APIError` from an arbitrary `Error`.
    static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .secureConnectionFailed:
                return .sslError(underlying: urlError)
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .notConnectedToInternet:
                return .networkError(underlying: urlError)
            default:
                return .networkError(underlying: urlError)
            }
        }
        return .unknown(underlying: error)
    }
}

/// Result of a health check with proxy detection.
enum HealthCheckResult: Sendable {
    /// Server is healthy and responding normally.
    case healthy
    /// Server responded but not with expected status.
    case unhealthy
    /// Server appears to be behind an authentication proxy.
    case proxyAuthRequired
    /// Server could not be reached.
    case unreachable
}
