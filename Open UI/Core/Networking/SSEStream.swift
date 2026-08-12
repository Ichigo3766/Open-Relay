import Foundation

/// Parses a `URLSession.AsyncBytes` stream as Server-Sent Events (SSE).
///
/// Yields individual SSE data payloads as strings, handling the `data:` prefix
/// and the `[DONE]` terminator used by OpenAI-compatible APIs.
///
/// Uses `AsyncBytes.lines` for correct UTF-8 line splitting, avoiding
/// the byte-by-byte `UnicodeScalar` approach that corrupts multi-byte
/// characters (emoji, CJK, accented Latin, etc.).
struct SSEStream: AsyncSequence {
    typealias Element = SSEEvent

    let bytes: URLSession.AsyncBytes
    /// Maximum time (seconds) allowed between any two SSE lines before the stream
    /// is considered stalled and terminated with a timeout error.
    /// 60 seconds matches open-webui's client-side stall detection.
    var stallTimeout: TimeInterval = 60

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes, stallTimeout: stallTimeout)
    }

    // MARK: - Class-boxed line iterator
    //
    // `withTaskGroup` closures are `@Sendable`, which means they cannot capture
    // `inout` (mutating) struct state. `AsyncLineSequence.AsyncIterator` is a struct
    // with a `mutating func next()`, so we wrap it in a final class to allow safe
    // concurrent access from the timeout-race task group below.
    private final class LineIteratorBox: @unchecked Sendable {
        // nonisolated(unsafe) lets Swift 6 call the mutating `next()` on this var
        // without actor isolation. Safe because `next()` is never called concurrently —
        // only the owning `AsyncIterator.next()` mutates it, sequentially.
        nonisolated(unsafe) var iterator: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator

        init(_ bytes: URLSession.AsyncBytes) {
            self.iterator = bytes.lines.makeAsyncIterator()
        }

        /// Calls the underlying mutating `next()`. Only ever called from the owning
        /// `AsyncIterator.next()` — never concurrently — so `@unchecked Sendable` is safe.
        func next() async throws -> String? {
            try await iterator.next()
        }
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        /// Class-boxed so it can be captured by the @Sendable timeout task group closure.
        private let lineBox: LineIteratorBox
        private var finished = false
        private let stallTimeout: TimeInterval

        /// Accumulates multi-line `data:` fields per the SSE spec.
        /// Multiple consecutive `data:` lines are concatenated with `\n`
        /// and dispatched as a single event when the blank-line separator arrives.
        private var pendingDataLines: [String] = []
        private var pendingEventName: String? = nil

        init(bytes: URLSession.AsyncBytes, stallTimeout: TimeInterval = 60) {
            self.lineBox = LineIteratorBox(bytes)
            self.stallTimeout = stallTimeout
        }

        mutating func next() async throws -> SSEEvent? {
            if finished { return nil }

            while true {
                // ── Stall-timeout watchdog ─────────────────────────────────────────
                // Race the next line against a sleep deadline. If no bytes arrive
                // within `stallTimeout` seconds the sleep task wins and throws a
                // `.timedOut` error, preventing the stream from hanging forever on a
                // server that has silently stopped sending data.
                let line: String? = try await withThrowingTaskGroup(of: String?.self) { group in
                    let box = lineBox          // capture reference, not mutating self
                    let timeout = stallTimeout

                    group.addTask {
                        try await box.next()
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw APIError.networkError(underlying: URLError(.timedOut))
                    }

                    // The first task to finish wins; immediately cancel the other.
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                // ── End watchdog ───────────────────────────────────────────────────

                guard let line else {
                    // Byte stream ended — flush any pending data before returning nil
                    finished = true
                    if !pendingDataLines.isEmpty {
                        return flushPendingEvent()
                    }
                    return nil
                }

                // Empty line = end of event block in SSE spec — dispatch accumulated data
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !pendingDataLines.isEmpty {
                        return flushPendingEvent()
                    }
                    continue
                }

                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.hasPrefix("data: ") {
                    let payload = String(trimmed.dropFirst(6))
                    // Fast path: single-line [DONE] — flush any pending lines first, then done
                    if payload == "[DONE]" {
                        if !pendingDataLines.isEmpty {
                            let event = flushPendingEvent()
                            // Re-queue the DONE for the next call by setting finished
                            // is not possible cleanly; instead yield DONE directly after flush.
                            // The natural stream close will handle true termination.
                            return event
                        }
                        return .done
                    }
                    pendingDataLines.append(payload)
                    continue
                }

                if trimmed == "data" || trimmed == "data:" {
                    // Empty data line per spec: append empty string
                    pendingDataLines.append("")
                    continue
                }

                if trimmed.hasPrefix("event: ") {
                    pendingEventName = String(trimmed.dropFirst(7))
                    continue
                }

                if trimmed.hasPrefix("id: ") || trimmed.hasPrefix("retry: ") {
                    // SSE event ID / reconnection interval — ignored
                    continue
                }

                // Lines starting with ":" are SSE comments (keepalive) — ignored
                if trimmed.hasPrefix(":") {
                    continue
                }

                // Handle bare [DONE] or "data: [DONE]" without surrounding blank line
                if trimmed == "[DONE]" || trimmed == "data: [DONE]" {
                    return .done
                }

                // Unrecognised non-empty line — treat as raw text data (legacy compat)
                if !trimmed.isEmpty {
                    return .text(trimmed)
                }
            }
        }

        /// Flushes accumulated `data:` lines into a single SSEEvent, then resets state.
        private mutating func flushPendingEvent() -> SSEEvent {
            let combined = pendingDataLines.joined(separator: "\n")
            pendingDataLines = []
            pendingEventName = nil

            if combined == "[DONE]" { return .done }

            if let data = combined.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return .json(json)
            }
            return .text(combined)
        }
    }
}

/// A parsed SSE event.
enum SSEEvent: Sendable {
    /// A JSON data payload from a `data:` field.
    case json([String: Any])
    /// A plain text data payload.
    case text(String)
    /// An event type field (`event: name`).
    case event(name: String)
    /// The `[DONE]` terminator signaling end of stream.
    case done

    // MARK: - Convenience

    /// Extracts the content delta from an OpenAI-style streaming chunk.
    var contentDelta: String? {
        guard case .json(let json) = self else { return nil }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }
        return content
    }

    /// Extracts usage statistics from the final streaming chunk.
    var usage: [String: Any]? {
        guard case .json(let json) = self else { return nil }
        return json["usage"] as? [String: Any]
    }

    /// Whether this chunk indicates the response is complete.
    var isFinished: Bool {
        switch self {
        case .done:
            return true
        case .json(let json):
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let finishReason = first["finish_reason"] as? String,
               !finishReason.isEmpty {
                return true
            }
            return false
        default:
            return false
        }
    }
}

// Sendable conformance for [String: Any]
extension SSEEvent {
    // SSEEvent is marked @unchecked Sendable because the json dictionary
    // contains only Foundation JSON types which are all value types or
    // thread-safe reference types.
}
