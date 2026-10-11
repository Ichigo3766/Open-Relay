import Foundation
import AVFoundation

/// Authenticated server bridge: voice audio stays on the call connection, while
/// delegated requests use the chat's existing model, tools and approval flow.
@MainActor
final class RealtimeCallSession {
    let audioEngine = CallAudioEngine()
    private let api: APIClient
    private let chat: ChatViewModel
    private let player: CallAudioPlayer
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var micTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var inputs: Set<String> = []
    private var ownedMessageID: String?
    private var replyTask: Task<Void, Never>?
    private var modelID = ""
    private var stopped = false
    private var ready = false
    private var muted = false
    private var paused = false
    private var responseID: String?
    private var playback: RealtimePlaybackPosition?
    private var interrupted: Set<String> = []
    private var finished: Set<String> = []
    private var calls: Set<String> = []
    private var pendingResults: [String: String] = [:]
    private var animationResponses: Set<String> = []
    private var ownsReply = false
    private var partialTranscript = ""

    var onState: ((VoiceCallViewModel.CallState) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?

    init(api: APIClient, chat: ChatViewModel) {
        self.api = api
        self.chat = chat
        self.player = CallAudioPlayer(engine: audioEngine)
        player.onStarted = { [weak self] in self?.onState?(.speaking) }
        player.onFinished = { [weak self] in
            guard let self, !self.stopped else { return }
            self.playback = nil
            self.onState?(self.paused ? .paused : .listening)
        }
        audioEngine.onRebuilt = { [weak self] in Task { await self?.interrupt() } }
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }

    func start() async throws {
        guard let model = chat.selectedModel, model.rawModelItem?["direct"] as? Bool != true else {
            throw Failure.message("Select a server-configured chat model for Realtime calls.")
        }
        guard try await api.getBackendConfig().audio?.realtime?.enabled == true else {
            throw Failure.message("Enable Realtime calls in the server's Audio settings first.")
        }
        guard !stopped else { throw CancellationError() }
        guard let token = api.network.authToken else { throw Failure.message("Sign in again to start a Realtime call.") }
        modelID = model.id
        var request = try api.network.buildRequest(path: "/api/v1/audio/realtime", timeout: 30)
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure.message("The call server address is invalid.")
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        let socket = api.network.session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        var auth: [String: Any] = ["type": "auth", "token": token, "model_id": modelID]
        if let id = chat.conversationId, !chat.isTemporaryChat { auth["chat_id"] = id }
        try await send(auth)
        guard !stopped else { throw CancellationError() }
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    try await self.handle(event)
                }
            } catch { if !self.stopped { self.fail("The Realtime call connection closed. Start a new call to reconnect.") } }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, !self.ready else { return }
            self.fail("The Realtime call did not connect. Check the server's voice configuration and try again.")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        receiveTask?.cancel()
        micTask?.cancel()
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
        replyTask?.cancel()
        stopOwnedReply()
        ownsReply = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        player.stopImmediately()
        audioEngine.stop()
    }

    func setMuted(_ value: Bool) { muted = value; audioEngine.isMicMuted = muted || paused }

    func setPaused(_ value: Bool) {
        paused = value
        audioEngine.isMicMuted = muted || paused
        Task {
            do {
                if value { await interrupt() }
                try await send(["type": "input_audio_buffer.clear"])
                if !stopped { onState?(value ? .paused : .listening) }
            } catch { fail("Could not update the Realtime call. Start a new call to reconnect.") }
        }
    }

    func audioRouteChanged() { player.refreshRoute() }

    func interrupt() async {
        let position = playback
        let time = audioEngine.playerNode.lastRenderTime.flatMap { audioEngine.playerNode.playerTime(forNodeTime: $0) }
        let milliseconds = position?.heardMilliseconds(currentSample: time?.sampleTime ?? 0, outputRate: time?.sampleRate ?? 0) ?? 0
        player.stopImmediately()
        playback = nil
        do {
            if let responseID, !finished.contains(responseID), interrupted.insert(responseID).inserted {
                try await send(["type": "response.cancel", "response_id": responseID])
            }
            if let position {
                try await send(["type": "conversation.item.truncate", "item_id": position.itemID,
                                "content_index": position.contentIndex, "audio_end_ms": milliseconds])
            }
        } catch { if !stopped { fail("Could not interrupt the Realtime call. Start a new call to reconnect.") } }
    }

    private func stopOwnedReply() {
        if ownsReply, let ownedMessageID,
           chat.streamingStore.streamingMessageId == ownedMessageID || chat.messages.last?.id == ownedMessageID {
            chat.stopStreaming(stopAllChatTasks: false)
        }
    }

    private func send(_ event: [String: Any]) async throws {
        guard !stopped, let socket else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func handle(_ event: [String: Any]) async throws {
        guard !stopped, let type = event["type"] as? String else { return }
        switch type {
        case "bridge.ready":
            guard !ready, event["sample_rate"] as? Int == 24000 else { throw Failure.message("Unsupported call audio format.") }
            ready = true
            timeoutTask?.cancel()
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(20))
                        try await self?.send(["type": "bridge.ping"])
                    } catch {
                        if let self, !self.stopped { self.fail("The Realtime call connection was lost. Start a new call to reconnect.") }
                        return
                    }
                }
            }
            try await sendContext()
            let frames = try audioEngine.start(sampleRate: RealtimeCallWire.sampleRate)
            audioEngine.isMicMuted = muted || paused
            micTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for await frame in frames {
                        guard !Task.isCancelled, !self.stopped else { return }
                        self.onLevel?(self.muted || self.paused ? 0 : frame.rms)
                        guard !self.muted, !self.paused else { continue }
                        let pcm = RealtimeCallWire.pcm(frame.vadSamples)
                        for offset in stride(from: 0, to: pcm.count, by: 48000) {
                            try await self.send(["type": "input_audio_buffer.append", "audio": pcm.subdata(in: offset..<min(offset + 48000, pcm.count)).base64EncodedString()])
                        }
                    }
                } catch { if !self.stopped { self.fail("Could not send microphone audio. Start a new call to reconnect.") } }
            }
            onState?(paused ? .paused : .listening)
        case "bridge.error": fail(event["message"] as? String ?? "The server could not start this call.")
        case "input_audio_buffer.speech_started":
            if !paused { await interrupt(); partialTranscript = ""; onTranscript?(""); onState?(.listening) }
        case "conversation.item.input_audio_transcription.delta":
            if !paused, let delta = event["delta"] as? String { partialTranscript += delta; onTranscript?(partialTranscript) }
        case "conversation.item.input_audio_transcription.completed":
            guard !paused, let id = event["item_id"] as? String, let text = event["transcript"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, inputs.insert(id).inserted else { return }
            onTranscript?(text)
            onState?(.processing)
            try await send(["type": "bridge.respond", "item_id": id])
        case "response.created":
            responseID = (event["response"] as? [String: Any])?["id"] as? String
            playback = nil
            player.beginSession()
        case "response.output_audio.delta":
            guard !paused, let id = event["response_id"] as? String, id == responseID, !interrupted.contains(id),
                  let item = event["item_id"] as? String, let index = event["content_index"] as? Int,
                  let delta = event["delta"] as? String, let samples = RealtimeCallWire.samples(delta) else { return }
            if playback?.itemID != item || playback?.contentIndex != index {
                let time = audioEngine.playerNode.lastRenderTime.flatMap { audioEngine.playerNode.playerTime(forNodeTime: $0) }
                playback = RealtimePlaybackPosition(itemID: item, contentIndex: index, startSample: time?.sampleTime ?? 0)
            }
            playback?.receivedSamples += samples.count
            player.scheduleChunk(samples, sampleRate: RealtimeCallWire.sampleRate, sentence: "")
        case "response.output_audio.done":
            if event["response_id"] as? String == responseID { player.finishSession(lastSentence: "") }
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any], item["type"] as? String == "function_call",
                  item["status"] as? String == "completed", let callID = item["call_id"] as? String,
                  calls.insert(callID).inserted, let response = event["response_id"] as? String else { return }
            if item["name"] as? String == "play_animation" {
                try await send(["type": "bridge.animation.result", "call_id": callID, "status": "unavailable"])
                animationResponses.insert(response)
                if finished.contains(response) { try await finishAnimations(response) }
            } else if item["name"] as? String == "generate_chat_completion" {
                guard let arguments = item["arguments"] as? String, let request = RealtimeCallWire.request(arguments) else {
                    try await result(callID, response: response, status: "failed", answer: "Could not read the delegated chat request.")
                    return
                }
                if paused || interrupted.contains(response) {
                    try await result(callID, response: response, status: "cancelled", answer: "The call was paused or interrupted.")
                } else {
                    delegate(request, callID: callID, response: response)
                }
            }
        case "response.done":
            guard let response = (event["response"] as? [String: Any])?["id"] as? String else { return }
            finished.insert(response)
            try await finishAnimations(response)
            for (callID, origin) in pendingResults where origin == response { try await respondToResult(callID, response: origin) }
            if response == responseID, !player.isSpeaking, replyTask == nil { onState?(paused ? .paused : .listening) }
        default: break
        }
    }

    private func delegate(_ request: String, callID: String, response: String) {
        guard replyTask == nil, !chat.isStreaming, chat.selectedModelId == modelID else {
            Task { try? await result(callID, response: response, status: "deferred", answer: "The chat is busy or its selected model changed. Open the chat before continuing.") }
            return
        }
        replyTask = Task { [weak self] in
            guard let self else { return }
            defer { self.replyTask = nil; self.ownsReply = false }
            let known = ResponseTextStream.assistantIds(in: chat)
            let accepted = await chat.sendMessage(directText: request)
            if accepted {
                ownsReply = true
                ownedMessageID = chat.messages.last { $0.role == .assistant && !known.contains($0.id) }?.id
            }
            guard !Task.isCancelled, !stopped else { stopOwnedReply(); return }
            guard accepted else {
                try? await result(callID, response: response, status: "deferred", answer: CallOrchestrator.message(for: chat.lastSendBlockReason, chat: chat))
                return
            }
            var answer = ""
            for await text in ResponseTextStream.stream(for: chat, knownAssistantIds: known, sendFinished: { true }) {
                guard !Task.isCancelled, !stopped else { return }
                answer = text
            }
            guard !Task.isCancelled, !stopped else { return }
            do {
                try await sendContext()
                try await result(callID, response: response, status: chat.pendingToolApprovalCall != nil ? "deferred" : (chat.errorMessage == nil && !answer.isEmpty ? "completed" : "failed"),
                                 answer: String((chat.errorMessage ?? answer).prefix(100000)))
            } catch { if !stopped { fail("Could not deliver the chat result to the call. The result remains in the chat.") } }
        }
    }

    private func result(_ callID: String, response: String, status: String, answer: String) async throws {
        try await send(["type": "bridge.result", "call_id": callID, "status": status, "answer": answer])
        pendingResults[callID] = response
        if finished.contains(response) { try await respondToResult(callID, response: response) }
    }

    private func respondToResult(_ callID: String, response: String) async throws {
        pendingResults.removeValue(forKey: callID)
        guard !paused, !interrupted.contains(response) else { return }
        try await send(["type": "bridge.respond", "call_id": callID])
    }

    private func finishAnimations(_ response: String) async throws {
        guard animationResponses.remove(response) != nil, !interrupted.contains(response) else { return }
        try await send(["type": "bridge.animation.respond", "response_id": response])
    }

    private func sendContext() async throws {
        let messages = chat.messages.map { (role: $0.role.rawValue, content: $0.content) }
        try await send(["type": "bridge.context", "messages": RealtimeCallWire.context(messages)])
    }

    private func fail(_ message: String) { stop(); onError?(message) }
}
