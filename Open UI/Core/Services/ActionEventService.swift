import Foundation
import os.log

// MARK: - Action Event Models

/// An event emitted by an action function via `__event_emitter__`.
/// These are one-way: the server sends them, the client just reacts.
enum ActionEmitterEvent {
    /// A status update to display on the message (like a spinner pill).
    case status(action: String?, description: String, done: Bool)
    /// A toast/banner notification.
    case notification(type: String, message: String)
    /// Replace the message content in-place.
    case replace(content: String)
    /// Append content to the message.
    case message(content: String)
}

/// An event sent by an action function via `__event_call__`.
/// These are bidirectional: the client must respond with a value.
enum ActionCallEvent {
    /// Ask the user for a text input. Returns the entered string (or nil if cancelled).
    case input(title: String, message: String, placeholder: String, defaultValue: String)
    /// Ask the user for confirmation. Returns true/false.
    case confirmation(title: String, message: String)
    /// Execute client-side JS — on iOS we handle file downloads natively.
    case execute(code: String)
}

/// The response the client sends back to `__event_call__`.
enum ActionCallResponse {
    case string(String)
    case bool(Bool)
    case cancelled
}

// MARK: - Streaming Action Event Service

/// Streams SSE events from `/api/chat/actions/{actionId}`.
///
/// Open WebUI action functions emit two kinds of events:
/// - `__event_emitter__` — one-way: status, notification, replace, message
/// - `__event_call__`    — bidirectional: input, confirmation, execute
///
/// For `__event_call__` events the server sends a call id and waits for
/// the client to POST a response to `/api/chat/actions/{actionId}/respond`.
/// We surface these to the caller via an async callback that returns the value.
final class ActionEventService {
    private let network: NetworkManager
    private let logger = Logger(subsystem: "com.openui", category: "ActionEvent")

    init(network: NetworkManager) {
        self.network = network
    }

    // MARK: - Public Streaming API

    /// Streams an action invocation, calling the provided handlers as events arrive.
    ///
    /// - Parameters:
    ///   - actionId: The function's `id` (used in the URL).
    ///   - body: The full request body (model, messages, id, session_id, etc.).
    ///   - onEmitter: Called for every `__event_emitter__` event.
    ///   - onCall: Called for every `__event_call__` event; must return a response value.
    func stream(
        actionId: String,
        body: [String: Any],
        onEmitter: @escaping @Sendable (ActionEmitterEvent) async -> Void,
        onCall: @escaping @Sendable (ActionCallEvent) async -> ActionCallResponse
    ) async throws {
        logger.info("🟢 [ActionEvent] stream() ENTERING for actionId=\(actionId, privacy: .public)")

        let sseStream: SSEStream
        do {
            sseStream = try await network.streamRequestBytes(
                path: "/api/chat/actions/\(actionId)",
                method: .post,
                body: body,
                authenticated: true
            )
        } catch {
            logger.error("🔴 [ActionEvent] streamRequestBytes FAILED for actionId=\(actionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        logger.info("🟢 [ActionEvent] stream() SSE stream created for actionId=\(actionId, privacy: .public)")

        // Buffer the most recent `event:` field name so it can be applied
        // to the following `data:` payload. Open WebUI sends:
        //   event: __event_call__
        //   data: {"type": "input", ...}
        // The two SSE fields arrive as separate yields from the iterator.
        var pendingEventName: String? = nil

        for try await event in sseStream {
            switch event {
            case .done:
                logger.info("🏁 [ActionEvent] SSE .done received")
                return
            case .event(let name):
                // Stash the SSE event name — it will be applied to the
                // next data payload that arrives.
                pendingEventName = name
                logger.info("📌 [ActionEvent] SSE event name='\(name, privacy: .public)'")
            case .json(let json):
                let sseEventName = pendingEventName
                pendingEventName = nil
                let jsonDesc = "\(json)"
                logger.info("📦 [ActionEvent] SSE json sseEvent='\(sseEventName ?? "none", privacy: .public)' data=\(jsonDesc, privacy: .public)")
                await handleEventJSON(json, sseEventName: sseEventName, actionId: actionId, onEmitter: onEmitter, onCall: onCall)
            case .text(let text):
                let sseEventName = pendingEventName
                pendingEventName = nil
                logger.info("📄 [ActionEvent] SSE text sseEvent='\(sseEventName ?? "none", privacy: .public)' text=\(text, privacy: .public)")
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let jsonDesc = "\(json)"
                    logger.info("📦 [ActionEvent] text parsed as JSON: \(jsonDesc, privacy: .public)")
                    await handleEventJSON(json, sseEventName: sseEventName, actionId: actionId, onEmitter: onEmitter, onCall: onCall)
                }
            }
        }
        logger.info("🔚 [ActionEvent] stream() loop ended (server closed connection)")
    }

    // MARK: - Event Dispatching

    private func handleEventJSON(
        _ json: [String: Any],
        sseEventName: String?,
        actionId: String,
        onEmitter: @escaping @Sendable (ActionEmitterEvent) async -> Void,
        onCall: @escaping @Sendable (ActionCallEvent) async -> ActionCallResponse
    ) async {
        // The SSE `event:` field (e.g. "__event_call__") takes priority over
        // the JSON "type" field, which may hold the *inner* type ("input", "status", …)
        // rather than the outer envelope type.
        let sseType = sseEventName ?? ""
        let jsonType = json["type"] as? String ?? ""

        // Determine the effective envelope type:
        //   • If the SSE event name is a known envelope type, use it.
        //   • Otherwise fall back to the JSON "type".
        let envelopeType: String
        if sseType == "__event_emitter__" || sseType == "__event_call__" {
            envelopeType = sseType
        } else {
            envelopeType = jsonType
        }

        switch envelopeType {
        case "__event_emitter__":
            // The JSON "data" may carry the inner payload, or the JSON itself is the payload.
            if let event = parseEmitterEvent(json) {
                await onEmitter(event)
            }

        case "__event_call__":
            // When the SSE event name is __event_call__, the JSON *is* the call payload.
            // callId is optional — some servers don't send it.
            let callId = json["id"] as? String ?? json["call_id"] as? String
            if let callEvent = parseCallEvent(json) {
                let response = await onCall(callEvent)
                if let callId = callId {
                    try? await sendCallResponse(actionId: actionId, callId: callId, response: response)
                }
            }

        default:
            // Some servers nest events inside a "data" key
            if let nested = json["data"] as? [String: Any] {
                let nestedType = nested["type"] as? String ?? ""
                if nestedType == "__event_emitter__", let event = parseEmitterEvent(nested) {
                    await onEmitter(event)
                } else if nestedType == "__event_call__" {
                    let callId = nested["id"] as? String ?? json["id"] as? String
                    if let callEvent = parseCallEvent(nested) {
                        let response = await onCall(callEvent)
                        if let callId = callId {
                            try? await sendCallResponse(actionId: actionId, callId: callId, response: response)
                        }
                    }
                }
            }
            // Also handle flat status/notification/replace/message events at the top level.
            // Use if/else so a payload is not dispatched to both handlers.
            if let event = parseEmitterEvent(json) {
                await onEmitter(event)
            } else if let callEvent = parseCallEvent(json) {
                // Handles servers that send __event_call__ payloads (type: "input",
                // "confirmation", "execute") as plain data without the SSE `event:`
                // prefix — which would otherwise be silently dropped.
                let callId = json["id"] as? String ?? json["call_id"] as? String
                let response = await onCall(callEvent)
                if let callId = callId {
                    try? await sendCallResponse(actionId: actionId, callId: callId, response: response)
                }
            }
        }
    }

    // MARK: - Parsing Emitter Events

    private func parseEmitterEvent(_ json: [String: Any]) -> ActionEmitterEvent? {
        let payload = (json["data"] as? [String: Any]) ?? json
        let type_ = payload["type"] as? String ?? json["type"] as? String ?? ""

        switch type_ {
        case "status":
            let description = payload["description"] as? String ?? ""
            let done = payload["done"] as? Bool ?? false
            let action = payload["action"] as? String
            return .status(action: action, description: description, done: done)

        case "notification":
            let notifType = payload["notification_type"] as? String ?? "info"
            let message = payload["content"] as? String ?? payload["message"] as? String ?? ""
            return .notification(type: notifType, message: message)

        case "replace":
            let content = payload["content"] as? String ?? ""
            return .replace(content: content)

        case "message":
            let content = payload["content"] as? String ?? ""
            return .message(content: content)

        default:
            return nil
        }
    }

    // MARK: - Parsing Call Events

    private func parseCallEvent(_ json: [String: Any]) -> ActionCallEvent? {
        let payload = (json["data"] as? [String: Any]) ?? json
        let type_ = payload["type"] as? String ?? json["type"] as? String ?? ""

        switch type_ {
        case "input":
            let title = payload["title"] as? String ?? "Input Required"
            let message = payload["message"] as? String ?? payload["description"] as? String ?? ""
            let placeholder = payload["placeholder"] as? String ?? ""
            let defaultValue = payload["value"] as? String ?? ""
            return .input(title: title, message: message, placeholder: placeholder, defaultValue: defaultValue)

        case "confirmation":
            let title = payload["title"] as? String ?? "Confirm"
            let message = payload["message"] as? String ?? payload["description"] as? String ?? "Are you sure?"
            return .confirmation(title: title, message: message)

        case "execute":
            let code = payload["code"] as? String ?? payload["script"] as? String ?? ""
            return .execute(code: code)

        default:
            return nil
        }
    }

    // MARK: - Call Response

    /// POSTs the user's response to a `__event_call__` back to the server.
    private func sendCallResponse(
        actionId: String,
        callId: String,
        response: ActionCallResponse
    ) async throws {
        let responseValue: Any
        switch response {
        case .string(let s): responseValue = s
        case .bool(let b):   responseValue = b
        case .cancelled:     responseValue = NSNull()
        }

        let responseBody: [String: Any] = [
            "id": callId,
            "data": responseValue
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: responseBody)
        _ = try await network.requestRaw(
            path: "/api/chat/actions/\(actionId)/respond",
            method: .post,
            body: bodyData,
            authenticated: true,
            timeout: 30
        )
    }
}
