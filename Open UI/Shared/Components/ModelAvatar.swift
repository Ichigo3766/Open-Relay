import SwiftUI

// MARK: - Model Avatar

/// Displays a model's avatar image with automatic fallback UI and image caching.
///
/// The avatar can display:
/// - A network image loaded from a URL (cached via ``ImageCacheService``)
/// - A fallback showing the first letter of the model name
/// - A brain icon when no name is available
///
/// Usage:
/// ```swift
/// ModelAvatar(size: 32, imageURL: model.avatarURL, label: model.name)
/// ```
struct ModelAvatar: View {
    let size: CGFloat
    var imageURL: URL?
    var label: String?
    /// Optional Bearer token for authenticated model avatar endpoints.
    var authToken: String?

    @Environment(\.theme) private var theme

    var body: some View {
        if let imageURL {
            CachedAsyncImage(url: imageURL, authToken: authToken) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
            } placeholder: {
                shimmerPlaceholder
            }
            .accessibilityLabel(Text(label ?? String(localized: "AI Model")))
        } else {
            fallbackView
        }
    }

    private var fallbackView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                .fill(theme.brandPrimary.opacity(0.12))
            RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                .strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 0.5)

            if let initial = label?.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(initial).uppercased())
                    .scaledFont(size: size * 0.38, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.brandPrimary)
            } else {
                Image(systemName: "brain")
                    .scaledFont(size: size * 0.4, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(label ?? String(localized: "AI Model")))
    }

    private var shimmerPlaceholder: some View {
        RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
            .fill(theme.shimmerBase)
            .frame(width: size, height: size)
            .shimmer()
    }
}

// MARK: - User Avatar

/// Displays a user avatar with an image or initials fallback.
///
/// Uses ``ImageCacheService`` for efficient image loading and caching.
struct UserAvatar: View {
    let size: CGFloat
    var imageURL: URL?
    var name: String?
    /// Optional Bearer token for authenticated user avatar endpoints.
    var authToken: String?

    @Environment(\.theme) private var theme

    var body: some View {
        if let imageURL {
            CachedAsyncImage(url: imageURL, authToken: authToken) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } placeholder: {
                Circle()
                    .fill(theme.shimmerBase)
                    .frame(width: size, height: size)
                    .shimmer()
            }
            .accessibilityLabel(Text(name ?? String(localized: "User")))
        } else {
            initialsView
        }
    }

    private var initialsView: some View {
        ZStack {
            Circle()
                .fill(theme.brandPrimary.opacity(0.15))
            Circle()
                .strokeBorder(theme.brandPrimary.opacity(0.3), lineWidth: 0.5)

            if let initial = name?.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(initial).uppercased())
                    .scaledFont(size: size * 0.4, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.brandPrimary)
            } else {
                Image(systemName: "person.fill")
                    .scaledFont(size: size * 0.4, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(name ?? String(localized: "User")))
    }
}

// MARK: - Previews

#Preview("Avatars") {
    HStack(spacing: Spacing.md) {
        ModelAvatar(size: 40, label: "GPT-4")
        ModelAvatar(size: 40, label: nil)
        ModelAvatar(size: 32, label: "Claude")
        UserAvatar(size: 40, name: "Alice")
        UserAvatar(size: 40, name: nil)
    }
    .padding()
    .themed()
}
