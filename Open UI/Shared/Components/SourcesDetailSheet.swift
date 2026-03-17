import SwiftUI

/// A bottom sheet that displays the full list of source references for a message.
///
/// Matches the Flutter app's expandable sources list with numbered items,
/// favicons, and tappable URLs.
struct SourcesDetailSheet: View {
    let sources: [ChatSourceReference]

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                        sourceRow(source, index: index + 1)
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xxl)
            }
            .background(theme.background)
            .navigationTitle("\(sources.count) Source\(sources.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 20)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Source Row

    private func sourceRow(_ source: ChatSourceReference, index: Int) -> some View {
        let url = resolveURL(for: source)
        let isLink = url != nil

        return Button {
            if let url, let parsed = URL(string: url) {
                UIApplication.shared.open(parsed)
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                // Number badge
                Text("\(index)")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 24, height: 24)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Favicon
                if let url, let domain = extractDomain(url) {
                    AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=32&domain=\(domain)")) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        default:
                            Image(systemName: "globe")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                                .frame(width: 16, height: 16)
                        }
                    }
                } else {
                    Image(systemName: "doc.text")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 16, height: 16)
                }

                // URL or title
                VStack(alignment: .leading, spacing: 2) {
                    if let title = source.title, !title.isEmpty, !title.hasPrefix("http") {
                        Text(title)
                            .scaledFont(size: 14)
                            .fontWeight(.medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                    }

                    if let url {
                        Text(url)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(isLink ? theme.brandPrimary : theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let title = source.title, !title.isEmpty {
                        Text(title)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text("Source \(index)")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                    }

                    if let snippet = source.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if isLink {
                    Image(systemName: "arrow.up.right")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.vertical, Spacing.sm)
            .padding(.horizontal, Spacing.sm)
            .background(theme.surfaceContainer.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isLink)
    }

    // MARK: - Helpers

    private func resolveURL(for source: ChatSourceReference) -> String? {
        source.resolvedURL
    }

    private func extractDomain(_ url: String) -> String? {
        guard let parsed = URL(string: url) else { return nil }
        var host = parsed.host ?? ""
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host.isEmpty ? nil : host
    }
}