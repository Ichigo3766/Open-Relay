import Foundation

struct ChannelWebhook: Decodable, Identifiable {
    let id: String
    let channelId: String
    let name: String
    let token: String
    let profileImageURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, token
        case channelId = "channel_id"
        case profileImageURL = "profile_image_url"
    }

    func postingURL(serverURL: String) -> URL? {
        guard var url = URLComponents(string: serverURL),
              ["https", "http"].contains(url.scheme ?? ""), url.host != nil else { return nil }
        url.query = nil
        url.fragment = nil
        url.user = nil
        url.password = nil
        return url.url?.appendingPathComponent("api/v1/channels/webhooks")
            .appendingPathComponent(id).appendingPathComponent(token)
    }
}
