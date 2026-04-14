import Foundation

// MARK: - Analytics Group (for filter dropdown)

struct AnalyticsGroup: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String?
    let memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case memberCount = "member_count"
    }
}

// MARK: - Summary

struct AnalyticsSummary: Codable {
    let totalMessages: Int
    let totalChats: Int
    let totalModels: Int
    let totalUsers: Int

    enum CodingKeys: String, CodingKey {
        case totalMessages = "total_messages"
        case totalChats    = "total_chats"
        case totalModels   = "total_models"
        case totalUsers    = "total_users"
    }
}

// MARK: - Daily Stats

struct DailyStatsResponse: Codable {
    let data: [DailyStatPoint]
}

struct DailyStatPoint: Codable, Identifiable {
    /// ISO-8601 date string, e.g. "2026-04-10" or "2026-04-10T14:00:00"
    let date: String
    /// model_id → message count
    let models: [String: Int]

    var id: String { date }
}

// MARK: - Model Analytics

struct ModelAnalyticsResponse: Codable {
    let models: [ModelAnalytics]
}

struct ModelAnalytics: Codable, Identifiable {
    let modelId: String
    let count: Int

    var id: String { modelId }

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case count
    }
}

// MARK: - User Analytics

struct UserAnalyticsResponse: Codable {
    let users: [UserAnalytics]
}

struct UserAnalytics: Codable, Identifiable {
    let userId: String
    let name: String?
    let email: String?
    let count: Int
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int

    var id: String { userId }

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let e = email, !e.isEmpty { return e }
        return userId
    }

    enum CodingKeys: String, CodingKey {
        case userId      = "user_id"
        case name, email, count
        case inputTokens  = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens  = "total_tokens"
    }
}

// MARK: - Token Usage

struct TokenUsageResponse: Codable {
    let models: [TokenUsageModel]
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case models
        case totalInputTokens  = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
        case totalTokens       = "total_tokens"
    }
}

struct TokenUsageModel: Codable, Identifiable {
    let modelId: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let messageCount: Int

    var id: String { modelId }

    enum CodingKeys: String, CodingKey {
        case modelId      = "model_id"
        case inputTokens  = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens  = "total_tokens"
        case messageCount = "message_count"
    }
}

// MARK: - Time Range

enum AnalyticsTimeRange: String, CaseIterable, Identifiable {
    case last24Hours = "Last 24 hours"
    case last7Days   = "Last 7 days"
    case last30Days  = "Last 30 days"
    case last90Days  = "Last 90 days"
    case allTime     = "All time"

    var id: String { rawValue }

    /// Epoch timestamp for start_date, nil = no filter (all time)
    var startEpoch: Int? {
        let now = Date()
        switch self {
        case .last24Hours: return Int(now.addingTimeInterval(-86_400).timeIntervalSince1970)
        case .last7Days:   return Int(now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970)
        case .last30Days:  return Int(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        case .last90Days:  return Int(now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970)
        case .allTime:     return nil
        }
    }

    var endEpoch: Int? {
        self == .allTime ? nil : Int(Date().timeIntervalSince1970)
    }

    var granularity: String {
        self == .last24Hours ? "hourly" : "daily"
    }
}
