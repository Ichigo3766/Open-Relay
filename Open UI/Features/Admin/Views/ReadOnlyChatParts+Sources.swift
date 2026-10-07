import SwiftUI

/// "3 Sources" pill with favicons. Tapping opens the full list.
struct ReadOnlySourcesPill: View {
    let sources: [ChatSourceReference]
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.xs) {
                HStack(spacing: -4) {
                    ForEach(Array(sources.prefix(3).enumerated()), id: \.offset) { _, source in
                        badge(source)
                    }
                }
                Text("\(sources.count) Source\(sources.count == 1 ? "" : "s")")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(theme.surfaceContainer.opacity(0.6))
            .clipShape(Capsule())
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private func badge(_ source: ChatSourceReference) -> some View {
        let domain: String? = {
            guard let url = source.resolvedURL, let host = URL(string: url)?.host, !host.isEmpty else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }()
        if let domain, let icon = URL(string: "https://www.google.com/s2/favicons?sz=32&domain=\(domain)") {
            AsyncImage(url: icon) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill().frame(width: 18, height: 18).clipShape(Circle())
                } else {
                    letter(source)
                }
            }
        } else {
            letter(source)
        }
    }

    private func letter(_ source: ChatSourceReference) -> some View {
        Circle()
            .fill(theme.brandPrimary.opacity(0.2))
            .frame(width: 18, height: 18)
            .overlay(
                Text(String((source.title ?? source.url ?? "?").prefix(1)).uppercased())
                    .scaledFont(size: 8, weight: .bold)
                    .foregroundStyle(theme.brandPrimary)
            )
    }
}

/// A one-line error under a message.
struct ReadOnlyErrorLine: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 12)
            Text(text)
                .scaledFont(size: 12, weight: .medium)
                .lineLimit(2)
        }
        .foregroundStyle(theme.error)
        .padding(.top, Spacing.xs)
    }
}
