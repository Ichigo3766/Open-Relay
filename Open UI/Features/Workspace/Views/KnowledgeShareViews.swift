import SwiftUI

/// Generic `UIActivityViewController` wrapper for sharing files/URLs.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Banner listing files the server is still processing (`GET /knowledge/{id}/files/pending`).
struct KnowledgePendingBanner: View {
    @Environment(\.theme) private var theme
    let names: [String]

    var body: some View {
        if !names.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Processing \(names.count) file\(names.count == 1 ? "" : "s")…")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                    Text(names.prefix(3).joined(separator: ", "))
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(Spacing.sm)
            .background(theme.brandPrimary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
    }
}
