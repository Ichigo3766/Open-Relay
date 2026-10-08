import Foundation
import Observation
import WatchKit

/// Runs one prompt → reply exchange with the iPhone and exposes its
/// progress to the UI. Used by typed/dictated asks and by voice mode.
@MainActor @Observable
final class TurnController {

    enum Phase: Equatable {
        case idle
        case sending
        case transcribing
        case thinking
        case streaming
        case done
        case failed(String)
    }

    var phase: Phase = .idle
    var prompt: String?
    var reply = ""
    var chatId: String?
    var chatTitle: String?
    /// The reply is being read aloud (on the watch or the iPhone).
    var isSpeaking = false
    var speaksOnPhone = false
    /// Server-suggested next questions (tap to ask).
    var followUps: [String] = []
    /// The user's words while / right after they speak.
    var liveTranscript: String?

    @ObservationIgnored var turnId = 0
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var nextSentence = 0
    @ObservationIgnored var speakThisTurn = false
    @ObservationIgnored let speaker = ReplySpeaker.shared
    @ObservationIgnored var hapticForFirstText = true

    init(chatId: String? = nil, chatTitle: String? = nil) {
        self.chatId = chatId
        self.chatTitle = chatTitle
    }

    var isBusy: Bool {
        switch phase {
        case .sending, .transcribing, .thinking, .streaming: return true
        default: return false
        }
    }

    /// Unique per turn, so the iPhone never mixes turns up.
    static func newTurnId() -> Int {
        let base = Int(Int64(Date().timeIntervalSince1970 * 10) % 100_000_000)
        return base * 10 + Int.random(in: 0...9)
    }

    // MARK: - Asking

    func ask(_ text: String, modelId: String?, speak: Bool, voice: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        begin(prompt: trimmed, speak: speak)
        WidgetBridge.setReplyInProgress(true)
        WKInterfaceDevice.current().play(.click)
        let id = turnId
        let request = WatchAskRequest(turnId: id, chatId: chatId, text: trimmed,
                                      modelId: chatId == nil ? modelId : nil, voice: voice, speak: speak,
                                      serverVoice: WatchStore.shared.usesServerVoice)
        pollTask = Task { [weak self] in
            do {
                let state = try await WatchLink.shared.request(.ask, request, as: WatchTurnState.self)
                guard let self, self.turnId == id else { return }
                self.apply(state)
                await self.pollUntilDone(id)
            } catch {
                self?.fail(error, turn: id)
            }
        }
    }

    /// Prepares for a voice turn (shows "sending" while audio uploads).
    func beginVoiceTurn(speak: Bool) -> Int {
        begin(prompt: nil, speak: speak)
        return turnId
    }

    /// Called by voice mode once the recorded utterance is fully delivered.
    func startedVoiceTurn(_ id: Int, state: WatchTurnState) {
        guard turnId == id else { return }
        WidgetBridge.setReplyInProgress(true)
        apply(state)
        pollTask = Task { [weak self] in await self?.pollUntilDone(id) }
    }

    /// While the user is still speaking: ask the iPhone for live words.
    func pollLiveTranscript(_ id: Int) async {
        while !Task.isCancelled, turnId == id {
            try? await Task.sleep(for: .milliseconds(600))
            guard turnId == id, !Task.isCancelled else { return }
            if let state = try? await WatchLink.shared.request(.liveTranscript, WatchLiveRequest(turnId: id),
                                                               as: WatchTurnState.self, attempts: 1),
               let partial = state.partialTranscript, !partial.isEmpty, turnId == id {
                liveTranscript = partial
            }
        }
    }

    func fail(message: String) {
        phase = .failed(message)
        WKInterfaceDevice.current().play(.failure)
    }

    func cancel() {
        let id = turnId
        pollTask?.cancel()
        pollTask = nil
        speaker.stop()
        isSpeaking = false
        if isBusy || speaksOnPhone {
            Task {
                do {
                    let envelope = try WatchEnvelope.make(.cancelTurn, payload: WatchTurnRequest(turnId: id))
                    _ = try? await WatchLink.shared.sendWithRetry(envelope, attempts: 1)
                } catch {
                    // Best effort: the phone also times out an abandoned turn.
                }
            }
        }
        if isBusy { phase = reply.isEmpty ? .idle : .done }
        speaksOnPhone = false
        WidgetBridge.setReplyInProgress(false)
    }

    /// Clears the reply to start a fresh chat.
    func reset() {
        cancel()
        chatId = nil
        chatTitle = nil
        prompt = nil
        reply = ""
        phase = .idle
    }

    func begin(prompt: String?, speak: Bool) {
        pollTask?.cancel()
        speaker.stop()
        turnId = Self.newTurnId()
        speaker.begin(turnId: turnId, serverVoice: WatchStore.shared.usesServerVoice)
        self.prompt = prompt
        reply = ""
        followUps = []
        liveTranscript = nil
        nextSentence = 0
        speakThisTurn = speak
        speaksOnPhone = false
        isSpeaking = false
        hapticForFirstText = true
        phase = .sending
    }

    func fail(_ error: Error, turn id: Int) {
        guard turnId == id else { return }
        phase = .failed(error.localizedDescription)
        WKInterfaceDevice.current().play(.failure)
    }
}
