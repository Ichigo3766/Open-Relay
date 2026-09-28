import Foundation
import Observation

/// Consent is local to this chat, never a server preference or an automatic approval.
@MainActor @Observable
final class WebSearchConsent {
    struct Prompt: Identifiable {
        let id: UUID
        let message: String
    }

    private(set) var prompt: Prompt?
    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private var policy: BackendConfig.BackendFeatures?
    @ObservationIgnored private var loadedPolicy = false
    @ObservationIgnored private var confirmed = false
    @ObservationIgnored private var attempt: UUID?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    func request(using api: APIClient) async throws -> Bool {
        guard attempt == nil else { return false }
        let id = UUID()
        attempt = id
        defer { if attempt == id { attempt = nil } }
        if !loadedPolicy {
            let features: BackendConfig.BackendFeatures?
            do { features = try await api.getBackendConfig().features }
            catch {
                guard attempt == id, !Task.isCancelled else { return false }
                throw error
            }
            guard attempt == id, !Task.isCancelled else { return false }
            policy = features
            loadedPolicy = true
        }
        guard !Task.isCancelled else { return false }
        guard policy?.enableWebSearchConfirmation == true, !confirmed else { return true }
        let content = policy?.webSearchConfirmationContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { reply in
                guard !Task.isCancelled, attempt == id else { reply.resume(returning: false); return }
                continuation = reply
                prompt = Prompt(id: id, message: content.isEmpty
                    ? "Your query will be sent to the configured web search provider." : content)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: id, approved: false) }
        }
        return approved && attempt == id && !Task.isCancelled
    }

    func resolve(id: UUID, approved: Bool) {
        guard prompt?.id == id else { return }
        confirmed = approved
        let reply = continuation
        continuation = nil
        prompt = nil
        reply?.resume(returning: approved)
    }

    func reset() {
        cancelPending()
        confirmed = false
        policy = nil
        loadedPolicy = false
    }

    func cancelPending() {
        revision &+= 1
        if let prompt { resolve(id: prompt.id, approved: false) }
        attempt = nil
    }
}
