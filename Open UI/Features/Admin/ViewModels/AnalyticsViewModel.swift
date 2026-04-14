import Foundation
import os.log

/// Manages all analytics data for the Admin Analytics dashboard.
@Observable
final class AnalyticsViewModel {

    // MARK: - Filter State

    var selectedTimeRange: AnalyticsTimeRange = .last24Hours
    var selectedGroup: AnalyticsGroup? = nil   // nil = All Users

    // MARK: - Data

    var summary: AnalyticsSummary?
    var dailyStats: [DailyStatPoint] = []
    var modelStats: [ModelAnalytics] = []
    var userStats: [UserAnalytics] = []
    var tokenStats: TokenUsageResponse?
    var groups: [AnalyticsGroup] = []

    // MARK: - Loading / Error

    var isLoading = false
    var errorMessage: String?

    // MARK: - Private

    private weak var apiClient: APIClient?
    private let logger = Logger(subsystem: "com.openui", category: "Analytics")

    // MARK: - Configure

    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Load All

    /// Loads all analytics data in parallel, then loads groups.
    func loadAll() async {
        guard let api = apiClient else {
            errorMessage = "No server connection."
            return
        }

        isLoading = true
        errorMessage = nil

        let startDate = selectedTimeRange.startEpoch
        let endDate   = selectedTimeRange.endEpoch
        let groupId   = selectedGroup?.id
        let granularity = selectedTimeRange.granularity

        do {
            async let summaryReq  = api.getAnalyticsSummary(startDate: startDate, endDate: endDate, groupId: groupId)
            async let dailyReq    = api.getAnalyticsDaily(startDate: startDate, endDate: endDate, groupId: groupId, granularity: granularity)
            async let modelsReq   = api.getAnalyticsModels(startDate: startDate, endDate: endDate, groupId: groupId)
            async let usersReq    = api.getAnalyticsUsers(startDate: startDate, endDate: endDate, groupId: groupId)
            async let tokensReq   = api.getAnalyticsTokens(startDate: startDate, endDate: endDate, groupId: groupId)

            let (s, d, m, u, t) = try await (summaryReq, dailyReq, modelsReq, usersReq, tokensReq)

            summary    = s
            dailyStats = d.data
            modelStats = m.models.sorted { $0.count > $1.count }
            userStats  = u.users
            tokenStats = t

            logger.info("Analytics loaded: \(s.totalMessages) msgs, \(d.data.count) daily points, \(m.models.count) models, \(u.users.count) users")
        } catch {
            let apiError = APIError.from(error)
            errorMessage = apiError.errorDescription ?? "Failed to load analytics."
            logger.error("Analytics load failed: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Loads group list for the filter dropdown.
    func loadGroups() async {
        guard let api = apiClient else { return }
        do {
            groups = try await api.getAnalyticsGroups()
            logger.info("Loaded \(self.groups.count) groups")
        } catch {
            // Non-fatal: groups filter is optional
            logger.warning("Failed to load groups: \(error.localizedDescription)")
        }
    }

    // MARK: - Chart Helpers

    /// ISO-8601 parsers — handles both "2026-04-10" and "2026-04-10T14:00:00"
    private static let isoDateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func parseDate(_ string: String) -> Date {
        if let d = isoDateTimeFormatter.date(from: string) { return d }
        if let d = isoDateOnlyFormatter.date(from: string) { return d }
        return Date()
    }

    /// All unique model IDs that appear across daily data points.
    var chartModelIds: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for point in dailyStats {
            for key in point.models.keys {
                if seen.insert(key).inserted {
                    result.append(key)
                }
            }
        }
        // Sort by total count descending so top models get first colors
        return result.sorted { a, b in
            let sumA = dailyStats.reduce(0) { $0 + ($1.models[a] ?? 0) }
            let sumB = dailyStats.reduce(0) { $0 + ($1.models[b] ?? 0) }
            return sumA > sumB
        }
    }

    /// Flattened data series for Swift Charts.
    struct ChartPoint: Identifiable {
        let id = UUID()
        let modelId: String
        let date: Date
        let count: Int
    }

    /// Returns all model counts at the nearest date point to `target`, sorted by count descending.
    func dataAtDate(_ target: Date) -> [(modelId: String, count: Int)] {
        guard !dailyStats.isEmpty else { return [] }
        // Find the closest daily stat point to the target date
        let nearest = dailyStats.min(by: { a, b in
            let dA = abs(AnalyticsViewModel.parseDate(a.date).timeIntervalSince(target))
            let dB = abs(AnalyticsViewModel.parseDate(b.date).timeIntervalSince(target))
            return dA < dB
        })
        guard let point = nearest else { return [] }
        return point.models
            .map { (modelId: $0.key, count: $0.value) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
    }

    /// The parsed Date for a nearest data point to `target` (used for tooltip title).
    func dateForNearest(_ target: Date) -> Date? {
        guard let nearest = dailyStats.min(by: { a, b in
            let dA = abs(AnalyticsViewModel.parseDate(a.date).timeIntervalSince(target))
            let dB = abs(AnalyticsViewModel.parseDate(b.date).timeIntervalSince(target))
            return dA < dB
        }) else { return nil }
        return AnalyticsViewModel.parseDate(nearest.date)
    }

    var chartPoints: [ChartPoint] {
        let allModelIds = chartModelIds
        var points: [ChartPoint] = []
        for point in dailyStats {
            let date = AnalyticsViewModel.parseDate(point.date)
            for modelId in allModelIds {
                let count = point.models[modelId] ?? 0
                points.append(ChartPoint(modelId: modelId, date: date, count: count))
            }
        }
        return points
    }

    /// Total token count from token stats (falls back to summary if no token data).
    var totalTokens: Int {
        tokenStats?.totalTokens ?? (summary?.totalMessages ?? 0)
    }

    /// Formatted large number string: 1,234,567 → "1.2M", 930000 → "930.0K"
    static func formatted(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }
}
