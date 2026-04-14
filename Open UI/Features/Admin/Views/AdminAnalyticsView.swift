import SwiftUI
import Charts

// MARK: - Admin Analytics View

struct AdminAnalyticsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AnalyticsViewModel()

    // Chart interaction
    @State private var selectedDate: Date? = nil

    // Chart palette — consistent across the dashboard
    private let chartColors: [Color] = [
        .blue, .orange, .green, .red, .purple,
        .yellow, .cyan, .pink, .mint, .indigo
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Filter bar
                filterBar
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.sm)

                // Error banner
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                        .padding(.horizontal, Spacing.screenPadding)
                }

                // Summary stats
                summaryStats
                    .padding(.horizontal, Spacing.screenPadding)

                // Daily Messages Chart
                dailyChart
                    .padding(.horizontal, Spacing.screenPadding)

                // Tables row
                tablesSection
                    .padding(.horizontal, Spacing.screenPadding)

                // Footer note
                Text("Message counts are based on assistant responses.")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, Spacing.lg)
            }
        }
        .refreshable {
            await viewModel.loadAll()
        }
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            async let groups: () = viewModel.loadGroups()
            async let all: () = viewModel.loadAll()
            _ = await (groups, all)
        }
        .overlay {
            if viewModel.isLoading && viewModel.summary == nil {
                loadingOverlay
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: Spacing.sm) {
            // Group picker
            Menu {
                Button("All Users") {
                    viewModel.selectedGroup = nil
                    Task { await viewModel.loadAll() }
                }
                ForEach(viewModel.groups) { group in
                    Button(group.name) {
                        viewModel.selectedGroup = group
                        Task { await viewModel.loadAll() }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(viewModel.selectedGroup?.name ?? "All Users")
                        .scaledFont(size: 14, weight: .medium)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 11, weight: .semibold)
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
            }

            Spacer()

            // Time range picker
            Menu {
                ForEach(AnalyticsTimeRange.allCases) { range in
                    Button {
                        viewModel.selectedTimeRange = range
                        Task { await viewModel.loadAll() }
                    } label: {
                        HStack {
                            Text(range.rawValue)
                            if viewModel.selectedTimeRange == range {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(viewModel.selectedTimeRange.rawValue)
                        .scaledFont(size: 14, weight: .medium)
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 11, weight: .semibold)
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Summary Stats

    private var summaryStats: some View {
        HStack(spacing: Spacing.sm) {
            statCard(
                title: "Messages",
                value: AnalyticsViewModel.formatted(viewModel.summary?.totalMessages ?? 0),
                icon: "message.fill",
                color: theme.brandPrimary
            )
            statCard(
                title: "Tokens",
                value: AnalyticsViewModel.formatted(viewModel.totalTokens),
                icon: "bolt.fill",
                color: .orange
            )
            statCard(
                title: "Chats",
                value: AnalyticsViewModel.formatted(viewModel.summary?.totalChats ?? 0),
                icon: "bubble.left.and.bubble.right.fill",
                color: .green
            )
            statCard(
                title: "Users",
                value: "\(viewModel.summary?.totalUsers ?? 0)",
                icon: "person.2.fill",
                color: .purple
            )
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(color)
                Text(title)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
            Text(value)
                .scaledFont(size: 18, weight: .bold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Daily Messages Chart

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(viewModel.selectedTimeRange == .last24Hours ? "Hourly Messages" : "Daily Messages")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)

            if viewModel.chartPoints.isEmpty && !viewModel.isLoading {
                emptyChartPlaceholder
            } else {
                Chart {
                    // Main data lines
                    ForEach(viewModel.chartPoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Messages", point.count)
                        )
                        .foregroundStyle(by: .value("Model", shortModelName(point.modelId)))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }

                    // Interactive — vertical rule + highlight points at selected date
                    if let sel = selectedDate {
                        let nearestDate = viewModel.dateForNearest(sel) ?? sel
                        let tooltipData = viewModel.dataAtDate(sel)

                        RuleMark(x: .value("Selected", nearestDate))
                            .foregroundStyle(theme.textTertiary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(
                                position: annotationPosition(for: nearestDate),
                                spacing: 8,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                            ) {
                                chartTooltip(date: nearestDate, data: tooltipData)
                            }

                        // Highlight dots on each line at the selected x
                        ForEach(Array(tooltipData.prefix(10).enumerated()), id: \.offset) { idx, entry in
                            PointMark(
                                x: .value("Date", nearestDate),
                                y: .value("Messages", entry.count)
                            )
                            .foregroundStyle(by: .value("Model", shortModelName(entry.modelId)))
                            .symbolSize(30)
                        }
                    }
                }
                // Chart tap interaction — only enabled for daily/weekly/monthly/all-time ranges.
                // Hourly (24h) data points are too densely packed for reliable tap/drag,
                // so we disable the overlay entirely for that range.
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        if viewModel.selectedTimeRange != .last24Hours {
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            let origin = geo[proxy.plotFrame!].origin
                                            let x = value.location.x - origin.x
                                            if let date: Date = proxy.value(atX: x) {
                                                selectedDate = date
                                            }
                                        }
                                        .onEnded { _ in
                                            // Keep tooltip visible after finger lifts
                                        }
                                )
                        }
                    }
                }
                .chartForegroundStyleScale(range: chartColorRange)
                .chartXAxis {
                    AxisMarks(values: .stride(by: xAxisCalendarComponent, count: xAxisStrideCount)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                            .foregroundStyle(theme.textTertiary.opacity(0.3))
                        AxisValueLabel(format: xAxisDateFormat)
                            .foregroundStyle(theme.textTertiary)
                            .font(.system(size: 10))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                            .foregroundStyle(theme.textTertiary.opacity(0.3))
                        AxisValueLabel()
                            .foregroundStyle(theme.textTertiary)
                            .font(.system(size: 10))
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading) {
                    legendView
                }
                .frame(height: 200)
                .redacted(reason: viewModel.isLoading ? .placeholder : [])
            }
        }
        .padding(Spacing.md)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
    }

    /// Floating tooltip card shown when a data point is selected on the chart
    private func chartTooltip(date: Date, data: [(modelId: String, count: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Date header
            Text(tooltipDateString(date))
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(theme.textSecondary)

            if data.isEmpty {
                Text("No activity")
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(Array(data.prefix(6).enumerated()), id: \.offset) { idx, entry in
                    let colorIdx = modelColorIndex(entry.modelId)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(chartColors[colorIdx % chartColors.count])
                            .frame(width: 6, height: 6)
                        Text(shortModelName(entry.modelId))
                            .scaledFont(size: 11)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(entry.count)")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .fill(theme.surfaceContainer)
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .frame(minWidth: 130, maxWidth: 180)
    }

    /// Determine whether annotation should appear on left or right side of rule line
    private func annotationPosition(for date: Date) -> AnnotationPosition {
        guard let first = viewModel.chartPoints.first?.date,
              let last = viewModel.chartPoints.last?.date else { return .trailing }
        let total = last.timeIntervalSince(first)
        guard total > 0 else { return .trailing }
        let progress = date.timeIntervalSince(first) / total
        return progress > 0.6 ? .leading : .trailing
    }

    private func tooltipDateString(_ date: Date) -> String {
        if viewModel.selectedTimeRange == .last24Hours {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }

    /// Returns the color index for a given modelId based on its rank in chartModelIds
    private func modelColorIndex(_ modelId: String) -> Int {
        viewModel.chartModelIds.firstIndex(of: modelId) ?? 0
    }

    private var legendView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(viewModel.chartModelIds.prefix(10).enumerated()), id: \.element) { idx, modelId in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(chartColors[idx % chartColors.count])
                            .frame(width: 7, height: 7)
                        Text(shortModelName(modelId))
                            .scaledFont(size: 10)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private var emptyChartPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .fill(theme.background.opacity(0.4))
                .frame(height: 180)
            VStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .scaledFont(size: 32)
                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                Text("No data for selected period")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    // MARK: - Tables Section

    private var tablesSection: some View {
        VStack(spacing: Spacing.md) {
            modelUsageTable
            userActivityTable
        }
    }

    // MARK: - Model Usage Table

    // 3️⃣ REDESIGNED TABLE — horizontally scrollable with proper column widths
    private var modelUsageTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            tableHeader(title: "Model Usage", subtitle: nil)

            if viewModel.modelStats.isEmpty && !viewModel.isLoading {
                tableEmptyState(icon: "cpu", text: "No model data")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Column headers
                        HStack(spacing: 0) {
                            Text("#")
                                .frame(width: 28, alignment: .leading)
                            Text("MODEL")
                                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, Spacing.xs)
                            Text("MESSAGES")
                                .frame(width: 88, alignment: .trailing)
                            Text("TOKENS")
                                .frame(width: 88, alignment: .trailing)
                            Text("%")
                                .frame(width: 60, alignment: .trailing)
                        }
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 8)
                        .background(theme.background.opacity(0.5))

                        Divider().background(theme.cardBorder)

                        ForEach(Array(viewModel.modelStats.prefix(10).enumerated()), id: \.element.id) { idx, model in
                            modelRow(rank: idx + 1, model: model)
                            if idx < min(viewModel.modelStats.count, 10) - 1 {
                                Divider()
                                    .padding(.leading, Spacing.md)
                                    .background(theme.cardBorder.opacity(0.5))
                            }
                        }
                    }
                }
            }
        }
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .redacted(reason: viewModel.isLoading && viewModel.modelStats.isEmpty ? .placeholder : [])
    }

    private func modelRow(rank: Int, model: ModelAnalytics) -> some View {
        let tokenData = tokenDataForModel(model.modelId)
        let tokens = tokenData?.totalTokens ?? 0
        let total = totalModelMessages
        let pct = total > 0 ? Double(model.count) / Double(total) * 100.0 : 0.0

        return HStack(spacing: 0) {
            // Rank
            Text("\(rank)")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 28, alignment: .leading)

            // MODEL AVATAR — uses the per-model profile image endpoint (same as ModelSelectorSheet)
            HStack(spacing: 8) {
                ModelAvatar(
                    size: 26,
                    imageURL: modelAvatarURL(for: model.modelId),
                    label: shortModelName(model.modelId),
                    authToken: dependencies.apiClient?.network.authToken
                )
                Text(shortModelName(model.modelId))
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Spacing.xs)

            // Messages
            Text("\(model.count)")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

            // Tokens
            Text(AnalyticsViewModel.formatted(tokens))
                .scaledFont(size: 13)
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

            // Percentage
            Text(String(format: "%.1f%%", pct))
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    // MARK: - User Activity Table

    private var userActivityTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            tableHeader(title: "User Activity", subtitle: nil)

            if viewModel.userStats.isEmpty && !viewModel.isLoading {
                tableEmptyState(icon: "person.2", text: "No user data")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Column headers
                        HStack(spacing: 0) {
                            Text("#")
                                .frame(width: 28, alignment: .leading)
                            Text("USER")
                                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, Spacing.xs)
                            Text("MESSAGES")
                                .frame(width: 88, alignment: .trailing)
                            Text("TOKENS")
                                .frame(width: 88, alignment: .trailing)
                        }
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 8)
                        .background(theme.background.opacity(0.5))

                        Divider().background(theme.cardBorder)

                        ForEach(Array(viewModel.userStats.prefix(10).enumerated()), id: \.element.id) { idx, user in
                            userRow(rank: idx + 1, user: user)
                            if idx < min(viewModel.userStats.count, 10) - 1 {
                                Divider()
                                    .padding(.leading, Spacing.md)
                                    .background(theme.cardBorder.opacity(0.5))
                            }
                        }
                    }
                }
            }
        }
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder, lineWidth: 0.5)
        )
        .redacted(reason: viewModel.isLoading && viewModel.userStats.isEmpty ? .placeholder : [])
    }

    private func userRow(rank: Int, user: UserAnalytics) -> some View {
        // Construct user avatar URL using the correct profile image endpoint.
        // No authToken — CachedAsyncImage handles auth via cookies/session like AdminConsoleView does.
        let avatarURL: URL? = {
            guard let base = dependencies.apiClient?.baseURL else { return nil }
            return URL(string: base)?.appendingPathComponent("api/v1/users/\(user.userId)/profile/image")
        }()

        return HStack(spacing: 0) {
            // Rank
            Text("\(rank)")
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 28, alignment: .leading)

            // USER AVATAR
            HStack(spacing: 8) {
                UserAvatar(
                    size: 28,
                    imageURL: avatarURL,
                    name: user.displayName
                )
                Text(user.displayName)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Spacing.xs)

            // Messages
            Text("\(user.count)")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)

            // Tokens
            Text(AnalyticsViewModel.formatted(user.totalTokens))
                .scaledFont(size: 13)
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    // MARK: - Shared Table Components

    private func tableHeader(title: String, subtitle: String?) -> some View {
        HStack {
            Text(title)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.xs)
    }

    private func tableEmptyState(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary.opacity(0.5))
            Text(text)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 14)
                .foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.error)
            Spacer()
            Button("Retry") {
                Task { await viewModel.loadAll() }
            }
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .padding(Spacing.md)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Loading analytics…")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.opacity(0.6))
        .ignoresSafeArea()
    }

    // MARK: - Helpers

    /// Strips path/org prefix from model IDs: "anthropic/claude-3-5-sonnet" → "claude-3-5-sonnet"
    private func shortModelName(_ modelId: String) -> String {
        if let slash = modelId.lastIndex(of: "/") {
            return String(modelId[modelId.index(after: slash)...])
        }
        return modelId
    }

    /// Build a gradient color range array for the chart, one color per distinct model
    private var chartColorRange: [Color] {
        let ids = viewModel.chartModelIds
        return ids.prefix(chartColors.count).enumerated().map { idx, _ in
            chartColors[idx % chartColors.count]
        }
    }

    /// Calendar component to stride by (hours for 24h view, days otherwise)
    private var xAxisCalendarComponent: Calendar.Component {
        viewModel.selectedTimeRange == .last24Hours ? .hour : .day
    }

    /// How many units to skip between axis marks (keeps labels readable)
    private var xAxisStrideCount: Int {
        switch viewModel.selectedTimeRange {
        case .last24Hours: return 4   // every 4 hours → 6 labels
        case .last7Days:   return 1   // every day → 7 labels
        case .last30Days:  return 5   // every 5 days → 6 labels
        case .last90Days:  return 15  // every 15 days → 6 labels
        case .allTime:     return 30  // every 30 days
        }
    }

    /// Date format for x-axis labels
    private var xAxisDateFormat: Date.FormatStyle {
        if viewModel.selectedTimeRange == .last24Hours {
            return .dateTime.hour()
        } else {
            return .dateTime.month(.abbreviated).day()
        }
    }

    /// Look up token data for a given modelId from tokenStats
    private func tokenDataForModel(_ modelId: String) -> TokenUsageModel? {
        viewModel.tokenStats?.models.first { $0.modelId == modelId }
    }

    /// Total messages across all models (for % calculation)
    private var totalModelMessages: Int {
        viewModel.modelStats.reduce(0) { $0 + $1.count }
    }

    /// Builds the model avatar URL using the same endpoint as AIModel.resolveAvatarURL:
    /// `/api/v1/models/model/profile/image?id={modelId}`
    /// This works for any model ID without needing a client-side model lookup.
    private func modelAvatarURL(for modelId: String) -> URL? {
        guard let base = dependencies.apiClient?.baseURL, !modelId.isEmpty else { return nil }
        let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        var components = URLComponents(string: "\(normalizedBase)/api/v1/models/model/profile/image")
        components?.queryItems = [URLQueryItem(name: "id", value: modelId)]
        return components?.url
    }
}
