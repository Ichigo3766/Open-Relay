import SwiftUI

// MARK: - Generic Details Section

/// Renders a generic `<details>` block (anything other than a tool call or a
/// reasoning block) as a collapsible section, mirroring Open WebUI's
/// `Collapsible`:
/// - Header: chevron, a spinner while `done="false"`, and the `<summary>`
///   rendered with inline markdown (bold, italics, code, links, emoji).
/// - Collapsed by default; `<details open>` starts expanded.
/// - The body is rendered recursively through `AssistantMessageContent`, so
///   nested details, tool calls, thinking, code blocks, tables and images all
///   render exactly as they do at the top level, at any depth.
/// - Blocks with an empty body show a non-expandable header.
struct DetailsSectionView: View {
    let details: DetailsData
    var isStreaming: Bool = false
    var authToken: String? = nil
    var serverBaseURL: String? = nil
    var apiClient: APIClient? = nil

    @State private var isExpanded: Bool
    @Environment(\.theme) private var theme

    init(details: DetailsData, isStreaming: Bool = false, authToken: String? = nil,
         serverBaseURL: String? = nil, apiClient: APIClient? = nil) {
        self.details = details
        self.isStreaming = isStreaming
        self.authToken = authToken
        self.serverBaseURL = serverBaseURL
        self.apiClient = apiClient
        self._isExpanded = State(initialValue: details.startsOpen)
    }

    private var hasBody: Bool { !DetailsBlockScanner.isBlank(details.body) }
    private var inProgress: Bool { isStreaming && !details.isDone }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasBody else { return }
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .disabled(!hasBody)
            .accessibilityLabel(Text(Self.plainSummary(details.summary)))
            .accessibilityHint(hasBody ? Text(isExpanded ? "Collapse" : "Expand") : Text(""))

            if isExpanded && hasBody {
                // AnyView breaks the recursive opaque-type cycle
                // (AssistantMessageContent can itself contain DetailsSectionView).
                AnyView(
                    AssistantMessageContent(
                        content: details.body,
                        isStreaming: inProgress,
                        authToken: authToken,
                        serverBaseURL: serverBaseURL,
                        apiClient: apiClient
                    )
                )
                .padding(.leading, 22)
                .padding(.trailing, Spacing.sm)
                .padding(.bottom, Spacing.sm)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .fill(theme.surfaceContainer.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .strokeBorder(theme.brandPrimary.opacity(0.1), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .scaledFont(size: 9, weight: .bold)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 12)
                .opacity(hasBody ? 1 : 0.35)

            if inProgress {
                ProgressView()
                    .controlSize(.mini)
                    .tint(theme.brandPrimary)
            } else {
                Image(systemName: details.type == "code_interpreter" ? "terminal" : "text.justify.leading")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.brandPrimary.opacity(0.7))
            }

            Text(Self.inlineMarkdown(details.summary))
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
    }

    /// Renders inline markdown in the summary; falls back to the raw text.
    static func inlineMarkdown(_ summary: String) -> AttributedString {
        let cleaned = stripInlineHTML(summary)
        if let attributed = try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        ) {
            return attributed
        }
        return AttributedString(cleaned)
    }

    /// Plain-text summary for accessibility.
    static func plainSummary(_ summary: String) -> String {
        String(inlineMarkdown(summary).characters)
    }

    /// Removes simple inline HTML tags (`<b>`, `<code>`, `<br>`, …) that some
    /// filters put in summaries, keeping their text.
    private static func stripInlineHTML(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return text
            .replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</?[a-zA-Z][^<>]*>", with: "", options: .regularExpression)
    }
}
