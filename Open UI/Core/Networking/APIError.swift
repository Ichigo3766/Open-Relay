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
            return Self.friendlyHTTPMessage(statusCode: statusCode, serverMessage: message)

        case .requestEncoding:
            return "Something went wrong preparing your request. Please try again."

        case .responseDecoding:
            return "The server sent an unexpected response. Please try again."

        case .invalidURL:
            return "The server URL is invalid. Please check your settings."

        case .unauthorized:
            return "You need to sign in to continue."

        case .tokenExpired:
            return "Your session has expired. Please sign in again."

        case .proxyAuthRequired:
            return "Your network requires authentication. Please sign in through your network proxy first."

        case .networkError(let error):
            return Self.friendlyNetworkMessage(error)

        case .sslError:
            return "Couldn't establish a secure connection. If you're using a private server, enable self-signed certificates in Settings."

        case .streamError:
            return "The response was interrupted. Please try again."

        case .redirectDetected:
            return "The server is redirecting requests. Please check your server URL in Settings."

        case .cancelled:
            return "Request was cancelled."

        case .unknown:
            return "Something went wrong. Please try again."
        }
    }

    /// The raw detail message from the server, useful for debugging or power users.
    /// Returns `nil` for non-HTTP errors or when the server didn't provide a message.
    var serverDetail: String? {
        switch self {
        case .httpError(_, let message, _):
            return message
        case .networkError(let error):
            return error.localizedDescription
        case .streamError(let message):
            return message
        case .requestEncoding(let error):
            return error.localizedDescription
        case .responseDecoding(let error, _):
            return error.localizedDescription
        case .unknown(let error):
            return error?.localizedDescription
        default:
            return nil
        }
    }

    // MARK: - Friendly Message Helpers

    /// Maps HTTP status codes to user-friendly messages.
    /// For 400 errors, the server's `detail` field is usually already user-facing, so we show it directly.
    private static func friendlyHTTPMessage(statusCode: Int, serverMessage: String?) -> String {
        switch statusCode {
        case 400:
            // Server 400 "detail" messages are typically user-facing (e.g. "Email already registered")
            return serverMessage ?? "The request was invalid. Please check your input and try again."
        case 401:
            return "Your session has expired. Please sign in again."
        case 403:
            return serverMessage ?? "You don't have permission to do this."
        case 404:
            return "The requested item could not be found."
        case 409:
            return serverMessage ?? "This conflicts with an existing item. Please use a different name or ID."
        case 413:
            return "The file is too large. Please try a smaller file."
        case 422:
            return serverMessage ?? "Some of the information provided is invalid. Please check and try again."
        case 429:
            return "Too many requests. Please wait a moment and try again."
        case 500:
            return "The server ran into a problem. Please try again later."
        case 502:
            return "The server is temporarily unavailable. Please try again in a moment."
        case 503:
            return "The server is undergoing maintenance. Please try again later."
        case 504:
            return "The server took too long to respond. Please try again."
        default:
            if statusCode >= 500 {
                return "The server encountered an error (\(statusCode)). Please try again later."
            }
            // For other 4xx, show server message if available, otherwise generic
            return serverMessage ?? "Request failed (\(statusCode)). Please try again."
        }
    }

    /// Maps URLError codes to user-friendly network messages.
    private static func friendlyNetworkMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "You're offline. Check your internet connection and try again."
            case .timedOut:
                return "The request timed out. Please check your connection and try again."
            case .cannotFindHost:
                return "Couldn't find the server. Please check your server URL."
            case .cannotConnectToHost:
                return "Couldn't connect to the server. Make sure it's running and reachable."
            case .networkConnectionLost:
                return "Your connection was interrupted. Please try again."
            case .dnsLookupFailed:
                return "Couldn't look up the server address. Please check your server URL."
            case .internationalRoamingOff:
                return "International roaming is off. Enable it in Settings to use data abroad."
            case .dataNotAllowed:
                return "Cellular data is turned off. Enable it in Settings or connect to Wi-Fi."
            default:
                return "A network error occurred. Please check your connection and try again."
            }
        }
        return "A network error occurred. Please check your connection and try again."
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

    /// Whether this error indicates a connectivity issue (device offline,
    /// server unreachable, DNS failure, etc.) — as opposed to an app-logic
    /// error like 401 or a decoding failure.
    var isConnectivityError: Bool {
        switch self {
        case .networkError(let underlying):
            if let urlError = underlying as? URLError {
                switch urlError.code {
                case .notConnectedToInternet,
                     .cannotConnectToHost,
                     .cannotFindHost,
                     .networkConnectionLost,
                     .timedOut,
                     .dnsLookupFailed:
                    return true
                default:
                    return false
                }
            }
            return true
        case .sslError:
            return true
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
    /// Server is behind Cloudflare Bot Fight Mode / Browser Integrity Check.
    /// Requires a real browser (WKWebView) to complete the JS challenge.
    case cloudflareChallenge
    /// Server could not be reached.
    case unreachable
}
