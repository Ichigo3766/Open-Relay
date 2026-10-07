import SwiftUI

// MARK: - Read-Only Transcript Parts
//
// Small building blocks for `ReadOnlyChatTranscript` (the admin chat viewer). They draw
// the same things the main chat does — authenticated images, file chips — but without
// any of the main chat's editing/streaming machinery.

/// Extracts a file ID from either a bare ID or a `/api/v1/files/<id>/content` path.
func readOnlyFileId(_ file: ChatMessageFile) -> String? {
    guard let url = file.url, !url.isEmpty else { return nil }
    if !url.contains("/") { return url }
    let parts = url.split(separator: "/")
    if let idx = parts.firstIndex(of: "files"), idx + 1 < parts.count {
        return String(parts[idx + 1])
    }
    return url
}

func readOnlyIsImage(_ file: ChatMessageFile) -> Bool {
    file.type == "image" || (file.contentType ?? "").hasPrefix("image/")
}

/// Images in a message: one large, or a 2-column grid (max 4, with a "+N" overlay).
struct ReadOnlyImageGrid: View {
    let files: [ChatMessageFile]
    let apiClient: APIClient?
    var alignTrailing = false

    @Environment(\.theme) private var theme

    var body: some View {
        let shown = Array(files.prefix(4))
        let overflow = files.count - shown.count
        HStack(spacing: 0) {
            if alignTrailing { Spacer(minLength: 0) }
            Group {
                if shown.count == 1 {
                    tile(shown[0])
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, file in
                            tile(file)
                                .scaledToFill()
                                .frame(minHeight: 110, maxHeight: 130)
                                .clipped()
                                .overlay {
                                    if overflow > 0, index == shown.count - 1 {
                                        Color.black.opacity(0.45)
                                        Text("+\(overflow)")
                                            .scaledFont(size: 20, weight: .semibold)
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: 260)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                }
            }
            if !alignTrailing { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private func tile(_ file: ChatMessageFile) -> some View {
        if let id = readOnlyFileId(file) {
            AuthenticatedImageView(fileId: id, apiClient: apiClient)
        } else {
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .fill(theme.surfaceContainer)
                .frame(height: 100)
                .overlay {
                    Image(systemName: "photo")
                        .scaledFont(size: 24)
                        .foregroundStyle(theme.textTertiary)
                }
        }
    }
}

/// A non-image attachment: icon, name and extension.
struct ReadOnlyFileChip: View {
    let file: ChatMessageFile
    @Environment(\.theme) private var theme

    var body: some View {
        let name = file.name ?? file.url ?? "File"
        let ext = (name as NSString).pathExtension.lowercased()
        HStack(spacing: Spacing.xs) {
            Image(systemName: "doc")
                .scaledFont(size: 12)
                .foregroundStyle(theme.brandPrimary)
            Text(name)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !ext.isEmpty {
                Text(ext.uppercased())
                    .scaledFont(size: 9, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(theme.surfaceContainer.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    }
}
