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

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: bytes)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        /// Uses the UTF-8–aware line iterator provided by Foundation.
        var lineIterator: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator
        private var finished = false

        init(bytes: URLSession.AsyncBytes) {
            self.lineIterator = bytes.lines.makeAsyncIterator()
        }

        mutating func next() async throws -> SSEEvent? {
            if finished { return nil }

            while true {
                guard let line = try await lineIterator.next() else {
                    // Byte stream ended (server closed connection)
                    finished = true
                    return nil
                }

                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                // Empty line = end of event block in SSE; skip
                if trimmed.isEmpty { continue }

                if let event = parseSSELine(trimmed) {
                    // Don't set `finished` on [DONE] – let the natural
                    // byte-stream close (server closes connection after
                    // the final [DONE]) terminate the iteration.  This
                    // makes the stream resilient to intermediate [DONE]
                    // markers that some servers send between tool calls
                    // and continuations.
                    return event
                }
            }
        }

        private func parseSSELine(_ line: String) -> SSEEvent? {
            // Handle [DONE] terminator
            if line == "[DONE]" || line == "data: [DONE]" {
                return .done
            }

            // Standard SSE field parsing
            if line.hasPrefix("data: ") {
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" {
                    return .done
                }
                // Try parsing as JSON
                if let data = payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return .json(json)
                }
                return .text(payload)
            }

            if line.hasPrefix("event: ") {
                let eventName = String(line.dropFirst(7))
                return .event(name: eventName)
            }

            if line.hasPrefix("id: ") {
                // SSE event ID, typically ignored for chat
                return nil
            }

            if line.hasPrefix("retry: ") {
                // SSE reconnection interval, ignored
                return nil
            }

            // Lines starting with ":" are SSE comments (keepalive)
            if line.hasPrefix(":") {
                return nil
            }

            // Raw text not matching SSE format
            if !line.isEmpty {
                return .text(line)
            }

            return nil
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
