import SwiftUI

// MARK: - Network Error Recovery View

/// A comprehensive error view that provides context-specific recovery
/// actions based on the type of error encountered.
///
/// Automatically maps ``APIError`` types to user-friendly messages
/// and appropriate recovery options (retry, sign in, check settings).
///
/// Usage:
/// ```swift
/// NetworkErrorRecoveryView(
///     error: .networkError(underlying: urlError),
///     onRetry: { await loadData() },
///     onSignIn: { router.navigate(to: .login) }
/// )
/// ```
struct NetworkErrorRecoveryView: View {
    let error: APIError
    var onRetry: (() async -> Void)?
    var onSignIn: (() -> Void)?
    var onSettings: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: Spacing.xl) {
            // Animated icon
            errorIcon
                .padding(.top, Spacing.xl)

            // Error details
            VStack(spacing: Spacing.sm) {
                Text(errorTitle)
                    .font(AppTypography.headlineSmallFont)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(errorDescription)
                    .font(AppTypography.bodySmallFont)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            // Recovery actions
            VStack(spacing: Spacing.sm) {
                if let onRetry {
                    LoadingButton(
                        title: String(localized: "Try Again"),
                        isLoading: isRetrying
                    ) {
                        Task {
                            isRetrying = true
                            await onRetry()
                            isRetrying = false
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                }

                if error.requiresReauth, let onSignIn {
                    Button(action: onSignIn) {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "person.crop.circle")
                            Text("Sign In Again")
                                .font(AppTypography.labelLargeFont)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: TouchTarget.comfortable)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, Spacing.xl)
                }

                if case .sslError = error, let onSettings {
                    Button(action: onSettings) {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "gear")
                            Text("Open Settings")
                                .font(AppTypography.labelLargeFont)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: TouchTarget.comfortable)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, Spacing.xl)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(errorTitle). \(errorDescription)"))
    }

    // MARK: - Error Icon

    private var errorIcon: some View {
        ZStack {
            Circle()
                .fill(iconBackgroundColor.opacity(0.12))
                .frame(width: 80, height: 80)

            Image(systemName: iconName)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(iconColor)
        }
    }

    // MARK: - Error Properties

    private var errorTitle: String {
        switch error {
        case .networkError:
            return String(localized: "No Connection")
        case .unauthorized, .tokenExpired:
            return String(localized: "Session Expired")
        case .sslError:
            return String(localized: "Security Error")
        case .proxyAuthRequired:
            return String(localized: "Proxy Authentication Required")
        case .httpError(let code, _, _) where code >= 500:
            return String(localized: "Server Error")
        case .httpError(let code, _, _) where code == 429:
            return String(localized: "Too Many Requests")
        case .streamError:
            return String(localized: "Streaming Error")
        default:
            return String(localized: "Something Went Wrong")
        }
    }

    private var errorDescription: String {
        switch error {
        case .networkError:
            return String(localized: "Please check your internet connection and try again. Make sure your server is reachable.")
        case .unauthorized, .tokenExpired:
            return String(localized: "Your session has expired. Please sign in again to continue.")
        case .sslError:
            return String(localized: "The server's security certificate could not be verified. If using a private server, enable self-signed certificates in settings.")
        case .proxyAuthRequired:
            return String(localized: "Your network requires proxy authentication. Please check your network settings.")
        case .httpError(let code, _, _) where code >= 500:
            return String(localized: "The server is experiencing issues. Please try again in a few moments.")
        case .httpError(let code, _, _) where code == 429:
            return String(localized: "You've sent too many requests. Please wait a moment before trying again.")
        case .streamError:
            return String(localized: "The response stream was interrupted. Please try sending your message again.")
        case .httpError(_, let message, _):
            return message ?? String(localized: "An unexpected error occurred. Please try again.")
        default:
            return error.errorDescription ?? String(localized: "An unexpected error occurred. Please try again.")
        }
    }

    private var iconName: String {
        switch error {
        case .networkError: "wifi.slash"
        case .unauthorized, .tokenExpired: "lock.fill"
        case .sslError: "shield.slash"
        case .proxyAuthRequired: "network"
        case .httpError(let code, _, _) where code >= 500: "server.rack"
        case .httpError(let code, _, _) where code == 429: "clock.arrow.circlepath"
        case .streamError: "bolt.slash"
        default: "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch error {
        case .networkError: theme.warning
        case .unauthorized, .tokenExpired: theme.info
        case .sslError: theme.error
        default: theme.error
        }
    }

    private var iconBackgroundColor: Color {
        iconColor
    }
}

// MARK: - Inline Error Banner

/// A compact, dismissible error banner for showing errors within a view
/// without replacing the entire content.
///
/// Supports automatic retry with exponential backoff.
///
/// Usage:
/// ```swift
/// InlineErrorBanner(
///     message: "Failed to send message",
///     onRetry: { await resend() },
///     onDismiss: { error = nil }
/// )
/// ```
struct InlineErrorBanner: View {
    let message: String
    var detail: String?
    var onRetry: (() async -> Void)?
    var onDismiss: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var isRetrying = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(theme.error)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(message)
                    .font(AppTypography.labelSmallFont)
                    .foregroundStyle(theme.textPrimary)

                if let detail {
                    Text(detail)
                        .font(AppTypography.captionFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if let onRetry {
                Button {
                    Task {
                        isRetrying = true
                        await onRetry()
                        isRetrying = false
                    }
                } label: {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Retry")
                            .font(AppTypography.labelSmallFont)
                            .foregroundStyle(theme.brandPrimary)
                    }
                }
                .disabled(isRetrying)
                .accessibilityLabel(Text("Retry"))
            }

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.errorBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
    }
}

// MARK: - Retry Service

/// Provides automatic retry logic with exponential backoff for network
/// operations.
///
/// Usage:
/// ```swift
/// let result = try await RetryService.withRetry(maxAttempts: 3) {
///     try await apiClient.fetchData()
/// }
/// ```
enum RetryService {

    /// Executes an async operation with automatic retry on failure.
    ///
    /// Uses exponential backoff with jitter between retries.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum number of attempts (default 3).
    ///   - initialDelay: Initial delay between retries in seconds (default 1.0).
    ///   - maxDelay: Maximum delay between retries in seconds (default 30.0).
    ///   - shouldRetry: Closure to determine if the error is retryable.
    ///   - operation: The async operation to execute.
    /// - Returns: The result of the operation.
    static func withRetry<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        shouldRetry: ((Error) -> Bool)? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var currentDelay = initialDelay

        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Check if we should retry this error
                let apiError = APIError.from(error)
                let isRetryable = shouldRetry?(error) ?? apiError.isRetryable
                guard isRetryable && attempt < maxAttempts else {
                    throw error
                }

                // Exponential backoff with jitter
                let jitter = Double.random(in: 0...0.5)
                let delay = min(currentDelay + jitter, maxDelay)
                try? await Task.sleep(for: .seconds(delay))

                currentDelay *= 2 // Exponential increase
            }
        }

        throw lastError ?? APIError.unknown(underlying: nil)
    }
}

// MARK: - Crash Logger

/// A lightweight crash and error logger that persists error information
/// for diagnostic purposes.
///
/// Captures unexpected errors, categorizes them, and stores recent
/// entries for review in the settings/about screen.
///
/// Usage:
/// ```swift
/// CrashLogger.shared.log(.error, "Failed to parse response", error: error)
/// ```
final class CrashLogger: @unchecked Sendable {
    /// Shared singleton instance.
    static let shared = CrashLogger()

    /// Maximum number of log entries to retain.
    private let maxEntries = 100

    /// Log severity levels.
    enum Level: String, Codable {
        case debug
        case info
        case warning
        case error
        case fatal
    }

    /// A single log entry.
    struct Entry: Codable, Identifiable {
        let id: String
        let timestamp: Date
        let level: Level
        let message: String
        let errorDescription: String?
        let context: String?

        init(
            level: Level,
            message: String,
            errorDescription: String? = nil,
            context: String? = nil
        ) {
            self.id = UUID().uuidString
            self.timestamp = .now
            self.level = level
            self.message = message
            self.errorDescription = errorDescription
            self.context = context
        }
    }

    private let queue = DispatchQueue(label: "com.openui.crashlogger", qos: .utility)
    private var entries: [Entry] = []

    private init() {
        loadEntries()
    }

    /// Logs an event.
    ///
    /// - Parameters:
    ///   - level: The severity level.
    ///   - message: A human-readable description.
    ///   - error: The optional associated error.
    ///   - context: Additional context (e.g., screen name, action).
    func log(
        _ level: Level,
        _ message: String,
        error: Error? = nil,
        context: String? = nil
    ) {
        let entry = Entry(
            level: level,
            message: message,
            errorDescription: error?.localizedDescription,
            context: context
        )

        queue.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)

            // Trim to max entries
            if self.entries.count > self.maxEntries {
                self.entries = Array(self.entries.suffix(self.maxEntries))
            }

            self.saveEntries()
        }
    }

    /// Returns the most recent log entries.
    ///
    /// - Parameter count: Maximum number of entries to return.
    /// - Returns: Array of recent log entries, newest first.
    func recentEntries(count: Int = 50) -> [Entry] {
        queue.sync {
            Array(entries.suffix(count).reversed())
        }
    }

    /// Clears all stored log entries.
    func clearLogs() {
        queue.async { [weak self] in
            self?.entries = []
            self?.saveEntries()
        }
    }

    /// Exports all logs as a formatted string for sharing.
    func exportLogs() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return queue.sync {
            entries.map { entry in
                "[\(formatter.string(from: entry.timestamp))] " +
                "[\(entry.level.rawValue.uppercased())] " +
                "\(entry.message)" +
                (entry.errorDescription.map { " | \($0)" } ?? "") +
                (entry.context.map { " | ctx: \($0)" } ?? "")
            }
            .joined(separator: "\n")
        }
    }

    // MARK: - Persistence

    private var logFileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("crash_logs.json")
    }

    private func saveEntries() {
        guard let url = logFileURL,
              let data = try? JSONEncoder().encode(entries)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadEntries() {
        guard let url = logFileURL,
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = loaded
    }
}

// MARK: - Previews

#Preview("Error Recovery") {
    VStack(spacing: Spacing.xl) {
        NetworkErrorRecoveryView(
            error: .networkError(underlying: URLError(.notConnectedToInternet)),
            onRetry: { try? await Task.sleep(for: .seconds(1)) }
        )
    }
    .themed()
}
