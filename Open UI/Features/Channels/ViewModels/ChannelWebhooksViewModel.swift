import Foundation

@Observable @MainActor
final class ChannelWebhooksViewModel {
    let apiClient: APIClient
    let channelId: String
    private let scope: String?
    var webhooks: [ChannelWebhook] = []
    var isBusy = false
    var errorMessage: String?

    init(apiClient: APIClient, channelId: String) {
        self.apiClient = apiClient
        self.channelId = channelId
        scope = apiClient.network.conversationCacheScope
    }

    private func checkScope() throws {
        guard scope == apiClient.network.conversationCacheScope else {
            webhooks = []
            throw APIError.cancelled
        }
    }

    func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try checkScope()
            let fetched = try await apiClient.getChannelWebhooks(channelId: channelId)
            try checkScope()
            webhooks = fetched
            errorMessage = nil
        } catch {
            webhooks = []
            errorMessage = error.localizedDescription
        }
    }

    func save(_ webhook: ChannelWebhook?, name: String) async throws {
        guard !isBusy else { throw APIError.cancelled }
        try checkScope()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NSError(domain: "ChannelWebhook", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Enter a webhook name."])
        }
        isBusy = true
        defer { isBusy = false }
        let saved = try await apiClient.saveChannelWebhook(channelId: channelId, webhook: webhook, name: name)
        try checkScope()
        webhooks.removeAll { $0.id == saved.id }
        webhooks.append(saved)
        errorMessage = nil
    }

    func delete(_ webhook: ChannelWebhook) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try checkScope()
            try await apiClient.deleteChannelWebhook(channelId: channelId, webhookId: webhook.id)
            try checkScope()
            webhooks.removeAll { $0.id == webhook.id }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func postingURL(for webhook: ChannelWebhook) -> URL? {
        guard (try? checkScope()) != nil else { return nil }
        return webhook.postingURL(serverURL: apiClient.baseURL)
    }
}
