import SwiftUI
import PhotosUI

/// "Background Image" row for the model editor (web parity).
/// - `currentURL`: the saved `meta.background_image_url` (server path), if any.
/// - `pending`: a newly picked, validated image that will upload on Save.
/// - `removed`: the user cleared the image; Save writes `background_image_url = null`.
struct ModelBackgroundSection: View {
    @Environment(\.theme) private var theme

    let currentURL: String?
    let serverBaseURL: String
    let authToken: String?
    @Binding var pending: ModelBackgroundImage.Validated?
    @Binding var removed: Bool
    @State private var pickerItem: PhotosPickerItem?
    @State private var error: String?

    private var hasImage: Bool { pending != nil || (!removed && !(currentURL ?? "").isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Background Image")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)
            Text("Shown behind the chat when this model is selected. PNG, JPEG, WebP, or GIF. Up to 5 MiB and 25 megapixels.")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)

            HStack(spacing: Spacing.md) {
                preview
                    .frame(width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.cardBorder, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(hasImage ? "Replace" : "Upload", systemImage: "photo")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                    }
                    if hasImage {
                        Button(role: .destructive) {
                            pending = nil
                            removed = true
                            Haptics.play(.light)
                        } label: {
                            Label("Remove", systemImage: "trash").scaledFont(size: 14)
                        }
                    }
                }
                Spacer()
            }
            if let error {
                Text(error).scaledFont(size: 12).foregroundStyle(theme.error)
            }
        }
        .padding(Spacing.md)
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let pending {
            Image(uiImage: pending.preview).resizable().scaledToFill()
        } else if hasImage, let url = resolvedURL {
            CachedAsyncImage(url: url, authToken: authToken) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(theme.shimmerBase).shimmer()
            }
        } else {
            ZStack {
                Rectangle().fill(theme.surfaceContainer)
                Image(systemName: "photo").foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var resolvedURL: URL? {
        guard let path = currentURL, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        let base = serverBaseURL.hasSuffix("/") ? String(serverBaseURL.dropLast()) : serverBaseURL
        return URL(string: base + path)
    }

    private func load(_ item: PhotosPickerItem) async {
        error = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ModelBackgroundImage.ValidationError.invalid }
            let validated = try ModelBackgroundImage.prepare(data)
            pending = validated
            removed = false
            Haptics.play(.light)
        } catch {
            self.error = error.localizedDescription
            Haptics.notify(.error)
        }
        pickerItem = nil
    }
}
