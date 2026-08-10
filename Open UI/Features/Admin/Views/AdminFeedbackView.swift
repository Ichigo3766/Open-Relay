import SwiftUI

// MARK: - Admin Feedback View

/// The admin "Evaluations" tab — paginated list of all user feedback records.
struct AdminFeedbackView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var viewModel = AdminFeedbackViewModel()
    @State private var selectedItem: FeedbackItem? = nil
    @State private var detailItem: FeedbackItem? = nil
    @State private var isLoadingDetail = false

    private var baseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                loadingState
            } else if viewModel.items.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
                feedbackList
            }
        }
        .refreshable {
            await viewModel.loadFeedbacks()
        }
        .sheet(item: $selectedItem) { item in
            feedbackDetailSheet(for: item)
        }
        .task {
            viewModel.configure(apiClient: dependencies.apiClient)
            await viewModel.loadFeedbacks()
        }
    }

    // MARK: - Feedback List

    private var feedbackList: some View {
        List {
            if let error = viewModel.errorMessage {
                errorBanner(error)
                    .listRowInsets(EdgeInsets(top: Spacing.sm, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if !viewModel.isLoading && !viewModel.items.isEmpty {
                HStack {
                    Text("Feedback \(viewModel.total)")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                }
                .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.screenPadding, bottom: Spacing.xs, trailing: Spacing.screenPadding))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            ForEach(viewModel.items) { item in
                FeedbackRow(item: item, baseURL: baseURL, authToken: authToken)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedItem = item
                        Task {
                            if let detail = await viewModel.loadDetail(id: item.id) {
                                detailItem = detail
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await viewModel.deleteFeedback(id: item.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .onAppear {
                        if item.id == viewModel.items.last?.id {
                            Task { await viewModel.loadMore() }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.vertical, Spacing.lg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Detail Sheet

    @ViewBuilder
    private func feedbackDetailSheet(for item: FeedbackItem) -> some View {
        // Use the detailed version if it has loaded (it will have snapshot),
        // otherwise fall back to the list item.
        let displayItem = (detailItem?.id == item.id) ? detailItem! : item
        AdminFeedbackDetailSheet(item: displayItem)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
            .onDisappear { detailItem = nil }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Loading feedback…")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "hand.thumbsup")
                .scaledFont(size: 40)
                .foregroundStyle(theme.textTertiary)
            Text("No feedback records found.")
                .scaledFont(size: 16)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

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
                Task { await viewModel.loadFeedbacks() }
            }
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.brandPrimary)
        }
        .padding(Spacing.md)
        .background(theme.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
    }
}

// MARK: - Feedback Row

private struct FeedbackRow: View {
    let item: FeedbackItem
    let baseURL: String
    let authToken: String?
    @Environment(\.theme) private var theme

    private var avatarURL: URL? {
        guard !baseURL.isEmpty else { return nil }
        let userId = item.userId
        guard !userId.isEmpty else { return nil }
        return URL(string: "\(baseURL)/api/v1/users/\(userId)/profile/image")
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            // User avatar
            UserAvatar(
                size: 40,
                imageURL: avatarURL,
                name: item.user?.name ?? "Unknown",
                authToken: authToken
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Text(item.user?.name ?? "Unknown user")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    // Thumbs icon
                    Image(systemName: item.isPositive ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                        .scaledFont(size: 13)
                        .foregroundStyle(item.isPositive ? Color.green : theme.error)
                }

                HStack(spacing: Spacing.xs) {
                    if let modelId = item.data?.modelId, !modelId.isEmpty {
                        Text(modelId)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(item.relativeTimeString)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }

                // Tags row if present
                if let tags = item.data?.tags, !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            TagChip(label: tag, color: theme.brandPrimary)
                        }
                        if tags.count > 3 {
                            Text("+\(tags.count - 3)")
                                .scaledFont(size: 10)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 10)
    }
}

// MARK: - Feedback Detail Sheet

private struct AdminFeedbackDetailSheet: View {
    let item: FeedbackItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {

                    // Rating header card
                    ratingCard

                    // User info
                    infoCard

                    // Prompt & Response
                    if item.snapshot != nil {
                        conversationSection
                    }

                    // Feedback details
                    feedbackDetailsSection

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.md)
            }
            .background(theme.background)
            .navigationTitle("Feedback Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Rating Card

    private var ratingCard: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(item.isPositive ? Color.green.opacity(0.12) : theme.error.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: item.isPositive ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .scaledFont(size: 22)
                    .foregroundStyle(item.isPositive ? Color.green : theme.error)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.isPositive ? "Positive Feedback" : "Negative Feedback")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                if let rating = item.data?.rating {
                    Text("Rating: \(rating > 0 ? "+\(rating)" : "\(rating)")")
                        .scaledFont(size: 13)
                        .foregroundStyle(item.isPositive ? Color.green : theme.error)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(item.relativeTimeString)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
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

    // MARK: - Info Card

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            detailSectionHeader("Details")

            VStack(spacing: 0) {
                infoRow(label: "User", value: item.user?.name ?? item.userId)
                Divider().padding(.leading, Spacing.md)
                infoRow(label: "Email", value: item.user?.email ?? "—")
                Divider().padding(.leading, Spacing.md)
                infoRow(label: "Model", value: item.data?.modelId ?? item.meta?.modelId ?? "—")
                if let chatId = item.meta?.chatId {
                    Divider().padding(.leading, Spacing.md)
                    infoRow(label: "Chat ID", value: String(chatId.prefix(16)) + "…")
                }
            }
            .background(theme.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Conversation Section

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            detailSectionHeader("Conversation")

            if let prompt = item.promptMessage {
                messageBlock(role: "User", content: prompt.content, color: theme.brandPrimary)
            }

            if let response = item.ratedMessage {
                messageBlock(role: response.modelName ?? "Assistant", content: response.content, color: Color.green)
            }

            if item.promptMessage == nil && item.ratedMessage == nil {
                Text("Snapshot not available for this record.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            }
        }
    }

    // MARK: - Feedback Details Section

    private var feedbackDetailsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            detailSectionHeader("Feedback")

            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Reason
                if let reason = item.data?.reason, !reason.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reason")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .textCase(.uppercase)
                        Text(reason)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textPrimary)
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )
                }

                // Tags
                if let tags = item.data?.tags, !tags.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .textCase(.uppercase)
                        FlowLayout(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                TagChip(label: tag, color: theme.brandPrimary)
                            }
                        }
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )
                }

                // Comment
                if let comment = item.data?.comment, !comment.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Comment")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .textCase(.uppercase)
                        Text(comment)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textPrimary)
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                            .strokeBorder(theme.cardBorder, lineWidth: 0.5)
                    )
                }

                if (item.data?.reason == nil || item.data?.reason?.isEmpty == true)
                    && (item.data?.tags == nil || item.data?.tags?.isEmpty == true)
                    && (item.data?.comment == nil || item.data?.comment?.isEmpty == true) {
                    Text("No additional feedback details provided.")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surfaceContainer)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                }
            }
        }
    }

    // MARK: - Helpers

    private func detailSectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .textCase(.uppercase)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    private func messageBlock(role: String, content: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: 6, height: 6)
                Text(role)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(color)
                    .textCase(.uppercase)
            }
            Text(content)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Tag Chip

private struct TagChip: View {
    let label: String
    let color: Color
    @Environment(\.theme) private var theme

    var body: some View {
        Text(label)
            .scaledFont(size: 11, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }
}

// MARK: - Flow Layout

/// A simple horizontal-wrapping layout for tag chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > containerWidth && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        y += rowHeight
        return CGSize(width: containerWidth, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
